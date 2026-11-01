#!/usr/bin/env python3
"""Derive Milk's private app identity from a real provisioning profile."""
import plistlib
import sys
from pathlib import Path


def entitlements(base, profile):
    allowed = profile['Entitlements']
    app_id = allowed.get('com.apple.application-identifier', '')
    team = allowed.get('com.apple.developer.team-identifier', '')
    if not team or not app_id.endswith('.dev.milk.phase1') or '*' in app_id:
        raise ValueError('Profile must authorize the explicit dev.milk.phase1 App ID')
    if team not in profile.get('TeamIdentifier', []):
        raise ValueError('Profile team identifier mismatch')
    result = dict(base)
    result['com.apple.application-identifier'] = app_id
    result['com.apple.developer.team-identifier'] = team
    # No shared groups: SecItemAdd uses this app identifier as its private group.
    return result


if __name__ == '__main__':
    try:
        base, profile, output = map(Path, sys.argv[1:])
        output.write_bytes(plistlib.dumps(entitlements(plistlib.loads(base.read_bytes()), plistlib.loads(profile.read_bytes()))))
    except (ValueError, KeyError, OSError) as error:
        sys.exit('Milk Keychain signing configuration failed: ' + str(error))
