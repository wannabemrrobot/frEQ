#!/bin/bash
# Installs build/FrEQ.driver into /Library/Audio/Plug-Ins/HAL and restarts
# coreaudiod so the virtual device appears. Requires sudo.
#
# NOTE: restarting coreaudiod briefly interrupts all system audio.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE="$PWD/build/FrEQ.driver"
DEST="/Library/Audio/Plug-Ins/HAL"

if [[ ! -d "$BUNDLE" ]]; then
    echo "error: $BUNDLE not found — run scripts/build-driver.sh first" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "==> Re-running with sudo"
    exec sudo "$0" "$@"
fi

echo "==> Installing to $DEST/FrEQ.driver"
rm -rf "$DEST/FrEQ.driver"
cp -R "$BUNDLE" "$DEST/FrEQ.driver"
chown -R root:wheel "$DEST/FrEQ.driver"

echo "==> Restarting coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod

echo "==> Done. The 'FrEQ' device should appear in System Settings > Sound in a few seconds."
