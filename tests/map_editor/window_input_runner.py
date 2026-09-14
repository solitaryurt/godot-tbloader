#!/usr/bin/env python3
"""Isolated real X11/XTest Radiant journey; observer is read-only, all edits use XTest."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

import run_tests as harness
from x11_input import XTest
from performance_runner import blockout


def write_json(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def center(rect):
    return [rect[0] + rect[2] / 2, rect[1] + rect[3] / 2]


class Journey:
    def __init__(self, x, process, project, logs, timeout):
        self.x, self.process, self.project, self.logs = x, process, project, logs
        self.deadline = time.monotonic() + timeout
        self.sequence = 0
        self.checks = []
        self.timings = []
        self.states = []

    def alive(self):
        if self.process.poll() is not None:
            raise harness.GateFailure(f"Editor exited early: {self.process.returncode}")
        if time.monotonic() > self.deadline:
            raise harness.GateFailure("Window-input journey external timeout")

    def request(self, op="state", **kwargs):
        self.alive()
        self.sequence += 1
        write_json(self.project / "window-command.json", {"id": self.sequence, "op": op, **kwargs})
        if op == "finish":
            return None
        deadline = min(self.deadline, time.monotonic() + 10)
        while time.monotonic() < deadline:
            self.alive()
            path = self.project / "window-state.json"
            if path.exists():
                state = json.loads(path.read_text())
                if state.get("request") == self.sequence:
                    return state
            time.sleep(0.01)
        raise harness.GateFailure(f"Observer failed to answer {op} #{self.sequence}")

    def wait(self, label, predicate, seconds=5):
        deadline = min(self.deadline, time.monotonic() + seconds)
        state = self.request()
        while not predicate(state) and time.monotonic() < deadline:
            time.sleep(0.03)
            state = self.request()
        self.check(label, predicate(state), state)
        return state

    def check(self, label, condition, state=None):
        self.checks.append({"case": label, "pass": bool(condition)})
        if state is not None:
            self.states.append({"case": label, "state": state})
        if not condition:
            raise harness.GateFailure(label)
        print(f"PASS {label}", flush=True)

    def click(self, point, button=1, captured=False):
        self.x.move(point)
        time.sleep(0.06)
        self.x.button(button, True, captured)
        time.sleep(0.045)
        self.x.button(button, False)
        time.sleep(0.08)

    def control(self, text):
        state = self.request()
        matches = [c for c in state["controls"] if (c["text"] == text or c.get("tooltip") == text) and c["class"] in ("Button", "CheckBox", "TabBar", "ItemList")]
        if len(matches) != 1:
            raise harness.GateFailure(f"Expected one visible button {text!r}, got {len(matches)}")
        return center(matches[0]["rect"])

    def point(self, state, pane, world):
        graph = state[pane]
        axes = (1 if graph["orientation"] == 0 else 0, 1 if graph["orientation"] == 2 else 2)
        c = center(graph["rect"])
        return [c[0] + (world[axes[0]] - graph["origin"][axes[0]]) * graph["zoom"],
                c[1] - (world[axes[1]] - graph["origin"][axes[1]]) * graph["zoom"]]

    def drag(self, start, end, release=True):
        self.x.move(start)
        time.sleep(0.05)
        self.x.button(1, True)
        time.sleep(0.06)
        for i in range(1, 9):
            self.x.move([start[k] + (end[k] - start[k]) * i / 8 for k in (0, 1)])
            time.sleep(0.025)
        if release:
            began = time.monotonic_ns()
            self.x.button(1, False)
            state = self.request()
            self.timings.append({"operation": "release_to_observer", "milliseconds": (time.monotonic_ns() - began) / 1e6,
                                 "brushes": len(state["brushes"]), "faces": sum(b["faces"] for b in state["brushes"])})
            return state
        return self.request()

    def field(self, rect, text):
        self.click(center(rect))
        self.x.chord("a", "Control_L")
        self.x.type(text)

    def screenshot(self, name):
        state = self.request("screenshot", name=name)
        self.states.append({"case": "screenshot " + name, "state": state})
        self.check("rendered screenshot " + name, (self.project / "window-captures" / (name + ".png")).stat().st_size > 10000)

    def open_map(self, path):
        state = self.request()
        self.click(center(state["a"]["rect"]))
        self.x.chord("o", "Control_L")
        state = self.wait("Open resolves through picker or dirty prompt", lambda s: s["file_dialog"] or s["dirty_dialog"])
        if state["dirty_dialog"]:
            self.check("only empty untitled map discarded", not state["brushes"] and not state["path"])
            self.click(self.control("Discard"))
        state = self.wait("Open dialog displayed", lambda s: s["file_dialog"])
        # Pinned FileDialog OPEN_FILE requires a selected list item; typing the
        # filename alone leaves its Open button disabled even for an existing file.
        self.click(self.control(path.name))
        self.click(center(self.request()["file_ok_rect"]))
        return self.wait("map opened through file picker", lambda s: not s["file_dialog"] and s["path"].endswith(path.name))

    def run(self, reopen=False):
        state = self.request()
        self.x.log("coordinate_preflight", x11_origin=self.x.origin(), godot_origin=state["window_position"], pointer=self.x.pointer(self.x.root))
        self.click(self.control("Radiant"))
        state = self.wait("real Radiant main-screen button", lambda s: s["visible"])
        if reopen:
            state = self.open_map(self.project / "window-authored.map")
            expected = json.loads((self.logs / "expected.json").read_text())
            self.check("fresh-process canonical document and bounds match", state["text"] == expected["text"] and state["brushes"][0]["min"] == expected["brushes"][0]["min"] and state["brushes"][0]["max"] == expected["brushes"][0]["max"], state)
            self.check("fresh-process worldspawn property and six checker faces", '"message" "nh123 wasd"' in state["text"] and state["brushes"][0]["textures"] == ["baseline/checker"] * 6)
            self.check("fresh-process clean native document and rendered cuboid", not state["dirty"] and len(state["brushes"]) == 1 and state["triangles"] == 12)
            self.click(self.control("Frame"))
            self.screenshot("window-reopened")
            return

        self.check("new native document is empty", not state["brushes"])
        for splitter, axis, size_axis in (("quad_split", 0, 2), ("grid_split", 1, 3)):
            before = state["a"]["rect"][size_axis]
            start = center(state[splitter])
            end = start.copy()
            end[axis] += 32
            self.drag(start, end)
            state = self.wait(f"real {splitter} resize changes pane geometry", lambda s: s["a"]["rect"][size_axis] != before and not s["brushes"])
            start = center(state[splitter])
            end = start.copy()
            end[axis] -= 32
            self.drag(start, end)
            state = self.wait(f"real {splitter} resize restores pane geometry", lambda s: s["a"]["rect"][size_axis] == before and not s["brushes"])
        state = self.drag(self.point(state, "a", [-64, -48, 0]), self.point(state, "a", [64, 48, 0]))
        state = self.wait("real LMB cuboid creates and selects one brush", lambda s: len(s["brushes"]) == len(s["selected"]) == 1)
        self.check("cuboid exact bounds, six faces, eight vertices, twelve preview triangles", state["brushes"][0]["min"] == [-64, -48, -64] and state["brushes"][0]["max"] == [64, 48, 64] and state["brushes"][0]["faces"] == 6 and state["brushes"][0]["vertices"] == 8 and state["triangles"] == 12, state)
        self.check("one drag one history action", state["actions"] == 1)
        original = state["text"]
        self.x.chord("Escape")
        state = self.wait("Esc deselects", lambda s: not s["selected"])
        self.click(self.point(state, "a", [0, 0, 0]))
        state = self.wait("degenerate click selects without creation", lambda s: len(s["selected"]) == 1 and s["actions"] == 1)
        self.drag(self.point(state, "a", [0, 0, 0]), self.point(state, "a", [32, 16, 0]))
        state = self.wait("Top move exact snapped delta and hidden Z", lambda s: s["brushes"][0]["min"] == [-32, -32, -64] and s["brushes"][0]["max"] == [96, 64, 64] and s["actions"] == 2)
        moved = state["text"]
        self.x.chord("z", "Control_L")
        self.wait("real Ctrl+Z restores exact pre-move document", lambda s: s["text"] == original)
        self.x.chord("y", "Control_L")
        state = self.wait("real Ctrl+Y restores exact moved document", lambda s: s["text"] == moved)
        self.x.chord("h")
        state = self.wait("H hides and removes camera triangles without document edit", lambda s: s["hidden"] == 1 and not s["selected"] and s["triangles"] == 0 and s["text"] == moved)
        self.screenshot("window-hidden")
        self.x.chord("h", "Shift_L")
        state = self.wait("Shift+H reveals without selecting or editing", lambda s: s["hidden"] == 0 and not s["selected"] and s["triangles"] == 12 and s["text"] == moved)
        self.click(self.point(state, "a", [32, 16, 0]))
        state = self.wait("revealed brush is selectable", lambda s: len(s["selected"]) == 1)
        self.x.chord("4")
        self.wait("real grid key sets shared grid 8", lambda s: s["grid"] == 8)
        self.x.chord("5")
        self.wait("real grid key restores shared grid 16", lambda s: s["grid"] == 16)
        for pane, orientations in (("a", [1, 0, 2]), ("b", [0, 2, 1])):
            self.click(self.point(state, pane, [32, 16, 0]))
            other = "b" if pane == "a" else "a"
            fixed = self.request()[other]["orientation"]
            for orientation in orientations:
                self.x.chord("Tab", "Control_L")
                state = self.wait(f"Ctrl+Tab {pane} to {orientation}, other pane unchanged", lambda s: s[pane]["orientation"] == orientation and s[other]["orientation"] == fixed and s["text"] == moved)
                if pane == "a" and orientation in (0, 1):
                    start = self.point(state, pane, [32, 16, 0])
                    self.drag(start, [start[0] + 16, start[1] - 16])
                    minimum = [-16, -32, -48] if orientation == 1 else [-32, -16, -48]
                    maximum = [112, 64, 80] if orientation == 1 else [96, 80, 80]
                    self.wait(f"real orientation {orientation} move preserves hidden axis", lambda s: s["brushes"][0]["min"] == minimum and s["brushes"][0]["max"] == maximum)
                    self.x.chord("z", "Control_L")
                    state = self.wait(f"real orientation {orientation} move undo", lambda s: s["text"] == moved)
        # Crucially inspect the preview while LMB is still down, BEFORE focus loss.
        for pane in ("a", "b"):
            self.click(self.point(state, pane, [32, 16, 0]))
            before = self.request()
            start = self.point(before, pane, [32, 16, 0])
            preview = self.drag(start, [start[0] + 48, start[1] - 32], release=False)
            self.check(f"{pane} moved live drag exists before OS focus loss", preview[pane]["gesture"] == "move" and preview[pane]["delta"] != [0, 0, 0] and preview["text"] == before["text"], preview)
            self.x.lose_focus()
            count = len(self.x.events)
            try:
                self.x.key("h", True)
            except harness.GateFailure:
                pass
            else:
                raise harness.GateFailure("focus guard allowed a key outside staged Godot")
            self.check(f"{pane} input guard rejects non-Godot focus without injection", len(self.x.events) == count)
            state = self.wait(f"{pane} actual OS focus loss cancels held drag", lambda s: not s["window_focus"] and s[pane]["gesture"] == "" and s["text"] == before["text"] and s["revision"] == before["revision"] and s["history"] == before["history"])
            self.x.release_owned()
            self.x.activate()
            state = self.wait(f"{pane} refocus/release cannot commit cancelled preview", lambda s: s["window_focus"] and s[pane]["gesture"] == "" and s["revision"] == before["revision"] and s["history"] == before["history"] and s["text"] == before["text"])

        self.field(state["search_rect"], "nh123")
        state = self.wait("material search receives shortcut letters as text", lambda s: s["search"] == "nh123" and not s["inspector"] and s["hidden"] == 0 and s["grid"] == 16 and s["text"] == moved and not s["search_results"])
        self.field(state["search_rect"], "checker")
        state = self.wait("real material search finds both project folders", lambda s: len(s["search_results"]) == 2 and all("checker" in p for p in s["search_results"]))
        # Assign via production shader LineEdit and button, no observer mutations.
        shader = [c for c in state["controls"] if c["class"] == "LineEdit" and c["text"] == "common/caulk"]
        self.check("actual shader widget found", len(shader) == 1)
        self.field(shader[0]["rect"], "baseline/checker")
        self.click(self.control("Assign"))
        state = self.wait("real Assign button writes all six native face textures", lambda s: s["brushes"][0]["textures"] == ["baseline/checker"] * 6)
        self.click(self.control("Frame"))
        self.screenshot("window-textured")
        self.click(self.point(state, "a", [32, 16, 0]))
        self.x.chord("n")
        state = self.wait("N opens actual entity inspector", lambda s: s["inspector"])
        before_text = state["text"]
        self.field(state["key_rect"], "message")
        self.field(state["value_rect"], "nh123 wasd")
        state = self.wait("N inspector typing does not invoke graph/fly shortcuts", lambda s: s["entity_key"] == "message" and s["entity_value"] == "nh123 wasd" and s["hidden"] == 0 and s["grid"] == 16 and not s["flying"] and s["text"] == before_text)
        self.click(self.control("Set on targets"))
        state = self.wait("entity Set widget commits native worldspawn property", lambda s: '"message" "nh123 wasd"' in s["text"])
        self.screenshot("window-entity")
        # Embedded Window close affordance (single-window engine option).
        self.x.chord("Escape")
        state = self.request()
        if state["inspector"]:
            # Actual embedded titlebar close, coordinates supplied read-only.
            self.click(center(state["inspector_close_rect"]))
        state = self.wait("entity inspector closes through UI", lambda s: not s["inspector"])
        canonical = state["text"]
        self.click(self.point(state, "a", [32, 16, 0]))
        self.x.chord("z", "Control_L")
        self.wait("entity property real undo", lambda s: s["text"] == before_text)
        self.x.chord("y", "Control_L")
        state = self.wait("entity property real redo", lambda s: s["text"] == canonical)
        self.click(self.control("3D"))
        self.wait("real 3D tab hides Radiant and preserves document", lambda s: not s["visible"] and s["text"] == canonical)
        self.click(self.control("Radiant"))
        state = self.wait("real Radiant tab restores authoring document", lambda s: s["visible"] and s["text"] == canonical)

        for exit_mode in ("Escape", "RMB", "focus"):
            self.click(center(state["camera"]), 3)
            state = self.wait(f"RMB enters captured fly before {exit_mode}", lambda s: s["flying"] and s["mouse_mode"] == 2)
            initial_position = state["camera_position"]
            self.x.key("w", True)
            time.sleep(0.15)
            state = self.wait(f"real W moves camera before {exit_mode}", lambda s: s["camera_position"] != initial_position)
            if exit_mode == "focus":
                self.x.lose_focus()
                state = self.wait("OS focus loss releases fly and clears held W", lambda s: not s["window_focus"] and not s["flying"] and s["mouse_mode"] == 0 and not s["held"])
                stopped = state["camera_position"]
                self.x.release_owned()
                self.x.activate()
                time.sleep(0.2)
                state = self.request()
                self.check("no stuck fly movement after OS refocus", state["camera_position"] == stopped)
            else:
                self.x.key("w", False)
                if exit_mode == "Escape":
                    self.x.chord("Escape")
                else:
                    self.x.button(3, True, captured=True)
                    self.x.button(3, False)
                state = self.wait(f"{exit_mode} releases captured fly", lambda s: not s["flying"] and s["mouse_mode"] == 0 and not s["held"])

        self.x.chord("s", "Control_L", "Shift_L")
        state = self.wait("Save As dialog is real and visible", lambda s: s["file_dialog"])
        path = self.project / "window-authored.map"
        self.field(state["file_name_rect"], str(path))
        self.click(center(self.request()["file_ok_rect"]))
        state = self.wait("Save As writes canonical map and clears dirty", lambda s: not s["file_dialog"] and s["path"].endswith(path.name) and not s["dirty"])
        self.check("disk map exactly matches real native document", path.read_text() == canonical == state["text"], state)
        write_json(self.logs / "expected.json", state)
        self.click(center(state["a"]["rect"]))
        self.x.chord("n", "Control_L")
        self.wait("Ctrl+N replaces saved document with empty worldspawn", lambda s: not s["brushes"] and not s["path"])
        state = self.open_map(path)
        self.check("same-process reopen exact document and bounds", state["text"] == canonical and state["brushes"][0]["min"] == [-32, -32, -64] and state["brushes"][0]["max"] == [96, 64, 64], state)
        self.click(self.control("Frame"))
        self.screenshot("window-saved")

    def performance(self, samples):
        """Observation-inclusive timings, not hardware/presentation latency."""
        for count in (32, 256):
            state = self.open_map(self.project / f"blockout-{count}.map")
            self.check(f"displayed blockout {count} native/preview counts", len(state["brushes"]) == count and sum(b["faces"] for b in state["brushes"]) == count * 6 and state["triangles"] == count * 12)
            self.click(self.point(state, "a", [128, 96, 0]))
            state = self.wait(f"blockout {count} real click selects floor", lambda s: len(s["selected"]) == 1 and s["brushes"][0]["id"] in s["selected"])
            canonical = state["text"]
            self.request("measure", name=f"{count}-drag-undo-redo")
            memory = []
            for sample in range(samples):
                before = state
                start = self.point(state, "a", [128, 96, 0])
                self.x.move(start)
                self.x.button(1, True)
                began = time.monotonic_ns()
                state = self.wait(f"perf {count}/{sample} begin", lambda s: s["a"]["gesture"] == "move")
                self.timings.append({"operation": "begin_to_observer", "brushes": count, "milliseconds": (time.monotonic_ns() - began) / 1e6})
                for offset in (16, 32, 48):
                    began = time.monotonic_ns()
                    self.x.move([start[0] + offset, start[1]])
                    state = self.wait(f"perf {count}/{sample} motion {offset}", lambda s: s["a"]["delta"] == [offset, 0, 0] and s["text"] == canonical)
                    self.timings.append({"operation": "motion_to_observer", "brushes": count, "milliseconds": (time.monotonic_ns() - began) / 1e6})
                began = time.monotonic_ns()
                self.x.button(1, False)
                state = self.wait(f"perf {count}/{sample} release", lambda s: s["brushes"][0]["min"] == [48, 0, -16] and s["brushes"][0]["max"] == [432, 384, 0] and s["revision"] > before["revision"] and s["a"]["gesture"] == "")
                self.timings.append({"operation": "release_to_observer", "brushes": count, "milliseconds": (time.monotonic_ns() - began) / 1e6})
                moved = state["text"]
                for key, expected, operation in (("z", canonical, "undo"), ("y", moved, "redo"), ("z", canonical, "reset_undo")):
                    began = time.monotonic_ns()
                    self.x.chord(key, "Control_L")
                    state = self.wait(f"perf {count}/{sample} {operation}", lambda s: s["text"] == expected)
                    self.timings.append({"operation": operation + "_to_observer", "brushes": count, "milliseconds": (time.monotonic_ns() - began) / 1e6})
                memory.append({"sample": sample, "proc_status": Path(f"/proc/{self.process.pid}/status").read_text()})
            self.request("measure", name="")
            write_json(self.logs / f"memory-{count}.json", memory)
            self.check(f"blockout {count} returns exactly to saved baseline", state["text"] == canonical and not state["dirty"])
            self.click(self.control("Frame"))
            self.screenshot(f"window-blockout-{count}")
        self.open_map(self.project / "window-authored.map")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=harness.DEFAULT_ENGINE)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--samples", type=int, default=8, help="observed gesture samples for each 32/256-brush fixture")
    args = parser.parse_args()
    if args.timeout <= 0 or args.samples < 1:
        parser.error("--timeout and --samples must be positive")
    artifacts = harness.HERE / "artifacts"
    artifacts.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="window-input-", dir=artifacts))
    project = logs / "project"
    print(f"Artifacts: {logs}", flush=True)
    result = {"status": "FAIL", "suite": "window_input", "checks": [], "processes": []}
    x, process, journey = None, None, None
    lock = None
    try:
        lock = Path("/tmp/opencode/tbloader-window-input.lock").open("w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise harness.GateFailure("Another window_input runner owns the display test lock")
        if not os.environ.get("DISPLAY"):
            raise harness.GateFailure("DISPLAY required; no headless or handler fallback")
        x = XTest()
        result["xtest_version"] = x.version
        result["original_focus"] = x.original_focus
        result["original_pointer"] = x.original_pointer
        result["original_desktop"] = x.desktop
        result["source_head"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=harness.ROOT, text=True).strip()
        result["source_status"] = subprocess.check_output(["git", "status", "--short"], cwd=harness.ROOT, text=True)
        result["runner_sha256"] = {name: harness.sha256(harness.HERE / name) for name in ("window_input_runner.py", "x11_input.py", "run_tests.py", "performance_runner.py")}
        result["samples_per_fixture"] = args.samples
        engine = str(Path(args.godot).resolve())
        result["engine_sha256"] = harness.sha256(Path(engine))
        result.update(harness.stage(project))
        (project / "window-captures").mkdir()
        (project / "window-captures/.gdignore").touch()
        for count in (32, 256):
            text, manifest = blockout(count)
            (project / f"blockout-{count}.map").write_text(text)
            write_json(project / f"blockout-{count}.json", manifest)
        target = project / "addons/map_editor_tests"
        shutil.copy2(harness.HERE / "window_input_observer.gd", target)
        plugin = target / "plugin.cfg"
        plugin.write_text(plugin.read_text().replace('script="editor_suite.gd"', 'script="window_input_observer.gd"'))
        config = project / "project.godot"
        config.write_text(config.read_text().replace("TBLoader Phase 0 tests", "TBLoader XTest isolated acceptance"))
        # Import retains the existing strict suite; observer is activated afterwards.
        env = os.environ.copy()
        env["TB_TEST_SUITE"], env["TB_TEST_PROBE"] = "import", ""
        for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
            location = logs / key.lower()
            location.mkdir()
            env[key] = str(location)
        version = harness.execute([engine, "--headless", "--version"], project, env, 15, logs, "version").strip()
        if version != (harness.HERE / "engine_version.txt").read_text().strip():
            raise harness.GateFailure("Engine differs from pin")
        result["version"] = version
        # Use existing import plugin, then install our read-only observer.
        original_cfg = (harness.HERE / "plugin.cfg").read_text()
        plugin.write_text(original_cfg)
        base = [engine, "--path", str(project), "--audio-driver", "Dummy"]
        harness.execute(base + ["--headless", "--editor"], project, env, args.timeout, logs, "import", "TB_TEST_COMPLETE:import:PASS")
        plugin.write_text(original_cfg.replace('script="editor_suite.gd"', 'script="window_input_observer.gd"'))
        result["inputs"] = {str(p.relative_to(project)): harness.sha256(p) for p in sorted(project.rglob("*")) if p.is_file() and ".godot" not in p.relative_to(project).parts}
        if harness.sha256(project / "addons/tbloader/bin/libtbloader.linux.template_debug.x86_64.so") != result["library_sha256"]:
            raise harness.GateFailure("Staged library hash differs")
        env["TB_TEST_SUITE"] = "window_input"
        for phase in ("input", "reopen"):
            for name in ("window-ready.json", "window-state.json", "window-command.json"):
                (project / name).unlink(missing_ok=True)
            command = base + ["--editor", "--display-driver", "x11", "--rendering-method", "gl_compatibility", "--single-window", "--windowed", "--resolution", "1600x1100"]
            began = time.monotonic()
            record = {"command": command, "exit_code": None, "phase": phase}
            result["processes"].append(record)
            write_json(logs / f"{phase}.process.json", record)
            with (logs / f"{phase}.stdout.log").open("w") as out, (logs / f"{phase}.stderr.log").open("w") as err:
                process = subprocess.Popen(command, cwd=project, env=env, stdout=out, stderr=err, start_new_session=True)
                journey = Journey(x, process, project, logs, args.timeout)
                while not (project / "window-ready.json").exists():
                    journey.alive()
                    time.sleep(0.1)
                x.locate(process.pid)
                x.activate()
                journey.run(reopen=phase == "reopen")
                if phase == "input":
                    journey.performance(args.samples)
                journey.request("finish", checks=len(journey.checks))
                process.wait(timeout=max(1, journey.deadline - time.monotonic()))
            stdout = harness.ANSI.sub("", (logs / f"{phase}.stdout.log").read_text())
            stderr = (logs / f"{phase}.stderr.log").read_text()
            record.update(exit_code=process.returncode, seconds=time.monotonic() - began)
            write_json(logs / f"{phase}.process.json", record)
            if process.returncode or stderr.strip() or harness.ERROR.search(stdout + stderr) or stdout.splitlines().count("TB_TEST_COMPLETE:window_input:PASS") != 1 or stdout.splitlines().count(f"TB_TEST_COUNTS:window_input:{len(journey.checks)}:0") != 1:
                raise harness.GateFailure(f"{phase}: strict engine completion/diagnostic protocol failed")
            result["checks"].extend(journey.checks)
            write_json(logs / f"{phase}-states.json", journey.states)
            write_json(logs / f"{phase}-timings.json", journey.timings)
            shutil.copy2(project / "window-metrics.json", logs / f"{phase}-metrics.json")
            if phase == "input":
                summary = {}
                for item in journey.timings:
                    label = f"{item['brushes']}-{item['operation']}"
                    summary.setdefault(label, []).append(item["milliseconds"])
                metrics = json.loads((project / "window-metrics.json").read_text())
                for label, intervals in metrics["measurements"].items():
                    summary[label + "-frame_callback_intervals"] = [n / 1000 for n in intervals]
                write_json(logs / "latency-summary.json", {label: {
                    "samples": len(values), "median_ms": statistics.median(values),
                    "p95_ms": sorted(values)[math.ceil(len(values) * .95) - 1], "max_ms": max(values),
                    "above_16_7_ms": sum(v > 16.7 for v in values),
                } for label, values in summary.items() if values})
        result["status"] = "PASS"
    except (harness.GateFailure, OSError, subprocess.TimeoutExpired, KeyError, IndexError) as error:
        result["reason"] = str(error)
        print(f"FAIL window_input: {error}; {logs}", flush=True)
        if journey:
            result["checks"].extend(journey.checks)
            write_json(logs / "failure-states.json", journey.states)
    finally:
        if x:
            if x.keys or x.buttons:
                x.release_owned()
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if result["processes"] and process:
            record = result["processes"][-1]
            record["exit_code"] = process.returncode
            write_json(logs / f"{record['phase']}.process.json", record)
        if x:
            try:
                x.close()
            except (OSError, subprocess.CalledProcessError) as error:
                result.update(status="FAIL", reason=f"Desktop restoration failed: {error}")
            write_json(logs / "x11-events.json", x.events)
        write_json(logs / "result.json", result)
        if lock:
            lock.close()
    print(f"{result['status']} window_input: {len(result['checks'])} checks; {logs}", flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
