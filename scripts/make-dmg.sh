#!/bin/zsh
# Builds a universal Encore.app and wraps it in a drag-to-install disk image:
#   build/Encore.dmg  (Encore.app + Applications shortcut + a styled background)
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
VOL="Encore"
STAGE="$BUILD/dmg-stage"
RW="$BUILD/Encore-rw.dmg"
OUT="$BUILD/Encore.dmg"

cd "$ROOT"
"$ROOT/scripts/build.sh"

echo "▸ DMG background"
rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
swift "$ROOT/scripts/make-dmg-background.swift" "$BUILD" > /dev/null
tiffutil -cathidpicheck "$BUILD/background.png" "$BUILD/background@2x.png" \
  -out "$STAGE/.background/background.tiff" 2>/dev/null

echo "▸ Staging"
cp -R "$BUILD/Encore.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Creating image"
# Detach any stale mount with the same name first.
for dev in $(hdiutil info | awk '/\/Volumes\/Encore/ {print $1}'); do hdiutil detach "$dev" -force -quiet || true; done
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 40m -ov "$RW"
MOUNT_DIR="/Volumes/$VOL"
DEV=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1}')

echo "▸ Arranging the Finder window"
# Needs permission for Terminal/your shell to control Finder. If it's denied, the DMG still
# works, just without the background and icon layout.
if ! perl -e 'alarm 90; exec @ARGV' osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Encore.app" of container window to {170, 200}
    set position of item "Applications" of container window to {470, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "  (couldn't style the window – continuing with a plain layout)"
fi
chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true
sync
hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet

echo "▸ Compressing"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f "$RW"
hdiutil verify -quiet "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
