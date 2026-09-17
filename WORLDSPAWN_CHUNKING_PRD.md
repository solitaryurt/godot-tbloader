# TBLoader Worldspawn Mesh Chunking PRD

Status: Draft

Audience: implementation engineer / LLM

Related documents:

- `PRD.md` defines the broader geometry optimization and regeneration direction.
- `MAP_EDITOR_PRD.md` defines `.map` authoring and treats generated nodes as disposable output.
- `MATERIAL_PREVIEW_PRD.md` requires built preview geometry to match the bake path.

## 1. Problem

`Builder::build_worldspawn()` currently calls `Builder::build_entity_mesh()` once. The result is one
visual `MeshInstance3D` containing all renderable worldspawn geometry, with materials represented as
mesh surfaces. Collision is emitted separately by gameplay surface type.

A map-wide mesh has a map-wide AABB. When the camera is inside or can see any part of that AABB,
Godot generally cannot reject the instance through frustum or occlusion culling. Walls can contribute
to an occluder bake, but geometry behind those walls remains part of the same visible render instance.

Creating one node per brush would provide fine bounds but would replace the culling problem with
potentially thousands of scene nodes, rendering instances, and material surfaces. TBLoader needs a
bounded middle ground: spatially compact visual chunks that are substantially larger than renderer
meshlets and substantially smaller than the whole map.

## 2. Product Outcome

Add optional deterministic spatial chunking for built worldspawn visual geometry.

When enabled, the literal `worldspawn` container owns a bounded set of spatially coherent `MeshInstance3D`
children. Godot can cull each child independently. Chunk construction preserves the visual output,
material resolution, source geometry, lighting options, generated ownership, and transactional bake
behavior of the existing builder.

Collision generation remains independently partitioned. The first delivery does not implement PVS,
portals, meshlets, streaming, or runtime visibility scripts.

## 3. Goals

- Give worldspawn geometry useful per-instance bounds for Godot frustum and occlusion culling.
- Keep the normal result in the tens or low hundreds of chunks, with a configurable hard budget.
- Preserve each brush and patch as an indivisible geometry item in the first delivery.
- Isolate or regionally group oversized items instead of allowing them to contaminate ordinary chunk
  bounds.
- Keep collision node count and collision behavior independent from visual chunk count.
- Preserve visual triangle attributes, material assignment, smoothing, render layers, UV2 behavior,
  and source provenance.
- Produce deterministic chunk membership, child ordering, and names.
- Expose build metrics needed to tune the partitioner against real maps.
- Demonstrate an occluded-view improvement without an unacceptable fully visible regression.

## 4. Non-goals

- Do not reproduce Source 2 meshlets or add renderer-level geometry culling.
- Do not compile a BSP, PVS, portal graph, room graph, or visibility voxel field.
- Do not split or clip brush faces at chunk boundaries in the first delivery.
- Do not create one visual node per brush or per material.
- Do not use `MultiMesh`; generated chunks contain unique geometry.
- Do not replace `MeshInstance3D` nodes with direct `RenderingServer` RIDs before profiling proves the
  SceneTree layer is a material cost.
- Do not change `func_group`, `nocollision`, custom point, or custom brush entity output in the first
  delivery.
- Do not automatically configure or bake Godot `OccluderInstance3D` resources.
- Do not promise that chunking improves every open or fully visible scene.

## 5. Current Behavior

The relevant build path is:

1. `TBLoader::build_meshes_checked()` validates into a staging `Node3D`.
2. `Builder::build_map()` visits each map entity.
3. `Builder::build_worldspawn()` creates the entity container.
4. `Builder::build_entity_mesh()` creates one visual `MeshInstance3D`.
5. `LMSurfaceGatherer` gathers entity geometry by texture into `ArrayMesh` surfaces.
6. Collision-only textures are excluded from the visual mesh and gathered into collision meshes.
7. A successful build atomically replaces the loader's generated children.

For the actual `worldspawn`, the container is named `Default Layer`. The visual mesh is currently
named `entity_<entity index>_geometry`. `func_group` and common brush entities may use the same helper,
but their behavior is outside the first chunking delivery. The implementation must gate chunking on
`classname == "worldspawn"`, not merely on entry through `build_worldspawn()`.

The geometry cache already retains brush and patch boundaries in `LMEntityGeometry`. Partitioning
must operate from that source structure rather than attempting to recover brushes from a globally
gathered mesh.

## 6. User Experience and Configuration

Add a **Worldspawn Chunking** inspector group to `TBLoader`.

| Property | Type | Initial default | Meaning |
|---|---:|---:|---|
| `worldspawn_chunking_enabled` | `bool` | `false` | Build spatial visual chunks instead of one worldspawn mesh. |
| `worldspawn_chunk_size` | `double` | `24.0` | Target maximum chunk extent in Godot world units. |
| `worldspawn_chunk_triangles` | `int` | `15000` | Soft target triangle count per chunk. |
| `worldspawn_max_chunks` | `int` | `512` | Hard visual chunk budget per worldspawn entity. |

