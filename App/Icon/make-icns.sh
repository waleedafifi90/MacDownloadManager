#!/bin/zsh
# Renders the app icon and builds Icon/AppIcon.icns with every size macOS uses.
#   ./make-icns.sh [blue|dark|green]   (default: dark)
set -euo pipefail
cd "$(dirname "$0")"

style="${1:-dark}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift draw-icon.swift "$style" "$work/icon-1024.png"
set="$work/AppIcon.iconset"
mkdir -p "$set"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/icon-1024.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/icon-1024.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o AppIcon.icns
cp "$work/icon-1024.png" AppIcon-1024.png
echo "Built Icon/AppIcon.icns ($style)"
