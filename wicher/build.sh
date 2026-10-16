#!/usr/bin/env bash
#
# Builds wicher and assembles Wicher.app around the SwiftPM-produced binary.
# Requires an existing Swift toolchain (ships with Xcode / Command Line Tools).
# Installs nothing.

set -euo pipefail
cd "$(dirname "$0")"

APP="Wicher.app"
CONFIG="release"

echo "▸ Compiling (swift build -c $CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/wicher"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "✗ Build product not found at $BIN_PATH" >&2
  exit 1
fi

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/Wicher"
cp Info.plist "$APP/Contents/Info.plist"
# Icon: prebuilt by scripts/make-icon.sh from Resources/Wicher.icon (needs Xcode).
cp Resources/Assets.car Resources/Wicher.icns "$APP/Contents/Resources/"

# Sign with a stable identity when one exists, so the Accessibility grant
# survives rebuilds (see scripts/make-signing-identity.sh). Otherwise fall back
# to an ad-hoc signature, whose cdhash changes on every build — macOS then
# re-prompts for Accessibility after each one.
IDENTITY="${WICHER_SIGN_IDENTITY:-Wicher Development}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "▸ Code signing with \"$IDENTITY\"…"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "▸ Ad-hoc code signing (run scripts/make-signing-identity.sh for a stable identity)…"
  codesign --force --sign - "$APP"
fi

echo "✓ Built $PWD/$APP"
echo "  Launch it, grant Accessibility access when prompted, then press ⌥Tab."
