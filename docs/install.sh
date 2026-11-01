#!/bin/bash
# Installs the latest DiskTree release into ~/Applications.
# Usage: curl -fsSL https://alx-kap.github.io/DiskTree/install.sh | bash
set -euo pipefail
URL=https://github.com/alx-kap/DiskTree/releases/latest/download/DiskTree.zip
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading DiskTree…"
curl -fsSL -o "$TMP/DiskTree.zip" "$URL"
mkdir -p ~/Applications
pkill -x DiskTree 2>/dev/null || true
rm -rf ~/Applications/DiskTree.app
unzip -q -o "$TMP/DiskTree.zip" -d ~/Applications
# DiskTree is ad-hoc signed, not notarized. Clearing the quarantine flag skips the Gatekeeper prompt.
xattr -dr com.apple.quarantine ~/Applications/DiskTree.app 2>/dev/null || true
echo "Installed ~/Applications/DiskTree.app"
open ~/Applications/DiskTree.app
