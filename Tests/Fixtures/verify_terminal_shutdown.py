#!/usr/bin/env python3
"""Exercise packaged Terminal UI, then verify actual Quit/window-close cleanup."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

project = Path(__file__).resolve().parents[2]
app = project / 'output/Milk.app/Contents/MacOS/Milk'
output = project / 'output/verification-terminal'
metadata = output / 'quit-owned.json'
results = []
for close_window in [False, True]:
    metadata.unlink(missing_ok=True)
    unrelated = subprocess.Popen(['/bin/sleep', '120'])
    args = [str(app), '--verify-terminal']
    if close_window:
        args.append('--verify-terminal-window-close')
    process = subprocess.Popen(args, cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    started = time.monotonic()
    try:
        stdout, _ = process.communicate(timeout=100)
        label = 'window-close' if close_window else 'quit'
        (output / f'{label}-app.txt').write_bytes(stdout)
        assert process.returncode == 0, stdout.decode(errors='replace')
        assert metadata.exists(), stdout.decode(errors='replace')
        data = json.loads(metadata.read_text())
        failures = [s for s in (output / 'native-results.txt').read_text().splitlines() if s.startswith('FAIL')]
        assert not failures, '\n'.join(failures)
        for key in ['shell', 'foreground', 'background']:
            pid = int(data[key])
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.04)
            else:
                raise AssertionError(f'{key} {pid} survived real {label}')
        assert unrelated.poll() is None, 'Unrelated external shell/process was killed'
        fixture = Path(data['project'])
        assert (fixture / 'Milk.swift').exists(), 'Project file was removed by cleanup'
        assert fixture.name.startswith('Milk-Terminal-UI-')
        shutil.rmtree(fixture)
        results.append(f'PASS real {label}: shell, foreground and background groups gone; unrelated process and project preserved ({time.monotonic()-started:.2f}s)')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=4)
        unrelated.terminate()
        unrelated.wait(timeout=3)
print('\n'.join(results))
(output / 'shutdown-results.txt').write_text('\n'.join(results) + '\n')
