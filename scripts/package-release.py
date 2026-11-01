#!/usr/bin/env python3
"""Build through build.sh, verify the real bundle, and publish local ZIP metadata."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('app_version', ROOT / 'scripts/app-version.py')
versioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versioning)


def run(*args):
    return subprocess.check_output(args, text=True, cwd=ROOT).strip()


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def system_tuple(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', value):
        raise ValueError('Missing or invalid actual minimum macOS version')
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def bundle_metadata(app, expected):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = expected
    if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != expected:
        raise ValueError('Canonical version/build disagree with built bundle')
    executable = app / 'Contents/MacOS/Milk'
    if info.get('CFBundleExecutable') != 'Milk' or not os.access(executable, os.X_OK):
        raise ValueError('Missing or non-executable Milk binary')
    if run('/usr/bin/lipo', '-archs', str(executable)) != 'arm64':
        raise ValueError('Milk executable must contain exactly the arm64 architecture')
    minimum = info.get('LSMinimumSystemVersion')
    deployment = re.findall(r'^\s*minos\s+([0-9.]+)\s*$', run('/usr/bin/xcrun', 'vtool', '-show-build', str(executable)), re.MULTILINE)
    if len(deployment) != 1 or system_tuple(deployment[0]) != system_tuple(minimum):
        raise ValueError('Bundle minimum macOS version disagrees with Mach-O deployment target')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    return dict(version=version, build=int(build), platform='macOS', architecture='arm64',
                minimumSystemVersion=minimum, asset=f'Milk-{version}-macOS-arm64.zip',
                releaseTag=f'v{version}')


def validate_manifest(metadata, expected, archive):
    version, build = expected
    if (metadata['version'] != version or metadata['build'] != int(build)
            or metadata['releaseTag'] != f'v{version}'
            or metadata['asset'] != f'Milk-{version}-macOS-arm64.zip'
            or archive.name != metadata['asset'] or metadata['sha256'] != digest(archive)):
        raise ValueError('Release metadata, asset name, checksum or canonical values disagree')


def verify_archive(archive, expected, metadata):
    with zipfile.ZipFile(archive) as zipped:
        if not zipped.namelist() or any(not name.startswith('Milk.app/') or '..' in Path(name).parts for name in zipped.namelist()):
            raise ValueError('ZIP must contain only Milk.app')
        if zipped.testzip() is not None:
            raise ValueError('ZIP integrity check failed')
    with tempfile.TemporaryDirectory(prefix='Milk-release-verify-') as directory:
        run('/usr/bin/ditto', '-x', '-k', str(archive), directory)
        unpacked = bundle_metadata(Path(directory) / 'Milk.app', expected)
        if any(metadata.get(key) != value for key, value in unpacked.items()):
            raise ValueError('Unpacked bundle disagrees with release metadata')


def prepare_output(output):
    if output.is_symlink() or output.parent.is_symlink():
        raise ValueError('Release output directory must not be a symlink')
    output.mkdir(parents=True, exist_ok=True)
    unexpected = []
    for old in output.iterdir():
        if old.name == 'release.json' or re.fullmatch(r'Milk-.*-macOS-arm64\.zip', old.name):
            if not old.is_file() and not old.is_symlink():
                raise ValueError('Unexpected directory in release output: ' + old.name)
            old.unlink()
        else:
            unexpected.append(old.name)
    if unexpected:
        raise ValueError('Unexpected files in owned release output: ' + ', '.join(unexpected))
    return output


def main(arguments):
    # Keep release configuration authoritative; forward only this existing
    # developer sandbox option, never arbitrary alternate output/build settings.
    if arguments not in ([], ['--disable-sandbox']):
        raise ValueError('Usage: scripts/build-release.sh [--disable-sandbox]')
    output = prepare_output(ROOT / 'output/release')
    expected = versioning.read_metadata(ROOT)
    subprocess.run([str(ROOT / 'scripts/build.sh'), '--configuration', 'release', *arguments], cwd=ROOT, check=True)
    if versioning.read_metadata(ROOT) != expected:
        raise ValueError('Canonical metadata changed during the build')
    app = ROOT / 'output/Milk.app'
    metadata = bundle_metadata(app, expected)
    subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(app)], check=True)
    # Stage away from the public output; failed builds leave no stale manifest.
    with tempfile.TemporaryDirectory(prefix='.release-', dir=ROOT / 'output') as directory:
        staging = Path(directory)
        archive = staging / metadata['asset']
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', str(app), str(archive))
        metadata['sha256'] = digest(archive)
        manifest = staging / 'release.json'
        manifest.write_text(json.dumps(metadata, indent=2) + '\n')
        reread = json.loads(manifest.read_text())
        validate_manifest(reread, expected, archive)
        verify_archive(archive, expected, reread)
        if versioning.read_metadata(ROOT) != expected:
            raise ValueError('Canonical metadata changed during packaging')
        # Publish the manifest last, only after the complete pair is verified.
        archive.replace(output / archive.name)
        manifest.replace(output / manifest.name)
    print(json.dumps(metadata, indent=2))
    print('Archive bytes:', (output / metadata['asset']).stat().st_size)


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        sys.exit('Milk release packaging failed: ' + str(error))