Defaults are provisional and must be tuned with the benchmark matrix in this document.

Chunking initially defaults off to preserve shipped node paths, lightmap output, scene size, and
render characteristics. The default may change only after representative project testing and a
documented migration note.

Invalid non-positive sizes, triangle targets, or chunk budgets make `build_meshes_checked()` fail
with `INVALID_ARGUMENT` before replacing existing output.

After a successful build, the result value and editor feedback should include:

- worldspawn visual triangle count;
- input brush and patch item counts;
- final visual chunk count;
- oversized input item count and the subset emitted as isolated singleton chunks;
- total generated material surface count;
- largest chunk extent and triangle count;
- partition and total bake duration when timing is available.

When the requested thresholds cannot be met because one indivisible item exceeds them, the build
succeeds and reports that item as oversized. Exceeding the hard chunk budget must trigger deterministic
least-cost merges, not silent truncation or missing geometry.

## 7. Spatial Item Model

The partitioner consumes visual geometry items, not Godot nodes.

Each worldspawn brush becomes one item containing:

- entity index, source primitive ordinal, primitive kind, and source brush/patch array index;
- AABB over renderable vertices after skip and collision-only filtering;
- visual triangle count;
- set of visual material/texture IDs;
- references needed to gather its faces into a final chunk.

Each renderable worldspawn patch becomes one equivalent item. Empty and collision-only items do not
participate in visual partitioning.

All item AABBs and partition calculations must use one coordinate space consistently. Public size
configuration is in Godot units; implementation may partition in map space by multiplying thresholds
by `inverse_scale`. Entity and loader transforms must not change membership.

Document IDs may be retained as diagnostics, but disk bake currently reparses exported text and must
not depend on those IDs being populated. Primitive ordinal and source array index are the v1 stable
ordering keys.

An item is oversized when any AABB extent exceeds `worldspawn_chunk_size` or its triangle count
exceeds `worldspawn_chunk_triangles`. Oversized is a classification, not an error.

## 8. Partitioning Algorithm

### 8.1 Normal items

Use a deterministic top-down spatial partitioner based on a binned surface-area heuristic (SAH).
A k-d/BVH-style partition is preferred over a fixed grid because it can choose empty gaps, adapts to
uneven map density, and evaluates complete brush bounds rather than only brush centers.

For each candidate axis and split bin, classify whole items by AABB center and evaluate a cost derived
from:

```text
left AABB surface area  * left triangle count
+ right AABB surface area * right triangle count
+ AABB overlap penalty
+ material proliferation penalty
```

The exact normalized weights are implementation details but must be fixed constants covered by
determinism tests. Prefer, in order:

1. lower total score;
2. lower child AABB overlap;
3. better triangle balance;
4. axis order X, Y, Z;
5. lower split coordinate.

Split a cluster when its physical extent or triangle count exceeds its target and a non-empty,
lower-cost split exists. Never split a source item. Stop when thresholds are met, no valid split
exists, or further splitting would exceed the chunk budget.

Use bounded bins rather than testing every possible plane so partitioning remains near
`O(n log n)` for ordinary inputs. No output may depend on pointer addresses, hash iteration order, or
locale-sensitive string ordering.

### 8.2 Oversized items

Do not place oversized items into normal clusters. This prevents a large floor, sky shell, or facade
from expanding an otherwise useful chunk AABB.

Oversized items may be grouped only when all of the following hold:

- their AABBs overlap or occupy the same local region;
- the combined AABB does not materially inflate their existing bounds;
- grouping does not exceed the remaining hard chunk budget policy;
- the merge has lower estimated render-instance cost without reducing spatial culling utility.

Use the same deterministic AABB cost model for these merges. Do not create one global "oversized"
chunk. An oversized item with no beneficial regional peer remains isolated. Large high-detail items
remain indivisible in v1 and should be reported as candidates for future face subdivision.

### 8.3 Sparse merge and budget enforcement

After top-down partitioning, merge sparse sibling or spatially adjacent chunks when the union:

- remains within target extent and triangle thresholds;
- has acceptably low AABB inflation and overlap;
- does not create excessive material surfaces.

If output still exceeds `worldspawn_max_chunks`, repeatedly perform the lowest-cost merge until the
budget is met. The hard budget takes precedence over ordinary adjacency and oversized-isolation rules;
any forced nonadjacent merge must be counted and reported in build diagnostics. Default partitioning
must never merge distant oversized items when the hard budget does not require it.

Do not merge nonadjacent chunks merely because they share a material.

## 9. Mesh Construction

For every final chunk:

