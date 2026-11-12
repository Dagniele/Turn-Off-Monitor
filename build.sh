#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

killall SpegniMSI 2>/dev/null || true
killall TurnOffMonitor 2>/dev/null || true
rm -rf "$HOME/Applications/SpegniMSI.app"
rm -f "$HOME/.local/bin/spegnimsi"
defaults delete com.danielepagano.spegnimsi >/dev/null 2>&1 || true

APP="dist/Turn Off Monitor.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -swift-version 5 -O -whole-module-optimization \
  -o "$APP/Contents/MacOS/TurnOffMonitor" \
  src/SkyLight.swift src/Displays.swift src/CLI.swift src/main.swift \
  -framework AppKit -framework CoreGraphics -framework ServiceManagement

codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$HOME/Applications/Turn Off Monitor.app"
cp -R "$APP" "$HOME/Applications/Turn Off Monitor.app"
ln -sfn "$HOME/Applications/Turn Off Monitor.app/Contents/MacOS/TurnOffMonitor" "$HOME/.local/bin/turnoffmonitor"

echo "Installed ~/Applications/Turn Off Monitor.app"
