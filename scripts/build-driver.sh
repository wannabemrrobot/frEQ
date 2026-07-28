#!/bin/bash
# Builds FrEQ.driver — the Core Audio HAL AudioServerPlugIn — as a universal
# (arm64 + x86_64) bundle at build/FrEQ.driver.
#
# Usage: scripts/build-driver.sh [--sign "Developer ID Application: ..."]
#        (default signing is ad-hoc, which is sufficient for local use)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
BUNDLE="$BUILD/FrEQ.driver"
SIGN_IDENTITY="-"   # ad-hoc by default

if [[ "${1:-}" == "--sign" ]]; then
    SIGN_IDENTITY="${2:?usage: build-driver.sh --sign <identity>}"
fi

MIN_OS="13.0"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

mkdir -p "$BUILD/obj"

echo "==> Compiling driver (arm64 + x86_64)"
for ARCH in arm64 x86_64; do
    clang \
        -arch "$ARCH" \
        -isysroot "$SDK_PATH" \
        -mmacosx-version-min="$MIN_OS" \
        -bundle \
        -O2 \
        -Wall -Wextra -Wno-unused-parameter \
        -fno-objc-arc \
        -framework CoreAudio \
        -framework CoreFoundation \
        -o "$BUILD/obj/FrEQDriver-$ARCH" \
        Driver/FrEQDriver.c
done

echo "==> Creating universal binary"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
lipo -create \
    "$BUILD/obj/FrEQDriver-arm64" \
    "$BUILD/obj/FrEQDriver-x86_64" \
    -output "$BUNDLE/Contents/MacOS/FrEQDriver"
cp Driver/Info.plist "$BUNDLE/Contents/Info.plist"

echo "==> Signing ($SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE"

echo "==> Done: $BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/FrEQDriver"
codesign -dv "$BUNDLE" 2>&1 | head -3
