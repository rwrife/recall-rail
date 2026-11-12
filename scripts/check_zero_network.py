#!/usr/bin/env python3
"""Fail closed over first-party sources, entitlements, and declared dependency graph."""
import json
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r'\b(?:URLSession|NSURLSession|URLRequest|NWConnection|NWListener|NWBrowser|NetService|CFNetwork|WebSocket|URLProtocol|WKWebView|SFSafariViewController|import\s+(?:Network|WebKit|FoundationNetworking)|CFReadStreamCreate|CFWriteStreamCreate|SCNetwork|Stream\.getStreamsToHost|URL\(string:\s*"(?:https?|wss?|ftp)://|getaddrinfo|socket\s*\(|connect\s*\(|sendto\s*\(|recvfrom\s*\(|curl_|AVAudioRecorder|AVAudioEngine|SFSpeechRecognizer|requestAuthorization|registerForRemoteNotifications)')
ALLOWED_DEPENDENCIES = {'https://github.com/groue/GRDB.swift.git'}

def audit(root):
    failures = []
    for dirname in ['RecallRail', 'Packages']:
        for path in (root / dirname).rglob('*'):
            if any(part in {'.build', '.swiftpm'} for part in path.parts) or (dirname == 'Packages' and 'Tests' in path.relative_to(root).parts):
                continue
            if path.is_file() and path.suffix in {'.swift', '.c', '.h', '.m', '.mm', '.cpp'} and path.name != 'Package.swift':
                if FORBIDDEN.search(path.read_text()):
                    failures.append('source_api')
    for path in root.rglob('*.entitlements'):
        if '.build' in path.parts: continue
        values = plistlib.loads(path.read_bytes())
        if values: failures.append('source_entitlement')  # app currently needs none
    manifests = list((root / 'Packages').glob('*/Package.swift'))
    for path in manifests:
        urls = set(re.findall(r'\.package\(url:\s*"([^"]+)"', path.read_text()))
        if not urls <= ALLOWED_DEPENDENCIES: failures.append('dependency_manifest')
        paths = set(re.findall(r'\.package\(path:\s*"([^"]+)"', path.read_text()))
        if not paths <= {'../RecallRailKit'}: failures.append('dependency_local_path')
        if '.binaryTarget(' in path.read_text(): failures.append('dependency_binary')
        if urls and '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")' not in path.read_text(): failures.append('dependency_pin')
    for path in root.rglob('Package.resolved'):
        if '.build' in path.parts: continue
        for pin in json.loads(path.read_text())['pins']:
            if pin['location'] not in ALLOWED_DEPENDENCIES or pin['state'].get('version') != '7.11.1' or pin['state'].get('revision') != 'b83108d10f42680d78f23fe4d4d80fc88dab3212': failures.append('dependency_lock')
    for path in list((root / 'RecallRail.xcodeproj').rglob('project.pbxproj')):
        urls = set(re.findall(r'repositoryURL\s*=\s*"?([^";]+)', path.read_text()))
        if not urls <= ALLOWED_DEPENDENCIES: failures.append('project_dependency')
        paths = set(re.findall(r'relativePath\s*=\s*"?([^";]+)', path.read_text()))
        if not paths <= {'Packages/RecallRailKit', 'Packages/RecallStore'}: failures.append('project_local_dependency')
        if re.search(r'\b(?:CFNetwork|Network|WebKit)\.framework\b', path.read_text()): failures.append('project_network_framework')
        if re.search(r'INFOPLIST_KEY_(?:NSAppTransportSecurity|NSLocalNetworkUsageDescription|NSBonjourServices)', path.read_text()): failures.append('network_plist')
    return failures

if __name__ == '__main__':
    failures = audit(ROOT)
    print('Zero-network gate: ' + ('FAIL ' + ','.join(sorted(set(failures))) if failures else 'PASS (source, entitlements, dependencies; empty network allowlist)'))
    sys.exit(bool(failures))
