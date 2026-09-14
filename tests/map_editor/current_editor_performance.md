# CURRENT-editor Tohunga baseline

`current_editor_performance_runner.py` measures the current worktree's real Map
editor against `fixtures/tohunga.map`. It stages the addon and existing debug library
in an isolated project and rejects engine-version drift, nonzero exits, stderr,
recognized diagnostics, missing/duplicate completion markers, invalid counts, and
missing memory counters.

Run from the repository root:

```bash
python tests/map_editor/current_editor_performance_runner.py \
  --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 \
  --samples 31 --timeout 180 --display-driver headless
```

The four memory checkpoints are ordered and isolated:

1. Empty editor after the Map UI has reached a rendering synchronization boundary.
2. Loaded native document before session draw/entity or native chunk accessors.
3. Populated production draw/entity/marker caches and native chunk manifest while detached from UI.
4. Full visible two-grid/camera UI after fitting the fixture and rendering sync.

Each checkpoint records Linux RSS/HWM, Godot static/peak static memory, and applicable
document, cache, geometry, viewport, and picking counts. Timings include native load,
first production-cache population, cache hits, UI attach/initial camera build,
explicit camera rebuild/cache reconciliation, 2D broad-phase candidate queries and
complete hit/miss picking, camera picking, compatibility preview generation after
the production checkpoints, and grid redraw queue-to-`frame_post_draw`.

`frame_post_draw` is only a synchronization boundary. The redraw interval includes
frame scheduling and renderer work and is not input-to-photon latency. Headless mode
exercises visible controls and renderer synchronization without a physical display;
use `--display-driver x11` with an existing `DISPLAY` for a display-backed run. RSS
includes the entire editor process and allocator retention, while Godot static memory
does not include every native `malloc` allocation. The runner copies but does not
build or prove source freshness of the debug library; hashes and git status are kept
with every run under ignored `tests/map_editor/artifacts/current-editor-performance-*`.

## Recorded step 6 comparison

The paired 2026-09-13 headless runs used the pinned
`4.8.dev.custom_build.3924ec46f` editor (SHA-256
`3feb1c1096c470af669d53b37bbc63c86b70b34e90703533d0c946ec6625af5d`).
Both passed with empty stderr and one completion marker. Raw before evidence is in
`tests/map_editor/artifacts/current-editor-performance-okn7ircz/`; after evidence is
in `tests/map_editor/artifacts/current-editor-performance-iwmccbpw/`.

| Checkpoint | Before RSS MiB | After RSS MiB | Before static MiB | After static MiB |
|---|---:|---:|---:|---:|
| Empty editor | 875.672 | 875.742 | 579.135 | 579.173 |
| Loaded native document | 899.559 | 899.547 | 579.143 | 579.181 |
| Populated session/production caches | 979.301 | 977.324 | 644.600 | 638.967 |
| Full visible grids/camera after render sync | 1265.848 | 1260.152 | 821.644 | 816.040 |

Counts were 5,060 brushes, 30,104 faces, 59,610 edges, 39,626 brush
vertices, 46 entities, 17 point markers, 88 textures, and 59,012 native
preview/camera triangles. Camera output used 117 geometry chunks/mesh instances.
The compatibility API, measured only after all production memory checkpoints,
returned 88 groups, 119,220 vertices, and the same 59,012 triangles in 8.402 ms.

| Operation | Before | After |
|---|---:|---:|
| Native document load | 202.552 ms | 199.566 ms |
| First session/production cache population | 123.249 ms | 108.172 ms |
| Session cache hit, median / p95 (31) | 0.001 / 0.001 ms | 0.001 / 0.001 ms |
| Attach session and initial camera rebuild | 502.488 ms | 493.318 ms |
| Camera rebuild/cache reconciliation | 25.976 ms | 24.746 ms |
| Full grid redraw queue-to-render-sync | 287.705 ms | 278.623 ms |
| 2D complete hit, median / p95 (31) | 1.108 / 1.480 ms | 0.025 / 0.039 ms |
| Camera full-scan miss, median / p95 (31) | 21.289 / 29.282 ms | 20.266 / 26.784 ms |

The after probe additionally records a representative successful graph hit with 442
candidates: candidate query median/p95 was 0.016/0.020 ms and complete hit median/p95
was 0.025/0.039 ms. Its zero-candidate miss measured 0.003/0.003 ms for the query and
0.003/0.005 ms complete. The camera-center ray hit no geometry in either run, so those
camera values are miss-path measurements. The runs were not display-backed because
the environment had neither `DISPLAY` nor `WAYLAND_DISPLAY`.

## Final bounded-chunk run

After enforcing the 2,048-triangle maximum for dense spatial cells, the final
31-sample headless run passed at
`tests/map_editor/artifacts/current-editor-performance-vnfx82hd/`. It produced 131
bounded chunks for the same 59,012 triangles. Camera cache reconciliation took
31.589 ms; camera miss picking measured 20.860/23.927 ms median/p95; graph hit
measured 0.027/0.036 ms. Final RSS was 1,260.500 MiB and Godot static memory was
816.150 MiB. Camera samples were recorded separately as 0 hits and 31 misses rather
than combining unlike paths.

The subsequent static-edge batching run at
`tests/map_editor/artifacts/current-editor-performance-e808lpus/` reduced the same
two-grid redraw boundary from 293.590 ms to 275.959 ms (6.0%). Final RSS was
1,261.301 MiB and Godot static memory was 816.154 MiB. This modest gain indicates
that processing the complete fitted map's 119,220 projected edge segments now
dominates over CanvasItem call count; no lossy screen-space LOD was introduced.

The dense map-space edge cache removes that repeated GDScript projection work during
pan and zoom while preserving every edge. Two independent 31-sample process runs at
`tests/map_editor/artifacts/current-editor-performance-rcpwcmkj/` and
`tests/map_editor/artifacts/current-editor-performance-rhwb2h2v/` measured the same
two-grid redraw boundary at 37.872 ms and 38.440 ms, respectively. This is an 86.1%
reduction from the 275.959 ms static-edge batching run; final RSS was 1,262.668 MiB
and 1,262.156 MiB.

The targeted brush-translation path was measured at
`tests/map_editor/artifacts/current-editor-performance-weby2iy6/`. A Tohunga
one-brush move took 50.258 ms for the native immutable-map commit, 60.185 ms for
targeted session/camera refresh, and 45.155 ms through the following rendered frame,
or 155.598 ms total. The earlier equivalent breakdown totaled about 600 ms. Empty
point-entity translation, previously a second whole-document edit in the grid move
path, now returns in 0.012 ms.
