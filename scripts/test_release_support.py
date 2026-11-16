#!/usr/bin/env python3
import importlib.util
import json
import unittest
import tempfile
from unittest.mock import patch
from io import BytesIO
from pathlib import Path
spec = importlib.util.spec_from_file_location('release_support', Path(__file__).with_name('release_support.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SanitizerTests(unittest.TestCase):
    def test_partial_secret_canaries(self):
        raw = 'error: KEYCANARYprefix signing TEAMCANARY warning: issuer ISSUERCANARY\n-----BEGIN PRIVATE KEY-----\nP8CANARYsuffix\n** ARCHIVE SUCCEEDED **'
        encoded = json.dumps(module.sanitize(raw))
        for fragment in ['KEYCANARY', 'TEAMCANARY', 'ISSUERCANARY', 'P8CANARY', 'PRIVATE KEY', 'prefix', 'suffix']:
            self.assertNotIn(fragment, encoded)
        self.assertEqual(module.sanitize(raw)['error_count'], 1)
    def test_unknown_output_is_not_copied(self):
        self.assertTrue(all(count == 0 for count in module.sanitize('unexpected sensitive identity').values()))

class MonotonicTests(unittest.TestCase):
    def test_decimal_components(self):
        self.assertGreater(module.build_components('42.10'), module.build_components('42.9'))
        self.assertEqual(module.build_components('42.01'), module.build_components('42.1.0'))
        for value in ['42.x', '-1', '1.2.3.4', '1e2']:
            with self.assertRaises(ValueError): module.build_components(value)
    def test_same_marketing_version_paginated_and_fail_closed(self):
        responses = [BytesIO(json.dumps({'data':[{'id':'app'}]}).encode()),
                     BytesIO(json.dumps({'data':[{'attributes':{'version':'42.9'}}], 'links':{'next':'https://api.appstoreconnect.apple.com/next'}}).encode()),
                     BytesIO(json.dumps({'data':[{'attributes':{'version':'42.10'}}]}).encode())]
        with patch.object(module, 'jwt', return_value='SECRET'), patch.object(module.urllib.request, 'urlopen', side_effect=responses) as get:
            with self.assertRaises(ValueError): module.require_monotonic('key', '42.10', '1.0')
            self.assertIn('filter[preReleaseVersion.version]=1.0', get.call_args_list[1].args[0].full_url)

class ProcessingTests(unittest.TestCase):
    def response(self, data): return BytesIO(json.dumps(data).encode())
    def build(self, state='VALID', version='42.2', uploaded='2026-10-10T10:00:00Z'):
        return {'id':'record-123','attributes':{'processingState':state,'version':version,'uploadedDate':uploaded}}
    def test_records_only_exact_valid_build_and_id(self):
        with tempfile.TemporaryDirectory() as folder:
            output = str(Path(folder)/'result.json')
            responses = [self.response({'data':[{'id':'app-1'}]}), self.response({'data':[self.build()]})]
            with patch.object(module, 'jwt', return_value='TOKEN_CANARY'), patch.object(module.urllib.request, 'urlopen', side_effect=responses):
                module.poll('unused', '42.2', module.datetime.datetime.fromisoformat('2026-10-10T09:59:59+00:00').timestamp(), output)
            result = json.loads(Path(output).read_text())
            self.assertEqual(result['processingState'], 'VALID')
            self.assertEqual(result['build_id'], 'record-123')
            self.assertNotIn('TOKEN_CANARY', Path(output).read_text())
    def test_complete_does_not_pass_and_old_or_wrong_build_is_ignored(self):
        for record in [self.build(state='COMPLETE'), self.build(version='41.2'), self.build(uploaded='2026-10-09T10:00:00Z')]:
            with tempfile.TemporaryDirectory() as folder:
                output = str(Path(folder)/'result.json')
                responses = [self.response({'data':[{'id':'app-1'}]}), self.response({'data':[record]})]
                with patch.object(module, 'jwt', return_value='TOKEN_CANARY'), patch.object(module.urllib.request, 'urlopen', side_effect=responses), patch.object(module.time, 'monotonic', side_effect=[0,0,1201]), patch.object(module.time, 'sleep'):
                    with self.assertRaises(RuntimeError): module.poll('unused', '42.2', module.datetime.datetime.fromisoformat('2026-10-10T09:59:59+00:00').timestamp(), output)
                self.assertFalse(Path(output).exists())
    def test_failed_processing_rejects(self):
        responses = [self.response({'data':[{'id':'app-1'}]}), self.response({'data':[self.build(state='FAILED')]})]
        with patch.object(module, 'jwt', return_value='TOKEN_CANARY'), patch.object(module.urllib.request, 'urlopen', side_effect=responses):
            with self.assertRaises(RuntimeError): module.poll('unused', '42.2', module.datetime.datetime.fromisoformat('2026-10-10T09:59:59+00:00').timestamp(), 'unused')

if __name__ == '__main__': unittest.main()
