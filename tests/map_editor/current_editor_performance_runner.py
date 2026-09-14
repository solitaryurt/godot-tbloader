#!/usr/bin/env python3
"""Reproducible CURRENT Map editor baseline for fixtures/tohunga.map."""

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

import run_tests as harness


MARKER = "TB_CURRENT_EDITOR_PERF_COMPLETE:PASS"
COUNTS = re.compile(r"^TB_CURRENT_EDITOR_PERF_COUNTS:(\d+):(\d+):(\d+):(\d+)$", re.MULTILINE)
FIXTURE_SHA256 = "1e9d250d26267ebda5ff52978ebacca23e37a686865fe47f950b0109e7ca8811"
MIB = 1024 * 1024
ABSOLUTE_BUDGETS = {
    "load_native_document_ms": 350,
    "populate_production_session_caches_ms": 175,
    "attach_session_and_initial_camera_rebuild_ms": 400,
    "set_texture_sizes_uv_only_ms": 100,
    "move_connected_session_translation_ms": 5,
    "selection_layer_queue_to_frame_post_draw_ms": 10,
    "camera_marker_queue_to_frame_post_draw_ms": 10,
    "grid_redraw_queue_to_frame_post_draw_ms": 100,
    "local_mutation_and_preview_array_max_ms": 10,
    "memento_undo_redo_p95_ms": 1,
    "full_visible_rss_growth_mib": 450,
    "full_visible_godot_static_growth_mib": 375,
}
LOCAL_ARRAY_TIMINGS = (
    "native_preview_translate_one_brush", "native_preview_rotate_one_brush",
    "native_preview_translate_face_component", "native_rotate_one_brush_local",
    "native_translate_one_face_local", "native_texture_one_face_local",
    "native_uv_one_face_local", "native_atomic_two_face_local",
    "native_move_face_component_local",
)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def environment():
    cpu = Path("/proc/cpuinfo").read_text()
    model = next((line.split(":", 1)[1].strip() for line in cpu.splitlines()
                  if line.startswith("model name")), platform.processor())
    return {
        "utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "cpu": model,
        "logical_cpus": os.cpu_count(),
        "affinity": sorted(os.sched_getaffinity(0)),
        "load_average": os.getloadavg(),
        "display": os.environ.get("DISPLAY", ""),
        "wayland_display": os.environ.get("WAYLAND_DISPLAY", ""),
    }


def summary(values):
    ordered = sorted(values)
    return {
        "n": len(values), "min_ms": min(values) / 1000,
        "median_ms": statistics.median(values) / 1000,
        "p95_ms": ordered[math.ceil(len(values) * 0.95) - 1] / 1000,
        "max_ms": max(values) / 1000,
    }


