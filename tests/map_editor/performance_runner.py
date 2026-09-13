#!/usr/bin/env python3
"""Reproducible, Linux/headless native TBMapDocument benchmark; no build or UI."""

import argparse
import ctypes
import ctypes.util
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ENGINE = "/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64"
TEMP = Path("/tmp/opencode")
LIBRARY = ROOT / "addons/tbloader/bin/libtbloader.linux.template_debug.x86_64.so"
MARKER = "TB_PERF_COMPLETE:PASS"
ERROR = re.compile(
    r"SCRIPT ERROR|\b(?:ERROR|FATAL|CRASH)\b|TB_PERF_FAIL|Parse Error|"
    r"AddressSanitizer|UndefinedBehaviorSanitizer|Segmentation fault|handle_crash|leaked",
    re.I,
)
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
OPERATIONS = {"import_text", "rebuild", "translate_one", "translate_all", "snapshot",
              "export_text", "get_draw_data", "get_preview_data"}


class Failure(RuntimeError):
    pass


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def execute(command, cwd, env, timeout, logs, name, marker=None):
    started = time.monotonic()
    timed_out = False
    out_path, err_path = logs / f"{name}.stdout.log", logs / f"{name}.stderr.log"
    with out_path.open("w") as out, err_path.open("w") as err:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=out, stderr=err,
                                   start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    stdout = ANSI.sub("", out_path.read_text(errors="replace"))
    stderr = ANSI.sub("", err_path.read_text(errors="replace"))
    failures = []
    if timed_out:
        failures.append("timeout")
    if process.returncode:
        failures.append(f"exit={process.returncode}")
    if ERROR.search(stdout + "\n" + stderr):
        failures.append("diagnostic")
    if stderr.strip():
        failures.append("nonempty-stderr")
    if marker and stdout.splitlines().count(marker) != 1:
        failures.append("completion-marker")
    write_json(logs / f"{name}.process.json", {
        "command": command, "timeout_seconds": timeout, "timed_out": timed_out,
        "wall_seconds": time.monotonic() - started, "exit_code": process.returncode,
        "failures": failures,
    })
    return stdout, failures


def checked_execute(*args, **kwargs):
    output, failures = execute(*args, **kwargs)
    if failures:
        raise Failure(f"{args[5]}: {', '.join(failures)}; full logs: {args[4]}")
    return output


def blockout(count):
    """Eight solids/room: floor, two walls, platform, two pillars, two steps."""
    module = [
        (0, 0, -16, 384, 384, 0), (0, 368, 0, 384, 384, 128),
        (0, 0, 0, 16, 368, 128), (224, 224, 0, 352, 352, 48),
        (64, 64, 0, 96, 96, 128), (288, 64, 0, 320, 96, 128),
        (160, 224, 0, 192, 352, 16), (192, 224, 0, 224, 352, 32),
    ]
    bounds, lines = [], ['{', '"classname" "worldspawn"']
    for i in range(count):
        room = i // len(module)
        ox, oy = (room % 8) * 512, (room // 8) * 512
        x, y, z, X, Y, Z = module[i % len(module)]
        x, X, y, Y = x + ox, X + ox, y + oy, Y + oy
        bounds.append([x, y, z, X, Y, Z])
        faces = [((X, y, z), (X, Y, Z), (X, Y, z)),
                 ((x, y, Z), (x, Y, z), (x, Y, Z)),
                 ((x, Y, z), (X, Y, Z), (x, Y, Z)),
                 ((x, y, Z), (X, y, z), (x, y, z)),
                 ((x, y, Z), (X, Y, Z), (X, y, Z)),
                 ((X, y, z), (x, Y, z), (x, y, z))]
        lines.append("{")
        for face in faces:
            lines.append(" ".join("( %d %d %d )" % p for p in face)
                         + " common/caulk 0 0 0 1 1")
        lines.append("}")
    return "\n".join(lines + ["}", ""]), {"bounds": bounds}


def stage(project, sizes):
    project.mkdir()
    # Real addon copied verbatim except build/import products. Plugins are not
    # enabled: lifecycle/editor_suite work is independently owned and not needed.
    addon = project / "addons/tbloader"
    shutil.copytree(ROOT / "addons/tbloader", addon,
                    ignore=shutil.ignore_patterns("bin", "*.uid", "*.import", ".godot"))
    (addon / "bin").mkdir()
    before = digest(LIBRARY)
    staged_library = addon / "bin" / LIBRARY.name
    shutil.copy2(LIBRARY, staged_library)
    if digest(staged_library) != before or digest(LIBRARY) != before:
        raise Failure("library changed during staging; retry after build finishes")
    shutil.copy2(HERE / "performance_suite.gd", project)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="TBLoader native performance"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
        '[audio]\ndriver/driver="Dummy"\n')
    for count in sizes:
        text, manifest = blockout(count)
        (project / f"blockout-{count}.map").write_text(text)
        write_json(project / f"blockout-{count}.json", manifest)
    return {"library_source": str(LIBRARY), "library_sha256": before,
            "inputs": {str(p.relative_to(project)): digest(p)
                       for p in sorted(project.rglob("*")) if p.is_file()}}


