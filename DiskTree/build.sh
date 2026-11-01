#!/bin/zsh
# Builds DiskTree.app into ./build. Pass --universal for an Apple silicon + Intel build.
set -euo pipefail
cd "$(dirname "$0")"
# Build outside iCloud Drive: its extended attributes make codesign fail.
SCRATCH=~/Library/Caches/DiskTree/swiftpm
FLAGS=(-c release --scratch-path "$SCRATCH")
[[ "${1:-}" == "--universal" ]] && FLAGS+=(--arch arm64 --arch x86_64)
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/DiskTree"
APP=build/DiskTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
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
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
