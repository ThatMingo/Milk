#!/usr/bin/env python3
"""Focused release resource recipe test; no Swift build or signing acceptance."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('stage_resources', ROOT / 'scripts/stage-app-resources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CleanAppResourcesTests(unittest.TestCase):
    def test_actual_recipe_needs_no_pi_runtime_and_stages_no_agent(self):
        with tempfile.TemporaryDirectory(prefix='Milk-clean-resources-') as folder:
            root = pathlib.Path(folder)
            # This source tree deliberately has no Runtime/PiRuntime at all.
            (root / 'source/Runtime').mkdir(parents=True)
            (root / 'source/Runtime/MilkPiIntegration.ts').write_bytes((ROOT / 'Runtime/MilkPiIntegration.ts').read_bytes())
            for name in module.NOTICES:
                path = root / 'source/ThirdPartyNotices' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes((ROOT / 'ThirdPartyNotices' / name).read_bytes())
            resources = root / 'Milk.app/Contents/Resources'
            module.stage(root / 'source', resources)
            self.assertTrue((resources / 'MilkPiIntegration.ts').is_file())
            self.assertEqual(set(str(p.relative_to(resources)) for p in resources.rglob('*') if p.is_file()),
                             {'MilkPiIntegration.ts'} | {'ThirdPartyNotices/' + name for name in module.NOTICES})
            self.assertFalse((resources / 'PiRuntime').exists())
            script = (ROOT / 'scripts/build.sh').read_text()
            self.assertIn('python3 scripts/stage-app-resources.py "$resources"', script)
            for obsolete in ['verify-runtime.py', 'bootstrap-runtime.py', 'Runtime/PiRuntime', 'PiRuntime/', 'pi-runtime.entitlements', 'executableSHA256']:
                self.assertNotIn(obsolete, script)
            (resources / 'PiRuntime').mkdir()
            with self.assertRaises(RuntimeError):
                module.stage(root / 'source', resources)


if __name__ == '__main__':
    unittest.main()
