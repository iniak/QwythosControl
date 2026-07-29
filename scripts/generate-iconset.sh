#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Resources/AppIcon.png"
CATALOG="$ROOT/build/AppIcon.xcassets"
ICONSET="$CATALOG/AppIcon.appiconset"
COMPILE_OUTPUT="$ROOT/build/AppIcon.compile"
OUTPUT="$ROOT/Resources/AppIcon.icns"

test -f "$SOURCE"
rm -rf "$CATALOG" "$COMPILE_OUTPUT"
mkdir -p "$ICONSET" "$COMPILE_OUTPUT"
cp "$ROOT/Resources/AppIconContents.json" "$ICONSET/Contents.json"

typeset -a sizes=(16 32 128 256 512)
for size in $sizes; do
    sips -z "$size" "$size" "$SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null

    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" "$SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

xcrun actool "$CATALOG" \
    --compile "$COMPILE_OUTPUT" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$COMPILE_OUTPUT/partial.plist" \
    --warnings \
    --notices \
    --errors >/dev/null

cp "$COMPILE_OUTPUT/AppIcon.icns" "$OUTPUT"
printf '%s\n' "$OUTPUT"
