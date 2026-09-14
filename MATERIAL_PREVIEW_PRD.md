# TBLoader Built Material Preview PRD

Status: Draft

Audience: implementation engineer / LLM

Related documents:

- `MAP_EDITOR_PRD.md` defines the in-Godot `.map` authoring workflow.
- `PRD.md` defines persistent overrides, normal editing, and the broader material workspace.
- `MAP_EDITOR_IMPLEMENTATION.md` documents the current material resolver and preview behavior.

## 1. Problem

The Map Editor camera resolves Godot `Material` resources and textures, but it does
not render the same visual output that `TBLoader::build_meshes()` creates. The
camera reconstructs a simplified, globally texture-grouped mesh from
`TBMapDocument::get_preview_data()`, while the builder creates entity-scoped,
indexed surfaces with additional attributes and filtering.

This distinction becomes visible with:

- normal-mapped materials, because camera meshes have no tangents;
- `_phong`, `smooth`, or `soft` shading, because camera normals remain flat;
- patches, which are absent from the camera preview;
- transparent materials, whose instance and surface boundaries affect sorting;
- clip, skip, hidden-layer, and skybox behavior;
- custom `ShaderMaterial` resources;
- UV2, lightmapping, GI, and scene rendering context.

Users need an optional preview that answers: "What will the visual map geometry
look like after I build this loader?" They must still be able to return to the
fast, selection-oriented authoring preview.

## 2. Product Outcome

Add a camera-local **Built appearance** toggle to the Map Editor.

When disabled, the existing authoring preview remains available. When enabled,
the camera renders transient visual geometry produced by the same native rules as
the TBLoader build path, using the current in-memory map document and the bound
loader's material and build configuration.

The preview must not bake nodes into the edited scene, modify the `.map`, create
undo history, or require the map to be saved.

## 3. Goals

- Render the same resolved Godot materials and textures used by a successful bake.
- Share visual mesh construction with `Builder`; do not maintain a second parity
  implementation in GDScript.
- Preview unsaved document edits.
- Match built visual surfaces, indices, UVs, normals, tangents, patches, smoothing,
  filtering, transforms, and render layers.
- Show the effective `WorldEnvironment` sky from the bound loader's edited scene
  when one is available.
- Preserve fast camera navigation, selection, overlays, and authoring tools.
- Make mode changes deterministic and non-destructive.
- Report preview failures without replacing the last valid camera result.
- Keep repeated refreshes responsive through revision-based invalidation and
  caching.

## 4. Non-goals

- Do not add generated preview nodes to the edited scene.
- Do not build collision bodies, areas, audio players, or gameplay behavior.
- Do not make preview nodes persistent or user-editable.
- Do not replace the existing authoring and picking geometry.
- Do not guarantee exact baked lightmap or GI output in the first delivery.
- Do not execute arbitrary custom entity scene scripts in the preview viewport.
- Do not infer arbitrary `ShaderMaterial` sampler parameters.
- Do not preserve direct edits made to generated build output.
- Do not turn the camera into a general scene/game preview.

## 5. Current Behavior

### 5.1 Material resolution

`MapEditor.preview_material()` calls the bound loader's native
`resolve_material(token)` method. This already provides strong lookup parity for
ordinary materials and textures:

- exact `res://` resources;
- root-relative `.material`, `.tres`, and `.res` resources;
- legacy extensionless texture lookup;
- companion material precedence;
- configured material templates;
- texture dimensions used by UV generation.

However, the camera duplicates resolved materials, creates a blue fallback for
unresolved tokens, and enables `vertex_color_use_as_albedo` on
`BaseMaterial3D`. The build path does not apply all of those changes.

### 5.2 Preview geometry

`TBMapDocument::get_preview_data()` returns brush vertices, flat face normals,
primary UVs, indices, brush IDs, and face IDs grouped globally by texture.
`camera_view.gd` expands these triangles into spatial chunks.

