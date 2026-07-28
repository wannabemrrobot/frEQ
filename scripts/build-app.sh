#!/bin/bash
# Builds FrEQ.app (menu-bar host app) as a universal binary at build/FrEQ.app.
#
# Usage: scripts/build-app.sh [--sign "Developer ID Application: ..."] [--arch arm64|x86_64]
#        (default: ad-hoc signing, both architectures)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
BUNDLE="$BUILD/FrEQ.app"
SIGN_IDENTITY="-"
ARCHS=(arm64 x86_64)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN_IDENTITY="${2:?}"; shift 2 ;;
        --arch) ARCHS=("${2:?}"); shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

MIN_OS="13.0"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_SOURCES=(App/Sources/*.swift App/Sources/Audio/*.swift App/Sources/EQ/*.swift App/Sources/UI/*.swift)

mkdir -p "$BUILD/obj"

C_SOURCES=(App/Sources/Audio/AERingBuffer.c App/Sources/Audio/AEDSP.c)

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    C_OBJECTS=()
    for SRC in "${C_SOURCES[@]}"; do
        NAME="$(basename "$SRC" .c)"
        echo "==> Compiling $NAME ($ARCH)"
        clang -c \
            -arch "$ARCH" \
            -isysroot "$SDK_PATH" \
            -mmacosx-version-min="$MIN_OS" \
            -O2 -Wall -Wextra -std=c11 \
            -o "$BUILD/obj/$NAME-$ARCH.o" \
            "$SRC"
        C_OBJECTS+=("$BUILD/obj/$NAME-$ARCH.o")
    done

    echo "==> Compiling app ($ARCH)"
    swiftc \
        -target "$ARCH-apple-macosx$MIN_OS" \
        -sdk "$SDK_PATH" \
        -O \
        -swift-version 5 \
        -parse-as-library \
        -import-objc-header App/Sources/BridgingHeader.h \
        -framework CoreAudio \
        -framework AudioToolbox \
        -framework AVFoundation \
        -framework AppKit \
        -o "$BUILD/obj/FrEQ-$ARCH" \
        "${SWIFT_SOURCES[@]}" \
        "${C_OBJECTS[@]}"
    BINARIES+=("$BUILD/obj/FrEQ-$ARCH")
done

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
if [[ ${#BINARIES[@]} -gt 1 ]]; then
    lipo -create "${BINARIES[@]}" -output "$BUNDLE/Contents/MacOS/FrEQ"
else
    cp "${BINARIES[0]}" "$BUNDLE/Contents/MacOS/FrEQ"
fi
cp App/Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# App icon (generate once via scripts/make-icon.sh).
if [[ -f App/Resources/FrEQ.icns ]]; then
    mkdir -p "$BUNDLE/Contents/Resources"
    cp App/Resources/FrEQ.icns "$BUNDLE/Contents/Resources/FrEQ.icns"
fi

echo "==> Signing ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$BUNDLE"
else
    # Hardened runtime + entitlements for notarizable distribution builds.
    codesign --force --options runtime --timestamp \
        --entitlements App/Resources/FrEQ.entitlements \
        --sign "$SIGN_IDENTITY" "$BUNDLE"
fi

echo "==> Done: $BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/FrEQ" 2>/dev/null || true