def x11_feasibility():
    # Load/query symbols only: never open a display or inject an event.
    result = {}
    for name, symbols in {
        "X11": ["XOpenDisplay", "XQueryTree", "XGetWindowProperty", "XTranslateCoordinates", "XSync"],
        "Xtst": ["XTestQueryExtension", "XTestFakeMotionEvent", "XTestFakeButtonEvent", "XTestFakeKeyEvent"],
    }.items():
        path = ctypes.util.find_library(name)
        entry = {"library": path}
        try:
            lib = ctypes.CDLL(path) if path else None
            entry["symbols"] = {symbol: lib is not None and hasattr(lib, symbol) for symbol in symbols}
        except OSError as error:
            entry["load_error"] = str(error)
        result[name] = entry
    result["DISPLAY_present"] = bool(os.environ.get("DISPLAY"))
    result["WAYLAND_DISPLAY_present"] = bool(os.environ.get("WAYLAND_DISPLAY"))
    return result


def environment():
    cpu = Path("/proc/cpuinfo").read_text()
    model = next((line.split(":", 1)[1].strip() for line in cpu.splitlines()
                  if line.startswith("model name")), platform.processor())
    # Record concurrent Godot sessions without interacting with them.
    peers = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            command = (entry / "cmdline").read_bytes().split(b"\0")
            if command and "godot" in Path(os.fsdecode(command[0])).name.lower():
                peers.append({"pid": int(entry.name), "argv": [os.fsdecode(p) for p in command if p]})
        except (OSError, ValueError):
            pass
    policies = {}
    for path in Path("/sys/devices/system/cpu/cpufreq").glob("policy*/scaling_governor"):
        policies[str(path)] = path.read_text().strip()
    return {"utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
            "python": sys.version, "cpu": model, "logical_cpus": os.cpu_count(),
            "affinity": sorted(os.sched_getaffinity(0)), "load_average": os.getloadavg(),
            "scaling_governors": policies, "concurrent_godot_processes": peers,
            "x11_feasibility": x11_feasibility()}


def summarize(values):
    ordered = sorted(values)
    return {"n": len(values), "min_ms": min(values) / 1000,
            "median_ms": statistics.median(values) / 1000,
            "p95_ms": ordered[math.ceil(len(values) * .95) - 1] / 1000,
            "max_ms": max(values) / 1000,
            "over_16_7_ms": sum(value > 16700 for value in values)}


def validate(report, count, args, project):
    if (report["schema"] != 1 or report["brushes"] != count or report["faces"] != count * 6
            or report["triangles"] != count * 12 or report["entities"] != 1
            or report["samples"] != args.samples or report["warmups"] != args.warmups
            or report["display_driver"] != "headless"
            or report["map_sha256"] != digest(project / f"blockout-{count}.map")
            or set(report["operations_us"]) != OPERATIONS):
        raise Failure("invalid result identity/counts/scope")
    for name, values in report["operations_us"].items():
        if len(values) != args.samples or any(not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for v in values):
            raise Failure(f"invalid timing samples: {name}")
    for counters in report["memory"].values():
        if any(counters.get(key, 0) <= 0 for key in ("VmRSS_bytes", "VmHWM_bytes", "godot_static_bytes")):
            raise Failure("missing memory counters")