It does not contain:

- tangents;
- UV2;
- generated `_phong` normals;
- entity-level `smooth` or `soft` output;
- patch surfaces;
- built entity and surface boundaries;
- skybox classification;
- exact visual filtering decisions.

### 5.3 Build geometry

`Builder::build_entity_mesh()` creates one visual `MeshInstance3D` per built
entity, gathers indexed surfaces by texture, assigns resolved materials, removes
collision-only and skip surfaces, optionally unwraps UV2, assigns GI mode, and
uses visual or skybox layer masks.

This native path is the behavioral authority for Built appearance.

## 6. User Experience

### 6.1 Control

Add a toggle beside the camera's existing **Frame** button:

- Label: **Built appearance**
- Off tooltip: "Use the fast authoring preview."
- On tooltip: "Preview visual geometry and materials using TBLoader build rules."

Do not place the toggle in the global tool row. The existing **Texture** control
is an editing mode and must remain distinct from camera rendering mode.

### 6.2 Mode behavior

| Concern | Authoring appearance | Built appearance |
|---|---|---|
| Geometry source | Existing preview data | Shared native visual builder |
| Picking | Existing preview triangles | Existing preview triangles |
| Selection overlays | Visible | Visible |
| Clip/skip surfaces | Existing authoring filters | Match build output |
| Patches | Existing behavior | Rendered |
| Normals/tangents | Authoring attributes | Match build output |
| Materials | Existing preview policy | Exact build material policy |
| Scene mutation | None | None |

Switching modes must preserve:

- camera transform and fly state;
- brush, face, edge, vertex, and entity selection;
- hidden state and visibility filters;
- active tool and material browser state;
- document text, revision, dirty state, and undo history.

The toggle is a UI preference, not document state. It persists while the plugin
instance is alive, including across document/session changes. It does not enter
map recovery records. The initial default is Authoring appearance until built
mode meets its performance acceptance gate.

### 6.3 Loading and failure feedback

While a built preview is being regenerated, retain the last valid result and show
a concise camera status such as `Updating built appearance...`.

If generation fails:

- retain the last valid preview;
- display the native diagnostic in the editor notice/status area;
- visually indicate that Built appearance is stale;
- do not fall back silently to a different material or geometry policy;
- allow the user to return to Authoring appearance immediately.

Standalone documents without a bound loader may use an explicit transient loader
configuration matching TBLoader defaults. The UI must label this as default
configuration rather than implying scene parity.

## 7. Functional Requirements

### 7.1 Exact visual construction

Built appearance must use the same implementation as the bake path for:

- map-to-Godot coordinate conversion and inverse scale;
- entity-local geometry placement;
- brush and patch tessellation;
- surface gathering and indexing;
- primary UV generation and texture dimensions;
- generated normals and tangents;
- source `_phong` and `_phong_angle` behavior;
- entity `smooth` and `soft` behavior;
- skip and collision-only material decisions;
- hidden TrenchBroom layer decisions;
- material resolution and assignment;
- visual and skybox layer masks;
- UV2 generation and static GI mode when enabled.

Any future visual build rule must enter the shared visual pipeline so bake and
preview cannot diverge by default.

### 7.2 Material fidelity

Built appearance must:

- assign the same resolved `Material` resource or generated template result as
  the build path;
- avoid preview-only mutation such as forcing vertex color albedo;
- preserve `BaseMaterial3D`, `ShaderMaterial`, `next_pass`, render priority,
  transparency, culling, depth, and shader render modes;
- use the same unresolved-resource policy as a bake;
- preserve entity and surface boundaries required for transparency sorting;
- use shader global parameters from the project normally;
- use declared instance uniform defaults when no explicit instance override
  exists.

Arbitrary shader sampler discovery is out of scope. A material without a
discoverable albedo texture continues to use the resolver's documented `1x1` UV
dimension fallback unless an explicit future mapping contract is added.

### 7.3 In-memory source

