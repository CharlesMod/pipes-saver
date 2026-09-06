#!/bin/bash
# Reference render: load the three.js page with a fixed seed, let it run N
# update rounds, and save the WebGL canvas as a PNG.
#   render-web.sh <seed> <updates> <WxH> <out.png> [page.html] [noteapot 0|1]
set -euo pipefail
SEED="$1"; UPDATES="$2"; SIZE="$3"; OUT="$4"; PAGE="${5:-/Users/cmod/Software/pipes/index.html}"; NOTEAPOT="${6:-0}"
W="${SIZE%x*}"; H="${SIZE#*x}"
TMP="$(mktemp -t renderweb).swift"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<SWIFT
import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let config = WKWebViewConfiguration()
config.userContentController.addUserScript(WKUserScript(
  source: "window.__PIPES_SEED__ = $SEED; window.__PIPES_MAX_UPDATES__ = $UPDATES; window.__PIPES_DEBUG_CANVAS__ = true; window.__PIPES_FORCE_RENDER__ = true; window.__PIPES_NO_TEAPOT__ = $NOTEAPOT;",
  injectionTime: .atDocumentStart, forMainFrameOnly: true))
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: $W, height: $H), configuration: config)
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: $W, height: $H), styleMask: [.titled], backing: .buffered, defer: false)
win.level = .floating
win.contentView = web
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let url = URL(fileURLWithPath: "$PAGE")
web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
var done = false
func poll() {
  web.evaluateJavaScript("window.__pipesUpdateRounds ? window.__pipesUpdateRounds() : -1") { r, _ in
    let n = (r as? Int) ?? -1
    if n >= $UPDATES {
      // one more frame so the frozen state is presented, then read the canvas
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        web.evaluateJavaScript("JSON.stringify({png: document.getElementById('canvas-webgl').toDataURL('image/png'), cam: [camera.position.x, camera.position.y, camera.position.z], w: innerWidth, h: innerHeight, rounds: __pipesUpdateRounds(), pipes: pipes.length})") { r, e in
          guard let s = r as? String, let d = s.data(using: .utf8),
                let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                let png = o["png"] as? String, let comma = png.firstIndex(of: ",") else { print("FAIL: \\(String(describing: e))"); done = true; return }
          let b64 = String(png[png.index(after: comma)...])
          try? Data(base64Encoded: b64)?.write(to: URL(fileURLWithPath: "$OUT"))
          print("WEB: rounds=\\(o["rounds"] ?? 0) pipes=\\(o["pipes"] ?? 0) size=\\(o["w"] ?? 0)x\\(o["h"] ?? 0) cam=\\(o["cam"] ?? [])")
          done = true
        }
      }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
    }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { poll() }
let dl = Date().addingTimeInterval(Double($UPDATES) / 15.0 + 20)
while !done && Date() < dl {
  if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { app.sendEvent(e) }
}
if !done { print("FAIL: timeout") }
SWIFT
swift "$TMP" 2>&1 | grep -E "^(WEB|FAIL)"
