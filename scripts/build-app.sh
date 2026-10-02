#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p build
staging="$(mktemp -d build/.gonzo-build.XXXXXX)"
app="$staging/Gonzo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/Gonzo" "$app/Contents/MacOS/Gonzo"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
if [ ! -f Resources/Gonzo.icns ] || [ scripts/make-icon.swift -nt Resources/Gonzo.icns ]; then
    swift scripts/make-icon.swift build/Gonzo.iconset
    iconutil -c icns build/Gonzo.iconset -o Resources/Gonzo.icns
fi
cp Resources/Gonzo.icns "$app/Contents/Resources/Gonzo.icns"
codesign --force --sign "${GONZO_SIGNING_IDENTITY:--}" --options runtime --entitlements Resources/Gonzo.entitlements "$app"
codesign --verify --deep --strict "$app"
# Never overwrite a mapped executable: keep the previous bundle intact for
# any running process, and publish the fully signed replacement by renaming.
if [ -e build/Gonzo.app ]; then
    mv build/Gonzo.app "$staging/Previous.app"
fi
if ! mv "$app" build/Gonzo.app; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" build/Gonzo.app; fi
    exit 1
fi
echo "Built build/Gonzo.app"
