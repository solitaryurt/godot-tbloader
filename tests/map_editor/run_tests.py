#!/usr/bin/env python3
"""Run the real TBLoader addon in an isolated, disposable Linux Godot project."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_ENGINE = "/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64"
ERROR = re.compile(
    r"SCRIPT ERROR|(?:^|\n)\s*(?:ERROR|FATAL|CRASH)\b|"
    r"TB_TEST_ASSERTION_FAILED|AddressSanitizer|UndefinedBehaviorSanitizer|"
    r"Segmentation fault|handle_crash|Parse Error",
    re.IGNORECASE,
)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class GateFailure(Exception):
    pass


def execute(command, directory, env, timeout, logs, name, marker=None):
    """Do not trust exit zero: check diagnostics and the test's completion protocol."""
    started = time.monotonic()
    stdout_path = logs / f"{name}.stdout.log"
    stderr_path = logs / f"{name}.stderr.log"
    timed_out = False
    with stdout_path.open("w") as out, stderr_path.open("w") as err:
        process = subprocess.Popen(
            command, cwd=directory, env=env, stdout=out, stderr=err,
            start_new_session=True,
        )
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Terminate import helpers too, not just the editor parent.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    stdout = ANSI.sub("", stdout_path.read_text(errors="replace"))
    stderr = ANSI.sub("", stderr_path.read_text(errors="replace"))
    failures = []
    if timed_out:
        failures.append(f"timeout after {timeout}s")
    if process.returncode != 0:
        failures.append(f"exit status {process.returncode}")
    if ERROR.search(stdout + "\n" + stderr):
        failures.append("engine/script/assertion error")
    # Also catches unstructured printerr() failures in the existing native loader.
    if stderr.strip():
        failures.append("nonempty stderr")
    if marker and stdout.splitlines().count(marker) != 1:
        failures.append(f"missing or duplicate completion marker: {marker}")
    result = {
        "command": command, "exit_code": process.returncode,
        "seconds": round(time.monotonic() - started, 3),
        "timed_out": timed_out, "failures": failures,
    }
    (logs / f"{name}.json").write_text(json.dumps(result, indent=2) + "\n")
    if failures:
        raise GateFailure(f"{name}: " + "; ".join(failures))
    return stdout


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_checker(path, width=64, height=32, tint=None):
    """Deterministic RGB fixture (asymmetric 64x32 by default), no imaging dependency."""
    def chunk(kind, payload):
        data = kind + payload
        return struct.pack(">I", len(payload)) + data + struct.pack(">I", zlib.crc32(data))

    pixels = bytearray()
    for y in range(height):
        pixels.append(0)  # PNG filter: none.
        for x in range(width):
            color = (240, 240, 240) if (x // 8 + y // 8) % 2 else (32, 64, 128)
            if x < 8 and y < 8:
                color = (255, 32, 16)  # Unique top-left orientation marker.
            pixels.extend(tint or color)
    path.parent.mkdir(parents=True)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(pixels))) + chunk(b"IEND", b"")
    )


def stage(project):
    project.mkdir()
    shutil.copy2(HERE / "project.godot", project)
    for name in ("checks.gd", "document_suite.gd"):
        shutil.copy2(HERE / name, project)
    shutil.copytree(HERE / "fixtures", project / "fixtures")
    write_checker(project / "textures/baseline/checker.png")
    write_checker(project / "textures-other/baseline/checker.png", 16, 128, (20, 220, 60))
    addon = project / "addons" / "tbloader"
    shutil.copytree(
        ROOT / "addons" / "tbloader", addon,
        ignore=shutil.ignore_patterns("bin", "*.uid", "*.import", ".godot"),
    )
    # Copy exactly the freshly built debug library; never symlink writable inputs.
    library = ROOT / "addons/tbloader/bin/libtbloader.linux.template_debug.x86_64.so"
    if not library.is_file():
        raise GateFailure("debug library missing; run the documented SCons build first")
    (addon / "bin").mkdir()
    shutil.copy2(library, addon / "bin" / library.name)
    harness = project / "addons" / "map_editor_tests"
    harness.mkdir()
    for name in ("plugin.cfg", "editor_suite.gd"):
        shutil.copy2(HERE / name, harness)
    return {
        "library": str(library), "library_sha256": sha256(library),
        "inputs": {
            str(path.relative_to(project)): sha256(path)
            for path in sorted(project.rglob("*")) if path.is_file()
        },
    }


