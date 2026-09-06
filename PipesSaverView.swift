// PipesSaverView -- 3D Pipes screen saver, rendered natively and matched
// pixel-for-pixel against the three.js recreation of the Windows original.
//
// Fidelity design. The reference is ~/Software/pipes/index.html (the web
// recreation, itself checked against the NT 4 SDK source). This file ports
// it rather than approximating it:
//   * Same random generator (mulberry32) consumed in the same order, so a
//     seed produces the same pipe network, colours, joints and camera.
//   * Same geometry: three.js CylinderBufferGeometry(r, r, 1, 10, 4, open)
//     and SphereBufferGeometry(r, 8, 8), with the same vertex normals,
//     placed with the same quaternion maths.
//   * Same camera: PerspectiveCamera(45, aspect, 1, 1e5) at (0,0,14) or
//     (14,0,0) rotated 90 degrees about a random (unnormalised!) axis,
//     lookAt(origin), then OrbitControls.update()'s spherical round trip.
//   * Same shading: MeshPhongMaterial (specular 0xa9fcff, shininess 100,
//     emissive = colour * 0.3) under AmbientLight(0x111111) and a 0.9
//     DirectionalLight from (-1.2, 1.5, 0.5), evaluated with r98's exact
//     Blinn-Phong terms, per fragment, on interpolated normals.
//   * Same rasterisation model: triangles sampled at pixel centres, depth
//     LEQUAL, perspective-correct attribute interpolation, no antialiasing.
// compare/ holds the scripts that render both with one seed and diff them.
//
// Energy design. Nothing is redrawn: each new segment is rasterised once into
// a persistent colour + depth buffer, and frames reach the compositor through
// double-buffered IOSurfaces with dirty-rect copies (see pushFrame).
//
// Lifecycle notes (macOS 14+ legacyScreenSaver host, verified with logging):
//   * The host is a view service composited remotely by WallpaperAgent; this
//     process never sees its window as visible, so never gate on occlusion.
//   * Each activation creates a NEW view, re-fires startAnimation() on every
//     OLD view first, never calls stopAnimation(), and never releases views.
//     Only the newest instance renders; com.apple.screensaver.willstop /
//     didstop are the stop signal.
//   * Build with -parse-as-library or Swift globals stay uninitialised.

import AppKit
import ScreenSaver
import IOSurface
import os.log

private let pipesLog = OSLog(subsystem: "com.cmod.PipesSaver", category: "saver")
private func slog(_ msg: String) {
    os_log("%{public}@", log: pipesLog, type: .default, msg as NSString)
}

/// Every live instance in this host process (weak), for newest-wins logic.
private var liveInstances = NSHashTable<PipesSaverView>.weakObjects()

// MARK: - TUNING ------------------------------------------------------------

enum Tuning {
    /// Update rounds (and frame pushes) per second; the reference targets 30.
    static let tickHz: Double = 30
    /// 1500 = one framebuffer pixel per point (matches the reference page at
    /// pixel ratio 1). Lower values give integer-scaled chunky pixels.
    static let targetFramebufferWidth: CGFloat = 1500
    /// Pipe palette, as in the reference page (red, green, blue, amber).
    static let colors: [UInt32] = [0xd83a3a, 0x39b54a, 0x2f6fdc, 0xe0b020]
    /// Seconds between wipes (options.interval in the page).
    static let runSeconds: ClosedRange<Double> = 30...50
    static let pipeCountRange = 4...6
    static let teapotChance = 1.0 / 200.0
    static let candyTeapotChance = 1.0 / 20.0
    static let candyRunChance = 1.0 / 20.0
    static let ballJointChance = 0.0          // "elbow" joint mode in the page
    static let gridHalf = 10                  // gridBounds -10...10
    static let pipeRadius = 0.2
    static let ballJointRadius = 0.2 * 1.5
    static let teapotSize = 0.2 * 1.5
    static let wipeSeconds = 2.0
}

// MARK: - Deterministic random (mulberry32, identical to the page) ----------

struct Mulberry32 {
    var a: UInt32
    mutating func next() -> Double {
        a &+= 0x6D2B79F5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
}

/// JavaScript Math.round: ties toward +infinity.
@inline(__always) private func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

// MARK: - Vector maths (Double, mirroring three.js which computes in JS numbers)

struct V3: Equatable {
    var x: Double, y: Double, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, s: Double) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var lengthSq: Double { x * x + y * y + z * z }
    var length: Double { lengthSq.squareRoot() }
    /// three.js Vector3.normalize(): divides by (length || 1).
    var normalized: V3 { let l = length; let d = l == 0 ? 1 : l; return V3(x / d, y / d, z / d) }
}

struct Quat {
    var x: Double, y: Double, z: Double, w: Double
    static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    /// three.js Quaternion.setFromUnitVectors (r98).
    static func fromUnitVectors(_ from: V3, _ to: V3) -> Quat {
        let eps = 0.000001
        var r = from.dot(to) + 1
        var v: V3
        if r < eps {
            r = 0
            if abs(from.x) > abs(from.z) { v = V3(-from.y, from.x, 0) } else { v = V3(0, -from.z, from.y) }
        } else {
            v = from.cross(to)
        }
        return Quat(x: v.x, y: v.y, z: v.z, w: r).normalized
    }

    /// three.js Quaternion.setFromEuler, order XYZ.
    static func fromEulerXYZ(_ x: Double, _ y: Double, _ z: Double) -> Quat {
        let c1 = cos(x / 2), c2 = cos(y / 2), c3 = cos(z / 2)
        let s1 = sin(x / 2), s2 = sin(y / 2), s3 = sin(z / 2)
        return Quat(x: s1 * c2 * c3 + c1 * s2 * s3,
                    y: c1 * s2 * c3 - s1 * c2 * s3,
                    z: c1 * c2 * s3 + s1 * s2 * c3,
                    w: c1 * c2 * c3 - s1 * s2 * s3)
    }

