# Worldspawn Chunking Phase 4 Benchmark Record

Date: 2026-09-17

## Context

- Repository engine pin: `4.8.dev.custom_build.3924ec46f`
- Engine SHA-256: `eba81778168d3a8b96b5dda63d23a7b7a760661d61453dd177461825cd5dce00`
- Host: Linux 7.2.3, AMD Ryzen 9 5950X (16 cores/32 threads), 128 GiB RAM
- Display/renderer: X11 `:0`, OpenGL Compatibility 3.3, NVIDIA GeForce RTX 3090,
  NVIDIA driver 610.57.04; measured viewport size 1901x1048
- Protocol: 120 warmup frames, 240 measured frames per view, and five measured bakes after one
  warm bake for every fixture/profile pair
- Controls: project VSync mode `0`, runtime VSync mode `0`, `Engine.max_fps = 0`, measured display
  refresh 143.94 Hz, project/root viewport occlusion enabled

The strict 60-frame preflight is in ignored artifact `worldspawn-renderer-5u696ge8/`. The corrected
15-case matrix plus three ancillary provisional-default runs are in
`tests/map_editor/artifacts/worldspawn-renderer-9m3vomh7/`. Every run verified the exact pinned engine,
displayed GPU context, effective controls, uncapped frame distribution, and an isolated layer-1 object
changing from 1 object/12 primitives with the fixed occluder hidden to 0/0 with it visible. GPU viewport
timestamps were available in every run.

These results supersede `worldspawn-renderer-3qbcqw7y/`, whose approximately 6.9 ms frame medians were
refresh-capped. They also include the bounded oversized-region, split-time chunk-budget, global
lowest-cost hard-budget, checked arithmetic, corrected isolated-oversized metric, one-pass Builder
surface assembly, and entity-wide tangent fixes made after that run. Chunking remains off by default.

## Renderer measurements

Times are median/p95 milliseconds. `Bake` is total build time, `Visible frame` is wall frame time in
the fully visible view, and `Occluded render` is measured renderer CPU time in the heavily occluded
view. Actual chunk count is reported rather than the profile target.

| Fixture | Profile | Chunks | Triangles | Bake | Visible frame | Occluded render |
|---|---|---:|---:|---:|---:|---:|
| indoor | legacy | 1 | 3,924 | 34.303 / 36.807 | 1.522 / 1.855 | 1.191 / 1.474 |
| indoor | 50 | 43 | 3,924 | 42.964 / 43.417 | 1.695 / 2.075 | 1.288 / 1.628 |
| indoor | 200 | 128 | 3,924 | 170.806 / 175.803 | 2.194 / 2.837 | 1.696 / 2.380 |
| indoor | 500 | 2 | 3,924 | 1,355.766 / 2,293.958 | 3.170 / 4.512 | 2.184 / 3.213 |
| indoor | 1,000 | 318 | 3,924 | 126.347 / 130.028 | 4.015 / 5.617 | 1.988 / 2.572 |
| mixed | legacy | 1 | 9,108 | 74.416 / 75.386 | 1.661 / 2.442 | 1.305 / 1.778 |
| mixed | 50 | 50 | 9,108 | 97.066 / 98.741 | 1.849 / 2.444 | 1.324 / 1.675 |
| mixed | 200 | 105 | 9,108 | 166.813 / 175.861 | 2.050 / 2.855 | 1.392 / 1.817 |
| mixed | 500 | 500 | 9,108 | 221.703 / 224.244 | 3.877 / 4.650 | 2.008 / 2.251 |
| mixed | 1,000 | 759 | 9,108 | 205.438 / 208.803 | 5.894 / 7.214 | 2.623 / 3.242 |
| open | legacy | 1 | 12,288 | 106.392 / 108.527 | 1.627 / 2.158 | 1.250 / 1.609 |
| open | 50 | 16 | 12,288 | 109.109 / 119.284 | 1.673 / 2.565 | 1.245 / 1.544 |
| open | 200 | 64 | 12,288 | 134.108 / 140.617 | 1.868 / 2.418 | 1.379 / 1.802 |
| open | 500 | 500 | 12,288 | 180.231 / 184.312 | 4.079 / 5.195 | 1.855 / 2.356 |
| open | 1,000 | 1,000 | 12,288 | 303.978 / 310.551 | 7.608 / 8.949 | 3.164 / 3.936 |

