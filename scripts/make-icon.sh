#!/usr/bin/env bash
#
# Compiles Resources/Wicher.icon (an Icon Composer document) into the files the
# app bundle ships, and commits-ready previews. Needs full Xcode (actool, and
# ictool inside Icon Composer.app); scripts/build.sh only copies the outputs, so a
# Command-Line-Tools-only machine can still build. Re-run after editing the icon.
#
#   Resources/Assets.car  — the Liquid Glass icon with light/dark/tinted/clear
#                           renditions (via CFBundleIconName)
#   Resources/preview/    — 1024 px light/dark renders

set -euo pipefail
cd "$(dirname "$0")/.."

ICON="Resources/Wicher.icon"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() { # rendition size output
  "$ICTOOL" "$ICON" --export-image --output-file "$3" --platform macOS \
    --rendition "$1" --width "$2" --height "$2" --scale 1 >/dev/null
}

echo "▸ actool → Assets.car…"
xcrun actool "$ICON" --compile "$TMP" --app-icon Wicher --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" Resources/Assets.car

echo "▸ Previews…"
mkdir -p Resources/preview
render Default 1024 Resources/preview/wicher-light.png
render Dark 1024 Resources/preview/wicher-dark.png

echo "✓ Icon assets updated"
