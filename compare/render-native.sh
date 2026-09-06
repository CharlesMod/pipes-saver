#!/bin/bash
# Native render with a fixed seed, for comparison with render-web.sh.
#   render-native.sh <seed> <updates> <WxH> <out.png> [bundle] [noteapot=1]
set -euo pipefail
SEED="$1"; UPDATES="$2"; SIZE="$3"; OUT="$4"; SAVER="${5:-$HOME/Library/Screen Savers/Pipes.saver}"; EXTRA="${6:-}"
W="${SIZE%x*}"; H="${SIZE#*x}"
TMP="$(mktemp -t rendernative).swift"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<SWIFT
import AppKit
import ScreenSaver
guard let b = Bundle(path: "$SAVER"), b.load(),
      let ssType = b.principalClass as? ScreenSaverView.Type,
      let view = ssType.init(frame: NSRect(x: 0, y: 0, width: $W, height: $H), isPreview: false)
else { print("FAIL: could not load saver bundle"); exit(1) }
let sel = NSSelectorFromString("debugRender:")
let spec = "seed=$SEED;updates=$UPDATES;w=$W;h=$H;png=$OUT;$EXTRA"
if let r = view.perform(sel, with: spec)?.takeUnretainedValue() as? String { print(r) } else { print("FAIL: no debugRender") }
SWIFT
swift "$TMP" 2>&1 | grep -E "^(NATIVE|FAIL|bad|png)"
