#!/usr/bin/env bash
# Redraws the app icon, Resources/AppIcon.icon, from Sources/MacOSAgentCore/AppIconDrawing.swift,
# and the picture of it in docs/icon.png. Run it after changing the drawing. bundle.sh
# compiles the icon itself.
#
#   scripts/render-icon.sh      # the shipped design, AppIconDrawing.shipped
#   scripts/render-icon.sh 3    # design 3 of the four instead
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -o "$WORK/render-icon" scripts/icon/main.swift Sources/MacOSAgentCore/AppIconDrawing.swift
"$WORK/render-icon" Resources/AppIcon.icon "$@"

# The README's picture, drawn by Icon Composer's own renderer with the system's glass.
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ -x "$ICTOOL" ]]; then
  # Absolute paths, like actool's in bundle.sh, in case ictool also resolves them
  # somewhere other than this folder.
  "$ICTOOL" "$PWD/Resources/AppIcon.icon" --export-image --output-file "$PWD/docs/icon.png" \
    --platform macOS --rendition Default --width 256 --height 256 --scale 2 >/dev/null
  echo "Drew docs/icon.png"
else
  echo "warning: Icon Composer's ictool is not in this Xcode, so docs/icon.png is unchanged" >&2
fi
