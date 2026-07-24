#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
swift build --package-path "$ROOT" -c release
APP="$ROOT/build/Qwythos Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/QwythosControlApp" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
