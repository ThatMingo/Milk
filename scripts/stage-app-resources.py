#!/usr/bin/env python3
"""Stage Milk-authored adapter resources and notices, never coding-agent code."""
import pathlib
import shutil
import sys

NOTICES = (
    'SwiftTerm-LICENSE.txt', 'Pi-LICENSE', 'Pi-Dependencies.txt', 'Bun-LICENSE.md',
    'Runtime-Libraries.txt', 'modelcontextprotocol-typescript-sdk.txt',
    'pi-install-package-lock.json', 'README.md', 'INVENTORY.md',
    'ripgrep/LICENSE-MIT', 'ripgrep/UNLICENSE', 'ripgrep/COPYING',
    'fd/LICENSE-MIT', 'fd/LICENSE-APACHE',
)


def stage(source: pathlib.Path, destination: pathlib.Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    # build.sh uses a fresh staging app. Fail rather than retain an old bundled agent.
    if (destination / 'PiRuntime').exists():
        raise RuntimeError('Resource staging must not contain a bundled Pi runtime')
    shutil.copy2(source / 'Runtime/MilkPiIntegration.ts', destination / 'MilkPiIntegration.ts')
    for name in NOTICES:
        target = destination / 'ThirdPartyNotices' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'ThirdPartyNotices' / name, target)


if __name__ == '__main__':
    stage(pathlib.Path(__file__).resolve().parent.parent, pathlib.Path(sys.argv[1]))
