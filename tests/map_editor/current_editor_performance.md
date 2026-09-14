# Current-editor Tohunga performance

`current_editor_performance_runner.py` measures the current worktree's production
Map editor against `fixtures/tohunga.map`. By default it first builds the current
debug extension with `scons`; `--skip-build` is the explicit opt-out. Every artifact
records the source status, staged inputs, engine hash, and built/staged library
SHA-256, and rejects a staged-library hash mismatch.

The runner also enforces conservative absolute regression budgets derived from the
accepted final behavior: 350 ms load, 175 ms production-cache population, 400 ms
attach, 100 ms texture UV update, 5 ms connected one-brush move, 10 ms each for
selection/camera overlays, 100 ms grid render boundary, 10 ms maximum for every
local mutation and native preview sample, and 1 ms p95 for local memento undo/redo.
Full-visible growth over the empty editor is capped at 450 MiB RSS and 375 MiB Godot
static memory. These intentionally broad gates work with `--samples 1`; they detect
large regressions rather than serving as interactive frame-time claims.

Run from the repository root:

```bash
python tests/map_editor/current_editor_performance_runner.py \
  --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 \
  --samples 31 --timeout 180 --display-driver headless
```

The four isolated memory checkpoints are empty editor after render synchronization,
loaded native document before session/native-cache access, populated production
caches while detached from the UI, and full visible two-grid/camera UI after render
synchronization. Local mutation measurements run only after the final checkpoint.

## Accepted 31-sample comparison

The accepted baseline is
`tests/map_editor/artifacts/current-editor-performance-4ux9qqc1/`
(`2026-09-14T16:59:00.063294Z`); the accepted final is
`tests/map_editor/artifacts/current-editor-performance-ypxmod3a/`
(`2026-09-14T23:10:51.212520Z`). Both passed headless with 31 samples, empty
stderr, one completion marker, fixture SHA-256
`1e9d250d26267ebda5ff52978ebacca23e37a686865fe47f950b0109e7ca8811`,
and engine version `4.8.dev.custom_build.3924ec46f`. The baseline library hash was
`f27a1662bcff1cc07c3e7d31c6a98ad98e9cbd5a0f75c90c2a57ef5ad99eef4d`;
the final built library hash was
`a68365f2f1e6a897ed06f1cf46db709e7abfafcd625c7b28c8bda7e305021947`.
The final passed the mandatory build (`skip_build: false`) and retained the
successful `build.log`; the older baseline runner copied the existing library and
did not prove freshness.

The engine executable hashes differ (`3feb1c...af5d` baseline,
`ece3d6...f04` final) despite the same pinned version string. This and the host load
averages (1.657/1.515/2.123 baseline, 8.779/7.736/7.637 final) limit attribution of
small changes, but not the large accepted deltas below.

All 12 regression gates passed in the accepted 31-sample run with the mandatory
build:

| Regression gate | Measured | Limit |
|---|---:|---:|
| Native document load | 249.207 ms | 350 ms |
| Populate production session caches | 102.833 ms | 175 ms |
| Attach session and initial camera rebuild | 95.698 ms | 400 ms |
| Texture UV update | 13.798 ms | 100 ms |
| Connected one-brush move | 0.169 ms | 5 ms |
| Selection overlay | 2.081 ms | 10 ms |
| Camera overlay | 2.712 ms | 10 ms |
| Grid render boundary | 41.757 ms | 100 ms |
| Maximum local mutation/native preview sample | 4.585 ms | 10 ms |
| Local memento undo/redo p95 | 0.077 ms | 1 ms |
| Full-visible RSS growth | 341.77734375 MiB | 450 MiB |
| Full-visible Godot static growth | 278.302698135376 MiB | 375 MiB |

Counts are unchanged: 5,060 brushes, 30,104 faces, 59,610 edges, 39,626 brush
vertices, 46 entities, 17 point markers, 88 textures, 131 preview/camera chunks,
and 59,012 preview/camera triangles.

### Memory checkpoints

Values are exact bytes with MiB in parentheses; each cell is RSS/HWM or
Godot static/peak static.

| Checkpoint | Baseline RSS / HWM | Final RSS / HWM | Baseline static / peak | Final static / peak |
|---|---:|---:|---:|---:|
| Empty editor | 933,953,536 / 943,517,696 (890.688 / 899.809) | 936,210,432 / 943,718,400 (892.840 / 900.000) | 612,365,526 / 633,631,674 (583.997 / 604.278) | 612,722,447 / 634,399,128 (584.338 / 605.010) |
| Loaded native document | 950,329,344 / 950,329,344 (906.305 / 906.305) | 949,456,896 / 949,456,896 (905.473 / 905.473) | 612,375,598 / 633,631,674 (584.007 / 604.278) | 612,740,983 / 634,399,128 (584.355 / 605.010) |
| Populated production caches | 1,032,462,336 / 1,032,462,336 (984.633 / 984.633) | 1,028,579,328 / 1,028,579,328 (980.930 / 980.930) | 675,588,246 / 675,599,726 (644.291 / 644.302) | 675,953,415 / 675,964,895 (644.639 / 644.650) |
| Full visible grids/camera | 1,300,041,728 / 1,300,041,728 (1,239.816 / 1,239.816) | 1,294,589,952 / 1,294,589,952 (1,234.617 / 1,234.617) | 902,238,620 / 915,448,104 (860.442 / 873.039) | 904,543,977 / 917,751,285 (862.640 / 875.236) |

