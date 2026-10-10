from pathlib import Path
import struct
import unittest
import zlib
ROOT = Path(__file__).resolve().parents[2]
class OwnershipStructureTests(unittest.TestCase):
    def test_production_entry_and_error_propagation(self):
        self.assertIn('OwnershipView(library: library)', (ROOT/'RecallRail/DeckListView.swift').read_text())
        source = (ROOT/'RecallRail/OwnershipView.swift').read_text()
        for token in ['.fileExporter(', '.fileImporter(', 'previewRestore(', '.restore(preview)', 'eraseLocalRecords()', 'Export failed:', 'Operation failed:', 'startAccessingSecurityScopedResource', 'maximumBytes']:
            self.assertIn(token, source)
        for ancestor in ['ownership.form', 'ownership.container', 'ownership.view']:
            self.assertNotIn(f'.accessibilityIdentifier("{ancestor}")', source)
        export = (ROOT/'RecallRail/DeckLibrary.swift').read_text().split('func exportCSV')[1]
        self.assertIn('throws -> String', export)
        self.assertNotIn('try?', export)
    def test_opaque_1024_icon(self):
        data = (ROOT/'RecallRail/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        offset = 8; compressed = b''; dimensions = None
        while offset < len(data):
            size = struct.unpack('>I', data[offset:offset+4])[0]
            kind = data[offset+4:offset+8]; payload = data[offset+8:offset+8+size]
            self.assertEqual(struct.unpack('>I', data[offset+8+size:offset+12+size])[0], zlib.crc32(kind+payload)&0xffffffff)
            if kind == b'IHDR': dimensions = struct.unpack('>IIBBBBB', payload)
            if kind == b'IDAT': compressed += payload
            offset += size + 12
        self.assertEqual(dimensions, (1024, 1024, 8, 2, 0, 0, 0))
        self.assertEqual(len(zlib.decompress(compressed)), 1024 * (1 + 1024 * 3))
    def test_release_secret_and_transport_contract(self):
        workflow = (ROOT/'.github/workflows/testflight.yml').read_text()
        import re
        self.assertEqual(set(re.findall(r'secrets\.([A-Z_0-9]+)', workflow)), {'ASC_KEY_ID','ASC_ISSUER_ID','ASC_KEY_P8','ASC_TEAM_ID'})
        release = (ROOT/'scripts/testflight_release.sh').read_text()
        for token in ['set +x', 'umask 077', 'mktemp -d', '-exportArchive', "'destination':'upload'", "'method':'app-store-connect'", '${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}']:
            self.assertIn(token, release)
        for forbidden in ['altool', 'fastlane', 'tee ']: self.assertNotIn(forbidden, release)
        self.assertIn("state == 'VALID'", (ROOT/'scripts/release_support.py').read_text())
if __name__ == '__main__': unittest.main()
