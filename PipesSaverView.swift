// PipesSaverView -- pixel-art 3D Pipes screen saver, rendered natively.
//
// Energy design. The previous version hosted a WebGL page in a WKWebView,
// which costs three helper processes (WebContent, GPU, Networking) plus
// full-resolution shaded rendering every frame. This version has no web
// stack at all:
//   * The scene is an isometric software render into a framebuffer (one
//     pixel per point by default, see Tuning) shown through a CALayer with
//     nearest-neighbour magnification.
//   * Pipe segments are analytic ray-traced sprites (cylinders and spheres)
//     precomputed once per size, each pixel carrying its real depth, so a
//     persistent z-buffer gives correct occlusion without ever redrawing
//     the scene: a tick only blits the handful of new segments.
//   * Frames go to the compositor through two IOSurfaces (double-buffered,
//     zero-copy for the GPU); only the rectangles that changed since a
//     surface was last shown are copied into it. Pushing a full-frame CGImage
//     instead cost ~20% of a core at full resolution -- CA copies and
//     converts it on the main thread every frame.
//
// Lifecycle notes (macOS 14+ legacyScreenSaver host, verified with logging):
//   * The host is a view service composited remotely by WallpaperAgent, so
//     this process never sees its own window as visible; do not gate on
//     occlusion.
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
    /// Frame pushes per second. Every push wakes the compositor, so this is
    /// the main energy knob. 30 matches the original; 20 or 15 for pixel art.
    static let tickHz: Double = 30
    /// Growth speed: move attempts per second per pipe (original: one per
    /// rendered frame, ~30).
    static let stepsPerSecondPerPipe: Double = 20
    static let pipeCountRange = 4...6
    /// Seconds between wipes.
    static let runSeconds: ClosedRange<Double> = 30...50
    static let wipeSeconds: Double = 2
    /// Wipe block size in framebuffer pixels.
    static let wipeBlock = 20
    /// Grid half-extents. A flatter box than the original cube fits an
    /// isometric view of the whole thing on a 3:2 screen.
    static let gridX = 10, gridY = 6, gridZ = 10
    static let pipeRadius: Float = 0.30
    static let ballRadius: Float = 0.45
    static let teapotChance = 1.0 / 200.0
    /// Framebuffer width the renderer aims for; the integer scale factor is
    /// derived from the view size so pixels stay square. 1500 means scale 1
    /// (one framebuffer pixel per point) on any normal display; 480 gives the
    /// chunky 3x pixel-art look.
    static let targetFramebufferWidth: CGFloat = 1500
    /// Pipe palette (red, green, blue, amber) -- edit freely.
    static let colors: [UInt32] = [0xd83a3a, 0x39b54a, 0x2f6fdc, 0xe0b020]
    /// Shading bands, darkest to brightest; a specular band is added. Eight
    /// reads as a rounded tube; five reads as pixel art.
    static let shadeBands: [Float] = [0.22, 0.33, 0.44, 0.55, 0.66, 0.78, 0.89, 1.0]
    static let lightDirection: (Float, Float, Float) = (-0.45, 0.80, -0.55)
}

// MARK: - Geometry helpers --------------------------------------------------

