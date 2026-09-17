# Worldspawn chunking benchmarks

Phase 4 has two deliberately separate measurements. Renderer results are valid only with the exact
engine in `../map_editor/engine_version.txt` and a real displayed GPU context. The native partition
benchmark is valid headlessly and never claims renderer performance.

## Renderer matrix

`generate_fixtures.py` deterministically creates three maps and a hash-bearing manifest:

| Fixture | Geometry | Fixed views |
|---|---|---|
| `indoor` | 327 brushes in a 12 by 10 room/corridor grid | overhead fully visible, corridor frustum, room behind a wall occluder |
| `mixed` | 759 brushes: hollow buildings plus an open detail field | overhead fully visible, edge frustum, inside-building occlusion |
| `open` | 1,024 separated terrain blocks | overhead fully visible, low edge frustum, low terrain occlusion |

The runner compares legacy one-mesh output with profiles targeting 50, 200, 500, and 1,000 chunks.
Actual chunks are always reported; indivisible/oversized brushes mean smaller fixtures cannot reach
every target. Profiles are benchmark controls, not product defaults. Chunking remains disabled by
default and these controls must not be used to tune defaults from unpinned exploratory data.

Each fixture/profile uses a fresh engine process. It records engine executable/version/hash, renderer,
display driver, GPU vendor/adapter/API/driver, OS/CPU/load/display, resolution, fixture hashes, raw warm
frame samples and median/p95 summaries for frame wall time, process CPU, render CPU, GPU (only when
viewport timestamps return real data), draw calls, rendered objects/primitives, and renderer video
memory. It also records RSS/static memory, total bake and partition median/p95, source/visual/collision
build metrics, actual chunks, material surfaces, generated nodes/mesh instances, and packed scene size.
Collision and UV2 unwrap are disabled to isolate visual partition/render costs; that context is embedded
in the probe. The staged project disables VSync and enables root-viewport occlusion culling. The probe
also disables VSync through `DisplayServer`, removes `Engine.max_fps`, verifies all effective values,
and records screen refresh. Acceptance fails if at least 80% of a view's frames remain within 3% of the
refresh interval. A fixed `BoxOccluder3D` matching authored fixture walls must be visible and in-tree.
Before measurement, an isolated layer-1 box behind it must render while the occluder is hidden and be
rejected while it is visible; the map uses layer 32 and is excluded from this control. Failure means the
occluded gate is not valid.

```bash
export GODOT_BIN=/path/to/the/exact/pinned/godot
DISPLAY=:0 python tests/worldspawn_benchmark/renderer_runner.py --godot "$GODOT_BIN" --include-provisional-default
```

Preflight retains all pin/display/renderer checks and uses 60 frames so refresh-cap detection is valid:

```bash
DISPLAY=:0 python tests/worldspawn_benchmark/renderer_runner.py --godot "$GODOT_BIN" --preflight
```

There is no headless renderer option. Missing display sockets or a mismatched engine fail before results
can be accepted. `--exploratory-unpinned` is the only way to try a mismatched engine; output is labeled
`acceptance_eligible: false`, cannot satisfy gates, and may still fail safely on GDExtension ABI mismatch.
Zero GPU timestamps are stored as unavailable with a reason, never transformed into fake GPU data.

## Native partition scalability

The standalone C++ benchmark uses production partitioner code and deterministic item grids. `sah_grid`
measures ordinary splitting. `forced_pairwise_budget` starts with isolated oversized items and forces a
50% hard-budget reduction, directly exercising lowest-cost pair selection. Every warm/sample run must
produce the same membership fingerprint and remain under budget.

```bash
bash tests/worldspawn_benchmark/run_partition_benchmark.sh --samples 7 --max-items 1024 \
  > /tmp/opencode/worldspawn-partition.json
```

The optimized build uses `-O2`; sanitizer correctness is provided separately by
`bash tests/map_editor/run_native_tests.sh worldspawn`.