    var normalized: Quat {
        let l = (x * x + y * y + z * z + w * w).squareRoot()
        if l == 0 { return .identity }
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }

    /// three.js Vector3.applyQuaternion.
    func rotate(_ v: V3) -> V3 {
        let ix = w * v.x + y * v.z - z * v.y
        let iy = w * v.y + z * v.x - x * v.z
        let iz = w * v.z + x * v.y - y * v.x
        let iw = -x * v.x - y * v.y - z * v.z
        return V3(ix * w + iw * -x + iy * -z - iz * -y,
                  iy * w + iw * -y + iz * -x - ix * -z,
                  iz * w + iw * -z + ix * -y - iy * -x)
    }
}

/// three.js Matrix4.makeRotationAxis(axis, angle) applied to a point --
/// note the page passes an UNNORMALISED axis, so this is generally not a
/// pure rotation. Reproduced as-is.
private func applyRotationAxisMatrix(_ v: V3, axis: V3, angle: Double) -> V3 {
    let c = cos(angle), s = sin(angle), t = 1 - c
    let x = axis.x, y = axis.y, z = axis.z
    let tx = t * x, ty = t * y
    let r0 = V3(tx * x + c, tx * y - s * z, tx * z + s * y)
    let r1 = V3(tx * y + s * z, ty * y + c, ty * z - s * x)
    let r2 = V3(tx * z - s * y, ty * z + s * x, t * z * z + c)
    return V3(r0.dot(v), r1.dot(v), r2.dot(v))
}

// MARK: - Camera (PerspectiveCamera + lookAt + OrbitControls.update) --------

struct Camera {
    var position = V3(0, 0, 14)
    // Rotation columns: the camera's local x, y, z axes in world space.
    var ax = V3(1, 0, 0), ay = V3(0, 1, 0), az = V3(0, 0, 1)
    let fov = 45.0, near = 1.0, far = 100000.0
    var aspect: Double

    /// three.js Matrix4.lookAt(eye, target, up=(0,1,0)) as used by cameras.
    mutating func lookAt(_ target: V3) {
        var z = position - target
        if z.lengthSq == 0 { z.z = 1 }
        z = z.normalized
        let up = V3(0, 1, 0)
        var x = up.cross(z)
        if x.lengthSq == 0 {
            if abs(up.z) == 1 { z.x += 0.0001 } else { z.z += 0.0001 }
            z = z.normalized
            x = up.cross(z)
        }
        x = x.normalized
        ax = x; az = z; ay = z.cross(x)
    }

    /// OrbitControls.update() with no input: the position takes a round trip
    /// through spherical coordinates (with makeSafe) and lookAt runs again.
    mutating func orbitControlsUpdate(target: V3 = V3(0, 0, 0)) {
        let offset = position - target
        let radius = offset.length
        var theta = 0.0, phi = 0.0
        if radius != 0 {
            theta = atan2(offset.x, offset.z)
            phi = acos(min(1, max(-1, offset.y / radius)))
        }
        let eps = 0.000001
        phi = max(0, min(Double.pi, phi))
        phi = max(eps, min(Double.pi - eps, phi))
        let sinPhiRadius = sin(phi) * radius
        position = target + V3(sinPhiRadius * sin(theta), cos(phi) * radius, sinPhiRadius * cos(theta))
        lookAt(target)
    }

    func toView(_ p: V3) -> V3 { let d = p - position; return V3(d.dot(ax), d.dot(ay), d.dot(az)) }
    func toViewDir(_ v: V3) -> V3 { V3(v.dot(ax), v.dot(ay), v.dot(az)) }

    /// makePerspective terms: clip = (sx*x, sy*y, c*z + d, -z).
    var projection: (sx: Double, sy: Double, c: Double, d: Double) {
        let top = near * tan(Double.pi / 180 * 0.5 * fov)
        let height = 2 * top, width = aspect * height
        let sx = 2 * near / width, sy = 2 * near / height
        let c = -(far + near) / (far - near), d = -2 * far * near / (far - near)
        return (sx, sy, c, d)
    }
}

// MARK: - Meshes (three.js r98 geometry generators) -------------------------

struct Mesh {
    var positions: [V3] = []
    var normals: [V3] = []
    var indices: [Int] = []
    /// three.js stores attributes in Float32Arrays; round the same way.
    mutating func roundToFloat32() {
        func f(_ v: V3) -> V3 { V3(Double(Float(v.x)), Double(Float(v.y)), Double(Float(v.z))) }
        positions = positions.map(f)
        normals = normals.map(f)
    }
}

enum MeshFactory {
    /// CylinderBufferGeometry(radiusTop, radiusBottom, height, radial, heightSeg, openEnded=true)
    static func cylinder(radiusTop: Double, radiusBottom: Double, height: Double,
                         radialSegments: Int, heightSegments: Int) -> Mesh {
        var m = Mesh()
        let halfHeight = height / 2
        let slope = (radiusBottom - radiusTop) / height
        var grid: [[Int]] = []
        var index = 0
        for y in 0...heightSegments {
            var row: [Int] = []
            let v = Double(y) / Double(heightSegments)
            let radius = v * (radiusBottom - radiusTop) + radiusTop
            for x in 0...radialSegments {
                let u = Double(x) / Double(radialSegments)
                let theta = u * 2 * Double.pi
                let sinTheta = sin(theta), cosTheta = cos(theta)
                m.positions.append(V3(radius * sinTheta, -v * height + halfHeight, radius * cosTheta))
                m.normals.append(V3(sinTheta, slope, cosTheta).normalized)
                row.append(index); index += 1
            }
            grid.append(row)
        }
        for x in 0..<radialSegments {
            for y in 0..<heightSegments {
                let a = grid[y][x], b = grid[y + 1][x], c = grid[y + 1][x + 1], d = grid[y][x + 1]
                m.indices += [a, b, d, b, c, d]
            }
        }
        m.roundToFloat32()
        return m
    }

