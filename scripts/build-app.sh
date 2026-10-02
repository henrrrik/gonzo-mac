#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
app="build/Gonzo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Gonzo" "$app/Contents/MacOS/Gonzo"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
if [ ! -f Resources/Gonzo.icns ] || [ scripts/make-icon.swift -nt Resources/Gonzo.icns ]; then
    swift scripts/make-icon.swift build/Gonzo.iconset
    iconutil -c icns build/Gonzo.iconset -o Resources/Gonzo.icns
fi
cp Resources/Gonzo.icns "$app/Contents/Resources/Gonzo.icns"
codesign --force --sign - "$app"
echo "Built $app"
