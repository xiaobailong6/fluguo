import copy
import json
import tempfile
import unittest
from pathlib import Path

import generate_source_capabilities as generator


class SourceCapabilitiesTest(unittest.TestCase):
    def test_generated_files_are_current(self):
        for name, expected in generator.generated(generator.load_sources()).items():
            self.assertEqual((generator.ROOT / name).read_text(encoding='utf-8'), expected, name)

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
