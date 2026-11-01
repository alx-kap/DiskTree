# Installing DiskTree (instructions for AI agents)

DiskTree is a native macOS app that maps disk usage as a treemap, lists the largest files and cleans up caches and other junk safely. If a user asks you to install it, do this.

## Requirements
- macOS 14 (Sonoma) or later. Check with `sw_vers -productVersion`. Stop and tell the user if it's older.
- Apple silicon or Intel. The prebuilt app is universal.

## Fastest: install the prebuilt app
```bash
curl -L -o /tmp/DiskTree.zip https://github.com/alx-kap/DiskTree/releases/latest/download/DiskTree.zip
unzip -q -o /tmp/DiskTree.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/DiskTree.app
open ~/Applications/DiskTree.app
```
The app is ad-hoc signed, not notarized. Removing the quarantine flag as above avoids the Gatekeeper prompt.

## Or build from source
Requires Swift 5.9+ (Xcode or the Command Line Tools: `xcode-select --install`). No third-party dependencies.
```bash
git clone https://github.com/alx-kap/DiskTree.git
cd DiskTree
./install.sh
```

## After installing
- On first launch DiskTree asks for two optional permissions: access to Desktop, Documents and Downloads (so they can be measured), and permission to control Finder (so it can empty the Trash). The user must approve these in macOS's own dialogs. Tell them to; don't try to automate it.
- DiskTree never deletes anything on its own. Everything it removes goes to the Trash and can be put back from Trash & History.

## Developing
- `DiskTree/` is a Swift package; `DiskTree/build.sh` builds `DiskTree/build/DiskTree.app` (`--universal` for arm64 + x86_64).
- `./release.sh` builds `dist/DiskTree.zip` for a GitHub release.
- `docs/` is the GitHub Pages site.