def validate(report, samples):
    if (report.get("schema") != 2 or report.get("scope") != "current_editor_tohunga"
            or report.get("fixture_sha256") != FIXTURE_SHA256 or report.get("samples") != samples):
        raise harness.GateFailure("invalid result identity or settings")
    expected = ["empty_editor", "loaded_native_document", "populated_production_caches",
                "full_visible_grids_camera_after_render_sync"]
    if report.get("checkpoint_order") != expected or set(report.get("checkpoints", {})) != set(expected):
        raise harness.GateFailure("missing or reordered isolated checkpoints")
    for checkpoint in report["checkpoints"].values():
        memory = checkpoint.get("memory", {})
        if any(memory.get(key, 0) <= 0 for key in ("VmRSS_bytes", "VmHWM_bytes", "godot_static_bytes")):
            raise harness.GateFailure("missing positive memory counter")
    counts = report["checkpoints"]["full_visible_grids_camera_after_render_sync"]["counts"]
    if (counts.get("brushes", 0) <= 100 or counts.get("faces", 0) <= 0
            or counts.get("preview_triangles", 0) <= 0
            or counts.get("camera_triangles") != counts.get("preview_triangles")
            or counts.get("visible_graphs") != 2 or counts.get("visible_camera") != 1):
        raise harness.GateFailure("invalid final editor counts")
    candidates = report.get("graph_hit_candidates", {})
    if (candidates.get("hit", {}).get("count", 0) <= 0
            or candidates.get("hit", {}).get("result", 0) <= 0
            or candidates.get("miss") != {"count": 0, "result": 0}):
        raise harness.GateFailure("invalid representative graph hit candidate metrics")
    compatibility = report.get("compatibility_preview", {})
    if (compatibility.get("groups", 0) <= 0
            or compatibility.get("triangles") != counts.get("preview_triangles")
            or compatibility.get("vertices", 0) <= 0):
        raise harness.GateFailure("invalid compatibility preview measurement")
    draw_delta = report.get("draw_delta_counters", {})
    if (draw_delta.get("touched_draw_entries", 0) <= 0
            or draw_delta.get("full_draw_resets", -1) < 0
            or draw_delta.get("full_cache_duplicates") != 0
            or draw_delta.get("history_cache_retained_bytes") != 0):
        raise harness.GateFailure("invalid draw delta counters")
    texture_sizes = report.get("set_texture_sizes_counters", {})
    if (texture_sizes.get("compact_full_builds") != 0
            or texture_sizes.get("compact_uv_updates", 0) <= 0
            or texture_sizes.get("compact_uv_copy_bytes", 0) <= 0
            or texture_sizes.get("brush_builds") != 0):
        raise harness.GateFailure("invalid texture-size UV-only counters")
    texture_memory = report.get("set_texture_sizes_memory", {})
    if any(not isinstance(texture_memory.get(key), int)
           for key in ("delta_VmRSS_bytes", "delta_godot_static_bytes")):
        raise harness.GateFailure("missing texture-size memory deltas")
    texture_draw = report.get("set_texture_sizes_draw_counters", {})
    if (texture_draw.get("full_draw_resets") != 0 or texture_draw.get("full_draw_reads") != 0
            or texture_draw.get("preview_uv_cache_retentions") != 1):
        raise harness.GateFailure("texture-size update invalidated the session draw cache")
    local_history = report.get("local_history", {})
    if (local_history.get("retained_bytes_per_action", 0) <= 0
            or local_history.get("changed_brushes") != 1
            or local_history.get("restore_touched_brushes") != 1
            or local_history.get("restore_full_resets") != 0):
        raise harness.GateFailure("invalid local object-history counters")
    for name, values in report["timings_us"].items():
        values = values if isinstance(values, list) else [values]
        if not values or any(not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0
                             for value in values):
            raise harness.GateFailure(f"invalid timing: {name}")

    timings = report["timings_us"]
    measured = {}
    scalar_budgets = {
        "load_native_document": "load_native_document_ms",
        "populate_production_session_caches": "populate_production_session_caches_ms",
        "attach_session_and_initial_camera_rebuild": "attach_session_and_initial_camera_rebuild_ms",
        "set_texture_sizes_uv_only": "set_texture_sizes_uv_only_ms",
        "move_connected_session_translation": "move_connected_session_translation_ms",
        "selection_layer_queue_to_frame_post_draw": "selection_layer_queue_to_frame_post_draw_ms",
        "camera_marker_queue_to_frame_post_draw": "camera_marker_queue_to_frame_post_draw_ms",
        "grid_redraw_queue_to_frame_post_draw": "grid_redraw_queue_to_frame_post_draw_ms",
    }
    for timing_name, budget_name in scalar_budgets.items():
        measured[budget_name] = timings[timing_name] / 1000
    measured["local_mutation_and_preview_array_max_ms"] = max(
        max(timings[name]) for name in LOCAL_ARRAY_TIMINGS) / 1000
    memento_values = (timings["apply_document_change_undo_local"],
                       timings["apply_document_change_redo_local"])
    measured["memento_undo_redo_p95_ms"] = max(
        sorted(values)[math.ceil(len(values) * .95) - 1] for values in memento_values) / 1000
    empty = report["checkpoints"]["empty_editor"]["memory"]
    final = report["checkpoints"]["full_visible_grids_camera_after_render_sync"]["memory"]
    measured["full_visible_rss_growth_mib"] = (final["VmRSS_bytes"] - empty["VmRSS_bytes"]) / MIB
    measured["full_visible_godot_static_growth_mib"] = (
        final["godot_static_bytes"] - empty["godot_static_bytes"]) / MIB
    report["regression_budgets"] = {name: {"measured": measured[name], "limit": limit}
                                    for name, limit in ABSOLUTE_BUDGETS.items()}
    exceeded = [f"{name}={measured[name]:.3f} > {limit}"
                for name, limit in ABSOLUTE_BUDGETS.items() if measured[name] > limit]
    if exceeded:
        raise harness.GateFailure("absolute regression budget exceeded: " + "; ".join(exceeded))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", harness.DEFAULT_ENGINE))
    parser.add_argument("--samples", type=int, default=31)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--display-driver", choices=("headless", "x11"), default="headless")
    parser.add_argument("--skip-build", action="store_true", help="use the existing debug extension without running scons")
    args = parser.parse_args()
    if args.samples < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--samples and --timeout must be positive")
    if args.display_driver == "x11" and not os.environ.get("DISPLAY"):
        parser.error("--display-driver x11 requires DISPLAY")

    artifacts = harness.HERE / "artifacts"
    artifacts.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="current-editor-performance-", dir=artifacts))
    project = logs / "project"
    print(f"Artifacts: {logs}", flush=True)
    result = {"status": "FAIL", "settings": vars(args), "environment": environment()}
    try:
        engine = Path(args.godot).expanduser().resolve()
        if not engine.is_file() or not os.access(engine, os.X_OK):
            raise harness.GateFailure(f"Godot executable unavailable: {engine}")
        result["git_head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=harness.ROOT, text=True).strip()
        result["git_status"] = subprocess.check_output(["git", "status", "--short"], cwd=harness.ROOT, text=True)
        result["engine"] = str(engine)
        result["engine_sha256"] = harness.sha256(engine)
        if not args.skip_build:
            build = subprocess.run(
                ["scons", "platform=linux", "target=template_debug", "arch=x86_64", "-j2"],
                cwd=harness.ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=args.timeout,
            )
            (logs / "build.log").write_text(build.stdout)
            if build.returncode:
                raise harness.GateFailure(f"debug extension build failed with status {build.returncode}")
        result["runner_sha256"] = {
            name: harness.sha256(harness.HERE / name)
            for name in ("current_editor_performance_runner.py", "current_editor_performance_probe.gd", "run_tests.py")
        }
        result.update(harness.stage(project))
        env = os.environ.copy()
        env["TB_TEST_SUITE"], env["TB_TEST_PROBE"] = "import", ""
        for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            location = logs / key.lower()
            location.mkdir()
            env[key] = str(location)
        version = harness.execute([str(engine), "--headless", "--version"], project, env,
                                  min(args.timeout, 15), logs, "version").strip()
        expected_version = (harness.HERE / "engine_version.txt").read_text().strip()
        if version != expected_version:
            raise harness.GateFailure(f"engine version {version!r} differs from pin {expected_version!r}")
        result["version"] = version
        base = [str(engine), "--path", str(project), "--audio-driver", "Dummy"]
        harness.execute(base + ["--headless", "--editor"], project, env, args.timeout, logs,
                        "import", "TB_TEST_COMPLETE:import:PASS")
        target = project / "addons/map_editor_tests"
        shutil.copy2(harness.HERE / "current_editor_performance_probe.gd", target)
        plugin = target / "plugin.cfg"
        plugin.write_text(plugin.read_text().replace('script="editor_suite.gd"',
                                                     'script="current_editor_performance_probe.gd"'))
        result["inputs"] = {
            str(path.relative_to(project)): harness.sha256(path)
            for path in sorted(project.rglob("*"))
            if path.is_file() and ".godot" not in path.relative_to(project).parts
        }
        staged_library = project / "addons/tbloader/bin/libtbloader.linux.template_debug.x86_64.so"
        if harness.sha256(staged_library) != result["library_sha256"]:
            raise harness.GateFailure("staged debug library hash differs")
        env["TB_TEST_SUITE"] = "current_editor_performance"
        env["TB_CURRENT_EDITOR_PERF_SAMPLES"] = str(args.samples)
        command = base + ["--editor", "--resolution", "1600x1100"]
        if args.display_driver == "headless":
            command.append("--headless")
        else:
            command += ["--display-driver", "x11", "--rendering-method", "gl_compatibility",
                        "--single-window", "--windowed"]
        output = harness.execute(command, project, env, args.timeout, logs,
                                 "current-editor-performance", MARKER)
        matches = COUNTS.findall(output)
        if len(matches) != 1 or any(int(value) <= 0 for value in matches[0]):
            raise harness.GateFailure("missing, duplicate, or invalid completion counts")
        report_path = project / "current-editor-performance-result.json"
        if not report_path.is_file():
            raise harness.GateFailure("probe result file missing")
        report = json.loads(report_path.read_text())
        validate(report, args.samples)
        shutil.copy2(report_path, logs)
        report["timing_summary_ms"] = {
            name: summary(values) for name, values in report["timings_us"].items()
            if isinstance(values, list)
        }
        write_json(logs / "current-editor-performance-result.json", report)
        result["report"] = report
        result["status"] = "PASS"
        final = report["checkpoints"]["full_visible_grids_camera_after_render_sync"]
        counts = final["counts"]
        rss = final["memory"]["VmRSS_bytes"] / 1048576
        print(f"PASS current editor: {counts['brushes']} brushes, {counts['faces']} faces, "
              f"{counts['preview_triangles']} triangles; final RSS={rss:.2f} MiB", flush=True)
    except (harness.GateFailure, OSError, ValueError, KeyError, TypeError,
            subprocess.SubprocessError) as error:
        result["reason"] = str(error)
        print(f"FAIL current editor performance: {error}", file=os.sys.stderr, flush=True)
    finally:
        write_json(logs / "result.json", result)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
