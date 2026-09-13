# Map editor document and baseline harness

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

`document` checks the real **TBMapDocument** Result API: registration, new/load/import/
export/save/rebuild, deterministic semantic roundtrips, ordered epairs/ownership,
classic/Valve/flags/patch data, malformed/unsupported/UTF-8/limit errors, caller-owned
queries, stable IDs and epoch-bound snapshots, dirty baseline undo/redo, atomic-save
failure cleanup, external changes/removal and path aliases. It also retains the real
**TBLoader** cube bake, coordinate conversion/bounds, twelve triangles, finite UVs,
normals, collision and imported texture checks, and adds empty-worldspawn bake.

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
| `empty.map` | Worldspawn-only document and empty bake regression |
| `valve_cube.map` | Roundtrip explicit axes and fractional offsets |
| `patches.map` | def2/def3 header values/subdivisions, fractional point, ordered light epairs |
| `ownership.map` | Ordered duplicate/empty/escaped/Unicode epairs, point/brush owners, fractional planes and nonzero flags |
| Generated `textures/baseline/checker.png` | 64x32 checker with unique red top-left tile; stdlib-only generator in runner |

The document suite also composes interleaved brush/patch input and malformed cases
from these fixtures. Test file writes only target disposable `user://` paths.

## Native ownership instrumentation

From repository root, with Clang installed and `/tmp/opencode` available:

```bash
timeout 180s bash tests/map_editor/run_native_tests.sh > /tmp/opencode/tbloader-phase1-native.log 2>&1
rg 'error:|ERROR|runtime error|Assertion|PASS|SUMMARY' /tmp/opencode/tbloader-phase1-native.log
```

The script compiles **production** parser/writer/model/geometry sources in standalone
mode with ASan, UBSan and leak detection, then requires successful native assertions.
There are no sanitizer suppressions or engine dependencies in this target. It checks
field-by-field semantic equality, patch tessellation subdivisions, every fixture's
truncation prefixes, a deterministic byte mutation corpus, repeated load/rebuild/
reset/destruction, and cache disposal independent of source counts. It leaves the
normal extension binary untouched. `CXX` and `TB_NATIVE_OUTPUT` override compiler and
output path. The Godot wrapper and filesystem API are covered by the runtime suite,
not by this standalone instrumentation target.

Brush operations, draw/preview data, entity authoring and larger-map performance
coverage are upcoming gates. See [implementation contract/progress](../../MAP_EDITOR_IMPLEMENTATION.md).