The built preview must consume an immutable snapshot or canonical export of the
active `TBMapDocument`. It must not reopen `map_resource` from disk.

This ensures:

- unsaved geometry and material-token edits are shown;
- preview generation cannot race an external file save;
- the preview corresponds to the document revision displayed by the editor.

### 7.4 Transient output

Preview output must be:

- parented only inside the camera `SubViewport`;
- ownerless and excluded from scene serialization;
- replaceable as one atomic visual result;
- free of collision and gameplay nodes;
- free of tool scripts copied from custom entity scenes.

Custom point/entity scene instantiation is deferred. Brush geometry belonging to
an entity should still preserve the visual mesh organization the builder would
use where this can be done without instantiating gameplay scenes.

### 7.5 Rendering context

The first delivery must support synchronized directional scene lights and the
effective `WorldEnvironment` contained in the bound loader's edited-scene root.
The effective source is determined by identity with the loader's
`World3D.environment`, not by choosing an arbitrary `WorldEnvironment` node. When
that `Environment` uses a sky background and has a valid `Sky`, the camera
viewport must show that same sky, including its material, orientation, custom
field of view, and background energy settings. It must also copy the sky-related
ambient and reflected-light source settings so the sky contributes to PBR
lighting rather than appearing only as a backdrop.

The camera owns its `Environment`; the source `Sky` and dependent resources are
shared read-only because Godot sky resources can be used by multiple rendering
scenarios. The preview must not mutate the scene's `WorldEnvironment`,
`Environment`, `Sky`, or sky material. Changes to those resources must invalidate
or refresh the camera environment without rebuilding map geometry.

If there is no bound scene, active `WorldEnvironment`, valid `Environment`, or
usable sky background, the camera retains its current studio environment. A
missing or unsupported sky is a non-fatal rendering-context limitation, not a
built-geometry failure.

Scene-perfect context is a later phase and includes:

- non-sky `WorldEnvironment` properties;
- `OmniLight3D` and `SpotLight3D`;
- map-generated light entities;
- fog, reflection probes, decals, and GI resources;
- effective ancestor visibility;
- scene camera cull masks;
- tonemapping, adjustments, compositor effects, and `CameraAttributes` exposure.

Built appearance uses Godot's normal lit material pipeline with bake-equivalent
visual mesh attributes, resolved materials, transforms, boundaries, layers, and
filtering. It receives synchronized directional lights plus sky-based ambient and
reflected lighting. It does not claim scene-final lighting, baked GI, probes,
local lights, exposure, fog, or post-processing parity. The UI must not describe
the first delivery as exact lighting or a scene-final preview.

## 8. Architecture

### 8.1 Shared visual build stage

Refactor `Builder` into separable stages:

1. Parse or import a validated map snapshot.
2. Resolve material resources and texture dimensions.
3. Generate geometry.
4. Produce a visual build plan.
5. Instantiate visual nodes.
6. Optionally instantiate collision and gameplay nodes for a real bake.

The visual build plan is shared by preview and bake. It contains enough data to
create exact visual output without scene ownership or gameplay side effects.

Conceptual native structures:

```text
VisualBuildPlan
  entities[]
    source_entity_id
    transform
    layer_mask
    surfaces[]
      texture_token
      material
      arrays[Mesh::ARRAY_MAX]
    gi_mode
```

This is a conceptual contract, not a required public serialization format.

### 8.2 Native preview API

Expose one checked API through `TBMapDocument` or a dedicated native preview
builder. A conceptual signature is:

```text
build_visual_preview(loader_config: Object) -> Result
Result.value = Node3D or transient visual descriptor
```

The API must:

- use the document's current validated map data;
- apply bound loader configuration without mutating the loader;
- return structured errors using the repository's existing Result schema;
- avoid adding children before validation and generation succeed;
- transfer or copy resources with clear ownership;
- be callable repeatedly without leaking native geometry or Godot objects.

