#!/usr/bin/env python3
"""Exercise the real installer in a temporary per-user layout, never the user's Chrome profile."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='Instagram Pet 한글 install ')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.env = dict(os.environ, INSTAGRAMPET_INSTALL_ROOT=str(self.root))
        self.support = self.root / 'Library/Application Support/InstagramPet'
        self.app = self.root / 'Applications/InstagramPet.app'
        self.manifest = self.root / 'Library/Application Support/Google/Chrome/NativeMessagingHosts/com.instagrampet.bridge.json'

    def run_script(self, name, *args, success=True):
        result = subprocess.run([str(PROJECT / 'scripts' / name), *args], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_install_update_and_registration_have_exact_origin_and_absolute_paths(self):
        extension_id = 'a' * 32
        self.run_script('install.sh', extension_id)
        self.run_script('install.sh', extension_id)
        manifest = json.loads(self.manifest.read_text())
        config = json.loads((self.support / 'config.json').read_text())
        self.assertEqual(manifest['allowed_origins'], ['chrome-extension://' + extension_id + '/'])
        self.assertEqual(manifest['path'], str(self.support / 'bin/PetNativeHost'))
        self.assertTrue(Path(manifest['path']).is_absolute())
        self.assertTrue(os.access(manifest['path'], os.X_OK))
        self.assertEqual(config['appPath'], str(self.app))
        self.assertEqual(self.support.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.support / 'config.json').stat().st_mode & 0o777, 0o600)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(self.app)], check=True, capture_output=True)

    def test_remove_retains_or_deletes_only_project_data(self):
        self.run_script('install.sh', 'a' * 32)
        sentinel = self.root / 'unrelated.txt'
        sentinel.write_text('keep')
        pending = self.support / 'inbox/test.json'
        pending.write_text('fake queued content')
        self.run_script('uninstall.sh')
        self.assertTrue(pending.exists())
        self.assertFalse(self.app.exists())
        self.assertFalse(self.manifest.exists())
        self.run_script('uninstall.sh', '--delete-data')
        self.assertFalse(self.support.exists())
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_invalid_extension_id_refused_before_install(self):
        self.run_script('install.sh', 'not-an-id', success=False)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.support.exists())

    def test_unrelated_bundle_is_not_replaced(self):
        info = self.app / 'Contents/Info.plist'
        info.parent.mkdir(parents=True)
        with info.open('wb') as handle: plistlib.dump({'CFBundleIdentifier': 'com.example.unrelated'}, handle)
        self.run_script('install.sh', 'a' * 32, success=False)
        with info.open('rb') as handle: value = plistlib.load(handle)
        self.assertEqual(value['CFBundleIdentifier'], 'com.example.unrelated')


if __name__ == '__main__':
    if not (PROJECT / 'dist/PetNativeHost').is_file(): raise SystemExit('Build first: ./scripts/build-app.sh')
    unittest.main(verbosity=2)
