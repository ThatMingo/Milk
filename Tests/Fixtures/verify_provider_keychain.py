#!/usr/bin/env python3
"""Measure real ordinary-Keychain persistence/default ACLs with disposable app items.

No credential bytes in arguments, environment, metadata or logs. The app owns the
synthetic values. UUIDs identify only disposable entries. No ACL is edited.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'output/Milk.app'
BIN = APP / 'Contents/MacOS/Milk'


def signature():
    result = subprocess.run(['codesign', '-dvvv', str(APP)], capture_output=True, text=True, check=True)
    return next(line.partition('=')[2] for line in result.stderr.splitlines() if line.startswith('CDHash='))


def copy_app(source, target):
    if target.exists():
        assert target.suffix == '.app' and not target.is_symlink()
        shutil.rmtree(target)
    subprocess.run(['/usr/bin/ditto', str(source), str(target)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rebuild', action='store_true')
    parser.add_argument('--changed-signature', action='store_true')
    parser.add_argument('--authorize', action='store_true', help='Explicitly exercise the same user-requested recovery path as Settings')
    args = parser.parse_args()
    run_id = str(uuid.uuid4())
    results = {}

    def verify(phase, required=True):
        result = subprocess.run([str(BIN), '--verify-provider-keychain', '--keychain-run-id', run_id,
                                 '--keychain-phase', phase], cwd=ROOT, capture_output=True, text=True, timeout=15)
        print(result.stdout.strip(), flush=True)
        if required and result.returncode:
            raise RuntimeError('Credential verifier failed at ' + phase)
        return result.returncode == 0

    assert APP.is_dir() and not APP.is_symlink()
    with tempfile.TemporaryDirectory(prefix='Milk-Keychain-ACL-') as directory:
        backup = Path(directory) / 'Creator.app'
        current = Path(directory) / 'Current.app'
        copy_app(APP, backup)
        created = False
        try:
            verify('all')
            verify('keep'); created = True
            results['separate_launch_read'] = verify('read')
            before = signature()
            if args.rebuild:
                subprocess.run([str(ROOT / 'scripts/build.sh'), '--disable-sandbox'], cwd=ROOT, check=True)
                results['rebuild_signature_changed'] = signature() != before
                results['rebuild_noninteractive_read'] = verify('read', required=False)
            copy_app(APP, current)
            if args.changed_signature:
                info_path = APP / 'Contents/Info.plist'
                info = plistlib.loads(info_path.read_bytes())
                info['MilkDisposableACLVerificationNonce'] = str(uuid.uuid4())
                info_path.write_bytes(plistlib.dumps(info))
                prior = signature()
                subprocess.run(['codesign', '--force', '--options', 'runtime', '--entitlements',
                                str(ROOT / 'scripts/milk-app.entitlements'), '--sign', '-', str(APP)], check=True)
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
                results['variant_signature_changed'] = signature() != prior
                assert results['variant_signature_changed']
                results['variant_noninteractive_read'] = verify('read', required=False)
                if args.authorize and not results['variant_noninteractive_read']:
                    results['explicit_recovery'] = verify('authorize')
                    results['separate_launch_after_recovery'] = verify('read', required=False)
        finally:
            # Restore the exact creator identity/path for deletion, not a broader ACL.
            copy_app(backup, APP)
            try:
                if created:
                    results['creator_read_after_rebuild'] = verify('read')
                    results['cleanup_verified'] = verify('cleanup')
            finally:
                if current.exists():
                    copy_app(current, APP)
    print(json.dumps(results, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
