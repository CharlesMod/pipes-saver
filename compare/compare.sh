#!/bin/bash
# Compare two PNGs pixel by pixel and write a diff image.
#   compare.sh <a.png> <b.png> <diff.png> [tolerance-per-channel, default 2]
set -euo pipefail
A="$1"; B="$2"; OUT="$3"; TOL="${4:-2}"
TMP="$(mktemp -t cmp).swift"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<SWIFT
import AppKit
func load(_ p: String) -> (Int, Int, [UInt8])? {
  guard let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
  let w = img.width, h = img.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  return (w, h, buf)
}
guard let (wa, ha, a) = load("$A"), let (wb, hb, b) = load("$B") else { print("FAIL: could not load"); exit(1) }
guard wa == wb, ha == hb else { print("FAIL: size mismatch \\(wa)x\\(ha) vs \\(wb)x\\(hb)"); exit(1) }
let w = wa, h = ha
var out = [UInt8](repeating: 0, count: w * h * 4)
var same = 0, close = 0, diff = 0, litA = 0, litB = 0
var sumAbs = 0
var hist = [Int](repeating: 0, count: 256)
for i in 0..<(w * h) {
  let o = i * 4
  var m = 0
  for c in 0..<3 { m = max(m, abs(Int(a[o + c]) - Int(b[o + c]))) }
  sumAbs += m
  hist[m] += 1
  if a[o] | a[o+1] | a[o+2] > 0 { litA += 1 }
  if b[o] | b[o+1] | b[o+2] > 0 { litB += 1 }
  if m == 0 { same += 1 } else if m <= $TOL { close += 1 } else { diff += 1 }
  // diff image: reference dimmed in grey, mismatches in magenta scaled by magnitude
  let g = UInt8((Int(a[o]) + Int(a[o+1]) + Int(a[o+2])) / 9)
  if m <= $TOL { out[o] = g; out[o+1] = g; out[o+2] = g }
  else { let v = UInt8(min(255, 96 + m)); out[o] = v; out[o+1] = 0; out[o+2] = v }
  out[o+3] = 255
}
let n = w * h
print(String(format: "identical %.2f%%  within tol %.2f%%  mismatched %.3f%% (%d px)  mean|diff| %.3f  lit px A=%d B=%d",
  Double(same)/Double(n)*100, Double(close)/Double(n)*100, Double(diff)/Double(n)*100, diff, Double(sumAbs)/Double(n), litA, litB))
var big = ""; for (k, c) in hist.enumerated() where k > $TOL && c > 0 { big += "\\(k):\\(c) " }
print("mismatch histogram (maxdiff:count): " + (big.count > 400 ? String(big.prefix(400)) + "..." : big))
if let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
   let img = ctx.makeImage(),
   let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "$OUT") as CFURL, "public.png" as CFString, 1, nil) {
  CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}
SWIFT
swift "$TMP" 2>&1 | grep -vE "^\s*$"
