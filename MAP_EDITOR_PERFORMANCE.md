# Phase 6 native performance baseline

**Native measurement completed; display-backed performance acceptance remains open.**
On the measured debug library, the 32-brush fixture stayed below the 16.7 ms
reference budget for each individual native operation. At 256 and 512 brushes,
every measured translation exceeded it. These are synchronous native document API
wall times, including GDScript/native marshaling, **not actual editor gesture or
frame latency**. No optimization was made as part of this measurement.

## Reproduce

From `/mnt/data/code/godot-tbloader`:

```bash
python3 tests/map_editor/performance_runner.py \
  --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 \
  --brushes 32 256 512 --samples 31 --warmups 3 --repeats 2 \
  --timeout 120 --verify-failures
```

The existing Linux x86-64 debug addon library must be present. The runner does not
build it. Python 3.11+ and Linux `/proc` are required. Each run creates and retains
an isolated project under `/tmp/opencode/tbloader-performance-*`, with copied real
addon sources, `.gdextension`, library, suite, generated maps, and bounds manifests.
Inputs are copied, not symlinked. Library hashes before/after copying must agree.
`GDExtensionManager.load_extension()` loads the real staged extension directly;
no texture import or editor/plugin startup is needed for document measurements.
XDG configuration/data/cache paths point into the run directory.

Only summaries/errors reach the terminal. Retained artifacts include:

- `result.json`: settings, engine/library/input SHA-256s, source revision and dirty
  status, environment, all raw samples, per-process summaries and pooled summaries.
- `summary.json`: pooled median, nearest-rank p95, min/max, sample counts,
  counts above 16.7 ms, first imports and memory checkpoints.
- `native-<brushes>-r<repeat>.json`: individual process results.
- `*.stdout.log`, `*.stderr.log`, `*.process.json`: complete process logs,
  commands, exit codes, monotonic process duration and failures, including probes.
- `project/blockout-*.map` and `.json`: exact generated geometry and expected bounds.

Each process has an external timeout; expiry kills its process group and waits
for termination. A successful measurement requires exit zero, empty stderr, no
engine/script/crash/leak diagnostics, exactly one `TB_PERF_COMPLETE:PASS`, exactly
one matching `TB_PERF_COUNTS:<brushes>:<faces>:<triangles>`, and valid result data.
Stale result files are removed before each process. `--verify-failures` verified
rejection of an engine error despite exit zero and a success marker, missing
completion despite exit zero, and a deliberately stalled process (2 s timeout).
`PASS` means the measurement protocol passed; it does **not** mean the budget passed.

## Workload and timing method

The deterministic classic `.map` generator uses eight solids per room: a floor,
two walls, a raised platform, two pillars and two steps. Rooms are placed at
512-unit spacing, eight columns wide. Each has a 384 × 384 footprint, with
16-unit floors/walls and a maximum height of 128. All faces use `common/caulk`
with classic identity UV projection. This is a representative **simple cuboid
blockout workload**, not a complex production level: there are no patches,
non-axis-aligned solids, point entities, resource resolution, or textured rendering.

| Fixture | Rooms | Brushes | Faces | Preview triangles | Input bytes | Snapshot Variant bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small | 4 | 32 | 192 | 384 | 13,019 | 15,380 |
| Larger | 32 | 256 | 1,536 | 3,072 | 109,477 | 127,072 |
| Larger | 64 | 512 | 3,072 | 6,144 | 221,805 | 256,808 |

One worldspawn owns every brush. The suite verifies every generated brush's exact
bounds, six faces/eight vertices, total triangle counts and canonical agreement
between independent bulk imports. It uses one `import_text()` to set up each map;
repeated `create_cuboid()` and its cumulative rebuild costs do not dominate setup.
Text generation and file reading are outside all native operation timers.

For each size, two fresh Godot processes run three warmups followed by 31 measured
calls per operation. Size order is 32/256/512, then 512/256/32. Operation order is
rebuild, snapshot, export, draw data, preview data, translate one, translate all,
then repeated bulk import into a separate document. The initial setup import is
also reported separately (one per process); it is not a filesystem cold-cache test.

