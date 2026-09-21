#!/bin/bash
# Registers NoLarkingAround to start at login. Run only when you actually want that;
# uninstall with:  launchctl unload ~/Library/LaunchAgents/com.traveloka.nolarkingaround.plist
set -euo pipefail
cd "$(dirname "$0")"

APP="$(pwd)/NoLarkingAround.app/Contents/MacOS/NoLarkingAround"
PLIST="$HOME/Library/LaunchAgents/com.traveloka.nolarkingaround.plist"

if [ ! -x "$APP" ]; then
  echo "error: $APP not built yet — run ./build.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_BODY
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.traveloka.nolarkingaround</string>
  <key>ProgramArguments</key>
  <array><string>$APP</string></array>
  <!-- launchd's default PATH omits /usr/local/bin, where node usually lives, and
       lark-cli is a node script. The app also repairs PATH itself. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/nolarkingaround.err</string>
</dict>
</plist>
PLIST_BODY

launchctl unload "$PLIST" 2>/dev/null || true

# Stop any hand-launched instance first. RunAtLoad + KeepAlive starts its own, and
# two agents would mean two menu-bar icons and two takeovers per meeting.
if pgrep -f "NoLarkingAround.app/Contents/MacOS/NoLarkingAround" >/dev/null 2>&1; then
  echo "stopping existing instance…"
  pkill -f "NoLarkingAround.app/Contents/MacOS/NoLarkingAround" || true
  sleep 1
fi

launchctl load "$PLIST"
sleep 2

# macOS pgrep has no -c, so count lines rather than trusting a flag that errors.
COUNT=$(pgrep -f "NoLarkingAround.app/Contents/MacOS/NoLarkingAround" | wc -l | tr -d " ")
echo "installed: starts at login, and running now (instances: $COUNT)."
[ "$COUNT" = "1" ] || echo "warning: expected exactly 1 instance, found $COUNT"
echo "logs: /tmp/nolarkingaround.err"
echo "uninstall: launchctl unload $PLIST && rm $PLIST"
