#!/usr/bin/env bash
#
# Compiles Resources/Wicher.icon (an Icon Composer document) into the files the
# app bundle ships, and commits-ready previews. Needs full Xcode (actool, and
# ictool inside Icon Composer.app); build.sh only copies the outputs, so a
# Command-Line-Tools-only machine can still build. Re-run after editing the icon.
#
#   Resources/Assets.car  — the Liquid Glass icon with light/dark/tinted/clear
#                           renditions (macOS 26+, via CFBundleIconName)
#   Resources/Wicher.icns — flat fallback for older macOS (via CFBundleIconFile)
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
  --minimum-deployment-target 13.0 --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" Resources/Assets.car

# actool's own Wicher.icns stops at 256 px; build a full one from ictool renders,
# with the plate on the classic 824/1024 grid so it sits right on older macOS.
echo "▸ ictool → Wicher.icns…"
render Default 1024 "$TMP/full.png"
ISET="$TMP/Wicher.iconset"
mkdir "$ISET"
for s in 16 32 128 256 512; do
  for k in 1 2; do
    px=$((s * k)); body=$((px * 824 / 1024))
    suffix=""; [[ $k == 2 ]] && suffix="@2x"
    name="icon_${s}x${s}${suffix}.png"
    sips -z "$body" "$body" "$TMP/full.png" --out "$TMP/body.png" >/dev/null
    sips -p "$px" "$px" "$TMP/body.png" --out "$ISET/$name" >/dev/null
  done
done
iconutil -c icns "$ISET" -o Resources/Wicher.icns

echo "▸ Previews…"
mkdir -p Resources/preview
render Default 1024 Resources/preview/wicher-light.png
render Dark 1024 Resources/preview/wicher-dark.png

echo "✓ Icon assets updated"