- Create one `ArrayMesh` and one `MeshInstance3D`.
- Gather only items assigned to that chunk.
- Group geometry by texture/material using the existing material resolution and filtering rules.
- Preserve all currently emitted arrays: positions, indices, UVs, normals, and tangents. Colors and
  generated-mesh provenance require separate data-model work if introduced later.
- Preserve deterministic texture and surface ordering.
- Apply the effective visual or skybox layer mask exactly as the unchunked path does.
- Apply smoothing to every applicable chunk, not only the first child of the entity container.
- Run UV2 unwrap independently for each non-empty chunk when enabled.
- Set static GI mode consistently with current behavior.
- Remove empty chunk instances when `skip_empty_meshes` is enabled.

Names must be stable:

```text
entity_<entity index>_geometry_chunk_<zero-padded ordinal>
```

Ordinals are assigned by deterministic spatial order, then stable source identity as a tie-breaker.
If chunking produces one mesh, it may retain `entity_<entity index>_geometry` only if doing so does
not complicate deterministic tests or built-preview parity. The implementation must choose and
document one behavior rather than vary it by incidental partition state.

Generated ownership must remain compatible with staging, scene packing, Undo/Redo replacement, and
`build_meshes_checked()` failure retention.

## 10. Collision Independence

Visual partitioning must not multiply collision bodies or change gameplay surface classification.

In the first delivery:

- gather collision geometry once per entity using the existing collision surface categories;
- preserve `StaticBody3D` versus `Area3D` behavior;
- preserve collision and clip layer masks;
- preserve concave shape generation and debug colors;
- preserve collision-only texture behavior;
- keep collision naming deterministic and independent of visual chunk ordinals.

Future collision spatialization requires separate profiling and a separate product decision. Visual
chunk size is not automatically an appropriate physics broadphase partition size.

## 11. Compatibility and Behavioral Rules

- With chunking disabled, generated output must retain existing behavior.
- Chunking changes disposable generated children only; source `.map` text and `TBMapDocument` state
  remain unchanged.
- Failed partitioning or mesh construction must leave the previous generated output intact.
- Hidden-layer, skip, clip, ladder, cushion, no-wall-jump, and skybox behavior must remain unchanged.
- Material resolution failure must retain current checked-build diagnostics.
- Built appearance preview must use the same chunk construction or an explicitly node-free equivalent
  with identical visual surfaces and attributes.
- Selection and picking must continue to resolve generated triangles to source entities, brushes, and
  faces where provenance is supported.
- Entity-level smoothing properties must apply across all generated chunks. Smoothing inputs must be
  computed before partitioning, or from shared source adjacency, so chunk boundaries do not create
  normal seams. The implementation must not merely smooth each finished chunk independently.
- Per-chunk UV2 unwrap must be valid and deterministic for identical input and settings. Its packed
  UV2 arrays are not required to match the legacy entity-wide unwrap because independent atlases
  necessarily change island packing and may change vertex/index layout.
- Direct edits to generated chunk nodes are not preserved across rebuilds.

## 12. Performance Requirements

Node count is a guardrail, not the success metric. Every chunk adds a SceneTree node, a rendering
instance, culling metadata, and usually one surface per represented material. The primary tradeoff is:

```text
better spatial rejection versus more visible instances and material surface submissions
```

Benchmark at minimum:

1. Existing single worldspawn mesh.
2. Chunking tuned for approximately 50 chunks.
3. Chunking tuned for approximately 200 chunks.
4. Chunking tuned for approximately 500 chunks.
5. An intentionally excessive configuration approaching 1,000 chunks.

Use at least one indoor corridor/room map, one mixed indoor/outdoor map, and one mostly open map.
Capture warm-run medians and a high percentile for:

- total frame time, render CPU time, and render GPU time;
- draw calls, rendered objects, primitives, and material surface count;
- bake time and partition time;
- generated node count and packed scene size;
- process memory where stable measurement is available;
- chunk count, AABB extent distribution, and triangles per chunk;
- fully visible, frustum-limited, and heavily occluded camera positions.

Initial acceptance gates on the reference hardware are:

- no missing or duplicated visual triangles;
- no more than 10% median frame-time regression in the open, fully visible case;
- at least 20% median render-time improvement in the representative heavily occluded indoor case;
- no more than 50% bake-time regression at the provisional defaults;
- final chunk count never exceeds the configured hard budget;
- repeated builds produce identical membership, names, surfaces, and serialized scene order.

If the indoor improvement gate cannot be reached without violating the fully visible gate, keep the
feature experimental and default off. Do not infer success from chunk count or occlusion intuition
alone.

## 13. Functional Acceptance Criteria

- A sufficiently large worldspawn builds multiple spatially compact `MeshInstance3D` children when
  chunking is enabled.