struct Cell: Hashable {
    var x: Int, y: Int, z: Int
    static func + (a: Cell, b: Cell) -> Cell { Cell(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static let axes: [Cell] = [Cell(x: 1, y: 0, z: 0), Cell(x: -1, y: 0, z: 0),
                               Cell(x: 0, y: 1, z: 0), Cell(x: 0, y: -1, z: 0),
                               Cell(x: 0, y: 0, z: 1), Cell(x: 0, y: 0, z: -1)]
}

/// One pre-shaded sprite pixel: screen offset from the anchor cell's
/// projection, depth offset from the anchor cell's depth, shade band index
/// (Tuning.shadeBands.count == specular highlight).
struct SpritePixel {
    var dx: Int32
    var dy: Int32
    var depth: Float
    var band: UInt8
}

struct Sprite {
    var pixels: [SpritePixel] = []
    var minX: Int32 = 0, minY: Int32 = 0, maxX: Int32 = 0, maxY: Int32 = 0
    /// Compute the bounding box (inclusive) once the pixels are final.
    mutating func finalize() {
        guard let f = pixels.first else { return }
        minX = f.dx; maxX = f.dx; minY = f.dy; maxY = f.dy
        for p in pixels {
            if p.dx < minX { minX = p.dx }; if p.dx > maxX { maxX = p.dx }
            if p.dy < minY { minY = p.dy }; if p.dy > maxY { maxY = p.dy }
        }
    }
}

/// Framebuffer rectangle, half-open: x0 <= x < x1, y0 <= y < y1.
struct DirtyRect {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    func union(_ o: DirtyRect) -> DirtyRect {
        DirtyRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

/// Isometric projection with the camera looking along (1,-1,1): a unit step
/// in x moves (+2u, -u) on screen, in z moves (-2u, -u), in y moves (0, -2u).
/// Depth increases away from the camera: depth = x + z - y.
struct Projection {
    let u: Float
    func screen(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float) {
        ((x - z) * 2 * u, -(x + z) * u - y * 2 * u)
    }
    static func depth(_ x: Float, _ y: Float, _ z: Float) -> Float { x + z - y }
    /// Any world point that projects to the given screen offset (y = 0 plane).
    func rayOrigin(sx: Float, sy: Float) -> (Float, Float, Float) {
        let a = sx / (2 * u)   // x - z
        let b = -sy / u        // x + z
        return ((a + b) / 2, 0, (b - a) / 2)
    }
}

// MARK: - Sprite generation (analytic ray tracing, done once per size) ------

enum SpriteFactory {
    private static let inv3: Float = 1 / Float(3).squareRoot()
    /// View direction (into the scene).
    private static let view: (Float, Float, Float) = (inv3, -inv3, inv3)
    private static let light: (Float, Float, Float) = {
        let l = Tuning.lightDirection
        let n = (l.0 * l.0 + l.1 * l.1 + l.2 * l.2).squareRoot()
        return (l.0 / n, l.1 / n, l.2 / n)
    }()
    private static let half: (Float, Float, Float) = {
        // Half vector between the light and the direction toward the camera.
        let h = (light.0 - view.0, light.1 - view.1, light.2 - view.2)
        let n = (h.0 * h.0 + h.1 * h.1 + h.2 * h.2).squareRoot()
        return (h.0 / n, h.1 / n, h.2 / n)
    }()

    private static func band(forNormal n: (Float, Float, Float)) -> UInt8 {
        let diffuse = max(0, n.0 * light.0 + n.1 * light.1 + n.2 * light.2)
        let spec = max(0, n.0 * half.0 + n.1 * half.1 + n.2 * half.2)
        if spec > 0.975 { return UInt8(Tuning.shadeBands.count) } // highlight
        let v = 0.18 + 0.82 * diffuse
        let idx = min(Tuning.shadeBands.count - 1, Int(v * Float(Tuning.shadeBands.count)))
        return UInt8(max(0, idx))
    }

    /// Open cylinder of radius r from the origin along +axis (0=x, 1=y, 2=z),
    /// length 1. Front faces only, like the original's FrontSide material.
    static func cylinder(axis: Int, radius r: Float, proj: Projection) -> Sprite {
        var sprite = Sprite()
        var end: (Float, Float, Float) = (0, 0, 0)
        if axis == 0 { end.0 = 1 } else if axis == 1 { end.1 = 1 } else { end.2 = 1 }
        let p0 = proj.screen(0, 0, 0), p1 = proj.screen(end.0, end.1, end.2)
        let m = Int((r * 3 * proj.u).rounded(.up)) + 2
        let xMin = Int(min(p0.0, p1.0).rounded(.down)) - m, xMax = Int(max(p0.0, p1.0).rounded(.up)) + m
        let yMin = Int(min(p0.1, p1.1).rounded(.down)) - m, yMax = Int(max(p0.1, p1.1).rounded(.up)) + m
        for py in yMin...yMax {
            for px in xMin...xMax {
                let o = proj.rayOrigin(sx: Float(px) + 0.5, sy: Float(py) + 0.5)
                // Perpendicular components (axis component zeroed).
                var op = o, vp = view
                switch axis {
                case 0: op.0 = 0; vp.0 = 0
                case 1: op.1 = 0; vp.1 = 0
                default: op.2 = 0; vp.2 = 0
                }
                let A = vp.0 * vp.0 + vp.1 * vp.1 + vp.2 * vp.2
                let B = 2 * (op.0 * vp.0 + op.1 * vp.1 + op.2 * vp.2)
                let C = op.0 * op.0 + op.1 * op.1 + op.2 * op.2 - r * r
                let disc = B * B - 4 * A * C
                guard disc >= 0 else { continue }
                let t = (-B - disc.squareRoot()) / (2 * A)   // near root = front face
                let q = (o.0 + t * view.0, o.1 + t * view.1, o.2 + t * view.2)
                let s = axis == 0 ? q.0 : (axis == 1 ? q.1 : q.2)
                guard s >= 0, s <= 1 else { continue }
                var n = q
                if axis == 0 { n.0 = 0 } else if axis == 1 { n.1 = 0 } else { n.2 = 0 }
                n = (n.0 / r, n.1 / r, n.2 / r)
                sprite.pixels.append(SpritePixel(dx: Int32(px), dy: Int32(py),
                                                 depth: Projection.depth(q.0, q.1, q.2),
                                                 band: band(forNormal: n)))
            }
        }
        sprite.finalize()
        return sprite
    }

    static func sphere(radius r: Float, proj: Projection, depthBias: Float = 0) -> Sprite {
        var sprite = Sprite()
        let m = Int((r * 3 * proj.u).rounded(.up)) + 2
        for py in -m...m {
            for px in -m...m {
                let o = proj.rayOrigin(sx: Float(px) + 0.5, sy: Float(py) + 0.5)
                let B = 2 * (o.0 * view.0 + o.1 * view.1 + o.2 * view.2)
                let C = o.0 * o.0 + o.1 * o.1 + o.2 * o.2 - r * r
                let disc = B * B - 4 * C
                guard disc >= 0 else { continue }
                let t = (-B - disc.squareRoot()) / 2
                let q = (o.0 + t * view.0, o.1 + t * view.1, o.2 + t * view.2)
                let n = (q.0 / r, q.1 / r, q.2 / r)
                sprite.pixels.append(SpritePixel(dx: Int32(px), dy: Int32(py),
                                                 depth: Projection.depth(q.0, q.1, q.2) + depthBias,
                                                 band: band(forNormal: n)))
            }
        }
        sprite.finalize()
        return sprite
    }

    /// Utah teapot, pixel-art edition. Rows top to bottom; digits are shade
    /// bands (1 darkest), '*' the highlight, '.' transparent.
    private static let teapotArt: [String] = [
        "......*22......",
        ".....23332.....",
        "....2333332....",
        "..4443333332...",
        ".4.3333333322.2",
        ".4.4333333221.1",
        "..4433333221.1.",
        "...3332221111..",
        "....22111111...",
        ".....111111....",
    ]

    static func teapot(proj: Projection, radius r: Float) -> Sprite {
        var sprite = Sprite()
        // Scale the art so the teapot is about 1.4x the ball joint's width.
        let targetW = max(9, Int((r * 2 * 2 * proj.u * 1.4).rounded()))
        let artW = teapotArt[0].count, artH = teapotArt.count
        let scale = max(1, targetW / artW)
        let w = artW * scale, h = artH * scale
        for (row, line) in teapotArt.enumerated() {
            for (col, ch) in line.enumerated() {
                let band: UInt8
                switch ch {
                case "*": band = UInt8(Tuning.shadeBands.count)
                case "1": band = 0
                case "2": band = 1
                case "3": band = 2
                case "4": band = 3
                default: continue
                }
                for sy in 0..<scale {
                    for sx in 0..<scale {
                        sprite.pixels.append(SpritePixel(dx: Int32(col * scale + sx - w / 2),
                                                         dy: Int32(row * scale + sy - h / 2 - 2),
                                                         depth: -0.9, // sits in front of its joint
                                                         band: band))
                    }
                }
            }
        }
        sprite.finalize()
        return sprite
    }
}

// MARK: - Scene -------------------------------------------------------------

final class Pipe {
    var current: Cell
    var lastDirection: Cell?
    let palette: [UInt32]
    var stepAccumulator: Double = 0
    init(start: Cell, palette: [UInt32]) { current = start; self.palette = palette }
}

final class PipesScene {
    let width: Int, height: Int
    let proj: Projection
    private(set) var pixels: [UInt32]
    private var depth: [Float]
    private var occupied: [Bool]
    private var pipes: [Pipe] = []
    private var rotation = 0
    private let originX: Float, originY: Float

    private let cylinders: [Sprite]   // along +x, +y, +z
    private let ball: Sprite
    private let elbow: Sprite
    private let teapot: Sprite
    private let palettes: [[UInt32]]  // per colour: bands + highlight

    // Run / wipe state
    private var runEndsAt: TimeInterval = 0
    private var wipeBlocks: [Int] = []
    private var wipeIndex = 0
    private var wipeBlocksPerTick = 0

    // Regions changed since the last clearDirty(); the view copies exactly these.
    private(set) var dirtyRects: [DirtyRect] = []
    var dirty: Bool { !dirtyRects.isEmpty }
    let fullRect: DirtyRect

    // Stats
    private(set) var segments = 0
    private(set) var wipes = 0
    private(set) var ticks = 0

    private static let gridW = 2 * Tuning.gridX + 1
    private static let gridH = 2 * Tuning.gridY + 1
    private static let gridD = 2 * Tuning.gridZ + 1

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        fullRect = DirtyRect(x0: 0, y0: 0, x1: width, y1: height)
        pixels = [UInt32](repeating: 0xFF000000, count: width * height)
        depth = [Float](repeating: .greatestFiniteMagnitude, count: width * height)
        occupied = [Bool](repeating: false, count: PipesScene.gridW * PipesScene.gridH * PipesScene.gridD)

        // Pixels per grid unit: fit the whole box (a hexagonal silhouette)
        // into the framebuffer with a small margin.
        let spanX = Float(2 * (Tuning.gridX + Tuning.gridZ) + 2) * 2   // in units of u
        let spanY = Float(Tuning.gridX + Tuning.gridZ + 2) + Float(2 * Tuning.gridY + 2) * 2
        let u = max(2, min(Float(width) * 0.94 / spanX, Float(height) * 0.94 / spanY).rounded(.down))
        let p = Projection(u: u)
        proj = p
        originX = Float(width) / 2
        originY = Float(height) / 2

        cylinders = (0..<3).map { SpriteFactory.cylinder(axis: $0, radius: Tuning.pipeRadius, proj: p) }
        ball = SpriteFactory.sphere(radius: Tuning.ballRadius, proj: p)
        elbow = SpriteFactory.sphere(radius: Tuning.pipeRadius, proj: p, depthBias: -0.01)
        teapot = SpriteFactory.teapot(proj: p, radius: Tuning.ballRadius)
        palettes = Tuning.colors.map { PipesScene.makePalette($0) }

        startRun()
    }

    private static func makePalette(_ rgb: UInt32) -> [UInt32] {
        let r = Float((rgb >> 16) & 0xff), g = Float((rgb >> 8) & 0xff), b = Float(rgb & 0xff)
        func pack(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
            let R = UInt32(max(0, min(255, r))), G = UInt32(max(0, min(255, g))), B = UInt32(max(0, min(255, b)))
            return 0xFF000000 | (R << 16) | (G << 8) | B   // BGRA little-endian, opaque
        }
        var p = Tuning.shadeBands.map { pack(r * $0, g * $0, b * $0) }
        p.append(pack(r + (255 - r) * 0.65, g + (255 - g) * 0.65, b + (255 - b) * 0.65)) // highlight
        return p
    }

    // MARK: grid

    private func index(_ c: Cell) -> Int {
        ((c.y + Tuning.gridY) * PipesScene.gridD + (c.z + Tuning.gridZ)) * PipesScene.gridW + (c.x + Tuning.gridX)
    }
    private func inBounds(_ c: Cell) -> Bool {
        abs(c.x) <= Tuning.gridX && abs(c.y) <= Tuning.gridY && abs(c.z) <= Tuning.gridZ
    }

    /// Per-run view rotation about the vertical axis (four isometric views).
    private func rotated(_ c: Cell) -> Cell {
        switch rotation & 3 {
        case 1: return Cell(x: -c.z, y: c.y, z: c.x)
        case 2: return Cell(x: -c.x, y: c.y, z: -c.z)
        case 3: return Cell(x: c.z, y: c.y, z: -c.x)
        default: return c
        }
    }

    // MARK: dirty tracking

    private func markDirty(_ r: DirtyRect) {
        let c = DirtyRect(x0: max(0, r.x0), y0: max(0, r.y0), x1: min(width, r.x1), y1: min(height, r.y1))
        guard !c.isEmpty else { return }
        dirtyRects.append(c)
        if dirtyRects.count > 128 {   // too fragmented: collapse to one box
            dirtyRects = [dirtyRects.dropFirst().reduce(dirtyRects[0]) { $0.union($1) }]
        }
    }

    func clearDirty() { dirtyRects.removeAll(keepingCapacity: true) }

    // MARK: drawing

    private func blit(_ sprite: Sprite, at cell: Cell, palette: [UInt32]) {
        let w = rotated(cell)
        let s = proj.screen(Float(w.x), Float(w.y), Float(w.z))
        let ax = Int((originX + s.0).rounded()), ay = Int((originY + s.1).rounded())
        let baseDepth = Projection.depth(Float(w.x), Float(w.y), Float(w.z))
        let width = self.width, height = self.height
        pixels.withUnsafeMutableBufferPointer { px in
            depth.withUnsafeMutableBufferPointer { dz in
                for p in sprite.pixels {
                    let x = ax + Int(p.dx), y = ay + Int(p.dy)
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    let i = y * width + x
                    let d = baseDepth + p.depth
                    if d < dz[i] {
                        dz[i] = d
                        px[i] = palette[Int(p.band)]
                    }
                }
            }
        }
        markDirty(DirtyRect(x0: ax + Int(sprite.minX), y0: ay + Int(sprite.minY),
                            x1: ax + Int(sprite.maxX) + 1, y1: ay + Int(sprite.maxY) + 1))
    }

    private func drawCylinder(from a: Cell, direction d: Cell, palette: [UInt32]) {
        // Rotate the direction into world space, then normalise so the sprite
        // runs along +axis from the lower cell.
        let wd = rotated(d)
        var start = a
        let axis: Int
        if wd.x != 0 { axis = 0; if wd.x < 0 { start = a + d } }
        else if wd.y != 0 { axis = 1; if wd.y < 0 { start = a + d } }
        else { axis = 2; if wd.z < 0 { start = a + d } }
        blit(cylinders[axis], at: start, palette: palette)
        segments += 1
    }

    // MARK: pipes

    private func spawnPipe() {
        for _ in 0..<64 {
            let c = Cell(x: Int.random(in: -Tuning.gridX...Tuning.gridX),
                         y: Int.random(in: -Tuning.gridY...Tuning.gridY),
                         z: Int.random(in: -Tuning.gridZ...Tuning.gridZ))
            if occupied[index(c)] { continue }
            occupied[index(c)] = true
            let pipe = Pipe(start: c, palette: palettes.randomElement()!)
            blit(ball, at: c, palette: pipe.palette)
            pipes.append(pipe)
            return
        }
    }

    /// One move attempt -- a direct port of the original Pipe.update().
    private func step(_ pipe: Pipe) {
        let direction: Cell
        if let last = pipe.lastDirection, Bool.random() {
            direction = last
        } else {
            direction = Cell.axes.randomElement()!
        }
        let next = pipe.current + direction
        guard inBounds(next), !occupied[index(next)] else { return }
        occupied[index(next)] = true

        if let last = pipe.lastDirection, last != direction {
            if Double.random(in: 0..<1) < Tuning.teapotChance {
                blit(teapot, at: pipe.current, palette: pipe.palette)
            } else {
                blit(elbow, at: pipe.current, palette: pipe.palette)
            }
        }
        drawCylinder(from: pipe.current, direction: direction, palette: pipe.palette)
        pipe.current = next
        pipe.lastDirection = direction
    }

    // MARK: runs and wipes

    private func startRun() {
        pixels.withUnsafeMutableBufferPointer { $0.update(repeating: 0xFF000000) }
        depth.withUnsafeMutableBufferPointer { $0.update(repeating: .greatestFiniteMagnitude) }
        occupied.withUnsafeMutableBufferPointer { $0.update(repeating: false) }
        pipes.removeAll()
        rotation = Int.random(in: 0..<4)
        for _ in 0..<Int.random(in: Tuning.pipeCountRange) { spawnPipe() }
        runEndsAt = ProcessInfo.processInfo.systemUptime + Double.random(in: Tuning.runSeconds)
        dirtyRects = [fullRect]
    }

    private func startWipe() {
        let cols = (width + Tuning.wipeBlock - 1) / Tuning.wipeBlock
        let rows = (height + Tuning.wipeBlock - 1) / Tuning.wipeBlock
        wipeBlocks = Array(0..<(cols * rows)).shuffled()
        wipeIndex = 0
        wipeBlocksPerTick = max(1, Int((Double(wipeBlocks.count) / (Tuning.wipeSeconds * Tuning.tickHz)).rounded(.up)))
        wipes += 1
    }

    private func wipeTick() {
        let cols = (width + Tuning.wipeBlock - 1) / Tuning.wipeBlock
        let end = min(wipeBlocks.count, wipeIndex + wipeBlocksPerTick)
        let width = self.width, height = self.height
        var box: DirtyRect? = nil
        pixels.withUnsafeMutableBufferPointer { px in
            for i in wipeIndex..<end {
                let bx = (wipeBlocks[i] % cols) * Tuning.wipeBlock
                let by = (wipeBlocks[i] / cols) * Tuning.wipeBlock
                for y in by..<min(height, by + Tuning.wipeBlock) {
                    for x in bx..<min(width, bx + Tuning.wipeBlock) {
                        px[y * width + x] = 0xFF000000
                    }
                }
                let r = DirtyRect(x0: bx, y0: by, x1: bx + Tuning.wipeBlock, y1: by + Tuning.wipeBlock)
                box = box.map { $0.union(r) } ?? r
            }
        }
        wipeIndex = end
        if let b = box { markDirty(b) }
        if wipeIndex >= wipeBlocks.count {
            wipeBlocks = []
            startRun()
        }
    }

    /// Advance the scene by one tick (1 / Tuning.tickHz seconds).
    func tick() {
        ticks += 1
        if !wipeBlocks.isEmpty {
            wipeTick()
            return
        }
        if ProcessInfo.processInfo.systemUptime >= runEndsAt {
            startWipe()
            return
        }
        let perTick = Tuning.stepsPerSecondPerPipe / Tuning.tickHz
        for pipe in pipes {
            pipe.stepAccumulator += perTick
            while pipe.stepAccumulator >= 1 {
                pipe.stepAccumulator -= 1
                step(pipe)
            }
        }
    }

    var summary: String {
        "fb=\(width)x\(height) u=\(Int(proj.u)) pipes=\(pipes.count) segments=\(segments) wipes=\(wipes) ticks=\(ticks)"
    }
}

// MARK: - The view ----------------------------------------------------------

@objc(PipesSaverView)
final class PipesSaverView: ScreenSaverView {

    private let pixelLayer = CALayer()
    private var scene: PipesScene?
    private var tickTimer: Timer?
    private var frames = 0
    /// Two IOSurfaces the compositor samples directly; `pending[i]` is what
    /// still has to be copied into surface i before it can be shown again.
    private var surfaces: [IOSurface] = []
    private var pending: [[DirtyRect]] = [[], []]
    private var back = 0

    private var hostSaidStop = false        // com.apple.screensaver.willstop seen after last start
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

        // We drive our own clock; keep the host's animateOneFrame quiet.
        animationTimeInterval = 1.0

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(saverWillStop(_:)),
                        name: Notification.Name("com.apple.screensaver.willstop"), object: nil)
        dnc.addObserver(self, selector: #selector(saverWillStop(_:)),
                        name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
        dnc.addObserver(self, selector: #selector(saverDidStart(_:)),
                        name: Notification.Name("com.apple.screensaver.didstart"), object: nil)

        // Own reconciliation clock: notifications only fire on changes.
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
            // Deferred: the host re-starts every OLD instance before creating
            // the new one it will show; half a second lets the newcomer
            // supersede them before they do any work.
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
        let s = PipesScene(width: w, height: h)
        scene = s
        frames = 0
        surfaces = (0..<2).compactMap { _ in
            IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4,
                                   .pixelFormat: UInt32(0x42475241) /* 'BGRA' */])
        }
        if surfaces.count < 2 { surfaces = []; slog("[\(instanceID)] IOSurface unavailable, using CGImage path") }
        pending = [[], []]
        back = 0
        pushFrame()
        let t = Timer(timeInterval: 1.0 / Tuning.tickHz, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2 / Tuning.tickHz
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        slog("[\(instanceID)] rendering started scale=\(scale) \(s.summary)")
    }

    private func stopRendering() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let s = scene { slog("[\(instanceID)] rendering stopped after \(frames) frames; \(s.summary)") }
        scene = nil
        pixelLayer.contents = nil
        surfaces = []
    }

