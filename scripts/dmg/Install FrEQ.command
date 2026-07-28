#!/bin/bash
# Double-clickable installer shipped inside the FrEQ DMG.
#
# It installs the two pieces that make FrEQ work:
#   1. FrEQ.app        -> /Applications
#   2. FrEQ.driver     -> /Library/Audio/Plug-Ins/HAL   (needs admin rights)
# then restarts coreaudiod so the virtual device appears. A single macOS
# password prompt covers the privileged steps.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/FrEQ.app"
DRIVER="$DIR/Support/FrEQ.driver"

echo "FrEQ installer"
echo "================"

if [[ ! -d "$APP" || ! -d "$DRIVER" ]]; then
    echo "error: FrEQ.app or Support/FrEQ.driver missing next to this installer." >&2
    echo "Run this from inside the mounted FrEQ disk image." >&2
    read -r -p "Press Return to close." _ || true
    exit 1
fi

# Quit a running copy so we can replace it cleanly.
osascript -e 'tell application "FrEQ" to quit' >/dev/null 2>&1 || true
pkill -x FrEQ >/dev/null 2>&1 || true

# All privileged steps run in one elevated shell (one password prompt). The
# steps are written to a temp script to avoid AppleScript quoting pitfalls.
PRIV="$(mktemp /tmp/freq-install.XXXXXX.sh)"
cat > "$PRIV" <<SCRIPT
#!/bin/bash
set -e
# App
rm -rf "/Applications/FrEQ.app"
cp -R "$APP" "/Applications/FrEQ.app"
xattr -cr "/Applications/FrEQ.app" 2>/dev/null || true
# Driver
mkdir -p "/Library/Audio/Plug-Ins/HAL"
rm -rf "/Library/Audio/Plug-Ins/HAL/FrEQ.driver"
cp -R "$DRIVER" "/Library/Audio/Plug-Ins/HAL/FrEQ.driver"
chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/FrEQ.driver"
xattr -cr "/Library/Audio/Plug-Ins/HAL/FrEQ.driver" 2>/dev/null || true
# Restart the audio server so the virtual device is published.
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
SCRIPT
chmod +x "$PRIV"

echo "Installing (you'll be asked for your password)…"
osascript -e "do shell script \"$PRIV\" with administrator privileges" >/dev/null
rm -f "$PRIV"

echo "Done. Launching FrEQ…"
open -a "/Applications/FrEQ.app" || true

cat <<'NOTE'

FrEQ is now in your menu bar (slider icon) and the "FrEQ" device is
available in System Settings > Sound.

First run: click the menu icon > Open Controls, flip Enable on, and grant
microphone access when asked. (macOS treats the virtual device's capture as
"microphone" use; FrEQ never records a real mic.)

You can close this window.
NOTE
