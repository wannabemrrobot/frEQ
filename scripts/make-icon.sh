#!/bin/bash
# Renders the FrEQ app icon (green squircle + white waveform) and builds
# App/Resources/FrEQ.icns. Run once; build-app.sh copies the result into the
# bundle. Regenerate only when the icon design changes.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rendering 1024px icon"
cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
// macOS icon grid: rounded-rect inset from the edges, continuous-ish corners.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let radius = rect.width * 0.2237

let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.26, green: 0.83, blue: 0.45, alpha: 1),
    NSColor(calibratedRed: 0.11, green: 0.63, blue: 0.31, alpha: 1),
])!
grad.draw(in: rect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// White waveform glyph, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let s = base.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (size - s.width)/2, y: (size - s.height)/2, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments[1]
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT
swift "$WORK/render.swift" "$WORK/icon_1024.png"

echo "==> Building iconset"
ICONSET="$WORK/FrEQ.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$WORK/icon_1024.png" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
cp "$WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/App/Resources/FrEQ.icns"
echo "==> Wrote App/Resources/FrEQ.icns"