    /// SphereBufferGeometry(radius, widthSegments, heightSegments)
    static func sphere(radius: Double, widthSegments: Int, heightSegments: Int) -> Mesh {
        var m = Mesh()
        var grid: [[Int]] = []
        var index = 0
        let thetaStart = 0.0, thetaLength = Double.pi, phiStart = 0.0, phiLength = 2 * Double.pi
        for iy in 0...heightSegments {
            var row: [Int] = []
            let v = Double(iy) / Double(heightSegments)
            for ix in 0...widthSegments {
                let u = Double(ix) / Double(widthSegments)
                let p = V3(-radius * cos(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength),
                           radius * cos(thetaStart + v * thetaLength),
                           radius * sin(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength))
                m.positions.append(p)
                m.normals.append(p.normalized)
                row.append(index); index += 1
            }
            grid.append(row)
        }
        let thetaEnd = thetaStart + thetaLength
        for iy in 0..<heightSegments {
            for ix in 0..<widthSegments {
                let a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1]
                if iy != 0 || thetaStart > 0 { m.indices += [a, b, d] }
                if iy != heightSegments - 1 || thetaEnd < Double.pi { m.indices += [b, c, d] }
            }
        }
        m.roundToFloat32()
        return m
    }
}

// MARK: - Material and lighting (MeshPhongMaterial under the page's lights) --

struct Material {
    var color: (Float, Float, Float)
    var emissive: (Float, Float, Float)
    static let specular: (Float, Float, Float) = (0xa9 / 255.0, 0xfc / 255.0, 0xff / 255.0)
    static let shininess: Float = 100
    static let ambient: Float = 0x11 / 255.0        // AmbientLight(0x111111)
    static let lightIntensity: Float = 0.9          // DirectionalLight(0xffffff, 0.9)
    static let lightPosition = V3(-1.2, 1.5, 0.5)   // target: origin

    init(rgb: UInt32) {
        let r = Float((rgb >> 16) & 0xff) / 255, g = Float((rgb >> 8) & 0xff) / 255, b = Float(rgb & 0xff) / 255
        color = (r, g, b)
        emissive = (r * 0.3, g * 0.3, b * 0.3)   // new THREE.Color(color).multiplyScalar(0.3)
    }
}

// MARK: - Framebuffer + rasteriser --------------------------------------------

/// Framebuffer rectangle, half-open: x0 <= x < x1, y0 <= y < y1 (top-down rows).
struct DirtyRect {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    func union(_ o: DirtyRect) -> DirtyRect {
        DirtyRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

final class Framebuffer {
    let width: Int, height: Int
    private(set) var pixels: [UInt32]     // BGRA little-endian, opaque; row 0 = top
    private var depth: [Float]            // NDC z, +inf = cleared
    private(set) var dirtyRects: [DirtyRect] = []
    let fullRect: DirtyRect
    var dirty: Bool { !dirtyRects.isEmpty }

    // Camera terms in Float, refreshed by setCamera().
    private var camPos = (Float(0), Float(0), Float(0))
    private var camAx = (Float(1), Float(0), Float(0)), camAy = (Float(0), Float(1), Float(0)), camAz = (Float(0), Float(0), Float(1))
    private var projSx: Float = 1, projSy: Float = 1, projC: Float = -1, projD: Float = -2
    private var lightDirView = (Float(0), Float(0), Float(1))
    private var near: Float = 1

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        fullRect = DirtyRect(x0: 0, y0: 0, x1: width, y1: height)
        pixels = [UInt32](repeating: 0xFF000000, count: width * height)
        depth = [Float](repeating: .greatestFiniteMagnitude, count: width * height)
    }

    func clear() {
        pixels.withUnsafeMutableBufferPointer { $0.update(repeating: 0xFF000000) }
        depth.withUnsafeMutableBufferPointer { $0.update(repeating: .greatestFiniteMagnitude) }
        dirtyRects = [fullRect]
    }

    func clearDirty() { dirtyRects.removeAll(keepingCapacity: true) }

    private func markDirty(_ r: DirtyRect) {
        let c = DirtyRect(x0: max(0, r.x0), y0: max(0, r.y0), x1: min(width, r.x1), y1: min(height, r.y1))
        guard !c.isEmpty else { return }
        dirtyRects.append(c)
        if dirtyRects.count > 128 {
            dirtyRects = [dirtyRects.dropFirst().reduce(dirtyRects[0]) { $0.union($1) }]
        }
    }

    func setCamera(_ cam: Camera) {
        camPos = (Float(cam.position.x), Float(cam.position.y), Float(cam.position.z))
        camAx = (Float(cam.ax.x), Float(cam.ax.y), Float(cam.ax.z))
        camAy = (Float(cam.ay.x), Float(cam.ay.y), Float(cam.ay.z))
        camAz = (Float(cam.az.x), Float(cam.az.y), Float(cam.az.z))
        let p = cam.projection
        projSx = Float(p.sx); projSy = Float(p.sy); projC = Float(p.c); projD = Float(p.d)
        near = Float(cam.near)
        // DirectionalLight direction in view space: normalize(viewMatrix * (lightPos - target)).
        let l = cam.toViewDir(Material.lightPosition).normalized
        lightDirView = (Float(l.x), Float(l.y), Float(l.z))
    }

