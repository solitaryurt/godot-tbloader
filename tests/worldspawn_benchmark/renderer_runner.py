#!/usr/bin/env python3
"""Run displayed worldspawn renderer benchmarks in isolated Godot processes."""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "map_editor"))
import run_tests as harness
from generate_fixtures import generate


HERE = Path(__file__).resolve().parent
MARKER = "TB_WORLDSPAWN_RENDER_BENCH_COMPLETE:PASS"
PROFILES = {
    "legacy": {"enabled": False, "extent": 24.0, "max_chunks": 512, "target_chunks": 1},
    "chunks_50": {"enabled": True, "extent": 32.0, "max_chunks": 50, "target_chunks": 50},
    "chunks_200": {"enabled": True, "extent": 16.0, "max_chunks": 200, "target_chunks": 200},
    "chunks_500": {"enabled": True, "extent": 6.0, "max_chunks": 500, "target_chunks": 500},
    "chunks_1000": {"enabled": True, "extent": 3.0, "max_chunks": 1000, "target_chunks": 1000},
    "provisional_default": {"enabled": True, "extent": 24.0, "max_chunks": 512,
                            "target_chunks": None, "triangles": 15000},
}
MATRIX_PROFILES = ("legacy", "chunks_50", "chunks_200", "chunks_500", "chunks_1000")


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1]


def summarize(values):
    return {"n": len(values), "median": statistics.median(values), "p95": percentile(values, .95)}


def summarize_report(report):
    report["bake_summary_ms"] = {key: summarize(values) for key, values in report["bake_samples"].items()}
    gpu_available = any(value > 0 for view in report["views"].values() for value in view["samples"]["render_gpu_ms"])
    report["gpu_timing"] = {"available": gpu_available,
                            "reason": None if gpu_available else "viewport GPU timestamp measurements returned zero"}
    for view in report["views"].values():
        view["summary"] = {}
        for key, values in view["samples"].items():
            view["summary"][key] = summarize(values) if key != "render_gpu_ms" or gpu_available else None


def refresh_cap_diagnostic(report):
    controls = report.get("controls", {})
    refresh = float(controls.get("screen_refresh_hz", 0.0))
    if refresh < 20.0:
        return None
    interval = 1000.0 / refresh
    tolerance = max(0.15, interval * 0.03)
    for name, view in report.get("views", {}).items():
        values = view.get("samples", {}).get("frame_ms", [])
        if not values:
            continue
        close = sum(abs(value - interval) <= tolerance for value in values) / len(values)
        median = statistics.median(values)
        if close >= 0.8 and abs(median - interval) <= tolerance:
            return {"view": name, "refresh_hz": refresh, "refresh_interval_ms": interval,
                    "median_ms": median, "fraction_near_refresh": close, "tolerance_ms": tolerance}
    return None


def validate_acceptance_controls(report):
    controls = report.get("controls", {})
    required = (controls.get("requested_max_fps") == 0 and controls.get("effective_max_fps") == 0
                and controls.get("project_vsync_mode") == 0 and controls.get("requested_vsync_mode") == 0
                and controls.get("effective_vsync_mode") == 0 and controls.get("project_occlusion_culling") is True
                and controls.get("root_viewport_occlusion_culling") is True
                and controls.get("occluded_gate_context_valid") is True
                and controls.get("occlusion_effect_probe", {}).get("effect_observed") is True)
    if not required:
        raise harness.GateFailure("benchmark controls could not be verified: " + json.dumps(controls, sort_keys=True))
    cap = refresh_cap_diagnostic(report)
    report["refresh_cap_sanity"] = {"passed": cap is None, "diagnostic": cap}
    if cap is not None:
        raise harness.GateFailure("frame samples remain obviously refresh-capped: " + json.dumps(cap, sort_keys=True))


