#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
swift build --package-path "$ROOT" -c release
APP="$ROOT/build/Qwythos Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/QwythosControlApp" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
DEPLOYMENT_BUNDLE="$ROOT/.build/release/QwythosControl_QwythosDeployment.bundle"
test -d "$DEPLOYMENT_BUNDLE"
ditto "$DEPLOYMENT_BUNDLE" \
    "$APP/Contents/Resources/QwythosControl_QwythosDeployment.bundle"
codesign --force --deep --sign - "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
"$ROOT/scripts/check-packaged-app.sh" "$APP"
printf '%s\n' "$APP"
