#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="${1:-$ROOT/build/Qwythos Control.app}"
EXECUTABLE="$APP/Contents/MacOS/QwythosControlApp"
MANIFEST="$APP/Contents/Resources/QwythosControl_QwythosDeployment.bundle/deployment-manifest.json"

test -x "$EXECUTABLE"
test -f "$MANIFEST"

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/qwythos-packaging.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
RELOCATED_APP="$TEMPORARY_DIRECTORY/Qwythos Control.app"
ditto "$APP" "$RELOCATED_APP"

SANDBOX_PROFILE="$TEMPORARY_DIRECTORY/deny-build.sb"
cat > "$SANDBOX_PROFILE" <<EOF
(version 1)
(deny file-read* (subpath "$ROOT/.build"))
(allow default)
EOF

RUNTIME_VERSION="$(
    sandbox-exec -f "$SANDBOX_PROFILE" \
        "$RELOCATED_APP/Contents/MacOS/QwythosControlApp" \
        --verify-deployment-resources
)"
test "$RUNTIME_VERSION" = "b10159"
