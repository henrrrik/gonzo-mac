#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Remove bundles retained by earlier runs once nothing can still be running
# them. Fail closed: keep everything if lsof is unavailable or if any Gonzo
# launched from this location is running for any user (lsof cannot see other
# users' processes). Directories without a retained app may belong to a run
# that crashed; keep them for an hour. Callers hold the run lock.
prune_retained() {
    local parent prefix="$2" keep="$3" directory executable status processes
    parent="$(cd "$1" && pwd -P)"
    [ -x /usr/sbin/lsof ] || return 0
    # Capture first: under pipefail, grep -q closing the pipe early would make
    # a matching ps pipeline report failure.
    processes="$(ps -axo comm=)" || return 0
    if grep -Fq "$parent/Gonzo.app/" <<< "$processes"; then return 0; fi
    for directory in "$parent/$prefix"*; do
        [ -d "$directory" ] && [ "$directory" != "$keep" ] || continue
        executable="$directory/Previous.app/Contents/MacOS/Gonzo"
        if [ -e "$executable" ]; then
            status=0
            /usr/sbin/lsof -t -- "$executable" >/dev/null 2>&1 || status=$?
            [ "$status" -eq 1 ] || continue
        elif [ -z "$(find "$directory" -maxdepth 0 -mmin +60)" ]; then
            continue
        fi
        rm -rf "$directory" || true
    done
}

# Serialize runs so one never prunes another's in-flight staging directory.
acquire_lock() {
    local waited=0
    until mkdir "$1" 2>/dev/null; do
        if [ "$waited" -ge 120 ]; then echo "Another run holds $1; remove it if no run is active." >&2; exit 1; fi
        sleep 1; waited=$((waited + 1))
    done
    lock_path="$1"
    trap 'rmdir "$lock_path"' EXIT
}
configuration="${1:-release}"
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p build
acquire_lock build/.gonzo-build-lock
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
prune_retained build .gonzo-build. "$(cd "$staging" && pwd -P)"
echo "Built build/Gonzo.app"
