# Worldspawn Mesh Chunking Implementation

Status: Phase 0 through Phase 4 implemented and tested; performance gates failed, feature remains default-off

Related requirements: `WORLDSPAWN_CHUNKING_PRD.md`

## Decisions From Repository Review

- Chunk only the literal `worldspawn` in v1. `func_group` represents authored layers and retains its
  current entity-local output.
- Partition generated brush and patch geometry, not recovered `ArrayMesh` surfaces.
- Use `(entity index, primitive ordinal, primitive kind, source array index)` for deterministic item
  identity. Disk bake does not currently retain `TBMapDocument` IDs after reparsing.
- Preserve map texture registration order inside every chunk.
- Separate collision construction before producing multiple visual meshes. Collision remains one
  entity-level pass and retains legacy names.
- Compute entity smoothing before partitioning or from shared source adjacency. Smoothing each chunk
  independently would introduce boundary seams.
- Unwrap UV2 per chunk. Require deterministic valid output and bake/preview parity, not equality with
  the legacy global atlas.
- Expose chunk settings only when scene bake and Built appearance preview share the same output path
  and cache invalidation.

## Delivery Plan

### Phase 0A: Baseline metrics

Status: Implemented

Files:

- `src/builder.h`
- `src/builder.cpp`
- `src/tb_loader.cpp`
- `tests/map_editor/document_suite.gd`

Deliverables:

- Add geometry metrics to successful `build_meshes_checked()` results.
- Record source brush/patch counts, visual triangles, material surfaces, visual chunks, largest chunk
  bounds, collision triangles, collision shapes, partition time, and total build time.
- Lock the existing classic-cube and empty-map baselines without changing generated hierarchy.

Verification:

- Debug extension build passes.
- Document integration suite passes 115,276 checks.

### Phase 0B: Primitive extraction

Status: Implemented

Files:

- Add `src/map/worldspawn_partitioner.h`.
- Add `src/map/worldspawn_partitioner.cpp`.
- Add `tests/map_editor/worldspawn_partitioner_test.cpp` or extend the native map test harness.

Deliverables:

- Build one descriptor for every renderable worldspawn brush and patch.
- Calculate map-space AABB, triangle count, texture indices, primitive ordinal, and source array index.
- Centralize visual texture classification so skip and collision-only geometry cannot affect visual
  bounds.
- Reject non-finite generated geometry.
- Preserve primitive source order and prove triangle/item conservation.
- Do not create nodes or alter bake output.

Verification:

- Focused native extraction suite passes with ASan, UBSan, and leak detection.
- Debug extension build passes.

### Phase 1A: Deterministic partitioner

Status: Implemented

Files:

- `src/map/worldspawn_partitioner.h`
- `src/map/worldspawn_partitioner.cpp`
- `tests/map_editor/worldspawn_partitioner_test.cpp`

Deliverables:

- Implement a fixed-bin top-down SAH partitioner over primitive descriptors.
- Freeze bin count, floating-point comparison tolerance, axis ties, split ties, and final chunk sort.
- Stop on physical extent and triangle targets.
- Keep every brush and patch indivisible.
- Cover empty gaps, overlapping bounds, flat bounds, insertion-order permutations, and large
  coordinates in native tests.

Frozen behavior:

- Settings are map-space `target_extent` and `target_triangles`. Extent must be finite and positive;
  triangles must be positive. Threshold equality stops partitioning.
- Use 16 bins on each axis. Candidate planes divide the center range evenly; item AABB centers on a
  plane go right. Items remain indivisible even when their bounds straddle a plane.
- Normalize bounds by the parent cluster's largest extent. Score child AABB measure weighted by child
  triangle share, add `0.25 * normalized overlap`, and add a `0.01` weighted normalized
  duplicated-material count. AABB measure is half surface area, with a length fallback for lines and
  zero for points.
- A candidate must improve the unsplit AABB score by more than the absolute `1e-12` tolerance.
  Score ties prefer lower overlap, lower absolute triangle imbalance, X then Y then Z, and finally the
  lower split coordinate.
- Canonically sort items by `(entity index, primitive ordinal, primitive kind, source array index)`
  before partitioning and within every chunk. Duplicate identities and invalid descriptors fail.
- Sort final chunks by minimum X/Y/Z, maximum X/Y/Z, then first item identity. Empty input returns no
  chunks. Output is guarded to at most one chunk per input item.
- Phase 1A stops when every physical axis is within `target_extent` and triangle count is within
  `target_triangles`, or when no non-empty lower-cost split exists. It does not isolate oversized
  items, merge sparse chunks, or enforce the future public hard budget.

Verification:

- Native ASan/UBSan/leak suite covers separated clusters and empty gaps, exact and exceeded
  thresholds, overlapping and straddling AABBs, flat and zero-extent bounds, source-order
  permutations, axis and split ties, split-side behavior, invalid settings/items, and large finite
  coordinates.
- Item occurrence, visual triangle totals, and material unions are conserved.
- Focused native sanitizer suite and debug extension build pass. Final integration passes on an
  isolated build of the exact repository-pinned Godot editor.