`Time.get_ticks_usec()` brackets the synchronous callable. It is monotonic and
microsecond-resolution. API return materialization and callable overhead are
included; validation, destruction of returned values, sample storage and logging
are outside the interval. Returned values are explicitly released before starting
the next sample. No overhead subtraction or outlier removal is performed.
Translations alternate +16/-16 map units on X; each must increment revision.
Any final unmatched move is reversed outside timing, then exact canonical equality
is checked. The translation wrapper also includes a small direction-toggle cost.
Native signals have no editor/session subscribers in this harness.

- **Rebuild** is `TBMapDocument.rebuild()`, not mesh bake, redraw, or rendering.
- **Translate one/all** commits geometry in the complete document, selecting the
  first brush or all brushes respectively; the similar times do not establish a
  particular complexity model.
- **Snapshot** is the native snapshot query. It excludes editor history encoding,
  undo registration and `restore_snapshot()`.
- **Export** returns canonical text in memory; it is not disk save/fsync timing.
- **Draw/preview data** are native copied-data queries. Neither submits an editor
  draw nor measures CPU draw callbacks, GPU work, input dispatch, or presentation.

## Measured results

Authoritative run: **2026-09-13 17:17:51 UTC**, artifacts:
`/tmp/opencode/tbloader-performance-owoi6osy`.

Cells below are **median / p95 milliseconds**, pooled across 62 measured calls per
operation per fixture. p95 is nearest-rank (59th sorted sample of 62). Per-process
results and every raw microsecond sample remain available; these repeated calls
are not 62 independent machines or confidence intervals.

| Native operation | 32 brushes | 256 brushes | 512 brushes |
| --- | ---: | ---: | ---: |
| Bulk import (replacement, warmed) | 2.498 / 5.820 | 19.917 / 32.764 | 40.638 / 61.217 |
| Rebuild | 1.826 / 1.954 | 14.544 / 28.376 | 29.295 / 41.908 |
| Translate one brush | 3.113 / 5.943 | 24.099 / 35.191 | 48.366 / 68.781 |
| Translate all brushes | 3.007 / 3.404 | 24.170 / 35.883 | 49.195 / 68.325 |
| Snapshot | 0.023 / 0.025 | 0.172 / 1.917 | 0.335 / 0.359 |
| Export text | 0.009 / 0.009 | 0.068 / 0.073 | 0.136 / 0.142 |
| Get draw data | 0.392 / 0.439 | 2.983 / 3.125 | 5.897 / 12.208 |
| Get preview data | 0.036 / 0.037 | 0.269 / 0.298 | 0.543 / 3.204 |

First setup imports in processes 1/2: **2.450/2.504 ms** (32),
**19.867/19.951 ms** (256), **40.167/40.249 ms** (512).

### Memory

All values below are **MiB (2²⁰ bytes)**; ranges span the two fresh processes.
Linux `/proc/self/status` RSS includes the engine, extension, native allocations,
fixture strings/manifests, result arrays, shared resident pages and allocator
retention. `VmHWM` is the process-lifetime resident high-water mark, not an
operation-specific allocation measurement. Godot static counters miss allocations
made directly by native C/C++ allocators.

| Checkpoint | 32 brushes | 256 brushes | 512 brushes |
| --- | ---: | ---: | ---: |
| RSS before document (fixtures already read) | 134.19–134.42 | 134.36–134.63 | 134.55–134.68 |
| RSS immediately after first import | 134.69–134.98 | 135.66–136.01 | 137.55–137.84 |
| RSS after main measured operations | 134.72–135.14 | 140.48–140.77 | 147.16–147.55 |
| Process HWM through release checkpoint | 134.72–135.14 | 140.48–140.83 | 147.19–147.55 |
| Godot static after operations | 43.76 | 44.64 | 45.67 |
| Godot static peak through release checkpoint | 44.37 | 47.79 | 52.05 |

The after-operations checkpoint precedes the second document's repeated imports.
After both document references are released, RSS remains approximately at the
after-operations level. The harness still retains fixture/canonical strings and
results, and allocators may retain pages. This is **not a leak diagnosis** or an
editor history memory test. Snapshot Variant byte counts above measure serialization
payload via `var_to_bytes()`, outside timers; they are not heap sizes.

### Environment and identity

- Engine: `4.8.dev.custom_build.3924ec46f`, debug build, headless display driver,
  Dummy audio; CPU benchmark with no renderer/GPU performance claim.
