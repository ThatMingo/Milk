import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('keychain_signing', Path(__file__).resolve().parents[2] / 'scripts/keychain-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)

class SigningTests(unittest.TestCase):
    def test_private_identity_without_shared_group(self):
        profile = {'TeamIdentifier': ['TEAM'], 'Entitlements': {'com.apple.application-identifier': 'TEAM.dev.milk.phase1', 'com.apple.developer.team-identifier': 'TEAM'}}
        result = signing.entitlements({'existing': True}, profile)
        self.assertEqual(result['com.apple.application-identifier'], 'TEAM.dev.milk.phase1')
        self.assertTrue(result['existing'])
        self.assertNotIn('keychain-access-groups', result)
    def test_mismatched_and_wildcard_profiles_rejected(self):
        for app_id in ['TEAM.*', 'TEAM.some.other.app', '']:
            with self.assertRaises(ValueError):
                signing.entitlements({}, {'TeamIdentifier': ['TEAM'], 'Entitlements': {'com.apple.application-identifier': app_id, 'com.apple.developer.team-identifier': 'TEAM'}})
        with self.assertRaises(ValueError):
            signing.entitlements({}, {'TeamIdentifier': ['OTHER'], 'Entitlements': {'com.apple.application-identifier': 'TEAM.dev.milk.phase1', 'com.apple.developer.team-identifier': 'TEAM'}})
