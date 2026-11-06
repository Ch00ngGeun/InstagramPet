#!/usr/bin/env python3
"""Framed native event -> actual AppKit poll/present/consume, offscreen in a logged-in Mac session."""
import datetime
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class AppPipelineTest(unittest.TestCase):
    def test_native_queue_reaches_real_appkit_bubble_and_is_consumed(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet App 한글 ') as folder:
            root = Path(folder)
            (root / 'config.json').write_text(json.dumps({
                'extensionId': 'a' * 32, 'appPath': str(PROJECT / 'dist/InstagramPet.app'), 'autoLaunch': False
            }))
            env = dict(os.environ, INSTAGRAMPET_HOME=str(root))
            event = {'version': 1, 'type': 'dm', 'eventId': 'app-pipeline-test', 'sender': 'fixture.sender',
                     'displayName': 'Fixture sender', 'text': 'Fixture 안녕 🐱', 'kind': 'thread-message',
                     'threadUrl': 'https://www.instagram.com/direct/t/12345/',
                     'observedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
            encoded = json.dumps(event, ensure_ascii=False).encode('utf-8')
            native = subprocess.run([str(PROJECT / 'dist/PetNativeHost'), 'chrome-extension://' + 'a' * 32 + '/'],
                                    input=struct.pack('=I', len(encoded)) + encoded, env=env,
                                    capture_output=True, timeout=15)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(json.loads(native.stdout[4:])['type'], 'ack')
            report = root / 'app-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-test', str(report)], env=env, capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, app.stderr)
            self.assertTrue(report.exists(), 'AppKit did not create the report; requires a logged-in Mac desktop session')
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['displayedEventId'], event['eventId'])
            self.assertTrue(result['bubbleVisible'])
            self.assertEqual(result['remainingQueueCount'], 0)
            self.assertEqual(list((root / 'inbox').glob('*.json')), [])
            self.assertNotIn(event['text'].encode(), app.stdout + app.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
