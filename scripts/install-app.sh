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
destination="${1:-/Applications}"
test -d "$destination"
codesign --verify --deep --strict build/Gonzo.app
acquire_lock "$destination/.gonzo-install-lock"
staging="$(mktemp -d "$destination/.gonzo-install.XXXXXX")"
ditto build/Gonzo.app "$staging/Gonzo.app"
codesign --verify --deep --strict "$staging/Gonzo.app"
# Preserve the old bundle's files for any instance still running from it.
if [ -e "$destination/Gonzo.app" ]; then
    mv "$destination/Gonzo.app" "$staging/Previous.app"
fi
if ! mv "$staging/Gonzo.app" "$destination/Gonzo.app"; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" "$destination/Gonzo.app"; fi
    exit 1
fi
prune_retained "$destination" .gonzo-install. "$(cd "$staging" && pwd -P)"
echo "Installed $destination/Gonzo.app; restart Gonzo to use the new version."
