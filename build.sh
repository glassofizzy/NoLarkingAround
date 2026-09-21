#!/bin/bash
# Builds NoLarkingAround.app. No Xcode project required — Command Line Tools suffice.
set -euo pipefail
cd "$(dirname "$0")"

APP="NoLarkingAround.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Fonts"

echo "compiling…"
swiftc -swift-version 5 -O Sources/*.swift -o "$CONTENTS/MacOS/NoLarkingAround"

cp Resources/Fonts/*.ttf "$CONTENTS/Resources/Fonts/"
cp Resources/Fonts/OFL-*.txt "$CONTENTS/Resources/Fonts/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NoLarkingAround</string>
  <key>CFBundleDisplayName</key><string>No Larking Around</string>
  <key>CFBundleIdentifier</key><string>com.traveloka.nolarkingaround</string>
  <key>CFBundleExecutable</key><string>NoLarkingAround</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu-bar agent: no dock icon, no main window. -->
  <key>LSUIElement</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHumanReadableCopyright</key><string>Internal tool. Fonts under OFL.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

# Ad-hoc signature: enough for a locally built binary, not notarised.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  && echo "ad-hoc signed" || echo "warning: codesign failed (app will still run)"

# Top-level CLI convenience copy — used by --selftest/--print-agenda/--snapshot
# without going through the .app bundle.
cp "$CONTENTS/MacOS/NoLarkingAround" nolarkingaround

echo "built $APP"
