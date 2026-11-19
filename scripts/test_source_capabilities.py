import copy
import json
import tempfile
import unittest
from pathlib import Path

import generate_source_capabilities as generator


class SourceCapabilitiesTest(unittest.TestCase):
    def test_generated_files_are_current(self):
        for name, expected in generator.generated(generator.load_sources()).items():
            self.assertEqual((generator.ROOT / name).read_bytes(), expected.encode('utf-8'), name)

    def test_dart_wraps_calls_and_feature_sets_at_80_columns(self):
        rows = [
            {'id': 'x' * 10}, {'id': 'y' * 11},  # Flat calls of length 80 and 81.
            {'id': 'fit', 'capabilities': ['recommendations', 'danmaku', 'devices', 'rankings', 'metadata']},
            {'id': 'wrap', 'capabilities': ['search', 'pagedSearch', 'recommendations', 'danmaku', 'devices']},
        ]
        dart = generator.dart_source(rows)
        self.assertIn('  "xxxxxxxxxx": SourceCapabilities(standard: false, adult: false, features: {}),\n', dart)
        self.assertIn('  "yyyyyyyyyyy": SourceCapabilities(\n', dart)
        self.assertIn('    features: {"recommendations", "danmaku", "devices", "rankings", "metadata"},\n', dart)
        self.assertIn('    features: {\n      "search",\n      "pagedSearch",\n', dart)
        self.assertIn('<String, SourceCapabilities>{};', generator.dart_source([]))

    def test_go_aligns_only_fields_present_in_each_descriptor(self):
        rows = [{'id': 'a', 'name': '甲'}, {'id': 'b', 'name': '乙', 'standard': True}]
        go = generator.go_source(rows)
        self.assertIn('\t\tID:   "a",\n\t\tName: "甲",\n', go)
        self.assertIn('\t\tID:       "b",\n\t\tName:     "乙",\n\t\tStandard: true,\n', go)
        self.assertIn('= []nativeSourceDescriptor{}\n', generator.go_source([]))

    def test_existing_editions_and_new_source_permissions(self):
        rows = generator.load_sources()
        self.assertEqual({r['id'] for r in rows if r.get('standard')}, {'hongguo', 'fanguo', 'shuangguo'})
        self.assertEqual(len(rows), 20)
        for row in rows:
            if row['id'] in ('missav', 'hanime1'):
                self.assertTrue(row['adult'])
                self.assertFalse(row.get('standard', False))
                self.assertTrue(row['browserFingerprint'])
                self.assertEqual(row['capabilities'], ['search', 'pagedSearch'])
        self.assertEqual({r['id'] for r in rows if r.get('dnsHosts')}, {'hongguo', 'hanxiaoquan', 'guipian', 'sorani'})

    def test_policy_rejects_unsafe_or_inconsistent_config(self):
        row = generator.load_sources()[-1]
        variants = [dict(row, id='bad:id'), dict(row, standard=True), dict(row, browserHosts=['*.example.com']), dict(row, capabilities=['unknown']), dict(row, capabilities=['pagedSearch']), dict(row, browserFingerprint=False)]
        for candidate in variants:
            with self.subTest(candidate=candidate), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'sources.json'
                path.write_text(json.dumps({'format': 1, 'sources': [candidate]}), encoding='utf-8')
                with self.assertRaises(ValueError):
                    generator.load_sources(path)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sources.json'
            path.write_text(json.dumps({'format': 1, 'sources': [row, copy.deepcopy(row)]}), encoding='utf-8')
            with self.assertRaises(ValueError):
                generator.load_sources(path)


if __name__ == '__main__':
    unittest.main()
