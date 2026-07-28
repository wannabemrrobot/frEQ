#!/bin/bash
# Builds a shareable disk image: build/FrEQ.dmg
#
# The DMG contains FrEQ.app, the HAL driver (in Support/), a double-clickable
# installer/uninstaller, example profiles, and a README. Uses only hdiutil
# (built in) — no third-party tooling.
#
# Usage:
#   scripts/create-dmg.sh                         ad-hoc signed (local sharing)
#   scripts/create-dmg.sh --sign "Developer ID Application: Name (TEAMID)"
#                                                 Developer ID (for notarizing)
#
# For distribution beyond your own machines, sign with a Developer ID and then
# notarize + staple (see docs/DISTRIBUTION.md).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
STAGE="$BUILD/dmg-stage"
DMG="$BUILD/FrEQ.dmg"
VOL="FrEQ"
SIGN_IDENTITY=""

if [[ "${1:-}" == "--sign" ]]; then
    SIGN_IDENTITY="${2:?usage: create-dmg.sh --sign <identity>}"
fi

SIGNFLAG=()
if [[ -n "$SIGN_IDENTITY" ]]; then
    SIGNFLAG=(--sign "$SIGN_IDENTITY")
fi

echo "==> Building universal driver + app"
scripts/build-driver.sh ${SIGNFLAG[@]+"${SIGNFLAG[@]}"}
scripts/build-app.sh ${SIGNFLAG[@]+"${SIGNFLAG[@]}"}

echo "==> Staging DMG contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/Support"
cp -R "$BUILD/FrEQ.app" "$STAGE/FrEQ.app"
cp -R "$BUILD/FrEQ.driver" "$STAGE/Support/FrEQ.driver"
cp "scripts/dmg/Install FrEQ.command"   "$STAGE/"
cp "scripts/dmg/Uninstall FrEQ.command" "$STAGE/"
cp "scripts/dmg/README.txt" "$STAGE/"
if [[ -d "$ROOT/Profiles" ]]; then
    cp -R "$ROOT/Profiles" "$STAGE/Profiles"
fi
chmod +x "$STAGE/Install FrEQ.command" "$STAGE/Uninstall FrEQ.command"

# hdiutil follows the directory as-is; keep it tidy.
find "$STAGE" -name ".DS_Store" -delete 2>/dev/null || true

echo "==> Creating compressed disk image"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing DMG"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

echo "==> Done: $DMG"
hdiutil imageinfo "$DMG" | grep -E "Format:|Compressed" | head -3 || true
ls -lh "$DMG" | awk '{print "    size:", $5}'

if [[ -z "$SIGN_IDENTITY" ]]; then
    cat <<'NOTE'

Note: this DMG is ad-hoc signed. On another Mac the recipient must
right-click > Open the installer once (unidentified developer). For
friction-free distribution, rebuild with --sign "Developer ID Application: …"
and notarize (see docs/DISTRIBUTION.md).
NOTE
fi
