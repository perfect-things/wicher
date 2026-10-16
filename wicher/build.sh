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

echo "▸ Ad-hoc code signing…"
# Ad-hoc signature (identity "-"). Note: the signature's cdhash changes on each
# rebuild, so macOS may re-prompt for Accessibility access after rebuilding.
codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "✓ Built $PWD/$APP"
echo "  Launch it, grant Accessibility access when prompted, then press ⌥Tab."