Returning a transient `Node3D` is acceptable if all children are ownerless and no
scripts execute. Returning visual descriptors for GDScript instantiation is also
acceptable, but the mesh/material policy must remain native and shared.

### 8.3 Picking separation

Do not ray-pick built preview meshes in the first delivery. Existing preview data
contains stable brush and face provenance and remains the picking authority.

The built visual root and authoring picking data occupy the same map transform.
Selection handles and outlines render above either mode. This avoids coupling
selection correctness to UV2 vertex splits, smoothing, patches, or transparent
surface organization.

### 8.4 Caching and invalidation

The built preview cache key must include:

- document epoch and preview revision;
- material resolver root and configuration;
- bound loader instance/configuration identity;
- inverse scale;
- material template identity and change revision;
- material texture property path;
- resolved material/resource revisions;
- clip, ladder, cushion, no-wall-jump, and skip texture names;
- hidden-layer and empty-mesh options;
- visual and skybox layer masks;
- UV2 and unwrap texel-size settings;
- smoothing/normal override revision when that feature exists;
- active rendering mode.

Sky/environment invalidation is tracked separately from visual geometry. It uses
the source node/resource identities, relevant property signatures, and
`Resource.changed` signals for the effective `WorldEnvironment`, `Environment`,
`Sky`, sky material, and dependent sky resources.

Selection, camera movement, overlays, and status changes must not regenerate built
geometry.

Resource change signals must invalidate explicit loaded materials as well as the
configured template. A stale duplicated material cache is not acceptable in Built
appearance.

## 9. Performance Requirements

- Toggling to a valid cached mode should complete within one rendered frame.
- Camera movement and selection changes must not rebuild visual geometry.
- Generation should replace the visible root only after a complete valid result
  exists.
- Repeated A-B-A mode and session switching must not increase retained preview
  node or mesh counts.
- A 256-brush fixture should remain interactive while built appearance is visible.
- Measure generation latency and peak memory for 32, 256, and representative real
  maps before making Built appearance the default.

Asynchronous generation is desirable but not required for the first functional
delivery if native map data cannot yet be copied safely across threads. If work
remains synchronous, the UI must avoid redundant rebuilds and expose progress for
operations that exceed perceptible latency.

## 10. Testing Requirements

### 10.1 Native parity tests

For the same document and loader configuration, compare bake and built preview:

- entity visual mesh count;
- surface count and texture token ordering;
- vertex, normal, tangent, UV, UV2, and index arrays;
- material resource identity or equivalent generated material state;
- layer masks and GI mode;
- patch triangle counts;
- clip/skip/hidden-layer omission;
- `_phong`, `smooth`, and `soft` normals;
- loader and entity transforms.

Fixtures must include opaque, transparent, normal-mapped, ShaderMaterial, patch,
skybox, clip, skip, hidden-layer, and unresolved-material cases.

### 10.2 Editor integration tests

Verify that:

- the toggle is camera-local and defaults to Authoring appearance;
- changing mode does not alter document text, revision, dirty state, selection,
  recovery data, or undo history;
- unsaved edits appear in Built appearance;
- camera movement and selection reuse built geometry;
- switching sessions cannot reuse another loader's materials;
- A-B-A switching restores identical visual signatures;
- failure retains the last valid result and exposes a diagnostic;
- toggling back restores the authoring preview and picking behavior;
- the active scene sky refreshes without regenerating map geometry;
- removing or invalidating the active scene sky restores the studio environment;
- multiple `WorldEnvironment` nodes resolve to the environment actually active in
  the loader's `World3D`;
- replacing the source environment or changing a nested sky dependency refreshes
  the sky while preserving preview mesh instance IDs;
- plugin teardown frees all transient preview resources.

### 10.3 Rendered tests

Add displayed fixtures or image comparisons for:

- albedo texture orientation and scale;
- normal-map response under directional light;
- smooth versus hard edges;
- alpha blend/cutout behavior;
- two transparent entities at different depths;
- patch material rendering;
- custom ShaderMaterial behavior;
- visual and skybox layer culling;
- panorama, procedural, and physical scene skies where supported by Godot;
- studio-environment fallback when the scene has no usable sky.

Image tests must use controlled renderer, viewport size, camera, environment, and
light settings, with separate Compatibility and Forward+ baselines. Structural
geometry/material assertions remain authoritative when renderer output varies
across hardware.

## 11. Delivery Plan

### Phase 1: Shared visual data

- Separate visual construction from collision/gameplay construction in `Builder`.
- Accept in-memory validated document data.
- Add complete surface parity tests.
- Correct tangent regeneration after smoothing before claiming normal-map parity.

### Phase 2: Transient built preview

- Add the checked native preview API.
- Instantiate ownerless visual output under the camera viewport.
- Preserve authoring geometry for picking and overlays.
- Implement atomic replacement and failure retention.

### Phase 3: Camera toggle and lifecycle

- Add **Built appearance** beside **Frame**.
- Add cache keys and material/resource invalidation.
- Synchronize the active scene `WorldEnvironment` sky into a preview-owned
  environment with studio fallback.
- Verify session switching, recovery exclusion, teardown, and performance.

### Phase 4: Rendering context parity

- Synchronize remaining environment properties and all relevant light classes.
- Add map-generated lights and effective scene visibility.
- Evaluate GI, probes, fog, exposure, and scene cull-mask support.

### Phase 5: Advanced shader contracts

- Define explicit sampler-to-UV-dimension mapping for arbitrary ShaderMaterials.
- Define stable entity/surface instance-uniform overrides.
- Integrate persistent material and normal overrides from `PRD.md`.

## 12. Acceptance Criteria

The first complete release is accepted when:

1. A user can toggle between Authoring and Built appearance without modifying the
   map, scene, selection, or undo history.
2. Built appearance renders unsaved map edits using the bound loader's exact
   material resolution policy.
3. Built preview and bake produce matching visual mesh arrays, materials, entity
   boundaries, filters, transforms, and render layers for supported fixtures.
4. Patches, source smoothing, tangents, and normal-mapped materials are represented
   correctly.
5. Clip, skip, and hidden build-only surfaces do not appear in Built appearance.
6. Transparent material fixtures preserve bake-equivalent instance and surface
   organization.
7. Failed generation retains the previous valid preview and reports the reason.
8. Camera movement, selection, and overlays do not regenerate built geometry.
9. Repeated mode/session switching and plugin teardown produce no retained-node or
   native-memory growth.
10. A usable sky from the effective scene `WorldEnvironment` appears in the
    camera, contributes visible reflected-light response to PBR materials, updates
    independently of map geometry, and falls back safely when unavailable.
11. The UI accurately describes the rendering context and does not claim exact
    baked GI before that phase is delivered.

## 13. Risks and Open Decisions

- `ArrayMesh::lightmap_unwrap()` may reorder or split vertices. Decide whether
  preview must run this expensive step continuously or only when a Lighting
  context is selected. Exact UV2 parity requires running it.
- Current entity smoothing changes normals without regenerating tangents. This
  must be corrected before normal-map parity can be accepted.
- Custom entity scenes may contain visual geometry needed for final appearance,
  but instantiating them can execute tool scripts. Keep them excluded until a
  safe, explicit policy exists.
- ShaderMaterials can depend on screen textures, depth, camera state, globals, and
  instance uniforms. Exact resource assignment is required; exact game-frame
  output is not universally possible in an isolated editor viewport.
- Sharing a `Sky` RID across worlds is supported. Profile radiance regeneration
  and test procedural and physical skies whose output depends on directional
  lights in the destination rendering scenario.
- Built geometry may be too expensive to regenerate on every interactive brush
  motion. Debounce, generation cancellation, or an explicit refresh policy may be
  required after profiling.