def aggregate(runs):
    result = {}
    for count in sorted({run["brushes"] for run in runs}):
        group = [run for run in runs if run["brushes"] == count]
        if len({run["canonical_sha256"] for run in group}) != 1:
            raise Failure("canonical map differs across fresh processes")
        result[count] = {
            "brushes": count, "faces": count * 6, "triangles": count * 12,
            "map_sha256": group[0]["map_sha256"], "map_bytes": group[0]["map_bytes"],
            "snapshot_variant_bytes": group[0]["snapshot_variant_bytes"],
            "first_import_ms": [run["first_import_us"] / 1000 for run in group],
            "operations": {key: summarize([value for run in group for value in run["operations_us"][key]])
                           for key in sorted(OPERATIONS)},
            "memory_mib": {phase: {key: [run["memory"][phase][key] / 1048576 for run in group]
                                   for key in group[0]["memory"][phase]}
                           for phase in group[0]["memory"]},
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=ENGINE)
    parser.add_argument("--brushes", type=int, nargs="+", default=[32, 256, 512])
    parser.add_argument("--samples", type=int, default=31)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--repeats", type=int, default=2, help="fresh processes per map size")
    parser.add_argument("--timeout", type=float, default=120, help="seconds per engine process")
    parser.add_argument("--verify-failures", action="store_true", help="test zero-exit error, missing marker and timeout rejection")
    args = parser.parse_args()
    if (not math.isfinite(args.timeout) or args.timeout <= 0 or args.samples < 1 or args.warmups < 0
            or args.repeats < 1 or any(n < 8 or n > 4096 or n % 8 for n in args.brushes)
            or len(set(args.brushes)) != len(args.brushes)):
        parser.error("positive timeout/samples/repeats; nonnegative warmups; unique brush counts in 8..4096 divisible by 8")
    if not TEMP.is_dir():
        parser.error(f"approved temp directory missing: {TEMP}")
    logs = Path(tempfile.mkdtemp(prefix="tbloader-performance-", dir=TEMP))
    print(f"Artifacts: {logs}", flush=True)
    result = {"status": "FAIL", "settings": vars(args), "runs": []}
    try:
        engine = Path(args.godot).resolve()
        result["environment"] = environment()
        result["git_head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        result["git_status"] = subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True)
        result["runner_sha256"] = digest(Path(__file__))
        result["engine_sha256"] = digest(engine)
        project = logs / "project"
        result.update(stage(project, args.brushes))
        env = os.environ.copy()
        for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            directory = logs / key.lower()
            directory.mkdir()
            env[key] = str(directory)
        env["TB_PERF_PROBE"] = ""
        version = checked_execute([str(engine), "--headless", "--version"], project, env,
                                  min(args.timeout, 15), logs, "version").strip()
        result["engine_version"] = version
        if version != (HERE / "engine_version.txt").read_text().strip():
            raise Failure(f"engine version differs from repository pin: {version}")
        base = [str(engine), "--headless", "--path", str(project), "--audio-driver", "Dummy"]
        command = base + ["--script", "res://performance_suite.gd"]
        if args.verify_failures:
            result["failure_probes"] = {}
            for probe, expected in (("engine-error", "diagnostic"), ("missing-marker", "completion-marker"), ("timeout", "timeout")):
                probe_env = dict(env, TB_PERF_PROBE=probe)
                _, failures = execute(command, project, probe_env, 2 if probe == "timeout" else args.timeout,
                                      logs, f"probe-{probe}", MARKER)
                if expected not in failures or (probe != "timeout" and any(f.startswith("exit=") for f in failures)):
                    raise Failure(f"failure probe {probe} did not exercise intended rejection: {failures}")
                result["failure_probes"][probe] = failures
        for repeat in range(args.repeats):
            # Reverse order on odd repetitions to expose simple order/warmth bias.
            for count in (args.brushes if repeat % 2 == 0 else list(reversed(args.brushes))):
                name = f"native-{count}-r{repeat + 1}"
                run_env = dict(env, TB_PERF_BRUSHES=str(count), TB_PERF_SAMPLES=str(args.samples),
                               TB_PERF_WARMUPS=str(args.warmups))
                output_file = project / "performance-result.json"
                output_file.unlink(missing_ok=True)
                stdout = checked_execute(command, project, run_env, args.timeout, logs, name, MARKER)
                if stdout.splitlines().count(f"TB_PERF_COUNTS:{count}:{count * 6}:{count * 12}") != 1:
                    raise Failure(f"{name}: missing/duplicate geometry counts")
                report = json.loads(output_file.read_text())
                validate(report, count, args, project)
                report["repeat"] = repeat + 1
                report["summary"] = {key: summarize(values) for key, values in report["operations_us"].items()}
                write_json(logs / f"{name}.json", report)
                result["runs"].append(report)
                metrics = ", ".join(f"{key}={s['median_ms']:.3f}/{s['p95_ms']:.3f}"
                                    for key, s in report["summary"].items())
                rss = report["memory"]["after_operations"]["VmRSS_bytes"] / 1048576
                print(f"PASS {name}: {count} brushes/{count * 6} faces; median/p95 ms: {metrics}; RSS={rss:.2f} MiB", flush=True)
        result["summary"] = aggregate(result["runs"])
        write_json(logs / "summary.json", result["summary"])
        result["status"] = "PASS"
        print("PASS native measurement (16.7 ms reference budget; no interactive-latency claim)")
    except (Failure, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result["reason"] = str(error)
        print(f"FAIL: {error}", file=sys.stderr)
    finally:
        write_json(logs / "result.json", result)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
