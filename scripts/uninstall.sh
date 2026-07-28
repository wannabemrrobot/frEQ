#!/bin/bash
# Removes the FrEQ HAL driver (and optionally the app) and restarts
# coreaudiod. Requires sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "==> Re-running with sudo"
    exec sudo "$0" "$@"
fi

DRIVER="/Library/Audio/Plug-Ins/HAL/FrEQ.driver"
APP="/Applications/FrEQ.app"

if [[ -d "$DRIVER" ]]; then
    echo "==> Removing $DRIVER"
    rm -rf "$DRIVER"
else
    echo "==> Driver not installed, skipping"
fi

if [[ -d "$APP" ]]; then
    echo "==> Removing $APP"
    rm -rf "$APP"
fi

echo "==> Restarting coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod

# Per-user settings live in the app's preferences domain; clear for the
# invoking user if run via sudo.
REAL_USER="${SUDO_USER:-$USER}"
sudo -u "$REAL_USER" defaults delete com.freq.app >/dev/null 2>&1 || true

echo "==> Uninstalled."
