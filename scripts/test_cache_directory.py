#!/usr/bin/env python3
import json
import tempfile
import unittest
from pathlib import Path

import clear_catalog_cache as cache


class CacheDirectoryTest(unittest.TestCase):
    def test_legacy_directory_is_unchanged(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            self.assertEqual(cache.cache_directory(directory), directory)

    def test_separated_and_portable_cache_preserve_state(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root) / 'data'
            data.mkdir()
            device = data / 'hongguo-devices.json'
            original = json.dumps({'version': 1, 'hongguo': {'deviceId': '1001'}})
            device.write_text(original, encoding='utf-8')
            marker = data / 'native-cache-layout.json'
            for target in (Path(root) / 'external-cache', data / 'cache'):
                marker.write_text(json.dumps({'version': 1, 'cache': str(target)}), encoding='utf-8')
                self.assertEqual(cache.cache_directory(data), target.resolve())
                self.assertEqual(device.read_text(encoding='utf-8'), original)

    def test_bad_and_overlapping_markers_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root) / 'data'
            data.mkdir()
            (data / 'hongguo-devices.json').write_text('{"version":1}', encoding='utf-8')
            marker = data / 'native-cache-layout.json'
            for target in (data, data / 'store', Path(root), data / 'downloads', Path('relative')):
                marker.write_text(json.dumps({'version': 1, 'cache': str(target)}), encoding='utf-8')
                with self.assertRaises(ValueError):
                    cache.cache_directory(data)
            marker.write_text('{invalid', encoding='utf-8')
            with self.assertRaises(ValueError):
                cache.cache_directory(data)

    def test_user_selected_downloads_are_never_cache(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root) / 'data'
            data.mkdir()
            (data / 'hongguo-devices.json').write_text('{"version":1}', encoding='utf-8')
            downloads = Path(root) / 'media'
            (data / 'download-location.json').write_text(json.dumps({'directory': str(downloads)}), encoding='utf-8')
            for target in (downloads, downloads / 'cache'):
                (data / 'native-cache-layout.json').write_text(json.dumps({'version': 1, 'cache': str(target)}), encoding='utf-8')
                with self.assertRaises(ValueError):
                    cache.cache_directory(data)


    def test_unmigrated_catalog_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root)
            catalog = data / 'catalogs.json'
            original = '{"version":3,"hongguoApp":{"deviceId":"1001"}}'
            catalog.write_text(original, encoding='utf-8')
            with self.assertRaisesRegex(ValueError, '身份拆分'):
                cache.cache_directory(data)
            self.assertEqual(catalog.read_text(encoding='utf-8'), original)

    def test_missing_or_bad_device_file_blocks_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root) / 'data'
            data.mkdir()
            (data / 'native-cache-layout.json').write_text(
                json.dumps({'version': 1, 'cache': str(Path(root) / 'cache')}),
                encoding='utf-8',
            )
            with self.assertRaises(ValueError):
                cache.cache_directory(data)
            (data / 'hongguo-devices.json').write_text('invalid', encoding='utf-8')
            with self.assertRaises(ValueError):
                cache.cache_directory(data)


if __name__ == '__main__':
    unittest.main()
