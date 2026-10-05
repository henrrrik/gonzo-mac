#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Package the signed, verified build/Gonzo.app into a compressed disk image
# with an Applications shortcut, then check the image before publishing it.
app=build/Gonzo.app
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9A-Za-z.-]+$ ]] || { echo "Unexpected version: $version" >&2; exit 1; }
dmg="build/Gonzo-$version.dmg"
work="$(mktemp -d build/.gonzo-dmg.XXXXXX)"
mount="$work/mount"
# Under pipefail, grep -q closing a pipe early would fail a matching pipeline,
# so outputs are captured before they are searched.
mounted() { local mounts; mounts="$(mount)"; grep -Fq " on $(cd "$mount" 2>/dev/null && pwd -P) (" <<< "$mounts"; }
# Spotlight or XProtect can hold a freshly mounted volume briefly.
detach() {
    local attempt
    for attempt in 1 2 3 4 5; do
        hdiutil detach -quiet "$mount" 2>/dev/null && return 0
        sleep 1
    done
    hdiutil detach -quiet -force "$mount"
}
cleanup() {
    if mounted; then detach 2>/dev/null || true; fi
    # Never delete through a volume that is still attached.
    if mounted; then echo "Left $work because its image is still attached." >&2; return; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/root" "$mount"
ditto "$app" "$work/root/Gonzo.app"
ln -s /Applications "$work/root/Applications"
hdiutil create -quiet -volname "Gonzo $version" -srcfolder "$work/root" -fs APFS -format UDZO "$work/Gonzo.dmg"
hdiutil verify -quiet "$work/Gonzo.dmg"
# Mount read-only and check the packaged app, not just the source bundle.
diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$mount" "$work/Gonzo.dmg" >/dev/null
codesign --verify --deep --strict "$mount/Gonzo.app"
# The distributed app keeps Hardened Runtime and gains no network access.
signature="$(codesign -d --verbose=2 "$mount/Gonzo.app" 2>&1)"
grep -q 'flags=.*runtime' <<< "$signature"
entitlements="$(codesign -d --entitlements :- "$mount/Gonzo.app" 2>/dev/null)"
if grep -q 'com.apple.security.network' <<< "$entitlements"; then
    echo "The packaged app has a network entitlement." >&2; exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mount/Gonzo.app/Contents/Info.plist")" = "$version"
detach
# Publish by renaming, so an interrupted run never leaves a partial image.
mv -f "$work/Gonzo.dmg" "$dmg"
echo "Built $dmg"
shasum -a 256 "$dmg"