### Phase 1B: Oversized and budget policies

Status: Implemented

Deliverables:

- Isolate oversized items from normal clusters.
- Regionally merge oversized items only when AABB inflation remains low.
- Merge sparse adjacent chunks.
- Enforce the hard budget with deterministic lowest-cost merges.
- Report oversized, sparse, budget, and forced nonadjacent merge counts.

Frozen behavior:

- `max_chunks` defaults to 512 and must be positive. It is a hard post-partition limit; soft extent
  and triangle limits may be exceeded to satisfy it.
- An item is oversized when any extent is strictly greater than `target_extent` or its triangle count
  is strictly greater than `target_triangles`. Oversized items never enter normal SAH clustering.
- Oversized chunks are regional peers only when their interval gap on every axis is at most 25% of
  `target_extent`, their union AABB measure is at most 1.25 times the sum of their existing AABB
  measures, and the merge strictly lowers instance cost. To prevent transitive region growth, union
  span on each axis may not exceed the largest original member span on that axis plus 25% of
  `target_extent`; merged bounds never become the next round's span allowance. This fixed rule also
  handles planes and lines through the Phase 1A lower-dimensional measure; coincident points may
  merge, while separated points do not.
- Closed AABBs are adjacent when their intervals touch or overlap on all three axes. The same rule is
  used for volumetric, flat, linear, and point bounds without scale-dependent epsilon.
- Merge cost is `1 + normalized AABB measure * triangle share + 0.01 * material count`, where AABB
  measure is normalized by `target_extent` and triangle share by `target_triangles`. Sparse merging
  repeatedly chooses the lowest-cost adjacent pair of normal leaves only when its union remains
  within both soft limits and strictly lowers this cost.
- Normal SAH splitting may create only the number of normal leaves left by the hard budget after
  regional oversized grouping. If oversized groups already consume the budget, normal items remain
  one leaf and final budget enforcement resolves the unavoidable excess.
- Hard-budget merging repeatedly chooses the globally lowest-cost pair, regardless of adjacency, and
  reports every selected nonadjacent pair. Budget merges may override oversized isolation and soft
  limits.
- Merge score ties use the absolute `1e-12` tolerance, then union bounds, union source identities, and
  pair source identities. Chunks and items retain the Phase 1A canonical final ordering.
- Results report oversized input item count and the subset still emitted as singleton isolated
  oversized chunks separately, plus sparse merge count, budget merge count, selected nonadjacent
  merge count, and final chunks with unmet soft limits. Checked derived calculations reject invalid
  center, extent, AABB measure, score, triangle, texture-count, or membership arithmetic. A final guard
  verifies every item occurs once and the input triangle total is conserved.

Verification:

- Native sanitizer coverage includes oversized isolation, colocated and distant oversized peers,
  bounded long chains, sparse merging, split-time budget caps, globally cheapest hard-budget merges,
  forced distant merges, `max_chunks = 1`, merge permutations and ties, flat adjacency, impossible
  soft limits, derived arithmetic failures, metrics, validation, and item/triangle conservation.

### Phase 2A: Separate visual and collision plans

Status: Implemented

Files:

- `src/builder.h`
- `src/builder.cpp`
- `src/map/surface_gatherer.h`
- `src/map/surface_gatherer.cpp`

Deliverables:

- Extract collision gathering and node creation from `build_entity_mesh()`.
- Preserve `entity_<index>_geometry_<surface>_col` collision names.
- Generate collision exactly once regardless of visual chunk count.
- Add arbitrary brush/patch inclusion to gathering, or replace repeated gathering with one visual
  accumulation pass keyed by chunk and texture.
- Avoid `O(chunks * textures * geometry)` rescanning and per-element allocator churn.
- Keep disabled output and collision arrays unchanged.

Verification:

- Native sanitizer coverage compares one-pass combined surfaces byte-for-byte with legacy gathering
  and covers efficient arbitrary source-primitive inclusion.
- Integration coverage was added for ordinary and special collision categories, stable names,
  body classes/layers, visual exclusion, collision-disabled builds, visual previews, `func_group`,
  `nocollision`, custom brush entities, and `ColliderType::Mesh`.
- Focused worldspawn and document sanitizer suites and the debug extension build pass. Final pinned
  document integration passes.

### Phase 2B: Internal chunk mesh generation

Status: Implemented

Deliverables:

- Build one `ArrayMesh` and `MeshInstance3D` per partition result.
- Preserve material order, visual layers, filtering, UV0, normals, and tangents.
- Apply source-consistent smoothing to all chunks.
- Run UV2 unwrap and static GI setup per chunk.
- Use stable zero-padded chunk names and generated ownership.
- Keep the feature internally disabled until integration tests pass.

Verification:

- Native coverage includes arbitrary chunk primitive lists, checked surface-plan size/index arithmetic,
  mirrored UVs, hard-edge tangent provenance, and entity-wide same-material smoothing across a
  partition boundary.
