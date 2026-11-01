#!/bin/zsh
# Build a universal DiskTree.app and package it as dist/DiskTree.zip for a GitHub release.
# No Apple Developer account needed (ad-hoc signed).
set -e
cd "$(dirname "$0")"
DiskTree/build.sh --universal
mkdir -p dist && rm -f dist/DiskTree.zip
ditto -c -k --keepParent DiskTree/build/DiskTree.app dist/DiskTree.zip
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" DiskTree/Support/Info.plist)
echo "Built dist/DiskTree.zip (version $VERSION)"
lipo -archs DiskTree/build/DiskTree.app/Contents/MacOS/DiskTree
shasum -a 256 dist/DiskTree.zip
