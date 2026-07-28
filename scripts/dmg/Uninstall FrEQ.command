#!/bin/bash
# Double-clickable uninstaller shipped inside the FrEQ DMG. Removes the app,
# the HAL driver, and restarts coreaudiod. One password prompt.
set -euo pipefail

echo "FrEQ uninstaller"
echo "=================="

osascript -e 'tell application "FrEQ" to quit' >/dev/null 2>&1 || true
pkill -x FrEQ >/dev/null 2>&1 || true

REAL_USER="$(id -un)"
PRIV="$(mktemp /tmp/freq-uninstall.XXXXXX.sh)"
cat > "$PRIV" <<SCRIPT
#!/bin/bash
set -e
rm -rf "/Applications/FrEQ.app"
rm -rf "/Library/Audio/Plug-Ins/HAL/FrEQ.driver"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
SCRIPT
chmod +x "$PRIV"

echo "Removing FrEQ (you'll be asked for your password)…"
osascript -e "do shell script \"$PRIV\" with administrator privileges" >/dev/null
rm -f "$PRIV"

# Per-user settings live in the invoking user's preferences domain.
defaults delete com.freq.app >/dev/null 2>&1 || true

echo "Uninstalled. You can close this window."
