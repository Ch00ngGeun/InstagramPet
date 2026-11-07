#!/usr/bin/env python3
"""Test the actual Swift executable over Chrome's framed stdin/stdout. No account/GUI needed."""
import datetime
import hashlib
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

    def test_config_only_returns_validated_instagram_selection(self):
        selected = {'username': ' @Fixture.Friend ', 'threadId': ' 123456 '}
        (self.root / 'sources.json').write_text(json.dumps({
            'instagram': selected, 'messages': {'handle': 'private-fixture@example.test'},
            'kakao': {'name': 'PRIVATE_CONTACT_CANARY'}
        }))
        result = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(unpack(result.stdout), [{
            'version': 1, 'type': 'config', 'ok': True,
            'instagram': {'username': 'fixture.friend', 'threadId': '123456'}
        }])
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(b'private-fixture', result.stdout)
        self.assertNotIn(b'PRIVATE_CONTACT_CANARY', result.stdout + result.stderr)

    def test_config_distinguishes_unmanaged_and_explicitly_disabled(self):
        unmanaged = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(unpack(unmanaged.stdout)[0]['instagram'], None)
        (self.root / 'sources.json').write_text(json.dumps({'instagram': None}))
        explicit_null = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(unpack(explicit_null.stdout)[0]['instagram'], None)
        (self.root / 'sources.json').write_text(json.dumps({'instagram': {'username': '', 'threadId': ''}}))
        disabled = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(unpack(disabled.stdout)[0]['instagram'], {'username': '', 'threadId': ''})

    def test_config_returns_canonical_multiple_instagram_pairs_without_local_contacts(self):
        (self.root / 'sources.json').write_text(json.dumps({
            'instagram': {'username': ' @Fixture.One, Fixture.Two, @Fixture.One ', 'threadId': ' 123, 456, 789 '},
            'messages': {'handle': 'PRIVATE_FIRST@example.test,PRIVATE_SECOND@example.test'},
            'kakao': {'name': 'PRIVATE_CONTACT_ONE,PRIVATE_CONTACT_TWO'}
        }))
        result = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(unpack(result.stdout), [{
            'version': 1, 'type': 'config', 'ok': True,
            'instagram': {'username': 'fixture.one,fixture.two,fixture.one', 'threadId': '123,456,789'}
        }])
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(b'PRIVATE_', result.stdout + result.stderr)

    def test_config_rejects_invalid_csv_pairs_without_echoing_partial_selections(self):
        for selected in ({'username': 'fixture.one,fixture.two', 'threadId': '123'},
                         {'username': 'fixture.one,', 'threadId': '123,456'},
                         {'username': 'fixture.one,,fixture.two', 'threadId': '123,456,789'},
                         {'username': 'fixture.one,fixture.two', 'threadId': '123,123'},
                         {'username': 'fixture.one,PRIVATE_USERNAME_CANARY bad', 'threadId': '123,456'},
                         {'username': ','.join('fixture' + str(i) for i in range(101)),
                          'threadId': ','.join(str(i + 1) for i in range(101))}):
            (self.root / 'sources.json').write_text(json.dumps({'instagram': selected}))
            result = self.run_host(frame({'version': 1, 'type': 'config'}) + frame({'version': 1, 'type': 'ping'}))
            self.assertEqual([reply['type'] for reply in unpack(result.stdout)], ['error', 'pong'])
            self.assertNotIn(b'fixture.one', result.stdout + result.stderr)
            self.assertNotIn(b'PRIVATE_USERNAME_CANARY', result.stdout + result.stderr)

    def test_config_rejects_invalid_values_and_payload_overrides_without_echoing(self):
        for selected in ({'username': 'PRIVATE_USERNAME_CANARY bad', 'threadId': '123'},
                         {'username': 'fixture.friend', 'threadId': 'not-a-thread'},
                         {'username': 'fixture.friend', 'threadId': '1' * 129},
                         {'username': '', 'threadId': '123'}, {'username': '@', 'threadId': ''},
                         {'username': 'fixture.friend', 'threadId': 123}):
            (self.root / 'sources.json').write_text(json.dumps({'instagram': selected}))
            result = self.run_host(frame({'version': 1, 'type': 'config'}) + frame({'version': 1, 'type': 'ping'}))
            self.assertEqual([reply['type'] for reply in unpack(result.stdout)], ['error', 'pong'])
            self.assertNotIn(b'PRIVATE_USERNAME_CANARY', result.stdout + result.stderr)
            self.assertNotIn(b'not-a-thread', result.stdout + result.stderr)
        (self.root / 'sources.json').unlink()
        result = self.run_host(frame({'version': 1, 'type': 'config', 'instagram': {'username': 'fixture.friend', 'threadId': '123'}}))
        self.assertEqual(unpack(result.stdout)[0]['type'], 'error')
        (self.root / 'sources.json').symlink_to(self.root / 'config.json')
        result = self.run_host(frame({'version': 1, 'type': 'config'}))
        self.assertEqual(unpack(result.stdout)[0]['type'], 'error')

    def test_config_is_reloaded_on_each_request_of_one_connection(self):
        source = self.root / 'sources.json'
        source.write_text(json.dumps({'instagram': {'username': 'fixture.one', 'threadId': '123'}}))
        process = subprocess.Popen([str(HOST), ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.env)
        try:
            def request_config():
                process.stdin.write(frame({'version': 1, 'type': 'config'}))
                process.stdin.flush()
                header = process.stdout.read(4)
                self.assertEqual(len(header), 4)
                return json.loads(process.stdout.read(struct.unpack('=I', header)[0]))
            self.assertEqual(request_config()['instagram']['username'], 'fixture.one')
            staged = self.root / '.sources-staged'
            staged.write_text(json.dumps({'instagram': {'username': 'fixture.two', 'threadId': '456'}}))
            staged.replace(source)
            self.assertEqual(request_config()['instagram'], {'username': 'fixture.two', 'threadId': '456'})
            process.stdin.close(); process.stdin = None
            output, errors = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'')
            self.assertEqual(errors, b'')
        finally:
            if process.poll() is None: process.kill(); process.communicate(timeout=5)

    def test_config_requires_the_registered_extension_origin(self):
        (self.root / 'sources.json').write_text(json.dumps({'instagram': {'username': 'fixture.friend', 'threadId': '123'}}))
        for origin in ('chrome-extension://' + 'b' * 32 + '/', ORIGIN + '?other', None):
            result = self.run_host(frame({'version': 1, 'type': 'config'}), origin=origin)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
            self.assertNotIn(b'fixture.friend', result.stderr)

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

    def test_read_mark_clears_that_threads_pending_messages(self):
        thread = 'https://www.instagram.com/direct/t/123/'
        result = self.run_host(frame(self.event()) + frame(self.event(eventId='other', threadUrl='https://www.instagram.com/direct/t/999/'))
                               + frame({'version': 1, 'type': 'read', 'threadUrl': thread})
                               + frame({'version': 1, 'type': 'read', 'threadUrl': 'https://evil.test/direct/t/1/'}))
        self.assertEqual([x['type'] for x in unpack(result.stdout)], ['ack', 'ack', 'ack', 'error'])
        left = [json.loads(f.read_text())['eventId'] for f in (self.root / 'inbox').glob('*.json')]
        self.assertEqual(left, ['other'])
        marks = [json.loads(f.read_text()) for f in (self.root / 'reads').glob('*.json')]
        self.assertEqual([m['threadUrl'] for m in marks], [thread])
        self.assertNotIn('PRIVATE_CANARY', json.dumps(marks))

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

    def test_chrome_cannot_inject_local_sources_or_local_read_marks(self):
        requests = []
        for source in ('kakao', 'messages'):
            key = source + ':' + hashlib.sha256(b'fixture-contact').hexdigest()
            requests.append(self.event(source=source, threadUrl=key))
            requests.append({'version': 1, 'type': 'read', 'source': source,
                             'threadUrl': 'https://www.instagram.com/direct/t/123/'})
        requests.append(self.event(source='instagram'))
        result = self.run_host(b''.join(map(frame, requests)))
        self.assertEqual([x['type'] for x in unpack(result.stdout)], ['error'] * 4 + ['ack'])
        self.assertEqual(len(list((self.root / 'inbox').glob('*.json'))), 1)
        self.assertEqual(list((self.root / 'reads').glob('*.json')), [])

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
