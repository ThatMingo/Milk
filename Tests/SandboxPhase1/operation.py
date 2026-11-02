"""One disposable worker operation. No host privileges, credentials or live data."""
import json, os, pathlib, subprocess, sys
r=json.load(sys.stdin);op=r['op'];a=r.get('args',{})
try:
    if op=='read':value=pathlib.Path(a['path']).read_text()
    elif op=='access':
        if not os.access(a['path'],os.R_OK):raise PermissionError('access denied')
        value=None
    elif op=='write':pathlib.Path(a['path']).write_text(a['content']);value=None
    elif op=='mkdir':pathlib.Path(a['path']).mkdir(parents=True,exist_ok=True);value=None
    elif op=='bash':
        p=subprocess.run(['/bin/sh','-c',a['command']],cwd=a['cwd'],capture_output=True,text=True,timeout=10)
        value={'exitCode':p.returncode,'output':p.stdout+p.stderr}
    elif op=='ls':value='\n'.join(sorted(p.name for p in pathlib.Path(a['path']).iterdir()))
    elif op=='find':value='\n'.join(str(p) for p in pathlib.Path(a['path']).rglob(a['pattern']))
    elif op=='grep':
        value='\n'.join(str(p) for p in pathlib.Path(a['path']).rglob('*') if p.is_file() and a['pattern'] in p.read_text())
    else:raise ValueError('unsupported operation; no fallback')
    print(json.dumps({'value':value}))
except Exception as e:print(json.dumps({'error':type(e).__name__}));sys.exit(1)
