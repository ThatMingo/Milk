#!/usr/bin/env python3
"""Run the packaged native app with a live Preview; verify real Quit and window-close cleanup."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

project = Path(__file__).resolve().parents[2]
app = project / "output/Milk.app/Contents/MacOS/Milk"
output = project / "output/verification-phase5"
metadata = output / "quit-probe.json"
results = []
for mode in ["--verify-preview-quit", "--verify-preview-window-close"]:
    metadata.unlink(missing_ok=True)
    process = subprocess.Popen([str(app), mode], cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    started = time.monotonic()
    group_confirmed_gone = False
    try:
        stdout, _ = process.communicate(timeout=20)
        assert process.returncode == 0, stdout.decode(errors="replace")
        data = json.loads(metadata.read_text())
        group = int(data["group"])
        try:
            os.killpg(group, 0)
        except ProcessLookupError:
            group_confirmed_gone = True
        else:
            raise AssertionError("Milk-owned Preview group survived app termination")
        assert not Path(data["temporary"]).exists(), "Milk temporary resources survived app termination"
        fixture = Path(data["project"])
        assert (fixture / "index.html").exists(), "App termination removed project content"
        assert fixture.name.startswith("Milk-Preview-Quit-")
        shutil.rmtree(fixture)  # Disposable test fixture, never production cleanup.
        results.append(f"PASS {mode}: app exits, owned group gone, temporary resources removed, project preserved ({time.monotonic()-started:.2f}s)")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=3)
        if metadata.exists() and not group_confirmed_gone:
            data = json.loads(metadata.read_text())
            # This probe itself launched the app and recorded its current-run owned group.
            try:
                os.killpg(int(data["group"]), 9)
            except ProcessLookupError:
                pass
print("\n".join(results))
(output / "shutdown-results.txt").write_text("\n".join(results) + "\n")