- Engine SHA-256: `3feb1c1096c470af669d53b37bbc63c86b70b34e90703533d0c946ec6625af5d`.
- Library: `addons/tbloader/bin/libtbloader.linux.template_debug.x86_64.so`.
- Library SHA-256: `cf3482283f24cd3be7822aad1fe347024bec1889385a561198a62d264b34c9d5`.
- Source HEAD at run: `96adf6a45b8c0c8e3b83fb9a2c4c955c2c91ba16`. The working tree
  also contained concurrent editor/lifecycle work; exact staged hashes and status
  are recorded. Those scripts were copied but not activated by this benchmark.
- AMD Ryzen 9 5950X, 16 cores/32 logical CPUs; affinity 0–31; Linux
  `7.2.3-arch1-3`, glibc 2.44; Python 3.14.4.
- Load averages at start: 4.774/6.261/5.885. Recorded CPU governors were powersave
  except policy11 (performance). Scheduling, clocks, thermal state and background
  load were not controlled. One pre-existing Godot Wayland editor was running on
  another project; no additional UI session was launched. This baseline describes
  a shared development workstation, not an idle dedicated benchmark machine.

Generated input SHA-256s:

```text
32   107b9d1c007aacad4a3845a7c4a7dd9ca4d39362aa7e642baa80699a8cf24d1d
256  9a205f2bf06b56fb1b795729e000e86e93d2c944c7c7c77d3bce32c2b5da7489
512  6999c1b93e820e356c5a334e0123a2eac473ad53188a8790bc6cb3d73b364b9f
```

Development evidence is retained too: the initial headless `--editor --import`
attempt ended with SIGABRT after editor layout loading, with empty stderr
(`/tmp/opencode/tbloader-performance-n5jl0182`). No cause is assigned here. A first
runtime attempt exposed the suite's procfs length-zero reading mistake and failed
strictly (`...-o8ohtu0w`); line-based procfs reads fixed the owned harness. A short
5-sample pilot then passed (`...-i8roszk3`). The first 31-sample run (`...-0y_4g3tw`)
was superseded after review made returned-value release explicit outside the timer,
preventing previous-return cleanup from contaminating the next sample. Only the
final 31-sample run above supplies the reported baseline; this harness correction
is not a product optimization.

## Budget and next UX gate

Based on this baseline, retain **16.7 ms for the complete frame at a 60 Hz target**
as the next interactive acceptance budget, reporting median/p95/max and missed
budget counts. The small map makes that target worth testing; the larger maps
already identify synchronous work that cannot fit into one such frame:

- 32: no measured individual native call exceeded 16.7 ms. This does not establish
  that combined editor work fits a frame.
- 256: 11/62 rebuilds and 62/62 calls of each translation exceeded 16.7 ms.
- 512: 62/62 rebuilds and calls of each translation exceeded 16.7 ms. Draw-data
  query max was 16.429 ms; translation maxima were 77.272 ms (one) and
  72.979 ms (all).

Actual drag feedback may use preview state and defer native commits until release.
Consequently these timings cannot establish pointer-motion responsiveness or
release-to-visible-result latency. Phase 6 still needs an exclusive display-backed
run measuring idle/redraw frames, drag begin, repeated motion, release/commit,
undo/redo, and multi-view updates on these same fixtures. Record event-to-visible
state timing separately from frame duration and native method duration; measure
memory with actual editor history and rendering resources present.

**Feasible next window-system strategy (researched only):** installed
`libX11.so.6` and `libXtst.so.6` loaded successfully and expose `XOpenDisplay`,
`XQueryTree`, `XGetWindowProperty`, `XTranslateCoordinates`, `XSync`,
`XTestQueryExtension`, and the XTest fake motion/button/key APIs. The harness
environment has neither `DISPLAY` nor `WAYLAND_DISPLAY`; it did not connect to a
display, query a live server's XTEST support, or inject events. With an explicitly
available X11/XWayland display and the other UI test session finished, launch one
staged Godot editor with `--display-driver x11`, verify XTEST, locate its window by
PID/title, confirm focus and root-coordinate geometry, then inject deterministic
mouse/keyboard sequences through XTest. Native Wayland windows are not XTest
targets. Observe resulting geometry/history and rendered frames rather than
calling `_gui_input()` directly. Timestamp injection and observation monotonically;
engine frame-drawn callbacks alone are not proof of compositor presentation or
input-to-photon latency. No desktop/system configuration changes are needed by the
proposed harness. Server access and a genuine presentation-observation method
remain unverified.
