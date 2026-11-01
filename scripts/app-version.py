#!/usr/bin/env python3
"""Validate canonical Milk metadata and optionally stamp a generated plist."""
import argparse
import pathlib
import plistlib
import re
import sys


def read_metadata(root):
    version = (root / 'VERSION').read_text().strip()
    build = (root / 'BUILD_NUMBER').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('VERSION must contain a stable MAJOR.MINOR.PATCH version without leading zeroes')
    if not re.fullmatch(r'[1-9][0-9]{0,3}', build):
        raise ValueError('BUILD_NUMBER must contain an integer from 1 through 9999')
    return version, build


def stamp(root, plist):
    version, build = read_metadata(root)
    data = plistlib.loads(plist.read_bytes())
    data.update(CFBundleShortVersionString=version, CFBundleVersion=build)
    plist.write_bytes(plistlib.dumps(data, sort_keys=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument('--plist', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.plist:
            stamp(args.root, args.plist)
        else:
            read_metadata(args.root)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        sys.exit('Milk version metadata error: ' + str(error))
