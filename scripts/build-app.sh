#!/bin/sh
# Builds TrayTranslate.app into build/ and, with --install, copies it to ~/Applications.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product TrayTranslate
BIN="$(swift build -c release --show-bin-path)/TrayTranslate"
APP=build/TrayTranslate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/TrayTranslate"
codesign --force --sign - "$APP"
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
    pkill -x TrayTranslate && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/TrayTranslate.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "installed $HOME/Applications/TrayTranslate.app"
fi