    /// Fill an axis-aligned rectangle black (the dissolve wipe's canvas2d squares).
    func fillBlack(x: Int, y: Int, w: Int, h: Int) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        guard x1 > x0, y1 > y0 else { return }
        pixels.withUnsafeMutableBufferPointer { px in
            for yy in y0..<y1 { for xx in x0..<x1 { px[yy * width + xx] = 0xFF000000 } }
        }
        markDirty(DirtyRect(x0: x0, y0: y0, x1: x1, y1: y1))
    }

    private struct SV {  // screen-space vertex
        var x: Float, y: Float, z: Float, invW: Float
        var nx: Float, ny: Float, nz: Float     // view normal / w
        var px: Float, py: Float, pz: Float     // view position / w
    }

    /// Rasterise a mesh placed at `position` with `rotation` (three.js
    /// Object3D matrix = compose(position, quaternion, scale 1)).
    func draw(_ mesh: Mesh, position: V3, rotation: Quat, material: Material) {
        let W = Float(width), H = Float(height)
        var sv = [SV](); sv.reserveCapacity(mesh.positions.count)
        var behind = [Bool](repeating: false, count: mesh.positions.count)
        var bbox: DirtyRect? = nil
        for i in 0..<mesh.positions.count {
            let pw = rotation.rotate(mesh.positions[i]) + position
            let nw = rotation.rotate(mesh.normals[i])
            // view space (Float from here on, like the GPU)
            let dx = Float(pw.x) - camPos.0, dy = Float(pw.y) - camPos.1, dz = Float(pw.z) - camPos.2
            let vx = dx * camAx.0 + dy * camAx.1 + dz * camAx.2
            let vy = dx * camAy.0 + dy * camAy.1 + dz * camAy.2
            let vz = dx * camAz.0 + dy * camAz.1 + dz * camAz.2
            let nX = Float(nw.x), nY = Float(nw.y), nZ = Float(nw.z)
            var tnx = nX * camAx.0 + nY * camAx.1 + nZ * camAx.2
            var tny = nX * camAy.0 + nY * camAy.1 + nZ * camAy.2
            var tnz = nX * camAz.0 + nY * camAz.1 + nZ * camAz.2
            let nl = (tnx * tnx + tny * tny + tnz * tnz).squareRoot()
            if nl > 0 { tnx /= nl; tny /= nl; tnz /= nl }   // vNormal = normalize(normalMatrix * normal)
            let wc = -vz
            if wc < near { behind[i] = true; sv.append(SV(x: 0, y: 0, z: 0, invW: 0, nx: 0, ny: 0, nz: 0, px: 0, py: 0, pz: 0)); continue }
            let invW = 1 / wc
            let sx = (projSx * vx * invW + 1) * 0.5 * W
            let syUp = (projSy * vy * invW + 1) * 0.5 * H
            let z = (projC * vz + projD) * invW
            sv.append(SV(x: sx, y: syUp, z: z, invW: invW,
                         nx: tnx * invW, ny: tny * invW, nz: tnz * invW,
                         px: vx * invW, py: vy * invW, pz: vz * invW))
            let r = DirtyRect(x0: Int(sx.rounded(.down)) - 1, y0: Int((H - syUp).rounded(.down)) - 1,
                              x1: Int(sx.rounded(.up)) + 1, y1: Int((H - syUp).rounded(.up)) + 1)
            bbox = bbox.map { $0.union(r) } ?? r
        }
        let idx = mesh.indices
        var t = 0
        while t + 2 < idx.count {
            let i0 = idx[t], i1 = idx[t + 1], i2 = idx[t + 2]
            t += 3
            if behind[i0] || behind[i1] || behind[i2] { continue }
            rasterize(sv[i0], sv[i1], sv[i2], material)
        }
        if let b = bbox { markDirty(b) }
    }

