#!/bin/zsh
# Builds DiskTree.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/DiskTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskTree "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift Support/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
