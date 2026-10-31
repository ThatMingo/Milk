#!/usr/bin/env python3
"""Download official hash-pinned runtime artifacts; requires Python 3.12+ and curl."""
import hashlib, json, pathlib, shutil, subprocess, tempfile, tarfile
root=pathlib.Path(__file__).resolve().parent.parent
runtime=root/'Runtime/PiRuntime'
manifest=json.loads((runtime/'runtime-manifest.json').read_text())
assert manifest['version']=='1.4.0'
artifacts=[('https://github.com/earendil-works/pi/releases/download/v1.4.0/pi-darwin-arm64.tar.gz',manifest['archiveSHA256'],'pi'),
('https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz',manifest['tools'][0]['archiveSHA256'],'rg'),
('https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz',manifest['tools'][1]['archiveSHA256'],'fd')]
with tempfile.TemporaryDirectory(prefix='milk-bootstrap-') as folder:
    temp=pathlib.Path(folder)
    for index,(url,digest,name) in enumerate(artifacts):
        archive=temp/f'{index}.tar.gz'
        subprocess.run(['curl','--fail','--location','--retry','2',url,'--output',str(archive)],check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=digest: raise SystemExit('Artifact checksum mismatch: '+name)
        destination=temp/name; destination.mkdir()
        with tarfile.open(archive) as tar: tar.extractall(destination,filter='data')
        if name=='pi':
            source=destination/'pi'
            shutil.rmtree(source/'examples/extensions/doom-overlay',ignore_errors=True)
            demo=runtime/'examples/extensions/doom-overlay'
            if demo.exists():
                preserved=root/'docs/private-reference'/('pi-doom-overlay-'+hashlib.sha256(str(temp).encode()).hexdigest()[:12])
                preserved.parent.mkdir(parents=True,exist_ok=True)
                shutil.move(str(demo),preserved)
            shutil.copytree(source,runtime,dirs_exist_ok=True)
        else:
            binary=next(p for p in destination.rglob(name) if p.is_file())
            (runtime/'bin').mkdir(exist_ok=True)
            shutil.copy2(binary,runtime/'bin'/name)
subprocess.run(['python3',str(root/'scripts/verify-runtime.py')],check=True)
