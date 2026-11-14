#!/usr/bin/env python3
"""Framed native event -> actual AppKit poll/present/consume, offscreen in a logged-in Mac session."""
import datetime
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class AppPipelineTest(unittest.TestCase):
    def test_settled_bubbles_stop_redrawing_but_wall_and_motion_changes_invalidate(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Idle Render ') as folder:
            report = Path(folder) / 'idle-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-idle-render', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=30)
            self.assertEqual(app.returncode, 0, app.stderr)
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['idleRedraws'], 0)

    def test_source_write_failures_acknowledge_accepted_prefix_and_allow_other_readers(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Source Failure ') as folder:
            report = Path(folder) / 'failure-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-source-failures', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, app.stderr)
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['cases'], 3)

    def test_tucked_bubbles_settle_at_every_corner_without_hidden_pet_distortion(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Bubbles ') as folder:
            report = Path(folder) / 'bubble-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-bubble-geometry', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=30)
            self.assertEqual(app.returncode, 0, app.stderr)
            result = json.loads(report.read_text())
            # Synthetic desktop previews remain available for visual QA after the temporary home is removed.
            shutil.copytree(folder, PROJECT / 'work/bubble-geometry', dirs_exist_ok=True)
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['cases'], 8)

    def test_settings_form_saves_recreates_only_changed_reader_and_preserves_other_sources(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Settings ') as folder:
            report = Path(folder) / 'settings-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-settings', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, 'settings form smoke failed')
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)

    def test_pet_stays_flush_and_strips_never_fold_during_deep_wall_pulls(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Geometry ') as folder:
            report = Path(folder) / 'geometry-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-pet-geometry', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, 'pet geometry check failed')
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['cases'], 540)

    def test_unread_long_burst_updates_all_five_bubbles_without_reading_delay(self):
        measured = subprocess.run([sys.executable, str(PROJECT / 'scripts/benchmark-delivery.py')],
                                  capture_output=True, timeout=45)
        self.assertEqual(measured.returncode, 0, 'synthetic burst measurement failed')
        samples = json.loads(measured.stdout)
        self.assertEqual([row[0] for row in samples], [1, 2, 3, 4, 4])  # one app keeps at most four
        self.assertLess(max(row[1] for row in samples), 3000, samples)

    def test_notification_wal_burst_reaches_five_bubbles_within_three_seconds(self):
        measured = subprocess.run([
            sys.executable, str(PROJECT / 'scripts/benchmark-delivery.py'),
            '--source', 'notifications', '--messages', '5', '--length', '1000'
        ], capture_output=True, timeout=45)
        self.assertEqual(measured.returncode, 0, 'synthetic notification measurement failed')
        samples = json.loads(measured.stdout)
        self.assertEqual([row[0] for row in samples], [1, 2, 3, 4, 4])  # one app keeps at most four
        self.assertTrue(all(row[1] >= 0 for row in samples), samples)
        self.assertLess(max(row[1] for row in samples), 3000, samples)

    def test_mixed_bubbles_clear_only_the_read_source_and_conversation(self):
        with tempfile.TemporaryDirectory(prefix='Instagram Pet Sources ') as folder:
            report = Path(folder) / 'source-report.json'
            app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                                  '--smoke-source-reads', str(report)],
                                 env=dict(os.environ, INSTAGRAMPET_HOME=folder), capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, app.stderr)
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['visibleCounts'], [5, 4, 2, 0])
            self.assertEqual(result['pendingCounts'], [3, 2, 1, 0])
            self.assertTrue(result['capacityRecovery'])
            self.assertTrue(result['orderPreserved'])
            self.assertTrue(result['monotonicReads'])
            self.assertNotIn(b'KakaoTalk', app.stdout + app.stderr)

    def test_native_queue_reaches_real_appkit_bubble_and_is_consumed(self):
        self.run_pipeline([])

    def test_new_message_ends_timed_hide(self):
        self.run_pipeline(['--start-hidden'])

    def test_new_message_leaves_tucked_pet_tucked(self):
        self.assertTrue(self.run_pipeline(['--start-tucked'])['petTucked'])

    def run_pipeline(self, extra):
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
                                  '--smoke-test', str(report)] + extra, env=env, capture_output=True, timeout=15)
            self.assertEqual(app.returncode, 0, app.stderr)
            self.assertTrue(report.exists(), 'AppKit did not create the report; requires a logged-in Mac desktop session')
            result = json.loads(report.read_text())
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['displayedEventId'], event['eventId'])
            self.assertTrue(result['bubbleVisible'])
            self.assertEqual(result['remainingQueueCount'], 0)
            self.assertEqual(list((root / 'inbox').glob('*.json')), [])
            self.assertNotIn(event['text'].encode(), app.stdout + app.stderr)
            return result


if __name__ == '__main__':
    unittest.main(verbosity=2)
