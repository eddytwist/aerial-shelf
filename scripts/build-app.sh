#!/bin/zsh
# Builds the menu bar app as a signed .app bundle without Xcode (Command Line Tools are enough).
# Usage: scripts/build-app.sh [--install] [--debug] [--universal] [--dmg]
#   --install    copy the app to /Applications (or ~/Applications when /Applications is not writable)
#   --debug      debug build with the testing launch options from DebugOptions.swift
#   --universal  one binary for Apple Silicon and Intel
#   --dmg        also make build/AerialShelf-<version>.dmg (the app and a link to Applications), for releases
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/app.config

CONFIG="release"
INSTALL=0
UNIVERSAL=0
DMG=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --dmg) DMG=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build -c "$CONFIG" --product AerialShelfApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN/AerialShelfApp"
if [[ "$UNIVERSAL" == 1 ]]; then
  # The Intel slice is built separately (no Xcode needed) and joined with lipo.
  swift build -c "$CONFIG" --product AerialShelfApp --triple x86_64-apple-macosx26.0 --scratch-path .build-x86_64
  INTEL="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx26.0 --scratch-path .build-x86_64 --show-bin-path)/AerialShelfApp"
  mkdir -p build/universal
  lipo -create "$EXECUTABLE" "$INTEL" -output build/universal/AerialShelfApp
  EXECUTABLE="build/universal/AerialShelfApp"
fi

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/${APP_NAME}"
cp -R Sources/AerialShelfApp/Resources/*.lproj "$APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built: $APP ($(lipo -archs "$APP/Contents/MacOS/${APP_NAME}"))"

if [[ "$DMG" == 1 ]]; then
  # A plain disk image: the app next to a link to Applications, ready to drag over.
  STAGE="build/dmg"
  IMAGE="build/AerialShelf-${VERSION}.dmg"
  rm -rf "$STAGE" "$IMAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$IMAGE" >/dev/null
  rm -rf "$STAGE"
  echo "disk image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
fi

if [[ "$INSTALL" == 1 ]]; then
  # /Applications when writable (admin users), otherwise ~/Applications.
  DEST="/Applications"
  [[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  # Quit only the installed copy, and open the new one again if it was running.
  WAS_RUNNING=0
  if pgrep -f "$DEST/${APP_NAME}.app/Contents/MacOS" >/dev/null; then
    WAS_RUNNING=1
    pkill -f "$DEST/${APP_NAME}.app/Contents/MacOS" || true
    sleep 1
  fi
  rm -rf "$DEST/${APP_NAME}.app"
  cp -R "$APP" "$DEST/"
  echo "installed: $DEST/${APP_NAME}.app"
  if [[ "$WAS_RUNNING" == 1 ]]; then
    open "$DEST/${APP_NAME}.app"
    echo "reopened: $DEST/${APP_NAME}.app"
  fi
fi
