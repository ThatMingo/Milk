import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('app_version', ROOT / 'scripts/app-version.py')
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


class ApplicationVersionTests(unittest.TestCase):
    def test_canonical_metadata_and_built_bundle(self):
        expected = versioning.read_metadata(ROOT)
        built = plistlib.loads((ROOT / 'output/Milk.app/Contents/Info.plist').read_bytes())
        self.assertEqual((built['CFBundleShortVersionString'], built['CFBundleVersion']), expected)

    def test_validation_and_stamping_preserve_other_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'VERSION').write_text('0.2.3\n')
            (root / 'BUILD_NUMBER').write_text('42\n')
            plist = root / 'Info.plist'
            plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.milk'}))
            versioning.stamp(root, plist)
            self.assertEqual(plistlib.loads(plist.read_bytes()), dict(CFBundleIdentifier='test.milk', CFBundleShortVersionString='0.2.3', CFBundleVersion='42'))
            for invalid in ('', '1.2', '01.2.3', '1.2.3.4', '0.2.0-beta.1', '1.2.3\n2.0.0', 'v1.2.3'):
                (root / 'VERSION').write_text(invalid)
                with self.subTest(version=invalid), self.assertRaises(ValueError):
                    versioning.read_metadata(root)
            (root / 'VERSION').write_text('1.0.0')
            for invalid in ('0', '-1', '01', '1.2', '10000', ''):
                (root / 'BUILD_NUMBER').write_text(invalid)
                with self.subTest(build=invalid), self.assertRaises(ValueError):
                    versioning.read_metadata(root)
            (root / 'BUILD_NUMBER').unlink()
            with self.assertRaises(FileNotFoundError):
                versioning.read_metadata(root)
            (root / 'VERSION').unlink()
            with self.assertRaises(FileNotFoundError):
                versioning.read_metadata(root)


if __name__ == '__main__':
    unittest.main()
