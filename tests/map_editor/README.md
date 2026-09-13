# Map editor baseline harness

Run from the repository root with Python **3.11+**, SCons and a C++ compiler.
The engine is pinned in `engine_version.txt`; a different version is a failure.

```bash
export GODOT_BIN=/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64
timeout 900s scons platform=linux target=template_debug arch=x86_64 -j2
python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite document
python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite editor
python -m unittest discover -s tests/map_editor -p test_harness.py -v
# Existing local X11/Xwayland display; no installation or system changes needed:
DISPLAY=:0 python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite ui
```

`document` currently checks **TBLoader**, before TBMapDocument exists: native
registration, properties, actual cube bake, coordinate conversion/bounds, twelve
triangles, finite vertices/normals/UVs, imported texture dimensions and collision.
Phase 1 must add real document assertions; this baseline is not a mock document.

`editor` runs an actual `@tool EditorPlugin` inside `--editor`: addon startup,
Build Meshes visibility callbacks, Map Materials, real EditorUndoRedoManager
commit/undo/redo, and addon disable/re-enable with released controls. Scene-bound
document history and graph interaction are Phase 3 tests, not current coverage.

`ui` is **display feasibility/editor smoke only**, adding a rendered screenshot
to the editor suite. It requires a display, never falls back to headless, and does
not implement the Phase 6 editing journey or window-system input automation.
The runner selects X11 when `DISPLAY` is set, otherwise Wayland.
Here X11 `:0` works; Wayland `wayland-1` produces engine GLES3 errors/crash.

## Isolation and failure protocol

- Every invocation copies the actual addon, one debug native library, harness,
  writable maps, and a generated asymmetric 64x32 checker PNG into a fresh project.
  No source project import or source-map output; no symlinks. Build first: the
  runner copies a binary but does not build it or prove source freshness.
- Linux debug/release binaries have separate target-qualified filenames. Package
  **both** for editor and release-export use. The old unqualified `.so` is ignored.
  Run builds sequentially; native intermediate object paths remain shared.
- Editor settings, cache, and `user://` data use isolated XDG directories. Logs
  and SHA-256 input/library provenance stay under ignored `artifacts/<run>/`.
  Failures retain their project; successful projects are deleted unless
  `--keep-project` is supplied. Screenshots are copied to the run directory.
- Import uses normal headless editor startup, waits for filesystem scanning and
  a one-second settle period, then explicitly quits. Immediate `--import` teardown
  crashed on fresh projects in the pinned engine; its failure is not suppressed.
- Each process is externally bounded (`--timeout 90` seconds by default), with
  stdout/stderr logs, command, elapsed time and exit code. Timeout kills the process
  group. A suite needs exactly one `TB_TEST_COMPLETE:<suite>:PASS`, positive check
  count, zero failed checks, exit zero, **empty stderr**, and no recognized engine,
  script or assertion error in stdout. There are no diagnostic suppressions.
- `test_harness.py` invokes the real engine four times and asserts runner exit 1
  for deliberate assertion, engine error despite PASS/exit 0, missing marker despite
  exit 0, and timeout. It verifies failure happened in the suite, not in setup.

Direct failure demonstration (expected **exit 1**, never a passing suite):

```bash
python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite document --probe assertion
```

## Fixtures

| Input | Purpose/current use |
|---|---|
| `classic_cube.map` | Baked baseline: bounds (-16,-32,-8)..(48,32,24), six planes, absent/zero flags, non-default classic UVs |
| `empty.map` | Worldspawn-only Phase 1 seed; intentionally not sent through current bake |
| `valve_cube.map` | Phase 1 seed: explicit axes and fractional offsets |
| `patches.map` | Phase 1 seed: def2/def3 header values/subdivisions, fractional point, ordered light epairs |
| Generated `textures/baseline/checker.png` | 64x32 checker with unique red top-left tile; stdlib-only generator in runner |

Semantic round-trip, unsupported/malformed input, ownership instrumentation,
brush/entity preservation and larger-map performance coverage are upcoming gates.
See [implementation contract/progress](../../MAP_EDITOR_IMPLEMENTATION.md).