def environment():
    cpu = Path("/proc/cpuinfo").read_text(errors="replace")
    memory = Path("/proc/meminfo").read_text(errors="replace")
    model = next((line.split(":", 1)[1].strip() for line in cpu.splitlines() if line.startswith("model name")), platform.processor())
    total_kib = next((int(line.split()[1]) for line in memory.splitlines() if line.startswith("MemTotal:")), 0)
    return {"utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(), "cpu": model,
            "logical_cpus": os.cpu_count(), "memory_bytes": total_kib * 1024, "load_average": os.getloadavg(),
            "display": os.environ.get("DISPLAY", ""),
            "wayland_display": os.environ.get("WAYLAND_DISPLAY", "")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", harness.DEFAULT_ENGINE))
    parser.add_argument("--samples", type=int, default=240)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--bake-samples", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--display-driver", choices=("x11", "wayland"), default="x11")
    parser.add_argument("--fixtures", nargs="+", choices=("indoor", "mixed", "open"), default=["indoor", "mixed", "open"])
    parser.add_argument("--profiles", nargs="+", choices=tuple(PROFILES), default=list(MATRIX_PROFILES))
    parser.add_argument("--include-provisional-default", action="store_true",
                        help="append one ancillary provisional-default run per selected fixture")
    parser.add_argument("--exploratory-unpinned", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--preflight", action="store_true", help="run one tiny displayed case while preserving all context checks")
    args = parser.parse_args()
    if args.samples <= 0 or args.warmup < 0 or args.bake_samples <= 0 or args.timeout <= 0:
        parser.error("sample counts and timeout must be positive")
    display_variable = "DISPLAY" if args.display_driver == "x11" else "WAYLAND_DISPLAY"
    if not os.environ.get(display_variable):
        parser.error(f"--display-driver {args.display_driver} requires {display_variable}; no headless fallback")
    if args.preflight:
        args.samples, args.warmup, args.bake_samples = 60, 30, 1
        args.fixtures, args.profiles = ["indoor"], ["legacy"]

    artifacts = harness.HERE / "artifacts"
    artifacts.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="worldspawn-renderer-", dir=artifacts))
    project = logs / "project"
    print(f"Artifacts: {logs}", flush=True)
    result = {"schema": 1, "status": "FAIL", "acceptance_eligible": False,
              "exploratory_unpinned": args.exploratory_unpinned, "settings": vars(args), "environment": environment(), "runs": []}
    try:
        engine = Path(args.godot).expanduser().resolve()
        if not engine.is_file() or not os.access(engine, os.X_OK):
            raise harness.GateFailure(f"Godot executable unavailable: {engine}")
        env = os.environ.copy()
        for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            location = logs / key.lower()
            location.mkdir()
            env[key] = str(location)
        version = harness.execute([str(engine), "--headless", "--version"], harness.ROOT, env,
                                  min(args.timeout, 15), logs, "version").strip()
        expected = (harness.HERE / "engine_version.txt").read_text().strip()
        if version != expected and not args.exploratory_unpinned:
            raise harness.GateFailure(f"engine version {version!r} differs from pin {expected!r}; use --exploratory-unpinned only for labeled non-gating data")
        result.update({"engine": str(engine), "engine_sha256": harness.sha256(engine), "version": version,
                       "expected_version": expected, "acceptance_eligible": version == expected})
        result["git_head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=harness.ROOT, text=True).strip()
        result["git_status"] = subprocess.check_output(["git", "status", "--short"], cwd=harness.ROOT, text=True)
        if not args.skip_build:
            build = subprocess.run(["scons", "platform=linux", "target=template_debug", "arch=x86_64", "-j2"],
                                   cwd=harness.ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=args.timeout)
            (logs / "build.log").write_text(build.stdout)
            if build.returncode:
                raise harness.GateFailure(f"debug extension build failed with status {build.returncode}")
        result.update(harness.stage(project))
        project_settings = project / "project.godot"
        project_text = project_settings.read_text()
        project_text = project_text.replace(
            'renderer/rendering_method="gl_compatibility"',
            'renderer/rendering_method="gl_compatibility"\nocclusion_culling/use_occlusion_culling=true')
        project_text += "\n[display]\nwindow/vsync/vsync_mode=0\n"
        project_settings.write_text(project_text)
        generate(project / "fixtures")
        harness.write_checker(project / "textures/benchmark/grid.png")
        shutil.copy2(HERE / "renderer_probe.gd", project)
        result["fixture_manifest"] = json.loads((project / "fixtures/manifest.json").read_text())
        base = [str(engine), "--path", str(project), "--audio-driver", "Dummy"]
        env["TB_TEST_SUITE"], env["TB_TEST_PROBE"] = "import", ""
        harness.execute(base + ["--headless", "--editor"], project, env, args.timeout, logs, "import", "TB_TEST_COMPLETE:import:PASS")
        profiles = list(args.profiles)
        if args.include_provisional_default and "provisional_default" not in profiles:
            profiles.append("provisional_default")
        for fixture in args.fixtures:
            for profile_name in profiles:
                profile = dict(PROFILES[profile_name])
                profile.setdefault("triangles", 1000000000)
                env.update({"TB_BENCH_FIXTURE": fixture, "TB_BENCH_PROFILE": profile_name,
                            "TB_BENCH_PROFILE_JSON": json.dumps(profile), "TB_BENCH_SAMPLES": str(args.samples),
                            "TB_BENCH_WARMUP": str(args.warmup), "TB_BENCH_BAKE_SAMPLES": str(args.bake_samples)})
                command = base + ["--display-driver", args.display_driver, "--rendering-method", "gl_compatibility",
                                  "--resolution", "1280x720", "--windowed", "--script", "res://renderer_probe.gd"]
                name = f"{fixture}-{profile_name}"
                harness.execute(command, project, env, args.timeout, logs, name, MARKER)
                report_path = project / "worldspawn-render-result.json"
                report = json.loads(report_path.read_text())
                if report.get("fixture") != fixture or report.get("profile") != profile_name:
                    raise harness.GateFailure(f"{name}: result identity mismatch")
                summarize_report(report)
                validate_acceptance_controls(report)
                (logs / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
                result["runs"].append(report)
        result["status"] = "PASS"
        label = "acceptance-eligible" if result["acceptance_eligible"] else "EXPLORATORY UNPINNED"
        print(f"PASS worldspawn renderer ({label}): {len(result['runs'])} runs", flush=True)
    except (harness.GateFailure, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result["reason"] = str(error)
        print(f"FAIL worldspawn renderer: {error}", file=sys.stderr, flush=True)
    finally:
        (logs / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
