import importlib.util
import pathlib
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_packaging', ROOT / 'scripts/package-release.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class ReleasePackagingTests(unittest.TestCase):
    def test_manifest_requires_matching_canonical_values_and_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / 'Milk-0.2.3-macOS-arm64.zip'
            archive.write_bytes(b'checksum fixture')
            metadata = dict(version='0.2.3', build=42, releaseTag='v0.2.3', asset=archive.name, sha256=packaging.digest(archive))
            packaging.validate_manifest(metadata, ('0.2.3', '42'), archive)
            for key, invalid in [('version', '0.2.4'), ('build', 43), ('releaseTag', 'v0.2.4'), ('asset', 'Milk-0.2.4-macOS-arm64.zip'), ('sha256', '0' * 64)]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    packaging.validate_manifest(dict(metadata, **{key: invalid}), ('0.2.3', '42'), archive)

    def test_archive_rejects_extra_roots_or_unsafe_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = pathlib.Path(directory) / 'test.zip'
            for invalid in ['source.txt', '__MACOSX/metadata', 'Milk.app/../outside.txt']:
                with zipfile.ZipFile(archive, 'w') as output:
                    output.writestr('Milk.app/Contents/Info.plist', b'fixture')
                    output.writestr(invalid, b'fixture')
                with self.subTest(entry=invalid), self.assertRaises(ValueError):
                    packaging.verify_archive(archive, ('0.2.3', '42'), {})

    def test_stale_outputs_are_removed_even_when_unknown_files_block_build(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / 'release'
            output.mkdir()
            (output / 'unrelated.txt').write_text('preserve')
            (output / 'Milk-0.2.3-macOS-arm64.zip').write_bytes(b'old')
            (output / 'release.json').write_text('{}')
            with self.assertRaises(ValueError):
                packaging.prepare_output(output)
            self.assertEqual([entry.name for entry in output.iterdir()], ['unrelated.txt'])

    def test_minimum_os_compares_numeric_components(self):
        self.assertEqual(packaging.system_tuple('26.0'), packaging.system_tuple('26.0.0'))
        for invalid in [None, '', '26', 'macOS 26', '26.0-beta']:
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                packaging.system_tuple(invalid)


if __name__ == '__main__':
    unittest.main()
