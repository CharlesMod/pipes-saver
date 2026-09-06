#!/bin/bash
# Build (and optionally install) the pixel-art 3D Pipes screen saver.
#   ./build.sh            -- build into ./build
#   ./build.sh --install  -- build, then install to ~/Library/Screen Savers
#
# Fully native: no web view, no resources. Sources: PipesSaverView.swift, Teapot.swift.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC_DIR/build"
SAVER="$BUILD/Pipes.saver"
SDK="$(xcrun --show-sdk-path)"
# Universal binary: one slice per architecture, joined with lipo.
ARCHS="${ARCHS:-arm64 x86_64}"

rm -rf "$BUILD"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

SLICES=()
for ARCH in $ARCHS; do
    TARGET="$ARCH-apple-macos14.0"
    echo "==> compiling ($ARCH)"
    # -parse-as-library is required: a single-file swiftc build otherwise treats
    # the file as a main file and never initialises globals when NSBundle loads
    # the bundle (crashes the host with signal 11).
    swiftc -O -wmo \
        -parse-as-library \
        -target "$TARGET" \
        -sdk "$SDK" \
        -module-name PipesSaver \
        -emit-object \
        -o "$BUILD/PipesSaver-$ARCH.o" \
        "$SRC_DIR/PipesSaverView.swift" "$SRC_DIR/Teapot.swift"

    echo "==> linking ($ARCH)"
    # Must be MH_BUNDLE (-bundle), not a dylib, for NSBundle principalClass loading.
    clang -bundle \
        -target "$TARGET" \
        -isysroot "$SDK" \
        -o "$BUILD/PipesSaver-$ARCH" \
        "$BUILD/PipesSaver-$ARCH.o" \
        -framework AppKit -framework ScreenSaver -framework QuartzCore \
        -L"$SDK/usr/lib/swift" \
        -Wl,-rpath,/usr/lib/swift
    SLICES+=("$BUILD/PipesSaver-$ARCH")
done

echo "==> lipo"
lipo -create "${SLICES[@]}" -output "$SAVER/Contents/MacOS/PipesSaver"
lipo -info "$SAVER/Contents/MacOS/PipesSaver"

echo "==> assembling bundle"
cp "$SRC_DIR/Info.plist" "$SAVER/Contents/Info.plist"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$SAVER"
codesign --verify --verbose "$SAVER"

echo "==> built $SAVER"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/Pipes.saver.old"
    [ -d "$DEST/Pipes.saver" ] && mv "$DEST/Pipes.saver" "$DEST/Pipes.saver.old"
    cp -R "$SAVER" "$DEST/Pipes.saver"
    rm -rf "$DEST/Pipes.saver.old"
    echo "==> installed to $DEST/Pipes.saver"
    echo "    (a running legacyScreenSaver host keeps the old code until it is restarted:"
    echo "     killall legacyScreenSaver)"
fi
