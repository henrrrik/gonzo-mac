#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-/Applications}"
test -d "$destination"
codesign --verify --deep --strict build/Gonzo.app
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
echo "Installed $destination/Gonzo.app; restart Gonzo to use the new version."
