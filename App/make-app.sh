#!/bin/zsh
# Builds a release binary and wraps it in build/MacDownloadManager.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product MacDownloadManager
swift build -c release --product mdm-native-host
bin="$(swift build -c release --show-bin-path)"
app=build/MacDownloadManager.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MacDownloadManager" "$bin/mdm-native-host" "$app/Contents/MacOS/"
# The Chrome extension (only the chrome/ folder; the signing key in keys/ stays out).
cp -R BrowserExtension/chrome "$app/Contents/Resources/ChromeExtension"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacDownloadManager</string>
    <key>CFBundleDisplayName</key><string>Mac Download Manager</string>
    <key>CFBundleIdentifier</key><string>local.macdownloadmanager</string>
    <key>CFBundleExecutable</key><string>MacDownloadManager</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally.
codesign --force --sign - "$app"
echo "Built $app"
