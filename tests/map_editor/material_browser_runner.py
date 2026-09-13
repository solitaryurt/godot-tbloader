#!/usr/bin/env python3
"""Compile-independent Godot runtime + real EditorFileSystem browser checks."""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ERROR = re.compile(r"SCRIPT ERROR|\bERROR:|Parse Error|MATERIAL_BROWSER_FAIL|CRASH|leaked", re.I)


def run(engine, project, artifacts, name, args, marker, expect_failure=False):
    env = dict(os.environ, GODOT_SILENCE_ROOT_WARNING="1")
    for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"):
        env[key] = str(artifacts / key.lower())
    with (artifacts / (name + ".log")).open("w") as log:
        process = subprocess.Popen([engine, "--headless", "--path", str(project), *args],
                                   stdout=log, stderr=subprocess.STDOUT, env=env,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError(name + " timed out")
    text = (artifacts / (name + ".log")).read_text(errors="replace")
    if expect_failure:
        if code != 1 or "deliberate harness failure probe" not in text:
            raise RuntimeError("failure probe was not detected")
    elif code or ERROR.search(text) or sum(line.startswith(marker) for line in text.splitlines()) != 1:
        for line in text.splitlines():
            if ERROR.search(line) or "at:" in line:
                print(line)
        raise RuntimeError(f"{name} failed (exit {code}); see {artifacts / (name + '.log')}")
    for line in text.splitlines():
        if line.startswith("MATERIAL_BROWSER_") and "FAIL" not in line:
            print(line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64")
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix="material-browser-", dir="/tmp/opencode"))
    project = artifacts / "project"
    project.mkdir()
    print("Logs/project:", artifacts)
    shutil.copy2(ROOT / "addons/tbloader/src/editor/material_browser.gd", project)
    shutil.copy2(HERE / "material_browser_suite.gd", project)
    for directory in ("art", "textures", "addons/material_browser_probe"):
        (project / directory).mkdir(parents=True)
    for path in ("textures/native.tres", "art/other.tres"):
        (project / path).write_text('[gd_resource type="StandardMaterial3D" format=3]\n[resource]\n')
    (project / "textures/plain.tres").write_text('[gd_resource type="Resource" format=3]\n[resource]\n')
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    (project / "textures/brick.png").write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\0\xff\0" * 2)) + chunk(b"IEND", b""))
    config = '[application]\nconfig/name="Material browser independent tests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
    (project / "project.godot").write_text(config)
    run(args.godot, project, artifacts, "runtime", ["--script", "res://material_browser_suite.gd"], "MATERIAL_BROWSER_PASS")
    run(args.godot, project, artifacts, "failure-probe", ["--script", "res://material_browser_suite.gd", "--", "--fail-probe"], "", True)
    plugin = project / "addons/material_browser_probe"
    shutil.copy2(HERE / "material_browser_editor_probe.gd", plugin)
    (plugin / "plugin.cfg").write_text('[plugin]\nname="Material Browser Probe"\ndescription="Independent browser integration"\nauthor="TBLoader"\nversion="1"\nscript="material_browser_editor_probe.gd"\n')
    (project / "project.godot").write_text(config + '[editor_plugins]\nenabled=PackedStringArray("res://addons/material_browser_probe/plugin.cfg")\n')
    run(args.godot, project, artifacts, "editor", ["--editor"], "MATERIAL_BROWSER_EDITOR_PASS")
    print("PASS: runtime, deliberate failure detection, real EditorFileSystem add/remove")


if __name__ == "__main__":
    main()
