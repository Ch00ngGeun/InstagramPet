#!/usr/bin/env python3
"""Synthetic queue or notification SQLite -> AppKit measurements. Output contains numbers only."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import struct
import subprocess
import tempfile
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]


def measure(count=5, length=1000):
    with tempfile.TemporaryDirectory(prefix='InstagramPet-benchmark-') as directory:
        root = Path(directory)
        root.joinpath('config.json').write_text(json.dumps({
            'extensionId': 'a' * 32, 'appPath': str(PROJECT / 'dist/InstagramPet.app'), 'autoLaunch': False
        }))
        environment = dict(os.environ, INSTAGRAMPET_HOME=str(root))
        started = datetime.datetime.now(datetime.timezone.utc)
        frames = []
        for index in range(count):
            event = {'version': 1, 'type': 'dm', 'source': 'instagram',
                     'eventId': f'synthetic-burst-{index:03d}', 'sender': 'fixture.sender',
                     'text': 'x' * length, 'kind': 'thread-message',
                     'threadUrl': 'https://www.instagram.com/direct/t/fixture/',
                     'observedAt': (started + datetime.timedelta(milliseconds=index)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
            encoded = json.dumps(event).encode()
            frames.append(struct.pack('=I', len(encoded)) + encoded)
        host = subprocess.run([str(PROJECT / 'dist/PetNativeHost'), 'chrome-extension://' + 'a' * 32 + '/'],
                              input=b''.join(frames), env=environment, capture_output=True, timeout=10)
        if host.returncode:
            raise RuntimeError('synthetic host failed')
        report = root / 'measurements.json'
        app = subprocess.run([str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                              '--smoke-burst-latency', str(report), str(count)],
                             env=environment, capture_output=True, timeout=count * 5 + 10)
        if app.returncode or not report.exists():
            raise RuntimeError('synthetic AppKit measurement failed')
        samples = json.loads(report.read_text())
        if len(samples) != count:
            raise RuntimeError('synthetic burst was incomplete')
        return samples


def measure_notifications(count=5, length=1000):
    """Use an isolated WAL fixture and the app's real notification-reader delivery path."""
    with tempfile.TemporaryDirectory(prefix='InstagramPet-notification-benchmark-') as directory:
        root = Path(directory)
        root.joinpath('config.json').write_text(json.dumps({
            'extensionId': 'a' * 32, 'appPath': str(PROJECT / 'dist/InstagramPet.app'), 'autoLaunch': False
        }))
        environment = dict(os.environ, INSTAGRAMPET_HOME=str(root))
        report = root / 'measurements.json'
        ready = root / 'baseline.ready'
        writer = sqlite3.connect(str(root / 'notification-fixture.db'))
        app = None
        try:
            if writer.execute('PRAGMA journal_mode=WAL').fetchone()[0].lower() != 'wal':
                raise RuntimeError('synthetic notification WAL fixture failed')
            writer.executescript('''
                CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier VARCHAR,badge INTEGER);
                CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB,
                    request_date REAL,request_last_date REAL,delivered_date REAL,
                    presented BOOL,style INTEGER,snooze_fire_date REAL);
                INSERT INTO app(app_id,identifier) VALUES(1,'com.kakao.KakaoTalkMac');
            ''')
            writer.commit()
            app = subprocess.Popen([
                str(PROJECT / 'dist/InstagramPet.app/Contents/MacOS/InstagramPet'),
                '--smoke-notification-latency', str(report), str(count)
            ], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            # Inject only after the actual reader has baselined the empty database.
            deadline = time.monotonic() + 10
            while True:
                if ready.exists() and ready.read_text().strip() == '1':
                    break
                if app.poll() is not None:
                    raise RuntimeError('synthetic notification AppKit baseline failed')
                if time.monotonic() >= deadline:
                    raise RuntimeError('synthetic notification AppKit baseline timed out')
                time.sleep(0.01)

            payload = plistlib.dumps({
                'app': 'com.kakao.KakaoTalkMac',
                'req': {'titl': 'Fixture Friend', 'body': 'x' * length}
            }, fmt=plistlib.FMT_BINARY)
            # Apple's notification dates are seconds since 2001-01-01 UTC.
            for _ in range(count):
                observed = time.time() - 978307200
                writer.execute('''
                    INSERT INTO record(app_id,uuid,data,request_date,request_last_date,
                        delivered_date,presented,style) VALUES(?,?,?,?,?,?,1,0)
                ''', (1, uuid.uuid4().bytes, payload, observed, observed, observed))
            writer.commit()
            try:
                app.wait(timeout=count * 2 + 10)
            except subprocess.TimeoutExpired:
                raise RuntimeError('synthetic notification AppKit measurement timed out') from None
            if app.returncode or not report.exists():
                raise RuntimeError('synthetic notification AppKit measurement failed')
            samples = json.loads(report.read_text())
            if len(samples) != count:
                raise RuntimeError('synthetic notification burst was incomplete')
            return samples
        finally:
            if app is not None and app.poll() is None:
                app.kill()
                app.wait(timeout=5)
            writer.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', choices=('queue', 'notifications'), default='queue')
    parser.add_argument('--messages', type=int, default=5, choices=range(1, 21))
    parser.add_argument('--length', type=int, default=1000, choices=range(1, 2001))
    args = parser.parse_args()
    benchmark = measure_notifications if args.source == 'notifications' else measure
    print(json.dumps(benchmark(args.messages, args.length)))