Final RSS improved by 5,451,776 bytes (5.199 MiB, 0.42%). Final static memory
increased by 2,305,357 bytes (2.199 MiB, 0.26%); this remains a memory bottleneck,
not an improvement.

### Opening path

The opening total is the sum of the directly comparable native load, first
production-cache population, and UI attach/initial camera build boundaries.

| Boundary | Baseline | Final | Change |
|---|---:|---:|---:|
| Native document load | 269.442 ms | 249.207 ms | -7.5% |
| Populate production session caches | 102.720 ms | 102.833 ms | +0.1% |
| Attach session and initial camera rebuild | 629.255 ms | 95.698 ms | -84.8% |
| Opening total | 1,001.417 ms | 447.738 ms | -55.3% |
| Production cache hit, median / p95 (31) | 0.001 / 0.001 ms | 0.001 / 0.001 ms | unchanged |
| Camera cache reconciliation | 1.296 ms | 1.743 ms | +34.5% |
| Compatibility preview | 11.298 ms | 25.001 ms | +121.3% |

The final semantic load performed one parser call (52.349 ms), one canonical writer
call (43.085 ms), and 5,060 compact builds (143.243 ms), with zero source clones,
materializations, deep clones, or `LMGeoGenerator` calls. It retained 7,320,137
source bytes and 8,508,104 compact bytes. Attach is the dominant opening improvement;
load and compact construction remain material costs.

### Local edits and translation

The corrected local transaction measurements did not exist in the baseline artifact,
so only final medians/p95 are reported; the old `native_preview_*` read-only geometry
measurements are not substituted for commit timings.

| Final local commit (31 samples) | Median / p95 |
|---|---:|
| Rotate one brush | 0.090 / 0.132 ms |
| Translate one face | 0.088 / 0.099 ms |
| Set one face texture | 0.163 / 0.266 ms |
| Set one face classic UV | 0.144 / 0.165 ms |
| Atomic two-face/two-brush batch | 0.253 / 0.278 ms |
| Move one face component | 0.099 / 0.129 ms |

Each sample asserts its exact operation and brush set and zero parser, writer,
`LMGeoGenerator`, materialization, and deep-clone work. The atomic batch has the
largest final local-commit median and p95.

| Connected one-brush translation boundary | Baseline | Final |
|---|---:|---:|
| Production session translation | 64.630 ms | 0.169 ms |
| Session refresh | 40.482 ms | 62.774 ms |
| Following rendered frame | 81.172 ms | 95.262 ms |
| Total | 186.284 ms | 158.205 ms |

The commit improved 99.7% and the total improved 15.1%, but refresh plus rendering
now account for 158.036 ms and are the translation bottleneck. Final before/after
capture took 0.023/0.005 ms, and empty point translation took 0.004 ms.

### Graph layers, picking, and grid

The final graph-layer assertions isolate invalidation correctly:

| Change | Static redraws / builds / restores | Selection redraws | Camera redraws | Dense states / retained bytes |
|---|---:|---:|---:|---:|
| Selection change | 0 / 0 / 0 | 2 | 0 | 1 / 1,034,720 |
| Camera marker | 0 / 0 / 0 | 0 | 1 | 1 / 1,034,720 |
| Grid translation | 2 / 0 / 0 | 4 | 1 | 2 / 2,069,440 |

Selection-only and camera-only updates reached `frame_post_draw` in 2.081 ms and
2.712 ms. Grid translation patches the dense static state without rebuilding edges.

| Boundary (31 samples where distributed) | Baseline | Final |
|---|---:|---:|
| 442-candidate query hit, median / p95 | 0.016 / 0.020 ms | 0.015 / 0.020 ms |
| Complete graph hit, median / p95 | 10.881 / 12.176 ms | 11.560 / 13.333 ms |
| Zero-candidate complete miss, median / p95 | 0.003 / 0.003 ms | 0.003 / 0.006 ms |
| Camera-center full-scan miss, median / p95 | 0.034 / 0.040 ms | 0.034 / 0.042 ms |
| Full two-grid redraw to `frame_post_draw` | 36.722 ms | 41.757 ms |

Spatial candidate lookup remains cheap, while the complete 442-candidate hit and full
grid redraw remain bottlenecks. The camera center hit no geometry in either run, so
camera figures describe only the miss path.

### Texture sizes and history

Final `set_texture_sizes` took 13.798 ms. It made 5,060 UV-only updates in 2.971 ms,
copied 8,022,072 compact bytes, and retained an 8,508,104-byte compact store, with
zero full/brush builds, parser/writer calls, source clones, materializations, deep
clones, or geogen calls. RSS changed by 0 bytes and Godot static memory changed by
-397,156 bytes across the measured boundary. The remaining 10.827 ms outside the
native UV update and the 7.65 MiB copy-on-write payload are the bottlenecks.
The session now recognizes this native change as `texture_uv` and retains draw,
entity, and marker caches; the probe requires zero full draw resets and reads.

