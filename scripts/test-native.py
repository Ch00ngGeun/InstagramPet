#!/usr/bin/env python3
"""Test the actual Swift executable over Chrome's framed stdin/stdout. No account/GUI needed."""
import datetime
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
HOST = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else PROJECT / 'dist/PetNativeHost'
# unittest must not interpret the optional executable path as a test selector.
sys.argv = sys.argv[:1]
EXTENSION_ID = 'a' * 32
ORIGIN = 'chrome-extension://' + EXTENSION_ID + '/'


def frame(value):
    data = json.dumps(value, ensure_ascii=False).encode('utf-8')
    return struct.pack('=I', len(data)) + data


def unpack(data):
    result = []
    while data:
        if len(data) < 4: raise AssertionError('stdout has non-protocol/truncated header')
        size = struct.unpack('=I', data[:4])[0]
        if size == 0 or size > 65536 or size > len(data) - 4:
            raise AssertionError('stdout has non-protocol/truncated frame')
        result.append(json.loads(data[4:4 + size]))
        data = data[4 + size:]
    return result


class NativeBridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='Instagram Pet 한글 test ')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'config.json').write_text(json.dumps({
            'extensionId': EXTENSION_ID, 'appPath': str(self.root / 'Missing.app'), 'autoLaunch': False
        }))
        self.env = dict(os.environ, INSTAGRAMPET_HOME=str(self.root))

    def run_host(self, payload, origin=ORIGIN):
        return subprocess.run([str(HOST)] + ([origin] if origin else []), input=payload,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=self.env, timeout=15)

    def event(self, **changes):
        value = {'version': 1, 'type': 'dm', 'eventId': 'event-1', 'sender': 'alice',
                 'text': 'PRIVATE_CANARY 안녕 🐱', 'displayName': 'Alice',
                 'threadUrl': 'https://www.instagram.com/direct/t/123/',
                 'kind': 'thread-message',
                 'observedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
        value.update(changes)
        return value

    def test_ping_unicode_delivery_replay_and_stdout_clean(self):
        result = self.run_host(frame({'version': 1, 'type': 'ping'}) + frame(self.event()) + frame(self.event()))
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = unpack(result.stdout)
        self.assertEqual([x['type'] for x in responses], ['pong', 'ack', 'ack'])
        self.assertFalse(responses[0]['appInstalled'])
        files = list((self.root / 'inbox').glob('*.json'))
        self.assertEqual(len(files), 1)
        self.assertEqual(json.loads(files[0].read_text())['text'], self.event()['text'])
        self.assertNotIn(b'PRIVATE_CANARY', result.stderr)
        self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.root / 'inbox').stat().st_mode), 0o700)
        files[0].unlink()  # simulate the UI acknowledging display
        replay = self.run_host(frame(self.event()))
        self.assertEqual(unpack(replay.stdout)[0]['type'], 'ack')
        self.assertEqual(len(list((self.root / 'inbox').glob('*.json'))), 0)

    def test_rejections_do_not_poison_next_frame_or_log_private_data(self):
        requests = [self.event(threadUrl='https://evil.example/'), self.event(sender='Alice Smith'),
                    self.event(eventId='../../bad'), self.event(text=''), self.event(sender='alice\n'),
                    {'version': 99, 'type': 'ping'}, self.event()]
        result = self.run_host(b''.join(map(frame, requests)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x['type'] for x in unpack(result.stdout)], ['error'] * 6 + ['ack'])
        self.assertNotIn(b'PRIVATE_CANARY', result.stderr)
        self.assertNotIn(b'PRIVATE_CANARY', result.stdout)

    def test_invalid_json_recovers_on_next_frame(self):
        malformed = b'{'  # valid framing, invalid JSON
        result = self.run_host(struct.pack('=I', len(malformed)) + malformed + frame({'version': 1, 'type': 'ping'}))
        self.assertEqual(result.returncode, 0)
        self.assertEqual([x['type'] for x in unpack(result.stdout)], ['error', 'pong'])

    def test_bad_framing_stops_safely(self):
        for payload in (b'\x01\x02', struct.pack('=I', 65537), struct.pack('=I', 0), struct.pack('=I', 100) + b'{}'):
            with self.subTest(payload=payload):
                result = self.run_host(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')

    def test_wrong_or_missing_extension_origin_rejected(self):
        for origin in ('chrome-extension://' + 'b' * 32 + '/', None):
            with self.subTest(origin=origin):
                result = self.run_host(frame(self.event()), origin=origin)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertFalse((self.root / 'inbox').exists() and list((self.root / 'inbox').glob('*.json')))

    def test_fragmented_pipe_writes(self):
        # Feed header and UTF-8 body through many writes; the receiver must read exact frame sizes.
        process = subprocess.Popen([str(HOST), ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.env)
        payload = frame(self.event())
        for byte in payload:
            process.stdin.write(bytes([byte]))
            process.stdin.flush()
        process.stdin.close()
        process.stdin = None
        output, errors = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, errors)
        self.assertEqual(unpack(output)[0]['type'], 'ack')


if __name__ == '__main__':
    if not HOST.is_file(): raise SystemExit('Build first: ./scripts/build-app.sh')
    unittest.main(verbosity=2)
