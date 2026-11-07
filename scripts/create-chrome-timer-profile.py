#!/usr/bin/env python3
"""Prepare a user-scoped macOS Chrome timer policy; never installs it automatically."""
import argparse
import ctypes
import json
from pathlib import Path
import plistlib
import uuid

POLICY = 'IntensiveWakeUpThrottlingEnabled'
IDENTIFIER = 'com.instagrampet.chrome.timer-policy'


def profile():
    return {
        'PayloadType': 'Configuration', 'PayloadVersion': 1,
        'PayloadIdentifier': IDENTIFIER,
        'PayloadUUID': str(uuid.uuid5(uuid.NAMESPACE_DNS, IDENTIFIER)).upper(),
        'PayloadDisplayName': 'InstagramPet Chrome Timer Policy',
        'PayloadDescription': 'Disables intensive background timer throttling for this user in Google Chrome. Does not prevent sleep, freezing, or tab discarding.',
        'PayloadScope': 'User', 'PayloadRemovalDisallowed': False,
        'PayloadContent': [{
            'PayloadType': 'com.apple.ManagedClient.preferences', 'PayloadVersion': 1,
            'PayloadIdentifier': IDENTIFIER + '.preferences',
            'PayloadUUID': str(uuid.uuid5(uuid.NAMESPACE_DNS, IDENTIFIER + '.preferences')).upper(),
            'PayloadDisplayName': 'Chrome Background Timer Preference',
            'PayloadContent': {'com.google.Chrome': {'Forced': [{
                'mcx_preference_settings': {POLICY: False}
            }]}}
        }]
    }


def check():
    """Only this public policy key is read; never dumps browser preferences."""
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    pointer = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [pointer, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = pointer
    cf.CFPreferencesCopyAppValue.argtypes = [pointer, pointer]
    cf.CFPreferencesCopyAppValue.restype = pointer
    cf.CFPreferencesAppValueIsForced.argtypes = [pointer, pointer]
    cf.CFPreferencesAppValueIsForced.restype = ctypes.c_bool
    cf.CFBooleanGetValue.argtypes = [pointer]
    cf.CFBooleanGetValue.restype = ctypes.c_bool
    cf.CFGetTypeID.argtypes = [pointer]
    cf.CFGetTypeID.restype = ctypes.c_ulong
    cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
    cf.CFRelease.argtypes = [pointer]
    key = cf.CFStringCreateWithCString(None, POLICY.encode(), 0x08000100)
    domain = cf.CFStringCreateWithCString(None, b'com.google.Chrome', 0x08000100)
    try:
        value = cf.CFPreferencesCopyAppValue(key, domain)
        try:
            typed = bool(value) and cf.CFGetTypeID(value) == cf.CFBooleanGetTypeID()
            return {'present': bool(value), 'boolean': bool(typed),
                    'value': bool(cf.CFBooleanGetValue(value)) if typed else None,
                    'forced': bool(cf.CFPreferencesAppValueIsForced(key, domain))}
        finally:
            if value:
                cf.CFRelease(value)
    finally:
        cf.CFRelease(key)
        cf.CFRelease(domain)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Read only the current policy value and macOS forced flag; does not verify Chrome policy status')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/InstagramPet Chrome Timer Policy.mobileconfig')
    args = parser.parse_args()
    if args.check:
        print(json.dumps(check(), indent=2))
        return
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('wb') as handle:
        plistlib.dump(profile(), handle, sort_keys=False)
    print('Prepared user-scoped profile: ' + str(args.output))
    print('Not installed. Review and install through macOS System Settings, then verify chrome://policy before restarting Chrome.')


if __name__ == '__main__':
    main()