The final one-brush document-change memento retains 7,212 bytes per action, changes
and restores exactly one brush, and performs zero full resets. Its 31-sample local
undo median/p95 is 0.062/0.077 ms; redo is 0.062/0.068 ms. The baseline did not expose
this memento boundary. The legacy full history-state compatibility restore, used only
to reset the six local benchmarks, measured 0.318/0.499 ms across 186 samples.

Regular connected editor undo/redo still includes session restoration and the next
rendered frame:

| Regular history boundary, median / p95 (31) | Baseline | Final |
|---|---:|---:|
| Undo session restore | 17.320 / 23.679 ms | 13.994 / 15.853 ms |
| Undo following frame | 78.355 / 92.990 ms | 96.118 / 107.822 ms |
| Redo session restore | 17.012 / 19.770 ms | 14.066 / 17.505 ms |
| Redo following frame | 77.364 / 92.107 ms | 90.978 / 114.717 ms |

Session restore improved, but rendering regressed and dominates regular undo/redo.
The draw-delta checks touched 561 entries, retained zero history-cache bytes, and
performed zero full-cache duplicates; final lifetime counters include one explicit
full draw read/reset (5,060 iterations), not per-local-restore work.

## Recorded intermediate milestones

- Step 6 (`okn7ircz` to `iwmccbpw`) reduced complete graph hit from
  1.108/1.480 ms to 0.025/0.039 ms median/p95 using broad-phase candidates. It
  reduced final RSS from 1,265.848 to 1,260.152 MiB and static memory from 821.644
  to 816.040 MiB.
- Bounded spatial chunks (`vnfx82hd`) enforced a 2,048-triangle maximum and produced
  131 chunks for 59,012 triangles: final RSS 1,260.500 MiB, static 816.150 MiB,
  camera reconciliation 31.589 ms, camera miss 20.860/23.927 ms, and graph hit
  0.027/0.036 ms.
- Static-edge batching (`e808lpus`) reduced the two-grid redraw from 293.590 to
  275.959 ms (6.0%), with final RSS 1,261.301 MiB and static 816.154 MiB.
- Dense map-space edge caches (`rcpwcmkj`, `rhwb2h2v`) preserved every edge and
  reduced that redraw to 37.872 and 38.440 ms (86.1% versus 275.959 ms), with final
  RSS 1,262.668 and 1,262.156 MiB.
- Targeted translation (`weby2iy6`) measured 50.258 ms connected operation,
  60.185 ms refresh, 45.155 ms following frame, and 155.598 ms total, down from
  about 600 ms. Empty point translation was 0.012 ms.
- Phase 2/4 (`4ux9qqc1` to `nz2qwaav`) reduced the connected translation from
  64.630 to 5.844 ms and refresh from 40.482 to 30.626 ms, while its following frame
  rose from 81.172 to 96.289 ms. Final RSS temporarily rose 43.629 MiB to
  1,283.445 MiB; this was a high-load, dirty-worktree run.
- Semantic-only load (`t5glty78` to `98ubzd6l`, one sample) reduced load from
  270.384 to 234.935 ms and attach from 362.662 to 337.711 ms. Verification
  `obk1xd8j` measured 236.268 ms load, 337.505 ms attach, 49.258 ms parser,
  42.394 ms writer, and 135.523 ms compact build; loaded/final RSS was
  948,756,480/1,292,709,888 bytes.
- UV-only texture context (`obk1xd8j` to `br4mso_a`, one sample) reduced
  `set_texture_sizes` from 172.451 to 51.417 ms (70.2%), replacing 5,060 full compact
  builds with 5,060 UV-only updates. It copied 8,022,072 bytes and spent 3.955 ms in
  UV calculation.
- The provisional final (`a7gyguou`, 31 samples) measured 537.951 ms opening total,
  133.008 ms connected translation total, 42.605 ms two-grid redraw, 46.603 ms
  `set_texture_sizes`, 1,293,725,696-byte final RSS, and 904,474,112-byte final Godot
  static memory before the accepted `ypxmod3a` verification superseded it.

## Limitations

- These are single-process debug, GL compatibility, headless runs, not
  display-backed measurements.
- The absolute gates are calibrated for the pinned debug/headless environment. They
  are deliberately loose, but host contention, a different engine binary, or a
  display-backed renderer can still make timing and whole-process memory incomparable.
- `frame_post_draw` is a queue-to-render synchronization boundary, not input-to-photon
  latency; it includes scheduling and renderer work.
- RSS covers the whole editor, renderer, extension, native allocations, and allocator
  retention. Godot static memory excludes some native `malloc` allocations.
- One-shot opening, grid, translation, texture, and layer timings have no distribution;
  small differences are not statistically separable from host and engine-binary drift.
- Local mutation samples occur after every memory checkpoint. Untimed base restoration
  and topology-token refresh are excluded from local commit intervals.
- Baseline lacks the corrected local commit, graph-layer, UV-only texture, and memento
  boundaries; only metrics present under equivalent boundaries are compared directly.
