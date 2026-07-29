# Mythos Core App Icon Design

## Goal

Create a distinctive macOS application icon for Qwythos Control that communicates
local model activity, control, and the mysterious character of the Mythos model.

## Visual Direction

- Use a standard macOS rounded-square app icon silhouette.
- Use a graphite-black base with subtle material depth rather than a flat black fill.
- Place two intersecting elliptical rings around a compact central core.
- Render one ring in cool silver-white and the other in restrained mint-cyan.
- Add a short vertical mint-cyan pulse through the center to suggest model startup.
- Keep the composition centered, symmetrical, and readable at 16 px.
- Use restrained glow only around the active core and cyan ring.
- Do not include letters, words, faces, circuitry, stars, or decorative background objects.

## Deliverables

- A 1024 x 1024 PNG master in `Resources/AppIcon.png`.
- A complete macOS iconset containing 16, 32, 128, 256, 512, and 1024 px variants.
- A compiled `Resources/AppIcon.icns`.
- App bundle integration through `Resources/Info.plist` and `scripts/build-app.sh`.

## Validation

- Inspect the master and representative small icon sizes visually.
- Confirm the iconset contains all required macOS filenames and dimensions.
- Build the app and confirm the `.icns` file is present in the app bundle.
- Confirm `Info.plist` points to the bundled icon resource.
