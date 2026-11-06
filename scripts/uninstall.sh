#!/bin/bash
set -euo pipefail
MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != "--delete-data" ]]; then
    printf 'Usage: %s [--delete-data]\n' "$0" >&2
    exit 2
fi
python3 - "$MODE" <<'PY'
import json, os, pathlib, plistlib, shutil, sys
base = pathlib.Path(os.environ.get('INSTAGRAMPET_INSTALL_ROOT', str(pathlib.Path.home()))).resolve()
support = base / 'Library/Application Support/InstagramPet'
manifest = base / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.instagrampet.bridge.json'
app = base / 'Applications/InstagramPet.app'
if manifest.exists():
    with manifest.open() as handle: value = json.load(handle)
    if value.get('name') != 'com.instagrampet.bridge':
        raise SystemExit('Refusing unrelated host manifest')
    manifest.unlink()
if app.is_symlink(): raise SystemExit('Refusing symlink app path')
if app.exists():
    with (app / 'Contents/Info.plist').open('rb') as handle: info = plistlib.load(handle)
    if info.get('CFBundleIdentifier') != 'com.instagrampet.app':
        raise SystemExit('Refusing unrelated app bundle')
    shutil.rmtree(app)
if support.is_symlink(): raise SystemExit('Refusing symlink data path')
if sys.argv[1] == '--delete-data':
    if support.exists(): shutil.rmtree(support)
    print('Removed app, bridge registration, and local message queue/receipts/config.')
else:
    for leaf in (support / 'bin/PetNativeHost', support / 'config.json'):
        if leaf.exists() or leaf.is_symlink(): leaf.unlink()
    print('Removed app and bridge registration. Local data retained; use --delete-data to remove it.')
print('Quit the pet before uninstalling. Remove the unpacked extension in chrome://extensions separately.')
PY
