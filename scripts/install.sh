#!/bin/bash
# Per-user installation for stable Google Chrome. No sudo, daemon, login item or network port.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION_ID="${1:-}"
if [[ ! "$EXTENSION_ID" =~ ^[a-p]{32}$ ]]; then
    printf 'Usage: %s <32-character Chrome extension ID>\nLoad extension/ in chrome://extensions first, then copy its ID.\n' "$0" >&2
    exit 2
fi
if [[ ! -x "$PROJECT_DIR/dist/PetNativeHost" || ! -d "$PROJECT_DIR/dist/InstagramPet.app" ]]; then
    "$PROJECT_DIR/scripts/build-app.sh"
fi
# Python is supplied by Apple Command Line Tools, which are also required for Swift compilation.
python3 - "$PROJECT_DIR" "$EXTENSION_ID" <<'PY'
import json, os, pathlib, re, shutil, sys, tempfile
project = pathlib.Path(sys.argv[1]).resolve()
extension_id = sys.argv[2]
assert re.fullmatch('[a-p]{32}', extension_id)
install_root = pathlib.Path(os.environ.get('INSTAGRAMPET_INSTALL_ROOT', str(pathlib.Path.home()))).resolve()
support = install_root / 'Library/Application Support/InstagramPet'
apps = install_root / 'Applications'
app = apps / 'InstagramPet.app'
manifest_dir = install_root / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'

def private_dir(path):
    if path.is_symlink():
        raise SystemExit('Refusing symbolic-link installation directory: ' + str(path))
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)

def atomic_json(path, value):
    fd, temp = tempfile.mkstemp(prefix='.instagrampet-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)

for directory in (support, support / 'bin', support / 'inbox', support / 'receipts'):
    private_dir(directory)
apps.mkdir(parents=True, exist_ok=True)
manifest_dir.mkdir(parents=True, exist_ok=True)
# Replace only this project's known app path. Quit the pet before updating it.
if app.is_symlink():
    raise SystemExit('Refusing symbolic-link app destination: ' + str(app))
if app.exists():
    info = app / 'Contents/Info.plist'
    import plistlib
    with info.open('rb') as handle:
        existing = plistlib.load(handle)
    if existing.get('CFBundleIdentifier') != 'com.instagrampet.app':
        raise SystemExit('An unrelated app exists at ' + str(app))
    shutil.rmtree(app)
shutil.copytree(project / 'dist/InstagramPet.app', app)
host = support / 'bin/PetNativeHost'
# Atomic binary replacement also avoids following an existing symlink.
fd, staged = tempfile.mkstemp(prefix='.host-', dir=str(host.parent))
os.close(fd)
shutil.copy2(project / 'dist/PetNativeHost', staged)
os.chmod(staged, 0o755)
os.replace(staged, host)
atomic_json(support / 'config.json', {'extensionId': extension_id, 'appPath': str(app), 'autoLaunch': True})
manifest = manifest_dir / 'com.instagrampet.bridge.json'
atomic_json(manifest, {
    'name': 'com.instagrampet.bridge',
    'description': 'InstagramPet local Swift bridge',
    'path': str(host),
    'type': 'stdio',
    'allowed_origins': ['chrome-extension://' + extension_id + '/']
})
print('Installed app: ' + str(app))
print('Registered stable Google Chrome host: ' + str(manifest))
print('Open the app and run the extension connection check. Installation did not launch Chrome or change Instagram.')
PY
