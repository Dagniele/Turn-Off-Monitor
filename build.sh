#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/SpegniMSI.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -swift-version 5 -O -whole-module-optimization \
  -o "$APP/Contents/MacOS/SpegniMSI" \
  src/SkyLight.swift src/Displays.swift src/CLI.swift src/main.swift \
  -framework AppKit -framework CoreGraphics -framework ServiceManagement

codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$HOME/Applications/SpegniMSI.app"
cp -R "$APP" "$HOME/Applications/SpegniMSI.app"
ln -sfn "$HOME/Applications/SpegniMSI.app/Contents/MacOS/SpegniMSI" "$HOME/.local/bin/spegnimsi"

echo "Installato in ~/Applications/SpegniMSI.app"