- Integration coverage was added for deterministic names/order, conservation, filtering, literal
  worldspawn gating, collision independence, smoothing, UV2/static GI, ownership, packing, metrics,
  legacy `_phong` plus `smooth`/`soft` composition, custom point PackedScene smoothing, tangent parity,
  and transactional failure retention. The pinned document suite passes 115,594 checks.
- The internal activation seam is not an inspector property and defaults off. Phase 2C remains
  responsible for validated public settings and enabling user-facing output.

### Phase 2C: Public settings and preview parity

Status: Implemented

Files:

- `src/tb_loader.h`
- `src/tb_loader.cpp`
- `doc_classes/TBLoader.xml`
- `addons/tbloader/src/editor/camera_view.gd`

Deliverables:

- Bind enabled, target extent, target triangles, and maximum chunk settings.
- Validate settings before staging output.
- Add `worldspawn_` settings to Built appearance cache invalidation.
- Enable identical chunk construction for scene bake and Built appearance preview.
- Keep defaults off until benchmark gates pass.

Verification:

- Public defaults, inspector order/ranges, PackedScene serialization, enabled setting validation,
  transactional bake/preview retention, hierarchy and stable names/order are covered by integration
  tests.
- Bake and Built appearance preview use the same validated Builder settings and are covered for exact
  surface/material parity, literal-worldspawn gating, unchanged `func_group`, collision independence,
  per-chunk UV2/static GI, ownership, and the disabled legacy hierarchy.
- Focused worldspawn and document sanitizer suites, the debug extension build, and final pinned
  document integration pass.

### Phase 3: Integration and reporting

Status: Implemented

Deliverables:

- Report chunk metrics and forced-policy warnings in editor build feedback.
- Verify packed scenes, ownership, transactional failure retention, and editor Undo/Redo.
- Verify hidden layers, special textures, patches, smoothing, UV2, and material resources.
- Verify repeated builds produce stable names, membership, surfaces, and child ordering.

Implementation notes:

- Successful spatial-toolbar and Map Editor checked bakes report worldspawn chunk and triangle counts
  when chunking is enabled. Disabled builds retain the existing concise feedback.
- Feedback warns about oversized items, hard-budget merges, forced nonadjacent merges, and chunks which
  still exceed soft limits without changing the checked `Result` schema.
- Smoothed worldspawn normals are computed across complete material surfaces. Tangents are regenerated
  on provenance-preserving primitive/material surfaces before chunk combination, and UV2 unwrap carries
  those attributes without ambiguous position/UV matching.
- Integration coverage exercises enabled/disabled hierarchy, deterministic rebuilds, packing and
  ownership, transactional failures, editor Undo/Redo, filtering, patches, smoothing, UV2/GI,
  materials, and Built appearance parity. The exact-pinned document suite passes 115,594 checks.

### Phase 4: Renderer benchmark and tuning

Status: Implemented and measured; acceptance gates failed, feature remains default-off

Deliverables:

- Add deterministic indoor, mixed, and open benchmark maps with fixed camera positions.
- Compare one mesh with approximately 50, 200, 500, and 1,000 chunks.
- Record frame, render CPU/GPU, draw calls, rendered objects, primitives, memory, bake time, node count,
  and packed scene size.
- Tune defaults only from measured results.
- Keep the feature experimental if occluded views do not improve enough to justify fully visible cost.

Implementation notes:

- `tests/worldspawn_benchmark/generate_fixtures.py` generates hash-checked indoor, mixed, and open maps
  with fixed fully visible, frustum-limited, and explicitly occluded cameras.
- `renderer_runner.py` runs the legacy and approximately 50/200/500/1,000 chunk profiles in isolated
  displayed processes and captures raw samples, median/p95 renderer counters, memory, bake/partition,
  hierarchy, surfaces, actual chunks, and packed size. It has no headless fallback, strictly gates the
  engine pin, and labels the explicit unpinned mode non-acceptance.
- The separate native benchmark measured cubic forced-budget pair merging: 512 items took a 7,741 ms
  median before optimization. Cached candidates with lazy invalidation reduced the identical case to
  176 ms; 1,024 items complete at a 641 ms median. Fingerprints remain stable where policy semantics
  are unchanged; split-capped normal cases and global-cost budget cases intentionally change output.
- The corrected exact-pinned matrix explicitly disables and verifies project/runtime VSync, rejects
  refresh-capped samples, enables project/root occlusion, and proves each fixed occluder rejects an
  isolated object before measuring. It includes three ancillary enabled provisional-default runs.
- Provisional defaults fail all performance gates as a set: +11.4% open visible frame time, +29.0%
  indoor occluded render CPU, and +96.2% indoor bake time. No settings or defaults were tuned from the
  failed matrix, and the enable flag remains false. See `WORLDSPAWN_CHUNKING_BENCHMARKS.md`.

## Immediate Next Step

Keep chunking experimental and disabled by default. Any future tuning needs a new exact-pinned matrix
and must satisfy every PRD gate rather than relying on chunk count or GPU time alone.
