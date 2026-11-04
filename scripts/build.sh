#!/bin/zsh
# Builds Encore.app with plain swiftc (no Xcode needed), ad-hoc signs it,
# and optionally installs it to /Applications (pass --install).
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
APP="$BUILD/Encore.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos26.0"
VERSION="1.0"

cd "$ROOT"
mkdir -p "$BUILD"

echo "▸ Codec self-test"
swiftc -O -target "$TARGET" -sdk "$SDK" -module-name SelfTest \
  Sources/EncoKit/*.swift Sources/EncoKitSelfTest/main.swift \
  -framework IOBluetooth -o "$BUILD/selftest"
"$BUILD/selftest" > /dev/null && echo "  all checks passed"

echo "▸ Compiling Encore"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$TARGET" -sdk "$SDK" -module-name Encore \
  Sources/EncoKit/*.swift Sources/Encore/*.swift \
  -framework IOBluetooth -framework ServiceManagement -framework UserNotifications \
  -o "$APP/Contents/MacOS/Encore"

echo "▸ App icon"
if [[ ! -f "$BUILD/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$BUILD/AppIcon.icns" ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Encore</string>
  <key>CFBundleDisplayName</key><string>Encore</string>
  <key>CFBundleIdentifier</key><string>app.encore.Encore</string>
  <key>CFBundleExecutable</key><string>Encore</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Encore talks to your OPPO earbuds over Bluetooth to show their battery and change their settings.</string>
  <key>NSHumanReadableCopyright</key><string>Made for OPPO Enco earbuds. Not affiliated with OPPO.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications"
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "▸ Installing to $DEST"
  pkill -x Encore 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST/Encore.app"
  cp -R "$APP" "$DEST/Encore.app"
  echo "  $DEST/Encore.app"
fi
echo "✓ Built $APP"