def run(args):
    args.artifacts.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix=f"{args.suite}-", dir=args.artifacts))
    project = logs / "project"
    print(f"Artifacts: {logs}", flush=True)
    result = {"suite": args.suite, "probe": args.probe, "status": "FAIL"}
    try:
        if args.suite == "ui" and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            raise GateFailure("UI smoke requires DISPLAY or WAYLAND_DISPLAY; no headless fallback")
        engine = Path(args.godot).expanduser().resolve()
        if not engine.is_file() or not os.access(engine, os.X_OK):
            raise GateFailure(f"Godot executable unavailable: {engine}")
        env = os.environ.copy()
        env["TB_TEST_PROBE"] = ""
        env["TB_TEST_SUITE"] = "import"
        # Prevent editor settings, caches and user:// files affecting a real project.
        for variable in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            location = logs / variable.lower()
            location.mkdir()
            env[variable] = str(location)
        version = execute(
            [str(engine), "--headless", "--version"], ROOT, env,
            min(args.timeout, 15), logs, "version",
        ).strip()
        expected = (HERE / "engine_version.txt").read_text().strip()
        result["engine"] = str(engine)
        result["version"] = version
        if version != expected:
            raise GateFailure(f"engine version {version!r} differs from pin {expected!r}")
        result.update(stage(project))
        base = [str(engine), "--path", str(project), "--audio-driver", "Dummy"]
        execute(
            base + ["--headless", "--editor"], project, env,
            args.timeout, logs, "import", "TB_TEST_COMPLETE:import:PASS",
        )
        env["TB_TEST_SUITE"] = args.suite
        env["TB_TEST_PROBE"] = args.probe or ""
        if args.suite == "document":
            command = base + ["--headless", "--script", "res://document_suite.gd"]
        elif args.suite in ("editor", "toolbar"):
            command = base + ["--headless", "--editor"]
        else:
            # Prefer the tested X11 path when both desktop sockets are available.
            driver = "x11" if env.get("DISPLAY") else "wayland"
            command = base + ["--editor", "--display-driver", driver, "--rendering-method", "gl_compatibility"]
        output = execute(
            command, project, env, args.timeout, logs, args.suite,
            f"TB_TEST_COMPLETE:{args.suite}:PASS",
        )
        counts = re.findall(rf"^TB_TEST_COUNTS:{args.suite}:(\d+):(\d+)$", output, re.MULTILINE)
        if len(counts) != 1 or int(counts[0][0]) == 0 or int(counts[0][1]) != 0:
            raise GateFailure("missing or invalid assertion counts")
        result["checks"] = int(counts[0][0])
        if args.suite == "ui":
            shutil.copy2(project / "editor-smoke.png", logs)
        result["status"] = "PASS"
        print(f"PASS {args.suite}: {result['checks']} checks", flush=True)
    except (GateFailure, OSError) as error:
        result["reason"] = str(error)
        print(f"FAIL {args.suite}: {error}", file=sys.stderr, flush=True)
    finally:
        (logs / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if result["status"] == "PASS" and not args.keep_project:
            shutil.rmtree(project)
    return 0 if result["status"] == "PASS" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", DEFAULT_ENGINE))
    parser.add_argument("--suite", choices=("document", "editor", "toolbar", "ui"), required=True)
    parser.add_argument("--timeout", type=float, default=90, help="external timeout per process, seconds")
    parser.add_argument("--artifacts", type=Path, default=HERE / "artifacts")
    parser.add_argument("--keep-project", action="store_true")
    parser.add_argument("--probe", choices=("assertion", "engine-error", "missing-marker", "timeout"))
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.probe and args.suite != "document":
        parser.error("failure probes use the document suite")
    args.artifacts = args.artifacts.resolve()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
