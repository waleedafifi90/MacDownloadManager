#!/bin/zsh
# Builds a universal MacDownloadManager.app and packs it into
# build/MacDownloadManager-<version>.dmg (drag to Applications), with its SHA-256.
#   ./make-dmg.sh 0.1.2   (also writes <dmg>.sig, signed with the key from mdm-release keygen)
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: ./make-dmg.sh <version>}"
VERSION="$version" UNIVERSAL=1 ./make-app.sh

staging=build/dmg
dmg="build/MacDownloadManager-$version.dmg"
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R build/MacDownloadManager.app "$staging/"
ln -s /Applications "$staging/Applications"

hdiutil create -quiet -volname "Mac Download Manager $version" -srcfolder "$staging" -format UDZO -ov "$dmg"
rm -rf "$staging"
shasum -a 256 "$dmg" | tee "$dmg.sha256"

# The app only installs updates signed with the release key (in the maintainer's Keychain).
swift build -c release --product mdm-release
"$(swift build -c release --show-bin-path)/mdm-release" sign "$dmg"
echo "Built $dmg and $dmg.sig"
