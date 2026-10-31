#!/usr/bin/env python3
"""Reject missing/corrupt pinned source artifacts before building. No network or user config."""
import hashlib,json,pathlib,sys
root=pathlib.Path(__file__).resolve().parent.parent
runtime=root/'Runtime/PiRuntime'; manifest=json.loads((runtime/'runtime-manifest.json').read_text())
if manifest['version'] != '1.4.0': sys.exit('Unexpected Pi version. Update the release pin deliberately.')
if hashlib.sha256((runtime/'pi').read_bytes()).hexdigest() != manifest['executableSHA256']: sys.exit('Pinned Pi binary checksum mismatch')
for item in manifest.get('tools',[]):
 if hashlib.sha256((runtime/'bin'/item['name']).read_bytes()).hexdigest() != item['executableSHA256']: sys.exit('Pinned tool checksum mismatch: '+item['name'])
for name,digest in manifest.get('runtimeFiles',{}).items():
 if hashlib.sha256((runtime/name).read_bytes()).hexdigest() != digest: sys.exit('Pinned runtime dependency checksum mismatch: '+name)
for name in ['Pi-LICENSE','Pi-Dependencies.txt','Bun-LICENSE.md','Runtime-Libraries.txt','README.md',
             'SwiftTerm-LICENSE.txt','modelcontextprotocol-typescript-sdk.txt','pi-install-package-lock.json',
             'ripgrep/LICENSE-MIT','ripgrep/UNLICENSE','ripgrep/COPYING','fd/LICENSE-MIT','fd/LICENSE-APACHE']:
 if not (root/'ThirdPartyNotices'/name).is_file(): sys.exit('Missing redistribution notice: '+name)
if (runtime/'examples/extensions/doom-overlay').exists(): sys.exit('Optional Doom example must not enter the runtime')
if not (root/'Runtime/MilkPiIntegration.ts').is_file(): sys.exit('Missing Milk Pi bridge')
print('Verified vanilla Pi 1.4.0 and bundled search tools')
