#!/bin/sh
# Builds TrayTranslate.app into build/ and, with --install, copies it to /Applications.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product TrayTranslate
BIN="$(swift build -c release --show-bin-path)/TrayTranslate"
APP=build/TrayTranslate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/TrayTranslate"
codesign --force --sign - "$APP"
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
    pkill -x TrayTranslate && sleep 1 || true
    ditto "$APP" /Applications/TrayTranslate.app
    echo "installed /Applications/TrayTranslate.app"
fi
