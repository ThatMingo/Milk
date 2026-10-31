#!/usr/bin/env python3
"""Rebuild notices from the upstream pinned install lock; verifies npm archive integrity."""
import base64, concurrent.futures, hashlib, io, json, pathlib, re, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parent.parent
lock = json.loads((root / 'ThirdPartyNotices/pi-install-package-lock.json').read_text())
packages = {}
for path, info in lock['packages'].items():
    if not path or 'resolved' not in info: continue
    name = path.rsplit('node_modules/', 1)[-1]
    packages[(name, info['version'])] = info

def collect(item):
    (name, version), info = item
    cache = pathlib.Path('/tmp/milk-notice-archives'); cache.mkdir(exist_ok=True)
    archive_path = cache / (hashlib.sha256(info['resolved'].encode()).hexdigest() + '.tgz')
    if not archive_path.exists():
        with urllib.request.urlopen(info['resolved'], timeout=60) as response: archive_path.write_bytes(response.read())
    archive = archive_path.read_bytes()
    if info.get('integrity'):
        algorithm, expected = info['integrity'].split('-', 1)
        actual = base64.b64encode(hashlib.new(algorithm, archive).digest()).decode()
        if actual != expected: raise RuntimeError('Integrity failure: ' + name)
    texts = []
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar.getmembers():
            if not member.isfile() or member.size > 2_000_000: continue
            base = member.name.rsplit('/', 1)[-1]
            if re.match(r'^(LICEN[CS]E|COPYING|NOTICE|AUTHORS)([.\-_].*)?$', base, re.I):
                texts.append(member.name + '\n' + tar.extractfile(member).read().decode('utf-8', 'replace'))
        if not texts:
            for member in tar.getmembers():
                if member.isfile() and member.name.rsplit('/', 1)[-1].lower().startswith('readme'):
                    text = tar.extractfile(member).read().decode('utf-8', 'replace')
                    if re.search(r'license|copyright', text, re.I): texts.append(member.name + '\n' + text)
    if not texts:
        if name.startswith('@earendil-works/'):
            texts.append((root / 'ThirdPartyNotices/Pi-LICENSE').read_text())
        elif name.startswith('@aws-sdk/') or name.startswith('@smithy/') or name.startswith('@aws/'):
            for filename in ['LICENSE', 'NOTICE']:
                try:
                    with urllib.request.urlopen('https://raw.githubusercontent.com/aws/aws-sdk-js-v3/main/' + filename, timeout=30) as response:
                        texts.append('AWS SDK upstream ' + filename + '\n' + response.read().decode())
                except urllib.error.HTTPError as error:
                    if error.code != 404: raise
        elif name == 'proxy-agent-negotiate':
            with urllib.request.urlopen('https://raw.githubusercontent.com/TooTallNate/proxy-agents/main/packages/proxy-agent/LICENSE', timeout=30) as response:
                texts.append(response.read().decode())
        elif name == 'standardwebhooks':
            with urllib.request.urlopen('https://raw.githubusercontent.com/standard-webhooks/standard-webhooks/main/LICENSE', timeout=30) as response:
                texts.append(response.read().decode())
        if not texts: raise RuntimeError('Missing license material: ' + name)
    return f"{'='*78}\n{name}@{version} — {info.get('license','see below')}\nSource: {info['resolved']}\n\n" + '\n\n'.join(texts)

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    result = list(pool.map(collect, sorted(packages.items())))
(root / 'ThirdPartyNotices/Pi-Dependencies.txt').write_text('Pi 1.4.0 dependency licenses and notices. Includes the full upstream install closure; some packages are bundled into the standalone executable.\n\n' + '\n\n'.join(result))
print(f'Collected {len(result)} verified package notices')