    @inline(__always) private func edge(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float, _ px: Float, _ py: Float) -> Float {
        (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    }

    private func rasterize(_ v0: SV, _ v1: SV, _ v2: SV, _ mat: Material) {
        // Signed area in window coords (y up): CCW > 0 is front-facing in GL.
        let area = edge(v0.x, v0.y, v1.x, v1.y, v2.x, v2.y)
        guard area > 0 else { return }   // back-face culled (FrontSide)
        let invArea = 1 / area
        let minX = max(0, Int(min(v0.x, v1.x, v2.x).rounded(.down)))
        let maxX = min(width - 1, Int(max(v0.x, v1.x, v2.x).rounded(.up)))
        let minY = max(0, Int(min(v0.y, v1.y, v2.y).rounded(.down)))
        let maxY = min(height - 1, Int(max(v0.y, v1.y, v2.y).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let lx = lightDirView.0, ly = lightDirView.1, lz = lightDirView.2
        pixels.withUnsafeMutableBufferPointer { px in
            depth.withUnsafeMutableBufferPointer { dz in
                for yUp in minY...maxY {
                    let py = Float(yUp) + 0.5
                    let row = (height - 1 - yUp) * width
                    for x in minX...maxX {
                        let pxc = Float(x) + 0.5
                        let w0 = edge(v1.x, v1.y, v2.x, v2.y, pxc, py)
                        let w1 = edge(v2.x, v2.y, v0.x, v0.y, pxc, py)
                        let w2 = edge(v0.x, v0.y, v1.x, v1.y, pxc, py)
                        if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                        let l0 = w0 * invArea, l1 = w1 * invArea, l2 = w2 * invArea
                        let z = l0 * v0.z + l1 * v1.z + l2 * v2.z
                        let i = row + x
                        if z > dz[i] { continue }          // depthFunc LEQUAL
                        dz[i] = z
                        // perspective-correct attributes
                        let invW = l0 * v0.invW + l1 * v1.invW + l2 * v2.invW
                        let rw = 1 / invW
                        var nx = (l0 * v0.nx + l1 * v1.nx + l2 * v2.nx) * rw
                        var ny = (l0 * v0.ny + l1 * v1.ny + l2 * v2.ny) * rw
                        var nz = (l0 * v0.nz + l1 * v1.nz + l2 * v2.nz) * rw
                        let ppx = (l0 * v0.px + l1 * v1.px + l2 * v2.px) * rw
                        let ppy = (l0 * v0.py + l1 * v1.py + l2 * v2.py) * rw
                        let ppz = (l0 * v0.pz + l1 * v1.pz + l2 * v2.pz) * rw
                        let nl = (nx * nx + ny * ny + nz * nz).squareRoot()
                        nx /= nl; ny /= nl; nz /= nl
                        // viewDir = normalize(vViewPosition) = normalize(-position)
                        var vdx = -ppx, vdy = -ppy, vdz = -ppz
                        let vl = (vdx * vdx + vdy * vdy + vdz * vdz).squareRoot()
                        vdx /= vl; vdy /= vl; vdz /= vl
                        // RE_Direct_BlinnPhong
                        let dotNL = max(0, min(1, nx * lx + ny * ly + nz * lz))
                        let irr = dotNL * Material.lightIntensity * Float.pi
                        var hx = lx + vdx, hy = ly + vdy, hz = lz + vdz
                        let hl = (hx * hx + hy * hy + hz * hz).squareRoot()
                        hx /= hl; hy /= hl; hz /= hl
                        let dotNH = max(0, min(1, nx * hx + ny * hy + nz * hz))
                        let dotLH = max(0, min(1, lx * hx + ly * hy + lz * hz))
                        let fresnel = exp2((-5.55473 * dotLH - 6.98316) * dotLH)
                        let D = (1 / Float.pi) * (Material.shininess * 0.5 + 1) * powf(dotNH, Material.shininess)
                        let specScale = irr * 0.25 * D
                        let lambert = irr / Float.pi           // BRDF_Diffuse_Lambert = color / PI
                        let amb = Material.ambient * Float.pi / Float.pi
                        func channel(_ c: Float, _ e: Float, _ s: Float) -> UInt32 {
                            let F = (1 - s) * fresnel + s
                            let v = c * lambert + amb * c + specScale * F + e
                            let q = (max(0, min(1, v)) * 255 + 0.5).rounded(.down)
                            return UInt32(q)
                        }
                        let r = channel(mat.color.0, mat.emissive.0, Material.specular.0)
                        let g = channel(mat.color.1, mat.emissive.1, Material.specular.1)
                        let b = channel(mat.color.2, mat.emissive.2, Material.specular.2)
                        px[i] = 0xFF000000 | (r << 16) | (g << 8) | b
                    }
                }
            }
        }
    }
}

// MARK: - The pipes simulation (port of the page's screensaver script) -------

struct Cell: Hashable { var x: Int, y: Int, z: Int }

final class PipeState {
    var current: Cell
    var positions: [Cell]
    let material: Material?         // nil = candy-cane texture run (see note in update)
    init(start: Cell, material: Material?) { current = start; positions = [start]; self.material = material }
}

final class PipesWorld {
    let fb: Framebuffer
    var rng: Mulberry32
    var camera: Camera
    private var nodes = Set<Cell>()
    private var pipes: [PipeState] = []
    private var runTexturePath = false
    private var runTeapotChance = Tuning.teapotChance
    private let disableTeapots: Bool

    // Meshes the page builds per segment; identical every time, so build once.
    private let cylinderMesh: Mesh
    private let ballMesh: Mesh
    private let elbowMesh: Mesh
    private let teapotMesh: Mesh
    private let candyMaterial = Material(rgb: 0xffffff)

    // Wipe state (the dissolve): wall-clock driven like the page.
    private(set) var clearing = false
    private var nextClearAt: TimeInterval
    private var dissolveRects: [(x: Int, y: Int)] = []
    private var dissolveIndex = -1
    private var dissolveRectsPerRow = 0, dissolveRectsPerColumn = 0
    private var dissolveStart: TimeInterval = 0
    private let useWallClock: Bool
    private var virtualNow: TimeInterval = 0

    private(set) var updateRounds = 0
    private(set) var segments = 0
    private(set) var teapots = 0
    private(set) var wipes = 0

    init(seed: UInt32, width: Int, height: Int, disableTeapots: Bool = false, wallClock: Bool = true) {
        fb = Framebuffer(width: width, height: height)
        rng = Mulberry32(a: seed)
        camera = Camera(aspect: Double(width) / Double(height))
        self.disableTeapots = disableTeapots
        useWallClock = wallClock
        cylinderMesh = MeshFactory.cylinder(radiusTop: Tuning.pipeRadius, radiusBottom: Tuning.pipeRadius,
                                            height: 1, radialSegments: 10, heightSegments: 4)
        ballMesh = MeshFactory.sphere(radius: Tuning.ballJointRadius, widthSegments: 8, heightSegments: 8)
        elbowMesh = MeshFactory.sphere(radius: Tuning.pipeRadius, widthSegments: 8, heightSegments: 8)
        teapotMesh = Teapot.mesh(size: Tuning.teapotSize)
        // Script order in the page: the wipe timer's delay is drawn first,
        // then look() picks the camera; pipes are spawned by the first frame.
        nextClearAt = 0
        let firstClearMs = random(Tuning.runSeconds.lowerBound, Tuning.runSeconds.upperBound) * 1000
        nextClearAt = now + firstClearMs / 1000
        look()
    }

    // MARK: random helpers, same call pattern as the page

    private func random(_ x1: Double, _ x2: Double) -> Double { rng.next() * (x2 - x1) + x1 }
    private func randomInteger(_ x1: Double, _ x2: Double) -> Int { Int(jsRound(random(x1, x2))) }
    private func chance(_ p: Double) -> Bool { rng.next() < p }
    private func chooseIndex(_ count: Int) -> Int { Int((rng.next() * Double(count)).rounded(.down)) }

    private var now: TimeInterval { useWallClock ? ProcessInfo.processInfo.systemUptime : virtualNow }

    // MARK: camera

    private func look() {
        if chance(1.0 / 2.0) {
            camera.position = V3(0, 0, 14)
        } else {
            let axis = V3(random(-1, 1), random(-1, 1), random(-1, 1))
            camera.position = applyRotationAxisMatrix(V3(14, 0, 0), axis: axis, angle: Double.pi / 2)
        }
        camera.lookAt(V3(0, 0, 0))
        camera.orbitControlsUpdate()
        fb.setCamera(camera)
    }

    // MARK: pipes

    private func spawnPipes() {
        // pipeOptions for this run
        runTexturePath = false
        runTeapotChance = disableTeapots ? 0 : Tuning.teapotChance
        if chance(Tuning.candyRunChance) {
            runTeapotChance = disableTeapots ? 0 : Tuning.candyTeapotChance
            runTexturePath = true
        }
        let pipeCount = randomInteger(Double(Tuning.pipeCountRange.lowerBound), Double(Tuning.pipeCountRange.upperBound))
        for _ in 0..<pipeCount {
            let g = Double(Tuning.gridHalf)
            let start = Cell(x: randomInteger(-g, g), y: randomInteger(-g, g), z: randomInteger(-g, g))
            let material: Material? = runTexturePath ? nil : Material(rgb: Tuning.colors[chooseIndex(Tuning.colors.count)])
            let pipe = PipeState(start: start, material: material)
            nodes.insert(start)     // the page does not check occupancy here either
            drawSphere(ballMesh, at: start, material: material)
            pipes.append(pipe)
        }
    }

    private func inBounds(_ c: Cell) -> Bool {
        abs(c.x) <= Tuning.gridHalf && abs(c.y) <= Tuning.gridHalf && abs(c.z) <= Tuning.gridHalf
    }

    private func update(_ pipe: PipeState) {
        var lastDirection: Cell? = nil
        if pipe.positions.count > 1 {
            let last = pipe.positions[pipe.positions.count - 2]
            lastDirection = Cell(x: pipe.current.x - last.x, y: pipe.current.y - last.y, z: pipe.current.z - last.z)
        }
        var direction: Cell
        if chance(1.0 / 2.0), let ld = lastDirection {
            direction = ld
        } else {
            direction = Cell(x: 0, y: 0, z: 0)
            let axis = chooseIndex(3)                       // chooseFrom("xyz")
            let sign = chooseIndex(2) == 0 ? 1 : -1         // chooseFrom([+1, -1])
            switch axis { case 0: direction.x += sign; case 1: direction.y += sign; default: direction.z += sign }
        }
        let next = Cell(x: pipe.current.x + direction.x, y: pipe.current.y + direction.y, z: pipe.current.z + direction.z)
        guard inBounds(next) else { return }
        guard !nodes.contains(next) else { return }
        nodes.insert(next)

        if let ld = lastDirection, ld != direction {
            if chance(runTeapotChance) {
                drawTeapot(at: pipe.current, material: pipe.material)
            } else if chance(Tuning.ballJointChance) {
                drawSphere(ballMesh, at: pipe.current, material: pipe.material)
            } else {
                drawSphere(elbowMesh, at: pipe.current, material: pipe.material)
            }
        }
        drawCylinder(from: pipe.current, to: next, material: pipe.material)
        pipe.current = next
        pipe.positions.append(next)
    }

    // MARK: drawing (only while not clearing; the page skips render then)

    private func mat(_ m: Material?) -> Material { m ?? candyMaterial }

    private func drawCylinder(from a: Cell, to b: Cell, material: Material?) {
        segments += 1
        guard !clearing else { return }
        let from = V3(Double(a.x), Double(a.y), Double(a.z)), to = V3(Double(b.x), Double(b.y), Double(b.z))
        let delta = to - from
        let q = Quat.fromUnitVectors(V3(0, 1, 0), delta.normalized)
        let position = from + delta * 0.5
        fb.draw(cylinderMesh, position: position, rotation: q, material: mat(material))
    }

    private func drawSphere(_ mesh: Mesh, at c: Cell, material: Material?) {
        guard !clearing else { return }
        fb.draw(mesh, position: V3(Double(c.x), Double(c.y), Double(c.z)), rotation: .identity, material: mat(material))
    }

    private func drawTeapot(at c: Cell, material: Material?) {
        // The page: rotation.x/y/z = floor(random(0, 50)) * PI / 2 (three draws).
        let rx = (random(0, 50)).rounded(.down) * Double.pi / 2
        let ry = (random(0, 50)).rounded(.down) * Double.pi / 2
        let rz = (random(0, 50)).rounded(.down) * Double.pi / 2
        teapots += 1
        guard !clearing else { return }
        fb.draw(teapotMesh, position: V3(Double(c.x), Double(c.y), Double(c.z)),
                rotation: Quat.fromEulerXYZ(rx, ry, rz), material: mat(material))
    }

    // MARK: wipe

    private func startClear() {
        nextClearAt = now + random(Tuning.runSeconds.lowerBound, Tuning.runSeconds.upperBound)
        guard !clearing else { return }
        clearing = true
        wipes += 1
        dissolve(seconds: Tuning.wipeSeconds)
    }

    private func dissolve(seconds: Double) {
        dissolveRectsPerRow = Int((Double(fb.width) / 20).rounded(.up))
        dissolveRectsPerColumn = Int((Double(fb.height) / 20).rounded(.up))
        var rects: [(x: Int, y: Int)] = []
        for i in 0..<(dissolveRectsPerRow * dissolveRectsPerColumn) {
            rects.append((i % dissolveRectsPerRow, i / dissolveRectsPerRow))
        }
        // shuffleArrayInPlace
        var i = rects.count - 1
        while i > 0 {
            let j = Int((rng.next() * Double(i + 1)).rounded(.down))
            rects.swapAt(i, j)
            i -= 1
        }
        dissolveRects = rects
        dissolveIndex = 0
        dissolveStart = now
    }

    private func dissolveStep() {
        let elapsed = (now - dissolveStart) * 1000
        let target = min(dissolveRects.count,
                         Int((Double(dissolveRects.count) * elapsed / (Tuning.wipeSeconds * 1000)).rounded(.down)))
        let rectW = Double(fb.width) / Double(dissolveRectsPerRow)
        let rectH = Double(fb.height) / Double(dissolveRectsPerColumn)
        while dissolveIndex < target {
            let r = dissolveRects[dissolveIndex]
            fb.fillBlack(x: Int((Double(r.x) * rectW).rounded(.down)), y: Int((Double(r.y) * rectH).rounded(.down)),
                         w: Int(rectW.rounded(.up)), h: Int(rectH.rounded(.up)))
            dissolveIndex += 1
        }
        if dissolveIndex == dissolveRects.count {
            dissolveRects = []
            dissolveIndex = -1
            reset()
        }
    }

    private func reset() {
        fb.clear()
        pipes.removeAll()
        nodes.removeAll()
        look()
        clearing = false
    }

    // MARK: one frame (animate)

    func tick() {
        if !useWallClock { virtualNow += 1.0 / Tuning.tickHz }
        camera.orbitControlsUpdate()
        if useWallClock, now >= nextClearAt { startClear() }
        if !pipes.isEmpty { updateRounds += 1 }
        for pipe in pipes { update(pipe) }
        if pipes.isEmpty { spawnPipes() }
        if dissolveIndex > -1 { dissolveStep() }
    }

    var summary: String {
        let p = camera.position
        return String(format: "fb=%dx%d rounds=%d pipes=%d segments=%d teapots=%d wipes=%d clearing=%d cam=(%.4f, %.4f, %.4f)",
                      fb.width, fb.height, updateRounds, pipes.count, segments, teapots, wipes, clearing ? 1 : 0, p.x, p.y, p.z)
    }
}

// MARK: - The view ----------------------------------------------------------

@objc(PipesSaverView)
final class PipesSaverView: ScreenSaverView {

    private let pixelLayer = CALayer()
    private var world: PipesWorld?
    private var tickTimer: Timer?
    private var frames = 0
    private var surfaces: [IOSurface] = []
    private var pending: [[DirtyRect]] = [[], []]
    private var back = 0

    private var hostSaidStop = false
    private var reconcileTimer: Timer?
    private var pendingStart: DispatchWorkItem?
    private let instanceID = UInt32.random(in: 1000...9999)
    private static var lastSerial = 0
    private let serial: Int

    override init?(frame: NSRect, isPreview: Bool) {
        PipesSaverView.lastSerial += 1
        serial = PipesSaverView.lastSerial
        super.init(frame: frame, isPreview: isPreview)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        PipesSaverView.lastSerial += 1
        serial = PipesSaverView.lastSerial
        super.init(coder: coder)
        commonSetup()
    }

    deinit {
        reconcileTimer?.invalidate()
        tickTimer?.invalidate()
        pendingStart?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        slog("[\(instanceID)] deinit")
    }

    private func commonSetup() {
        liveInstances.add(self)
        slog("[\(instanceID)] init #\(serial) frame=\(NSStringFromRect(frame)) preview=\(isPreview ? 1 : 0)")
        for other in liveInstances.allObjects where other !== self && other.isRendering {
            other.syncState(reason: "superseded")
        }

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pixelLayer.frame = bounds
        pixelLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        pixelLayer.contentsGravity = .resize
        pixelLayer.magnificationFilter = .nearest
        pixelLayer.minificationFilter = .nearest
        pixelLayer.backgroundColor = NSColor.black.cgColor
        pixelLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(pixelLayer)

        animationTimeInterval = 1.0

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(saverWillStop(_:)),
                        name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
        dnc.addObserver(self, selector: #selector(saverWillStop(_:)),
                        name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
        dnc.addObserver(self, selector: #selector(saverDidStart(_:)),
                        name: Notification.Name("com.apple.screensaver.didstart"), object: nil)

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isRendering != self.shouldRender { self.syncState(reason: "timer") }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        reconcileTimer = t
    }

    // MARK: state

    private var isRendering: Bool { tickTimer != nil }
    private var isNewestInstance: Bool { liveInstances.allObjects.allSatisfy { $0.serial <= serial } }
    private var shouldRender: Bool { isAnimating && !hostSaidStop && isNewestInstance }

    private func syncState(reason: String) {
        let want = shouldRender
        slog("[\(instanceID)] sync(\(reason)) animating=\(isAnimating ? 1 : 0) hostStop=\(hostSaidStop ? 1 : 0) -> render=\(want ? 1 : 0) (rendering=\(isRendering ? 1 : 0), #\(serial) of \(liveInstances.count), newest=\(isNewestInstance ? 1 : 0))")
        if want && !isRendering && pendingStart == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingStart = nil
                if self.shouldRender && !self.isRendering { self.startRendering() }
            }
            pendingStart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        if !want {
            pendingStart?.cancel()
            pendingStart = nil
            if isRendering { stopRendering() }
        }
    }

    // MARK: rendering

    private func startRendering() {
        let scale = max(1, Int((bounds.width / Tuning.targetFramebufferWidth).rounded()))
        let w = max(16, Int(bounds.width) / scale), h = max(16, Int(bounds.height) / scale)
        let seed = UInt32.random(in: 1...UInt32.max)
        let wld = PipesWorld(seed: seed, width: w, height: h)
        world = wld
        frames = 0
        surfaces = (0..<2).compactMap { _ in
            IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4,
                                   .pixelFormat: UInt32(0x42475241) /* 'BGRA' */])
        }
        if surfaces.count < 2 { surfaces = []; slog("[\(instanceID)] IOSurface unavailable, using CGImage path") }
        pending = [[], []]
        back = 0
        wld.tick()
        pushFrame()
        let t = Timer(timeInterval: 1.0 / Tuning.tickHz, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2 / Tuning.tickHz
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        slog("[\(instanceID)] rendering started scale=\(scale) seed=\(seed) \(wld.summary)")
    }

    private func stopRendering() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let w = world { slog("[\(instanceID)] rendering stopped after \(frames) frames; \(w.summary)") }
        world = nil
        pixelLayer.contents = nil
        surfaces = []
    }

    private func tick() {
        guard let w = world else { return }
        w.tick()
        if w.fb.dirty { pushFrame() }
    }

    private func pushFrame() {
        guard let wld = world else { return }
        let fb = wld.fb
        guard surfaces.count == 2 else { pushFrameCGImage(); return }
        let rects = fb.dirtyRects
        fb.clearDirty()
        for i in 0..<2 {
            pending[i].append(contentsOf: rects)
            if pending[i].count > 256 { pending[i] = [pending[i].dropFirst().reduce(pending[i][0]) { $0.union($1) }] }
        }
        let surface = surfaces[back]
        surface.lock(options: [], seed: nil)
        let stride = surface.bytesPerRow
        let dst = surface.baseAddress
        let w = fb.width
        fb.pixels.withUnsafeBufferPointer { src in
            guard let srcBase = src.baseAddress else { return }
            for r in pending[back] {
                let bytes = (r.x1 - r.x0) * 4
                for y in r.y0..<r.y1 {
                    memcpy(dst + y * stride + r.x0 * 4, srcBase + y * w + r.x0, bytes)
                }
            }
        }
        surface.unlock(options: [], seed: nil)
        pending[back].removeAll(keepingCapacity: true)
        pixelLayer.contents = surface
        back = 1 - back
        frames += 1
    }

    private func pushFrameCGImage() {
        guard let wld = world, let image = PipesSaverView.cgImage(of: wld.fb) else { return }
        pixelLayer.contents = image
        wld.fb.clearDirty()
        frames += 1
    }

    private static func cgImage(of fb: Framebuffer) -> CGImage? {
        let data = fb.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: fb.width, height: fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: fb.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func writePNG(_ image: CGImage, to path: String) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: ScreenSaverView

    override func startAnimation() {
        super.startAnimation()
        hostSaidStop = false
        syncState(reason: "startAnimation")
    }

    override func stopAnimation() {
        super.stopAnimation()
        syncState(reason: "stopAnimation")
    }

    override func animateOneFrame() {
        if isRendering != shouldRender { syncState(reason: "tick") }
    }

    override func layout() {
        super.layout()
        pixelLayer.frame = bounds
    }

    @objc private func saverWillStop(_ note: Notification) {
        slog("[\(instanceID)] \(note.name.rawValue)")
        hostSaidStop = true
        syncState(reason: note.name.rawValue.replacingOccurrences(of: "com.apple.screensaver.", with: ""))
    }

    @objc private func saverDidStart(_ note: Notification) {
        slog("[\(instanceID)] \(note.name.rawValue)")
        hostSaidStop = false
        syncState(reason: "didstart")
    }

    // MARK: debug hooks (verify.sh, compare/)

    @objc func debugStats() -> String {
        "rendering=\(isRendering) frames=\(frames) \(world?.summary ?? "no world")"
    }

    /// Save the currently displayed surface as a PNG.
    @objc func debugWritePNG(_ path: String) -> Bool {
        guard let wld = world else { return false }
        var image: CGImage? = nil
        if surfaces.count == 2 {
            let shown = surfaces[1 - back]
            shown.lock(options: [.readOnly], seed: nil)
            let data = Data(bytes: shown.baseAddress, count: shown.bytesPerRow * wld.fb.height)
            shown.unlock(options: [.readOnly], seed: nil)
            if let provider = CGDataProvider(data: data as CFData) {
                image = CGImage(width: wld.fb.width, height: wld.fb.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: shown.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
        } else {
            image = PipesSaverView.cgImage(of: wld.fb)
        }
        guard let img = image else { return false }
        return PipesSaverView.writePNG(img, to: path)
    }

    /// Deterministic offline render for comparison against the web page.
    /// spec: "seed=7;updates=240;w=1470;h=956;png=/path;noteapot=1"
    @objc func debugRender(_ spec: String) -> String {
        var kv: [String: String] = [:]
        for part in spec.split(separator: ";") {
            let p = part.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        guard let seed = UInt32(kv["seed"] ?? ""), let updates = Int(kv["updates"] ?? ""),
              let w = Int(kv["w"] ?? ""), let h = Int(kv["h"] ?? ""), let png = kv["png"] else { return "bad spec" }
        let wld = PipesWorld(seed: seed, width: w, height: h, disableTeapots: kv["noteapot"] == "1", wallClock: false)
        let t0 = Date()
        while wld.updateRounds < updates { wld.tick() }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard let img = PipesSaverView.cgImage(of: wld.fb), PipesSaverView.writePNG(img, to: png) else { return "png failed" }
        return "NATIVE: \(wld.summary) render=\(ms)ms"
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
