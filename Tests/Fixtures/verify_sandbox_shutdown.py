#!/usr/bin/env python3
"""Automated real-app quit/window-close with an anchored Sandbox request pending."""
import json
from pathlib import Path
import shutil
import subprocess

project = Path(__file__).resolve().parents[2]
binary = project / 'output/Milk.app/Contents/MacOS/Milk'
output = project / 'output/verification-sandbox'
output.mkdir(parents=True, exist_ok=True)
metadata = output / 'shutdown.json'
for mode, appearance in [('quit', 'light'), ('window-close', 'dark')]:
    metadata.unlink(missing_ok=True)
    unrelated = subprocess.Popen(['/bin/sleep', '60'])
    try:
        try:
            result = subprocess.run([str(binary), '--verify-sandbox-' + mode, '--verify-' + appearance],
                                    cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
        except subprocess.TimeoutExpired as error:
            (output / (mode + '-app.txt')).write_bytes(error.output or b'')
            raise
        (output / (mode + '-app.txt')).write_bytes(result.stdout)
        assert result.returncode == 0, result.stdout.decode(errors='replace')
        data = json.loads(metadata.read_text())
        for key in ['initialGrantsEmpty', 'popupWasVisible', 'grantClosedBeforeDrain',
                    'staleOperationRejected', 'pendingCancelled', 'requestClosed']:
            assert data[key] is True, (mode, key)
        assert unrelated.poll() is None, 'Unrelated process was killed'
        fixture = Path(data['project'])
        assert fixture.name.startswith('Milk-Sandbox-Quit-')
        assert (fixture / 'project.txt').read_text() == 'preserved'
        shutil.rmtree(fixture)
        print('PASS actual app ' + mode + ': pending popup cancelled, grants invalidated before drain; '
              'unrelated process/project preserved; ' + appearance + ' appearance')
    finally:
        unrelated.terminate()
        unrelated.wait(timeout=3)
