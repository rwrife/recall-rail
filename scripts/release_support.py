#!/usr/bin/env python3
"""Release helpers: output only fixed diagnostic categories, never input fragments."""
import argparse
import json
import os
import pathlib
import plistlib
import subprocess
import time
import urllib.request
import base64
import datetime


def sanitize(text):
    # No substring of raw tool output is ever emitted (including unknown diagnostics).
    lowered = text.lower()
    return {category: lowered.count(needle) for category, needle in {
        'error_count': 'error:', 'warning_count': 'warning:',
        'archive_success_count': '** archive succeeded **',
        'export_success_count': '** export succeeded **',
        'upload_success_count': 'upload succeeded',
    }.items()}


def verify_app(path):
    app = pathlib.Path(path)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.infinityball.recallrail', 'bundle category mismatch'
    assert info['UIDeviceFamily'] == [1], 'device category mismatch'
    assert (app / 'PrivacyInfo.xcprivacy').is_file(), 'privacy category missing'
    raw = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True)
    entitlements = plistlib.loads(raw.stdout)
    allowed = {'application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups', 'get-task-allow', 'beta-reports-active'}
    assert set(entitlements) <= allowed, 'entitlement category mismatch'
    assert entitlements.get('get-task-allow', False) is False, 'debug category mismatch'
    expected = os.environ['ASC_TEAM_ID'] + '.com.infinityball.recallrail'
    assert entitlements.get('application-identifier') == expected, 'signing category mismatch'
    assert entitlements.get('com.apple.developer.team-identifier') == os.environ['ASC_TEAM_ID'], 'team category mismatch'
    decoded = subprocess.run(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], capture_output=True, check=True)
    profile = plistlib.loads(decoded.stdout)
    assert profile['Entitlements']['application-identifier'] == expected, 'profile bundle category mismatch'
    assert profile['Entitlements'].get('get-task-allow', False) is False, 'profile debug category mismatch'
    assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices', False), 'profile distribution category mismatch'
    assert profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc).timestamp() > time.time(), 'profile expiry category mismatch'
    assert profile['TeamIdentifier'] == [os.environ['ASC_TEAM_ID']], 'profile team category mismatch'
    assert info['CFBundleVersion'] == os.environ['GITHUB_RUN_NUMBER'] + '.' + os.environ['GITHUB_RUN_ATTEMPT'], 'build category mismatch'
    assert info.get('DTXcodeBuild') == '17A400' and info.get('DTSDKName') == 'iphoneos26.0', 'built toolchain category mismatch'


def jwt(key_file):
    def b64(value):
        return base64.urlsafe_b64encode(value).rstrip(b'=')
    now = int(time.time())
    header = b64(json.dumps({'alg': 'ES256', 'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'}, separators=(',', ':')).encode())
    claims = b64(json.dumps({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'}, separators=(',', ':')).encode())
    message = header + b'.' + claims
    signed = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', key_file], input=message, capture_output=True, check=True).stdout
    # OpenSSL produces ASN.1 DER ECDSA; JWT requires the fixed-width r || s.
    index = 2
    if signed[1] & 128:
        index = 2 + (signed[1] & 127)
    assert signed[index] == 2
    size = signed[index + 1]; r = signed[index + 2:index + 2 + size]; index += size + 2
    assert signed[index] == 2
    size = signed[index + 1]; s = signed[index + 2:index + 2 + size]
    signature = r.lstrip(b'\0').rjust(32, b'\0') + s.lstrip(b'\0').rjust(32, b'\0')
    assert len(signature) == 64
    return (message + b'.' + b64(signature)).decode()


def poll(key_file, build, since, output):
    # API token and identity values remain in memory; no HTTP errors/bodies are logged.
    deadline = time.monotonic() + 1200
    while time.monotonic() < deadline:
        token = jwt(key_file)
        def get(url):
            request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token})
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        apps = get('https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=com.infinityball.recallrail')['data']
        assert len(apps) == 1, 'app match category failed'
        records = get('https://api.appstoreconnect.apple.com/v1/builds?filter[app]=' + apps[0]['id'] + '&filter[version]=' + build + '&limit=200')['data']
        matches = []
        for record in records:
            attributes = record['attributes']
            uploaded = datetime.datetime.fromisoformat(attributes['uploadedDate'].replace('Z', '+00:00')).timestamp()
            if attributes['version'] == build and uploaded >= since:
                matches.append(record)
        assert len(matches) <= 1, 'ambiguous build category failed'
        if matches:
            record = matches[0]
            state = record['attributes']['processingState']
            if state == 'VALID':
                pathlib.Path(output).write_text(json.dumps({'build_id': record['id'], 'build_number': build, 'processingState': state, 'uploadedDate': record['attributes']['uploadedDate']}) + '\n')
                return
            if state in {'FAILED', 'INVALID'}:
                raise RuntimeError('processing category failed')
        time.sleep(30)
    raise RuntimeError('processing category timed out')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['sanitize', 'verify', 'poll'])
    parser.add_argument('paths', nargs='+')
    args = parser.parse_args()
    try:
        if args.operation == 'sanitize':
            print(json.dumps(sanitize(pathlib.Path(args.paths[0]).read_text(errors='replace')), sort_keys=True))
        elif args.operation == 'verify':
            verify_app(args.paths[0]); print('archive_metadata_verified')
        else:
            poll(args.paths[0], args.paths[1], float(args.paths[2]), args.paths[3]); print('processing_valid')
    except Exception:
        # Exception messages can contain URLs, identities or raw server bodies.
        print('release_operation_failed')
        raise SystemExit(1)

if __name__ == '__main__':
    main()
