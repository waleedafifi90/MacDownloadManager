#!/bin/zsh
# Builds a release binary and wraps it in build/MacDownloadManager.app.
#   VERSION=0.1.2   version shown in Finder and About (default: the VERSION file)
#   UNIVERSAL=1     one app for both Apple silicon and Intel Macs (for releases)
set -euo pipefail
cd "$(dirname "$0")"

version="${VERSION:-$(cat VERSION)}"
arch_flags=()
[[ "${UNIVERSAL:-0}" == 1 ]] && arch_flags=(--arch arm64 --arch x86_64)

swift build -c release $arch_flags --product MacDownloadManager
swift build -c release $arch_flags --product mdm-native-host
bin="$(swift build -c release $arch_flags --show-bin-path)"
app=build/MacDownloadManager.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MacDownloadManager" "$bin/mdm-native-host" "$app/Contents/MacOS/"
# The Chrome extension (only the chrome/ folder; the signing key in keys/ stays out).
cp -R BrowserExtension/chrome "$app/Contents/Resources/ChromeExtension"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacDownloadManager</string>
    <key>CFBundleDisplayName</key><string>Mac Download Manager</string>
    <key>CFBundleIdentifier</key><string>local.macdownloadmanager</string>
    <key>CFBundleExecutable</key><string>MacDownloadManager</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally. The helper is signed first: universal
# builds leave it unsigned, and an app can't be signed around an unsigned executable.
codesign --force --sign - "$app/Contents/MacOS/mdm-native-host"
codesign --force --sign - "$app"
echo "Built $app"
