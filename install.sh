#!/bin/zsh
# Build DiskTree from source and install it to ~/Applications.
set -e
cd "$(dirname "$0")"
if ! command -v swift >/dev/null 2>&1; then
  echo "DiskTree needs Swift to build. Install Xcode, or run: xcode-select --install" >&2
  echo "(Prefer not to? Download the prebuilt DiskTree.zip from the Releases page instead.)" >&2
  exit 1
fi
DiskTree/build.sh
pkill -x DiskTree 2>/dev/null || true
A=~/Applications/DiskTree.app
mkdir -p ~/Applications && rm -rf "$A" && cp -R DiskTree/build/DiskTree.app "$A"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A"
echo "Installed $A"
open "$A"