The indoor 500 control legitimately emits two chunks under the corrected policy: all 327 inputs are
oversized at a 6 m target, and the very large floor/ceiling members make two bounded regional groups
cost-reducing. It is retained as measured output, not represented as approximately 500 chunks.

### Provisional defaults

Defaults here mean chunking enabled with 24 m extent, 15,000 triangles, and maximum 512 chunks. The
shipped enable flag remains false.

| Fixture | Chunks | Bake median / p95 | Visible frame median / p95 | Occluded render CPU median / p95 |
|---|---:|---:|---:|---:|
| indoor | 100 | 67.292 / 68.305 | 2.200 / 3.020 | 1.538 / 1.970 |
| mixed | 63 | 94.632 / 104.799 | 1.898 / 2.469 | 1.378 / 1.751 |
| open | 64 | 125.736 / 128.328 | 1.812 / 2.400 | 1.354 / 1.698 |

## Native measurements

Clock: `std::chrono::steady_clock`; compiler: Clang C++17 `-O2`; same host as above. This is a
headless/native partition measurement, not frame or renderer data. The post-policy three-sample result
is `/tmp/opencode/worldspawn-partition-review.json`; the 1,024 forced-budget median/p95 was
964.631/989.554 ms with the expected 512 globally selected nonadjacent merges.

| Case | Items | Before median / p95 (ms) | After median / p95 (ms) | Speedup |
|---|---:|---:|---:|---:|
| forced pairwise budget | 64 | 15.301 / 15.317 | 2.228 / 2.325 | 6.9x |
| forced pairwise budget | 128 | 120.146 / 120.726 | 9.110 / 9.180 | 13.2x |
| forced pairwise budget | 256 | 954.137 / 966.093 | 30.568 / 36.001 | 31.2x |
| forced pairwise budget | 512 | 7,741.050 / 7,776.620 | 176.231 / 185.450 | 43.9x |
| forced pairwise budget | 1,024 | not run (cubic extrapolation was excessive) | 640.829 / 648.066 | n/a |

Before the fix, doubling 64 to 128 to 256 to 512 multiplied median time by about 8, confirming cubic
repeated pair rescans plus repeated membership/metric rebuilding. The final implementation retains a
priority queue of immutable pair costs, lazily invalidates pairs after a merge, and adds only pairs for
the new merged chunk. Tie policy and output fingerprints are unchanged for cases unaffected by the
global-cost and split-time-budget corrections.

Ordinary 512-item SAH median/p95 after the fix was 16.385/16.975 ms. The 1,024-grid case naturally
terminated at 32 chunks under its SAH cost rule, so it is not presented as a 1,024-leaf result. The
forced-budget case is the direct scalability guard for 1,024 initial chunks.

A final seven-sample verification produced forced-budget median/p95 values of 2.241/2.278 ms (64),
6.714/9.033 ms (128), 27.701/35.494 ms (256), 174.075/190.951 ms (512), and 652.100/670.329 ms
(1,024), with the same fingerprints and exact expected merge counts.

## Renderer gates

- **Open fully visible: fail at provisional defaults.** Median frame time rose from 1.627 to 1.812 ms,
  an 11.4% regression versus the 10% limit. Among matrix controls only 50 passed (+2.9%); 200, 500,
  and 1,000 regressed 14.8%, 150.7%, and 367.6%.
- **Indoor heavily occluded: fail.** Provisional median render CPU rose from 1.191 to 1.538 ms, a
  29.0% regression rather than the required 20% improvement. No matrix chunk profile improved render
  CPU. Provisional GPU time fell from 0.193 to 0.056 ms, but that does not override the measured render
  CPU and frame submission regression.
- **Provisional bake: fail.** Indoor median bake rose 96.2%, exceeding the 50% limit. Mixed and open
  passed individually at +27.2% and +18.2%.
- **Correctness/budget: pass.** Every run conserved source triangles and stayed within its hard budget;
  the existing integration/native suites cover stable membership, names, surfaces, and scene order.
- **Controls: pass.** All runs used the exact pin and displayed renderer, reported effective VSync
  disabled and max FPS unlimited, passed refresh-cap detection, and observed isolated-object culling.

Not every PRD gate passes. The feature remains experimental and disabled by default.
