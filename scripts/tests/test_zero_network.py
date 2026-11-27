import importlib.util
from pathlib import Path
import tempfile
import unittest
spec = importlib.util.spec_from_file_location('gate', Path(__file__).resolve().parents[1] / 'check_zero_network.py')
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
class PolicyTests(unittest.TestCase):
    def test_forbidden_sources(self):
        for source in ['let x = URLSession.shared', 'import Network', 'socket(0)', 'socket( 0)', 'import FoundationNetworking', 'AVAudioRecorder()', 'requestAuthorization(options: [])', 'WKWebView()']:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); (root/'RecallRail').mkdir(); (root/'RecallRail/X.swift').write_text(source)
                self.assertIn('source_api', gate.audit(root), source)
    def test_dependency_and_entitlements(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'Packages/Bad').mkdir(parents=True)
            (root/'Packages/Bad/Package.swift').write_text('.package(url: "https://example.org/client", exact: "1")')
            (root/'Bad.entitlements').write_text('<plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>')
            self.assertEqual(set(gate.audit(root)), {'dependency_manifest', 'dependency_pin', 'source_entitlement'})
    def test_local_dependency_and_nested_app_source_do_not_evade_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'Packages/Bad').mkdir(parents=True)
            (root/'Packages/Bad/Package.swift').write_text('.package(path: "../../../HTTPClient")')
            (root/'RecallRail/Tests').mkdir(parents=True)
            (root/'RecallRail/Tests/Hidden.swift').write_text('import Network')
            self.assertEqual(set(gate.audit(root)), {'dependency_local_path', 'source_api'})
if __name__ == '__main__': unittest.main()
