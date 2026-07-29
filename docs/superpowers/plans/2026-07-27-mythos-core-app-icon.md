# Mythos Core App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the Mythos Core artwork, package it as a complete macOS icon, and include it in every Qwythos Control app build.

**Architecture:** A generated 1024 px PNG is the visual source of truth. A focused shell script produces the required `.iconset` sizes and compiles `AppIcon.icns`; the existing app build copies that compiled resource and declares it in `Info.plist`.

**Tech Stack:** OpenAI built-in image generation, PNG, macOS `sips`, `actool`, zsh, Swift Package Manager, `plutil`, `codesign`

## Global Constraints

- Use a graphite-black macOS rounded-square base.
- Use intersecting cool silver-white and mint-cyan elliptical rings.
- Include a restrained vertical mint-cyan startup pulse at the center.
- Keep the design centered, symmetrical, text-free, and legible at 16 px.
- Do not include faces, circuitry, stars, or decorative background objects.

---

### Task 1: Generate and Approve the Master Artwork

**Files:**
- Create: `Resources/AppIcon.png`

**Interfaces:**
- Consumes: The approved visual constraints in `docs/superpowers/specs/2026-07-27-mythos-core-app-icon-design.md`.
- Produces: A square RGB/RGBA PNG with exact dimensions `1024 x 1024`.

- [ ] **Step 1: Generate the artwork**

Use the built-in image generation tool with this production prompt:

```text
Use case: logo-brand
Asset type: macOS application icon master
Primary request: Create the Mythos Core icon for Qwythos Control.
Subject: Two intersecting elliptical orbital rings surrounding a compact active core, with a short vertical startup pulse through the center.
Style/medium: Premium native macOS app icon, minimal geometric 3D relief, polished and vector-friendly.
Composition/framing: Perfectly centered and symmetrical inside a macOS rounded-square silhouette, generous optical padding, readable at 16 px.
Color palette: Graphite-black base, one cool silver-white ring, one restrained mint-cyan ring and pulse.
Lighting/mood: Subtle material depth with a restrained cyan glow only around the active core and cyan ring.
Constraints: Square 1024 x 1024; no text; no letters; crisp silhouette; no elements outside the icon.
Avoid: faces, circuitry, stars, particles, scenery, extra symbols, strong bloom, busy textures, watermark.
```

- [ ] **Step 2: Inspect the generated master**

Open the generated output and verify the ring count, palette, centered geometry,
absence of text, and adequate edge padding. Regenerate once with a targeted prompt
only if one of those invariants fails.

- [ ] **Step 3: Save and validate the master**

Run:

```bash
sips -g pixelWidth -g pixelHeight Resources/AppIcon.png
```

Expected: both dimensions are `1024`.

- [ ] **Step 4: Commit**

```bash
git add Resources/AppIcon.png
git commit -m "design: add Mythos Core app icon"
```

### Task 2: Build the macOS Icon Resource

**Files:**
- Create: `scripts/generate-iconset.sh`
- Create: `Resources/AppIconContents.json`
- Create: `Resources/AppIcon.icns`
- Generate and ignore after use: `build/AppIcon.xcassets/`

**Interfaces:**
- Consumes: `Resources/AppIcon.png`.
- Produces: `Resources/AppIcon.icns` containing every required macOS representation.

- [ ] **Step 1: Add the iconset generator**

Create `scripts/generate-iconset.sh`:

```zsh
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
```

- [ ] **Step 2: Validate script syntax before execution**

Run:

```bash
zsh -n scripts/generate-iconset.sh
```

Expected: exit code `0`.

- [ ] **Step 3: Generate and inspect the icon resource**

Run:

```bash
chmod +x scripts/generate-iconset.sh
scripts/generate-iconset.sh
file Resources/AppIcon.icns
find build/AppIcon.xcassets/AppIcon.appiconset -name '*.png' | sort
```

Expected: a valid Apple icon image with all ten standard iconset filenames.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-iconset.sh Resources/AppIconContents.json Resources/AppIcon.icns
git commit -m "build: package macOS app icon"
```

### Task 3: Integrate and Verify the App Bundle

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `Resources/AppIcon.icns`.
- Produces: `build/Qwythos Control.app` with a declared and bundled app icon.

- [ ] **Step 1: Add a failing bundle assertion**

Run before modifying the build:

```bash
scripts/build-app.sh
test -f "build/Qwythos Control.app/Contents/Resources/AppIcon.icns"
```

Expected: the assertion fails because the icon is not copied yet.

- [ ] **Step 2: Declare the app icon**

Add this entry before `CFBundlePackageType` in `Resources/Info.plist`:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

- [ ] **Step 3: Copy the compiled icon during builds**

Add after the existing `Info.plist` copy in `scripts/build-app.sh`:

```zsh
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
```

- [ ] **Step 4: Build and validate**

Run:

```bash
scripts/build-app.sh
test -f "build/Qwythos Control.app/Contents/Resources/AppIcon.icns"
test "$(plutil -extract CFBundleIconFile raw 'build/Qwythos Control.app/Contents/Info.plist')" = "AppIcon"
codesign --verify --deep --strict "build/Qwythos Control.app"
```

Expected: all commands exit `0`.

- [ ] **Step 5: Run the project tests**

Run:

```bash
swift test
```

Expected: all QwythosCore tests pass.

- [ ] **Step 6: Commit**

```bash
git add Resources/Info.plist scripts/build-app.sh
git commit -m "feat: bundle Mythos Core app icon"
```