- Disabling chunking restores the existing single-mesh path.
- Every renderable source triangle appears exactly once in chunked output.
- Visual bounds, materials, UV0, normals, tangents, and render layers match unchunked output. UV2 is
  valid per chunk and matches built-preview output rather than the legacy global atlas layout.
- Clip-only and skip geometry does not appear in visual chunks.
- Collision shape geometry, categories, masks, and body types match unchunked output.
- A large brush does not expand normal chunk bounds and remains isolated when no compact regional
  merge exists.
- Nearby oversized brushes may merge; distant oversized brushes merge only when explicit hard-budget
  enforcement requires a reported forced merge.
- Chunk output remains at or below `worldspawn_max_chunks`.
- UV2 unwrap and static GI mode apply to every eligible chunk.
- Entity smoothing applies correctly to all chunks and never assumes child index zero is the only
  mesh.
- A failed build preserves the prior generated hierarchy.
- Packed scenes preserve all generated chunks and ownership.
- Built appearance and scene bake render equivalent visual geometry.
- Two builds of identical input and settings produce byte-stable ordering where Godot serialization
  permits it.

## 14. Test Plan

### 14.1 Native partitioner tests

Add isolated tests for:

- empty, one-item, and all-collision-only inputs;
- deterministic axis and split tie-breaking;
- dense clusters separated by empty space;
- overlapping and straddling AABBs;
- sparse sibling merges;
- oversized isolation and regional oversized merging;
- hard-budget merge behavior;
- degenerate flat and zero-extent bounds;
- very large coordinates and finite-value validation;
- repeatability under different insertion orders;
- conservation of item IDs and triangle counts.

### 14.2 Bake integration tests

Extend the existing map editor/document bake coverage to verify:

- inspector property binding and round-trip serialization;
- enabled and disabled hierarchy shape;
- material and attribute parity against unchunked output;
- collision parity;
- smoothing across multiple chunks;
- UV2 behavior;
- generated ownership after scene packing;
- failed-build retention;
- hidden layer and special texture filtering;
- built-preview parity;
- stable rebuild names and ordering.

### 14.3 Performance fixtures

Check in deterministic generated `.map` fixtures or fixture generators for the three required map
types. Performance tests must report results rather than use fragile absolute timing assertions in
ordinary CI. Correctness, chunk budget, and determinism remain hard CI assertions.

## 15. Delivery Phases

### Phase 0: Baseline and instrumentation

- Record current single-mesh hierarchy, triangle/material counts, collision output, bake duration,
  and representative rendering metrics.
- Add build-result geometry metrics without changing output.

### Phase 1: Pure partitioner

- Introduce the spatial item representation and deterministic SAH partitioner.
- Add oversized handling, sparse merging, hard-budget enforcement, and native tests.
- Keep the partitioner independent of Godot node creation.

### Phase 2: Visual bake integration

- Add `TBLoader` configuration and checked validation.
- Build chunked worldspawn meshes while retaining the legacy disabled path.
- Preserve collision generation independently.
- Fix all code that assumes an entity has exactly one mesh child.

### Phase 3: Preview, reporting, and persistence

- Match built appearance preview output.
- Surface chunk metrics and warnings.
- Verify scene packing, Undo/Redo build replacement, and inspector serialization.

### Phase 4: Benchmark and tune

- Run the complete benchmark matrix.
- Tune provisional defaults and cost weights.
- Keep default off unless all acceptance gates pass on representative maps.
- Document recommended profiles for indoor, mixed, and open maps.

## 16. Future Work

- Face or triangle subdivision for oversized high-detail brushes.
- Authored visibility hints or room/portal volumes.
- PVS generation that toggles the same chunk instances.
- Hierarchical chunks for streaming or HLOD.
- Dedicated collision partition policies.
- Renderer-level meshlet support if exposed by Godot in a suitable API.
- Direct `RenderingServer` instances if profiling identifies SceneTree overhead rather than render
  instance or draw-submission overhead.
- Automatic threshold selection from map density and camera-scale metadata.

## 17. External Design Evidence

- Godot documents SceneTree overhead as project- and platform-dependent, becoming a concern at large
  node counts rather than at a fixed universal threshold:
  <https://docs.godotengine.org/en/4.5/tutorials/performance/cpu_optimization.html#scenetree>
- Godot explicitly describes the batching-versus-individual-culling tradeoff for static 3D meshes:
  <https://docs.godotengine.org/en/4.5/tutorials/performance/gpu_optimization.html#d-batching>
- `MeshInstance3D` creates an individual rendering instance:
  <https://docs.godotengine.org/en/4.5/classes/class_meshinstance3d.html>
- Source 2's voxel visibility and meshlet pipeline is useful architectural context, but TBLoader must
  not equate renderer-level meshlets with Godot scene nodes:
  <https://s2v.app/SchemaExplorer/cs2/worldrenderer/CVoxelVisibility>