    private func tick() {
        guard let s = scene else { return }
        s.tick()
        if s.dirty { pushFrame() }
    }

    private func pushFrame() {
        guard let s = scene else { return }
        guard surfaces.count == 2 else { pushFrameCGImage(); return }
        let rects = s.dirtyRects
        s.clearDirty()
        for i in 0..<2 {
            pending[i].append(contentsOf: rects)
            if pending[i].count > 256 { pending[i] = [pending[i].dropFirst().reduce(pending[i][0]) { $0.union($1) }] }
        }
        let surface = surfaces[back]
        surface.lock(options: [], seed: nil)
        let stride = surface.bytesPerRow
        let dst = surface.baseAddress
        let w = s.width
        s.pixels.withUnsafeBufferPointer { src in
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

    /// Fallback when IOSurface allocation fails: full-frame CGImage (costly).
    private func pushFrameCGImage() {
        guard let s = scene else { return }
        let w = s.width, h = s.height
        let data = s.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        pixelLayer.contents = image
        s.clearDirty()
        frames += 1
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

    /// For verify.sh (called through the ObjC runtime).
    @objc func debugStats() -> String {
        "rendering=\(isRendering) frames=\(frames) \(scene?.summary ?? "no scene")"
    }

    /// For verify.sh: write the current framebuffer (unscaled) as a PNG.
    @objc func debugWritePNG(_ path: String) -> Bool {
        guard let s = scene else { return false }
        // Read back the surface the compositor was last given (not the master
        // framebuffer) so the image proves the IOSurface path itself.
        let data: Data
        let bytesPerRow: Int
        if surfaces.count == 2 {
            let shown = surfaces[1 - back]
            shown.lock(options: [.readOnly], seed: nil)
            bytesPerRow = shown.bytesPerRow
            data = Data(bytes: shown.baseAddress, count: bytesPerRow * s.height)
            shown.unlock(options: [.readOnly], seed: nil)
        } else {
            bytesPerRow = s.width * 4
            data = s.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
