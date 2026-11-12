"""Check that raw backup columns cover every application schema table."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[2]
class SchemaCoverageTests(unittest.TestCase):
    def test_current_schema_columns_are_exhaustive(self):
        migrations = (ROOT/'Packages/RecallStore/Sources/RecallStore/Migrations.swift').read_text()
        ownership = (ROOT/'Packages/RecallStore/Sources/RecallStore/Ownership.swift').read_text()
        tables = re.findall(r'CREATE TABLE (\w+) \((.*?)\n                \);', migrations, re.S)
        self.assertEqual({name for name, _ in tables}, {'deck', 'card', 'attempt', 'skip', 'session'})
        for name, body in tables:
            columns = re.findall(r'^\s*(\w+) (?:TEXT|REAL|INTEGER)\b', body, re.M)
            line = re.search(r'"'+name+r'": \((.*?)\)', ownership).group(1)
            self.assertEqual(set(re.findall(r'"(\w+)"', line)), set(columns), name)
if __name__ == '__main__': unittest.main()
