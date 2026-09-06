#!/bin/bash
# Sanity-check the 3D Pipes screen saver bundle without going through System
# Settings. Loads the bundle exactly as macOS does, shows it in a floating
# window for a few seconds, and prints the saver's own stats plus the CPU
# this process used while it ran (the saver is the only thing doing work).
#
# Expect: rendering=true, frames climbing at ~20/s, segments growing, and a
# CPU figure in the low single digits of one core.
# Set PIPES_PNG=/path/frame.png to also save the last framebuffer as an image.
set -euo pipefail

SAVER="${1:-$HOME/Library/Screen Savers/Pipes.saver}"
[ -d "$SAVER" ] || { echo "error: no saver at $SAVER" >&2; exit 1; }
SECS="${2:-8}"
SIZE="${3:-900x600}"   # window size, e.g. 1470x956 to match the real screen
W="${SIZE%x*}"; H="${SIZE#*x}"

TMP="$(mktemp -t pipesverify).swift"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<SWIFT
import AppKit
import ScreenSaver

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

guard let b = Bundle(path: "$SAVER"), b.load(),
      let ssType = b.principalClass as? ScreenSaverView.Type,
      let view = ssType.init(frame: NSRect(x: 0, y: 0, width: $W, height: $H), isPreview: false)
else { print("FAIL: could not load saver bundle"); exit(1) }

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: $W, height: $H),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.level = .floating
win.contentView = view
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
view.startAnimation()

func cpuSeconds() -> Double {
  var ru = rusage()
  getrusage(RUSAGE_SELF, &ru)
  return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
       + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}
func stats() -> String {
  let sel = NSSelectorFromString("debugStats")
  guard view.responds(to: sel), let r = view.perform(sel)?.takeUnretainedValue() as? String else { return "no debugStats" }
  return r
}

let secs = Double($SECS)
var done = false
var cpu0 = 0.0
// Let the saver's deferred start (0.5 s) and sprite generation finish first.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
  print("START: \\(stats())")
  cpu0 = cpuSeconds()
  DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    let cpu = cpuSeconds() - cpu0
    print("END:   \\(stats())")
    if let png = ProcessInfo.processInfo.environment["PIPES_PNG"] {
      let sel = NSSelectorFromString("debugWritePNG:")
      let ok = view.responds(to: sel) && (view.perform(sel, with: png) != nil)
      print("PNG:   \\(ok ? "wrote" : "failed") \\(png)")
    }
    print(String(format: "CPU:   %.3f s over %.0f s = %.1f%% of one core", cpu, secs, cpu / secs * 100))
    done = true
  }
}
let dl = Date().addingTimeInterval(secs + 10)
while !done && Date() < dl {
  if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
    app.sendEvent(e)
  }
}
view.stopAnimation()
SWIFT

echo "verifying $SAVER for ${SECS}s at ${SIZE} ..."
swift "$TMP" 2>&1 | grep -E "^(START|END|CPU|PNG|FAIL)"
