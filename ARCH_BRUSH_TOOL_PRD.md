# TBLoader Face-Based ARCH Brush Tool PRD

Status: Draft, implementation-ready product specification  
Audience: implementation engineer / LLM  
Repository basis: current working tree researched 2026-09-13

Related documents:

- `MAP_EDITOR_PRD.md` defines the Map Editor product and interaction conventions.
- `MAP_EDITOR_IMPLEMENTATION.md` defines the current native document API, identity, preview, and history contracts.
- `MAP_EDITOR_UI_IMPLEMENTATION.md` records delivered editor behavior and acceptance evidence.
- `MAP_EDITOR_PERFORMANCE.md` records native performance constraints.
- `tests/map_editor/README.md` defines the repository's test gates.

## 1. Summary

Add an **ARCH** geometry tool to the Map Editor. A mapper selects exactly one
rectangular brush face, enters ARCH mode, and drags an on-canvas manipulator in a
grid or 3D camera view. Dragging changes how far that face is rounded inward into
a convex, faceted circular crown. The editor previews the exact candidate brush
without changing the document and commits one atomic, undoable operation when the
drag ends.

The first delivery deliberately produces a **convex rounded crown**, such as the
top of a barrel-roof brush. It does not cut a concave doorway opening or generate
a hollow arch ring. A Quake brush is an intersection of planar half-spaces and
must remain convex; a hollow architectural arch would require several brushes or
a patch and is a different product operation.

ARCH output remains ordinary `.map` brush planes. No proprietary metadata or file
format extension is introduced. The resulting faceting is destructive but fully
undoable: after commit, the source face has become several faces and cannot be
reopened as a parametric arch unless the user undoes the operation.

## 2. Problem

The editor can create cuboids and prisms, clip brushes, move supporting faces, and
rebuild convex hulls from moved vertices. It cannot quickly turn a flat face into
a predictable rounded profile. A mapper currently has to construct and align each
supporting plane manually, with a high risk of invalid or uneven geometry.

The requested interaction is direct rather than dialog-driven: select a face,
enter ARCH mode, and drag a visible control to choose the amount of rounding while
reviewing the exact result in the map views.

## 3. Goals

- Create a convex circular crown from one selected rectangular brush face.
- Provide the same authoritative live candidate in grid and camera panes.
- Make the curvature amount legible in map units and as a percentage.
- Preserve the brush's stable ID, owner entity, primitive order, unaffected faces,
  face materials, UV projection fields, and surface flags.
- Commit a completed drag as one Map Editor undo action.
- Reject stale, unsupported, over-limit, degenerate, or non-convex candidates
  atomically and with an actionable diagnostic.
- Save and reopen output as standard canonical `.map` planes with preview/bake
  parity.
- Fit the current tool, selection, candidate-preview, and test architecture rather
  than introducing a second editing model.

## 4. Non-Goals

- Hollow doorway/window arches, concave brushes, arch rings, tunnels, vault arrays,
  or automatic multi-brush generation.
- Bezier patches, patch conversion, or runtime curved geometry.
- Persistent arch parameters or editing a committed arch parametrically.
- Rounding arbitrary polygons, triangles, trapezoids, skew quadrilaterals, or
  already-faceted crowns in the first delivery.
- Rounding multiple faces or multiple brushes in one gesture.
- Automatically smoothing normals. Existing brush preview normals are per-plane;
  smoothing is separate bake work described by `PRD.md`.
- Automatic texture seam correction, texture lock, or UV refitting.
- Changing grid snapping, camera navigation, selection semantics, or `.map` syntax.

## 5. Repository Findings and Constraints

### 5.1 Document and geometry model

- `TBMapDocument` is a `RefCounted` native document owning semantic map data in
  map-space coordinates (`src/map_document.h:34`). Generated geometry is cache.
- `LMBrush` stores a stable brush ID, topology revision, and an array of planar
  `LMFace` values, not editable mesh vertices (`src/map/brush.h:10`).
- `LMFace` stores three plane points, derived normal/distance, material index,
  classic or Valve UV projection, and optional surface flags (`src/map/face.h:41`).
- `LMGeoGenerator::generate_brush_vertices()` derives every brush vertex from
  triples of face planes and keeps intersections inside all half-spaces
  (`src/map/geo_generator.cpp:212`, `src/map/geo_generator.cpp:510`).
- Candidate edits are serialized, reparsed, regenerated, validated, and only then
  committed (`TBMapDocument::prepare_edit_candidate`, `finish_edit`, and
  `preview_edit` in `src/map_document_ops.cpp:149`). Failures leave the live
  document untouched.
- `valid_geometry()` requires finite, positive-volume, closed brush solids with at
  least four contributing faces and paired manifold edges
  (`src/map_document.cpp:62`).
- The parser rejects fewer than four or more than 64 source planes per brush and
  limits a document to 16 MiB (`src/map/map_parser.cpp:168`,
  `src/map/map_parser.h:22`). Geometry generation is approximately cubic in face
  count because it intersects face triples.

Implication: ARCH must generate supporting planes and preserve convexity. It must
not directly mutate derived winding vertices or represent a mathematically curved
surface.

### 5.2 Selection and component lifetime

- Primitive selection is `MapSession.selected: PackedInt64Array`; face selection is
  an entry in `MapSession.components` with `brush_id`, `kind`, `index`, and
  `topology_revision` (`addons/tbloader/src/editor/map_session.gd:10`).
- `MapSession.component_valid()` requires the owning brush to remain selected and
  visible and requires the topology token to match
  (`map_session.gd:265`).
- Face indices are source-array positions and are only valid for their topology
  revision. Every native content commit advances the shared topology counter and
  applies it to all brushes (`TBMapDocument::commit`, `src/map_document.cpp:177`).
- Grid face picking is available through `GraphView.pick_component()`
  (`graph_view.gd:325`). Camera ray hits include brush ID, face index, hit position,
  normal, and texture (`camera_view.gd:1183`, `map_document_spatial.cpp:257`).
- `MapEditor.set_tool()` cancels active interactions and currently clears all
  components (`map_editor.gd:892`). ARCH therefore needs an explicit exception to
  retain one eligible face when entering the tool; otherwise the requested
  select-face-then-enter-tool journey is impossible.

Implication: the target is captured as a topology-scoped face handle on tool entry.
Any unrelated topology change makes it stale and cancels ARCH preview. A successful
commit retains primitive selection on the brush but clears face components because
the source face no longer exists.

### 5.3 Views, overlays, and gestures

- Grid panes are `Control` nodes in map space. `orientation` is the hidden axis;
  `project`, `unproject`, and `snap_point` implement screen/map conversion
  (`graph_view.gd:6`, `graph_view.gd:81`). `_draw()` owns grid, edge, component,
  clip, and rotation overlays (`graph_view.gd:744`).
- Grid input is a single gesture state machine. Wheel zoom, RMB pan/context/box,
  LMB create/select/move/resize/component, Cut, and Rotate already compete in
  `_gui_input()` and `begin_left()` (`graph_view.gd:435`, `graph_view.gd:524`).
- Camera panes use a private `SubViewport`, map/Godot coordinate conversion, native
  ray picking, and their own gesture state machine (`camera_view.gd:86`,
  `camera_view.gd:277`, `camera_view.gd:1018`). RMB fly/pan and wheel camera controls
  must remain unchanged.
- `MapEditor.broadcast_mutation_preview()` sends native candidate draw payloads to
  every camera's `set_candidate_preview()` (`map_editor.gd:402`). Candidate hulls
  are currently translucent orange triangles and edges
  (`camera_view.gd:426`). Graph views draw local gesture approximations but can be
  extended to draw the exact returned candidate.
- Tool changes, focus loss, window focus loss, tab/session changes, and Escape call
  cancellation paths and must never commit synthetic mouse releases
  (`graph_view.gd:74`, `camera_view.gd:182`, `map_editor.gd:780`).

Implication: ARCH is a first-class exclusive tool and gesture, not a generic Godot
`EditorNode3DGizmo`. Its handle belongs to the Map Editor's private grid/camera
controls and coordinate conversion.

### 5.4 Commands and history

- UI edits run through `MapSession.transact(label, operation)`, which captures
  before/after native history states plus selection, components, points, and
  workzone (`map_session.gd:169`, `map_session.gd:200`).
- Transactions use the global `EditorUndoRedoManager`; failed multi-command edits
  restore the before state and no-op edits create no history entry.
- `TBMapDocumentState` shares immutable canonical/map state, while Map Editor
  history has 128 actions, 64 MiB per session, and 128 MiB total default budgets
  (`map_editor.gd:82`, `map_action.gd`).
- Current previews validate exact native candidates without committing; movement,
  rotation, component deformation, and clipping commit only on release/action.

Implication: every pointer motion calls preview only. Mouse release calls one native
ARCH mutation inside one `transact("Round map brush into arch", ...)`. Entering the
tool, changing axis, and cancelling do not dirty the map or create history.

### 5.5 Serialization and rendering

- `LMMapEdit` preserves entity/primitive order and copies every existing face's
  complete plane data plus texture token (`src/map/map_edit.cpp:19`).
- `lm_write_face()` writes ordinary classic/Valve projections and optional flags at
  double round-trip precision (`src/map/map_writer.cpp:71`).
- Draw data exposes each face's winding, center, normal, texture, and vertex indices
  (`src/map_document_draw.cpp:14`). Preview triangles carry brush/face ownership
  (`src/map_document_draw.cpp:40`).
- Camera geometry is chunked and caches unaffected chunks
  (`camera_view.gd:571`). Preview and bake use the same UV generation functions.
- Classic UV basis is selected from each face's dominant normal, while Valve UV
  uses explicit world axes (`LMGeoGenerator::get_standard_uv` and `get_valve_uv`,
  `src/map/geo_generator.cpp:553`). Copying classic texdefs onto differently angled
  facets can therefore produce visible orientation changes or seams.

Implication: ARCH output needs no serialization schema. Each crown facet copies the
source face's texture token, projection kind and values, and flags. The preview is
authoritative, but v1 does not promise seamless classic UVs across facets. Valve
axes naturally remain world projected. Unaffected faces retain their exact fields.

## 6. Users and Stories

### Primary user

A mapper blocking out convex world or brush-entity geometry in the in-Godot Map
Editor.

### User stories

- As a mapper, I can select the top rectangular face of a brush and activate ARCH
  to see whether it can be rounded.
- As a mapper, I can drag one obvious handle and see the exact crown update in all
  visible map panes without filling undo history.
- As a mapper, I can read both the inset depth and normalized amount while dragging.
- As a mapper, I can switch which rectangular face dimension the crown spans before
  committing.
- As a mapper, I can cancel without changing geometry.
- As a mapper, I can undo and redo the completed crown as one action, restoring the
  original face selection on undo and the resulting brush selection on redo.
- As a mapper, I receive a specific explanation when the face is unsupported or the
  requested facet count exceeds brush limits.
- As a mapper, I can save, reopen, preview, and bake the arch with the same geometry.

## 7. Product Semantics and Defaults

### 7.1 Meaning of "arch"

For v1, an arch is an inward, convex circular crown replacing one flat rectangular
face. In a cross-section perpendicular to the crown's extrusion axis:

- the original face center is the crown apex;
- both original side boundaries move inward by the selected depth;
- the profile is a symmetric circular arc through the apex and those two spring
  points;
- the arc is approximated by planar chord facets and extruded across the other face
  dimension;
- all original non-target supporting planes remain unchanged.

This rounds corners away from the original face and never expands the source brush.
The resulting solid is the intersection of the unchanged half-spaces and the new
crown half-spaces.

### 7.2 Eligibility

ARCH is enabled only when all are true:

- exactly one brush is selected;
- exactly one valid face component on that brush is selected;
- no point entity is selected;
- the brush and face are visible under current hide/filter state;
- the target winding has exactly four distinct vertices and positive area;
- opposite edges are parallel, adjacent edges are perpendicular, and opposite edge
  lengths match within tolerance;
- the face has two nonzero dimensions after projection to its local frame;
- replacing one face with the configured facet count does not exceed 64 source
  planes;
- a nonzero amount can produce a finite, closed, positive-volume candidate.

Tolerance is `max(1e-5 map units, longest_face_edge * 1e-6)` for positions and the
equivalent normalized angular tolerance of `1e-6` for parallel/perpendicular tests.
Validation must use native doubles, not rounded GDScript positions.

Redundant source faces are allowed elsewhere on the brush but count toward the
64-plane limit. A redundant/non-contributing target face is ineligible because it
has no four-vertex winding.

### 7.3 Local frame and deterministic axis

Let `n` be the source face's outward unit normal. Derive the two unsigned local axes
from its parallel edge pairs:

- `u` is the crown span axis;
- `v` is the extrusion axis that remains straight.

Default `u` is the shorter face dimension, producing a barrel crown along the
longer dimension. If the dimensions tie within tolerance, choose the edge direction
whose largest absolute map-axis component has the lowest axis index (`X`, then `Y`,
then `Z`). Canonicalize each axis sign so its largest absolute component is positive.
This makes imported winding order irrelevant.

An **Axis** toggle in the ARCH tool options swaps `u` and `v`. Default facet count
is **8**. The first delivery exposes facet count as a `3..32` integer control in the
toolbar/tool options; it is not changed by the on-canvas amount manipulator.

### 7.4 Amount

The authoritative amount is inward depth `d` in map units:

- `0 <= d <= a`, where `a` is half the selected face width along `u`;
- normalized amount is `d / a` and is displayed as `0..100%`;
- `0` is the unchanged flat face and committing it is a no-op;
- `a` is a semicircular crown whose apex-to-spring depth equals its half-width;
- default preview on entering ARCH is `d = min(a * 0.5, 2 * session.grid)`, clamped
  above zero. Entering still does not modify the document;
- the last preview amount may be retained per editor session for the next eligible
  face only as a normalized UI preference, not map data. If not implemented, use
  the default above every time.

Amount is continuous and is **not snapped to the map grid**. Fractional plane values
are supported and required for smooth feedback. Holding Shift applies precision
dragging at one tenth normal sensitivity. Alt is reserved for a future snap bypass
and has no v1 ARCH meaning. The value label displays enough decimals to distinguish
changes, capped at six fractional digits.

### 7.5 Circular construction

Use a face-local coordinate system with apex `(u=0, n=0)`, spring points
`(-a, -d)` and `(a, -d)`, and `v` spanning the original face length.

For `0 < d <= a`, the circle radius and center are:

```text
R = (a*a + d*d) / (2*d)
circle center = (u=0, n=-R)
theta = asin(a / R)
```

Sample `segments + 1` profile vertices at equal angular intervals from `-theta` to
`+theta`, including both spring points and the apex when the segment count is even.
For each adjacent profile pair, create one supporting plane parallel to `v` and
passing through the pair at both extrusion extremes. Orient its normal outward so
the original brush center remains inside its half-space. Remove the source face and
append these facet faces at its source-array position, in deterministic order from
negative to positive canonical `u`.

The implementation must not special-case the arc into mesh triangles. It must
construct valid `LMEditFace` planes and let the normal parser/generator/validator
produce windings. Near zero, use the unchanged source face rather than evaluating
an ill-conditioned large radius. Preview amounts below
`max(1e-8, a * 1e-9)` as zero.

### 7.6 Face data inheritance

Every generated crown facet copies the target face's:

- texture token;
- classic or Valve UV projection discriminator and all projection fields;
- rotation and scales;
- optional contents/surface/value flags, including specified-versus-absent state.

All non-target source faces are copied byte-for-byte at the semantic field level.
The brush ID, owning entity ID, primitive source order, and entity epairs are
retained. Facets receive no IDs because the current model does not assign stable
face IDs.

Classic textures may show seams when facet normals select different standard UV
axes. This limitation must be stated in the ARCH tooltip and is not a geometry
failure. No facet may silently switch projection kind.

## 8. Experience and Interaction

### 8.1 Entry

- Add `Arch` to the exclusive tool group near `Rotate` and component tools, with a
  distinct arch/crown icon and tooltip `Arch Tool (A)`.
- Plain `A` activates ARCH only while a graph or camera pane owns focus and existing
  text/dialog/browser shortcut isolation allows it.
- Entering with one eligible face retains that face component, captures its handle,
  computes the frame, displays the default preview, and shows the manipulator.
- Entering with no face, multiple faces, an unsupported face, or stale selection
  leaves ARCH active but in an empty/disabled state. The status explains the exact
  requirement and no preview appears. A subsequent valid single-face selection in
  ARCH mode initializes the tool.
- In ARCH mode, ordinary face click selects/replaces the target. Shift-click and
  paint selection are disabled for ARCH because v1 has one target; the status says
  `ARCH supports one face at a time` rather than silently creating multiple targets.

### 8.2 Manipulator

The manipulator consists of:

- an apex marker at the source face center;
- a line along `-n` from the apex to the current depth;
- a draggable circular handle at the line end;
- faint spring lines across the chosen `u` dimension;
- a label `Arch 12.5 u (50%) • 8 facets`;
- a small axis affordance or toolbar **Swap Axis** action.

Handle size is screen-constant: 12 px hit radius, 7 px visible radius, matching
existing component hit targets. It is orange at rest, pale yellow on hover/drag,
and red when the current candidate is invalid. The selected source face retains
its blue face outline beneath the orange candidate.

In a grid pane, show and allow the handle only when projected `-n` has at least
`0.1` screen-direction magnitude; otherwise draw a subdued `ARCH handle is edge-on
in this grid` label. Another grid orientation or camera remains usable. The handle
must not depend on the active grid's hidden-axis workzone value.

In a camera pane, project the same map-space apex/handle into screen space for
drawing and hit testing. Convert drag rays to the line through the apex along
`-n` by closest-points projection, clamped to `[0, a]`. If the view ray and handle
axis are nearly parallel, preserve the last valid amount and show
`Rotate camera for ARCH control`.

All visible graph and camera panes show the same amount and candidate. Only the
pane that owns the pointer gesture controls it.

### 8.3 Drag lifecycle

1. LMB press within the ARCH handle captures the gesture and the original target.
2. Motion past the existing 4 px threshold enters drag state.
3. Every motion computes amount from the original geometry, requests an exact native
   candidate, and updates all panes. It never compounds from the previous preview.
4. Valid candidates show the original brush dimmed and the exact candidate in the
   existing orange candidate style. Graph panes draw candidate edges from returned
   draw data; camera panes use `set_candidate_preview()`.
5. Invalid candidates retain the last valid preview, turn the handle red, and show
   the native Result diagnostic. Re-entering a valid range clears the error.
6. LMB release after a changed valid drag commits the final amount once.
7. LMB release without crossing the threshold leaves the default/current preview
   active and creates no history.
8. Escape, tool/session/tab change, focus loss, hidden/filtered target, selection
   change, topology change, or internal/synthetic release cancels without commit.

While an ARCH handle drag is active, it wins before normal LMB selection/component
dispatch. LMB outside the handle ends the preview target and performs single-face
selection for the new ARCH target. RMB pan/fly, wheel navigation, orientation gizmo,
and frame-selection controls retain current behavior.

### 8.4 Commit and post-commit state

- Commit through `MapSession.transact("Round map brush into arch", ...)`.
- Preserve `session.selected = [brush_id]`.
- Clear `session.components`; the old face handle is stale by definition.
- Recompute workzone through normal `prune()` behavior.
- Remain in ARCH mode but show `Select one rectangular face to create another arch`.
- Undo restores canonical source geometry, original stable brush ID, original face
  component, and workzone from the transaction's before envelope.
- Redo restores the arch, selected brush, cleared components, and post-commit
  workzone.
- A zero-amount commit or byte/identity-equivalent output is a no-op and creates no
  history entry.

### 8.5 Tool states

| State | Display | Available actions |
|---|---|---|
| Inactive | No ARCH overlay | Select face; activate tool |
| No target | Instruction in status | Single-face pick, leave tool |
| Ineligible target | Red face outline and reason | Pick another face, leave tool |
| Ready | Default exact preview and handle | Drag, swap axis, change facets, cancel |
| Hover | Highlighted handle | Begin drag |
| Dragging valid | Exact candidate in all panes, live value | Continue, release to commit, Esc |
| Dragging invalid | Last valid candidate, red handle, diagnostic | Return to valid value, Esc |
| Committing | Input blocked for this tool; prior document remains visible | Wait for synchronous native result |
| Stale/cancelled | Preview removed; instruction/status | Re-select a face |

## 9. Functional Requirements

### FR-1 Tool registration and routing

- Add `Arch` to `MapEditor`'s exclusive mode list, icon map, status reporting, and
  `A` shortcut.
- Preserve a single face component when transitioning into ARCH; retain current
  component-clearing behavior for all other tool transitions.
- Route ARCH handle input before existing grid/camera LMB behavior and use existing
  focus and dialog isolation.

### FR-2 Eligibility query

- Native code must validate and return deterministic frame/limits data from the
  authoritative double-precision brush geometry.
- The UI must not independently decide geometric eligibility from copied float
  windings, although it may use returned data for drawing.
- Failure Results must identify `brush_id` and `face` where applicable.

### FR-3 Exact preview

- Preview must execute the same construction and validation as commit.
- Preview returns candidate draw data compatible with existing candidate rendering
  and includes source brush ID mapping.
- Preview does not change revision, topology, dirty state, IDs, selection, signals,
  history, or canonical text.

### FR-4 Atomic mutation

- Commit validates brush ID, face index, topology revision, axis, segments, amount,
  coordinate bounds, plane count, and resulting geometry before mutation.
- Success performs one document commit and emits one `map_changed` signal.
- Failure changes no content, caches, identity, selection, revision, topology,
  history, or dirty baseline.

### FR-5 Geometry and data preservation

- Follow Sections 7.3 through 7.6 exactly.
- Retain brush and owner IDs; do not allocate a replacement brush.
- Retain all unaffected source faces and all target surface semantics.
- Enforce the 64-plane and 16 MiB limits before commit.

### FR-6 Cancellation

- Every existing editor cancellation path clears ARCH candidate and gesture state.
- Focus-loss/internal release cannot commit.
- Undo/redo first cancels ARCH preview, then invokes global history.

### FR-7 Persistence

- Saving writes standard face lines only.
- Reloading produces the same canonical text and equivalent draw/preview geometry.
- Save/bake includes ARCH geometry regardless of editor visibility filters.

### FR-8 Diagnostics

At minimum, distinguish:

- no single selected face;
- stale component;
- hidden/filtered target;
- non-quadrilateral face;
- non-rectangular face;
- zero-area/too-small span;
- invalid amount or segment count;
- 64-plane limit exceeded;
- generated degenerate/unbounded/non-convex brush;
- coordinate or document-size limit exceeded.

Expected user errors use the existing Result channel, never assertions or
`push_error`.

## 10. Proposed Native API

Names may change only if all bindings, consumers, tests, and implementation docs
change together. Follow the existing mandatory Result schema.

```text
get_arch_face_info(
  id: int,
  face: int,
  topology_revision: int
) -> Result.value Dictionary

Result.value = {
  brush_id: int,
  face_index: int,
  topology_revision: int,
  center: Vector3,
  normal: Vector3,
  span_axis_0: Vector3,
  span_axis_1: Vector3,
  size_0: float,
  size_1: float,
  default_axis: int,
  max_segments: int
}

preview_arch_face(
  id: int,
  face: int,
  topology_revision: int,
  axis: int,
  amount: float,
  segments: int
) -> Result.value Array[Dictionary] candidate draw data

arch_face(
  id: int,
  face: int,
  topology_revision: int,
  axis: int,
  amount: float,
  segments: int
) -> Result.value null
```

`axis` is `0` or `1` for the two deterministic local dimensions. `amount` is depth
in map units, not percentage. `max_segments` is
`min(32, 64 - source_face_count + 1)` and eligibility requires it to be at least 3.
Empty/no-op amount succeeds with `changed=false` for preview/commit after all handle
validation.

Use a shared native staging helper, analogous to `stage_components()` and
`stage_clip()`, so info, preview, and commit cannot drift. Do not implement ARCH as
repeated calls to existing public face/vertex mutation APIs.

Recommended private shape:

```text
stage_arch(id, face, token, axis, amount, segments,
           operation, edit, sources, optional_info) -> Result
```

The operation should edit one `LMEditPrimitive` in `LMMapEdit`, replace the source
`LMEditFace` at the same position with generated faces, and use `preview_edit()` or
`finish_edit()` for the existing candidate pipeline.

## 11. Likely Implementation Touchpoints

### Native

- `src/map_document.h`
  - Declare and document the three public APIs and shared staging helper.
- `src/map_document.cpp::TBMapDocument::_bind_methods`
  - Bind API names and argument order.
- `src/map_document_ops.cpp`
  - Implement authoritative rectangle/frame extraction, circular plane generation,
    face-field inheritance, limit checks, preview, and commit.
  - Reuse `check_face()`, `valid()` conventions, `LMMapEdit`, `preview_edit()`, and
    `finish_edit()`.
- `src/map/brush_topology.h/.cpp`
  - Optional home for a reusable double-precision rectangular-face frame helper if
    keeping it local to `map_document_ops.cpp` would duplicate logic. Prefer local
    implementation unless another operation needs it.
- `src/map/map_edit.h/.cpp`
  - Optional pure `lm_edit_arch_face` helper. It must not parse/commit independently;
    document staging remains responsible for transactional validation.
- `src/map_document_draw.cpp`
  - No schema change should be necessary if preview returns existing candidate draw
    dictionaries. Change only if graph rendering requires explicit source mapping
    not already supplied by `candidate_draw_data()`.
- `src/map/map_writer.cpp` and `src/map/geo_generator.cpp`
  - No behavior change expected. They are persistence and derived-geometry
    verification points.

### Editor

- `addons/tbloader/src/editor/map_editor.gd`
  - Register Arch icon/button/shortcut; own ARCH target, axis, amount, facets, and
    shared preview state; coordinate all panes; alter `set_tool()` component clearing;
    cancel on session/tool/history transitions; transact commit.
  - Keep state per active Map Editor/session, not in `.map` or `MapSession.capture()`.
- `addons/tbloader/src/editor/graph_view.gd`
  - Draw ARCH handle/label/candidate edges in `_draw()`; screen-space hit test;
    implement grid drag and exact preview dispatch before normal `begin_left()`.
  - Extend `cancel()` to release ARCH ownership without clearing another pane's
    preview.
- `addons/tbloader/src/editor/camera_view.gd`
  - Draw/project the map-space handle, hit test it, solve ray-to-axis amount, and
    route the ARCH camera gesture before normal face/brush manipulation.
  - Reuse `set_candidate_preview()`, `clear_candidate_preview()`, `transform_map()`,
    and map/preview conversions.
- `addons/tbloader/icons/map_toolbar/arch.svg`
  - New monochrome toolbar icon following existing custom icon conventions. This is
    part of implementation but not created by this PRD task.
- `addons/tbloader/src/editor/map_session.gd`
  - Prefer no ARCH-specific state. A small helper may be warranted for target
    validity, but geometry authority stays native and transaction behavior stays
    unchanged.

### Documentation and tests during implementation

- Update `MAP_EDITOR_IMPLEMENTATION.md` API contract and
  `MAP_EDITOR_UI_IMPLEMENTATION.md` acceptance evidence when shipping.
- Extend `tests/map_editor/native_document_test.cpp`, `document_suite.gd`, and
  `editor_suite.gd`.
- Extend displayed `ui` and genuine `window_input_runner.py` journeys for real
  manipulator input and focus-loss cancellation.

## 12. Non-Functional Requirements

### Performance

- Pointer motion must never commit or add history.
- Coalesce preview requests to at most one native preview per rendered frame. If
  several motion events arrive before a frame, evaluate only the latest amount.
- A one-brush, eight-facet preview should target under 16.7 ms p95 on the 32-brush
  fixture and report release-to-visible timing separately.
- On large maps, avoid reparsing on every raw mouse event. Phase 1 may use the
  existing full-document candidate pipeline with frame coalescing; Phase 2 should
  introduce localized preview/candidate caching if displayed tests miss budget.
- Do not rebuild material resolution or unaffected camera chunks merely because the
  handle moved. Candidate nodes are transient and separate from `map_geometry`.

Current evidence in `MAP_EDITOR_PERFORMANCE.md:108` shows a 256-brush full rebuild
at 14.5/28.4 ms median/p95 and translation around 24/35 ms; uncoalesced full parse
on pointer motion is therefore a known responsiveness risk.

### Reliability

- Use native double precision for frame tests and plane construction.
- Preview and commit must share code and produce identical candidate canonical
  geometry for the same arguments.
- All construction is deterministic across winding rotation/reversal and locale.
- No shallow native copies, leaked candidate geometry, dangling pointers, stale
  component rebinding, or ID reuse.

### Compatibility

- Output must remain parseable by the repository parser and ordinary classic/Valve
  `.map` consumers.
- Do not modify patches, bake coordinate conversion, material resolution, or scene
  ownership.
- Match the currently tested baseline first: Linux x86_64 and pinned Godot
  `4.8.dev.custom_build.3924ec46f`. Do not claim untested 4.1 or cross-platform
  editor behavior.

### Accessibility and usability

- The toolbar button needs tooltip and accessibility name.
- Amount is not communicated by color alone; always show text.
- Screen-space handle size remains usable independent of zoom/FOV/map scale.
- Keyboard users can enter ARCH with `A`, swap axis from a focusable toolbar action,
  enter an exact amount in a spin box, and commit with Enter. Exact-entry commit
  follows the same transaction path; Escape cancels.

## 13. Acceptance Criteria

### Selection and activation

- With one selected rectangular face, `A` activates ARCH without clearing the face
  and displays one shared default preview and manipulator.
- With zero, multiple, stale, hidden, triangular, or skew face targets, ARCH changes
  no document state and displays a specific reason.
- Text fields, dialogs, browser search, camera fly mode, and non-map panes do not
  trigger the ARCH shortcut.

### Geometry

- A `128 x 64` rectangular face with default short-axis span, amount `32`, and eight
  facets becomes eight crown faces across the 64-unit dimension; the other face
  dimension remains straight.
- At amount equal to half span width, sampled profile points lie on the expected
  semicircle within `1e-6` relative tolerance.
- At nonzero amounts, the apex stays on the original target plane, spring points
  move inward by exactly the requested depth, and no output vertex lies outside any
  supporting half-space.
- Output has positive finite volume, Euler characteristic 2, paired edges, outward
  unit normals, planar windings, and clockwise preview triangles under existing
  conventions.
- Swapping axis exchanges span/extrusion deterministically.
- Winding rotation/reversal and translated/rotated axis-aligned or oblique brushes
  produce the same canonical frame and equivalent geometry.
- Zero amount is an exact no-op. Negative, nonfinite, above-maximum, stale, or
  over-limit requests fail atomically.

### Preservation and persistence

- The brush ID, owning entity, primitive order, entity epairs, and every unaffected
  face semantic field remain unchanged.
- Every facet preserves source texture, classic/Valve kind and values, and
  specified/absent surface flags.
- Canonical export is a fixed point after import; save/reopen reproduces equivalent
  draw and preview data; bake bounds and triangles match preview geometry.
- No ARCH metadata or unsupported syntax appears in saved text.

### Interaction and history

- Grid and camera drags show equivalent exact candidates for equal amounts.
- Multiple motion events create no revision, dirty, signal, ID, or history changes.
- Valid release creates exactly one global history action and one document commit.
- Undo restores the original face geometry and selected face handle; redo restores
  the arch and brush-only selection.
- Escape, tool switch, Ctrl+Z/Y, document/session/tab switch, focus loss, and
  synthetic release clear preview and do not accidentally commit.
- RMB camera/grid navigation and wheel behavior are unchanged in ARCH mode.

### Performance

- Display-backed 31-sample tests report event-to-candidate and release-to-visible
  median/p95/max, missed 16.7 ms frames, and preview call count.
- Motion coalescing proves native preview calls do not exceed rendered frames.
- No monotonically growing native allocation or orphan candidate node is observed
  across 1,000 preview updates, 200 commit/undo/redo cycles, and tool/session churn.

## 14. Testing Strategy

### 14.1 Pure/native geometry tests

Extend `tests/map_editor/native_document_test.cpp` with:

- rectangle frame extraction under winding rotations, winding reversal, world
  translation, brush rotation, negative/fractional coordinates, and oblique planes;
- exact radius/profile checks at shallow, 50%, and semicircle amounts;
- segment counts 3, 4, 8, and 32;
- plane orientation, convex containment, finite intersections, manifold edges,
  positive volume, and parser/writer fixed points;
- source face data inheritance for classic, Valve, explicit zero flags, nonzero
  flags, and absent flags;
- rejection of triangle, pentagon, trapezoid, skew parallelogram, near-zero edge,
  stale token, NaN/infinity, negative/oversize amount, segment 2/33, 64-plane
  overflow, and generated degeneration;
- repeated candidate construction under ASan/UBSan/leak detection using
  `tests/map_editor/run_native_tests.sh`.

### 14.2 Native Godot document tests

Extend `tests/map_editor/document_suite.gd` with:

- mandatory Result schemas and copied `get_arch_face_info()` payload;
- preview purity: unchanged state, identities, revisions, topology, signals, dirty
  baseline, and history-independent canonical text;
- preview/commit draw-data equivalence;
- stable brush/entity identity and monotonic topology on commit;
- save/load/export fixed point and preview/bake parity;
- undo history state restoration across classic/Valve and texture-size cache states;
- 16 MiB and 64-plane limit behavior;
- caller mutation of returned info/candidate data cannot mutate the document.

Reuse `assert_solid()` in `document_suite.gd:736` for topology, winding, volume, and
preview ownership checks.

### 14.3 Editor integration tests

Extend `tests/map_editor/editor_suite.gd` with real handlers:

- toolbar icon, exclusive button group, tooltip, accessibility name, and `A` routing;
- face selection retained on tool entry;
- eligible/ineligible/no-target states;
- graph and camera handle hit testing, threshold, continuous amount, Shift precision,
  axis swap, facet count, exact entry, and all-pane preview;
- commit selection/component state and one-action undo/redo;
- no-op release and invalid drag do not create action tokens;
- cancellation on every focus/tool/session/history path;
- existing Brush/Cut/Rotate/Face/Edge/Vertex/Texture journeys still pass.

### 14.4 Displayed and genuine-input tests

- Add `ui` screenshots for ready, valid drag, invalid drag, edge-on grid, and camera
  manipulator states.
- Extend the X11 genuine-input journey to select a face, press `A`, drag the actual
  handle, observe candidate geometry before release, release, undo, and redo.
- Inject focus loss during drag and assert exact source text/history remains.
- Test at two graph zooms, two camera FOVs, map inverse scales, and 32/256-brush
  fixtures.
- Retain strict empty-stderr, one completion marker, bounded timeout, source/binary
  provenance, and fresh-process reopen requirements from
  `tests/map_editor/README.md`.

### 14.5 Regression gates

Run all existing commands documented in `tests/map_editor/README.md`, including the
native sanitizer target, document, editor, displayed UI, current-editor performance,
negative harness, and genuine window-input suite. A focused ARCH suite does not
replace those gates.

## 15. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Product expectation is a hollow doorway arch | Delivered shape appears wrong | Name the v1 result `convex crown` in tooltip/docs; resolve Open Question 1 before implementation sign-off |
| Full-document parse/generate on each preview misses frame budget | Drag feels laggy on representative maps | Frame-coalesce immediately; measure 32/256; add localized candidate cache in Phase 2 |
| Near-zero circular math is ill-conditioned | Invalid planes or huge-coordinate error | Exact zero branch and relative epsilon; native doubles; shared validation |
| Shallow adjacent planes stress face-triple intersections | Missing corners or invalid hull | Existing long-double intersection path; test shallow profiles and large coordinates |
| Facets push brush above 64 planes | Operation fails late | Return `max_segments`, disable invalid counts, revalidate atomically |
| Classic UV basis changes across facets | Visible seams | Preserve fields, show authoritative preview and tooltip; defer texture-lock/refit |
| Tool entry currently clears face components | No target survives activation | Explicit ARCH exception in `MapEditor.set_tool()` with regression tests |
| Face index becomes stale after any commit | Wrong face edited | Capture and validate topology token for every info/preview/commit call; cancel on change |
| Graph and camera duplicate amount math | Different results by pane | Panes only solve scalar depth; native code owns frame and geometry; one host preview state |
| Synthetic release commits after focus loss | Unwanted geometry/history | Follow existing device/window focus guards and test genuine focus loss |
| Generated output cannot be adjusted later | Destructive workflow surprise | State destructive behavior; retain single-step undo; consider metadata only in future |
| Added facets increase bake/render/collision cost | Dense maps regress | Default eight, cap 32, expose face limit, include representative performance tests |

## 16. Delivery Plan

### Phase 0: Product confirmation and geometry spike

- Resolve hollow arch versus convex crown expectation.
- Implement a standalone/native pure geometry spike for rectangular frame extraction
  and circular supporting planes.
- Prove deterministic output, source field inheritance, parser fixed point, limits,
  and sanitizer cleanliness before UI work.

Exit: native fixtures pass for axis-aligned, rotated, oblique, shallow, and
semicircle cases; product owner accepts the crown semantics.

### Phase 1: Native document API

- Add info, preview, commit, shared staging, bindings, and Result diagnostics.
- Add native and Godot document tests, save/reopen, identity, preview purity, and
  preview/bake parity.
- Update the frozen implementation API document.

Exit: all document/native gates pass; no UI calls private geometry math.

### Phase 2: Grid MVP

- Add Arch toolbar mode, `A`, options, target lifecycle, graph overlay/hit testing,
  exact graph/camera candidate broadcast, commit, cancellation, and history.
- Frame-coalesce preview calls.
- Add headless editor handler tests and displayed graph screenshots.

Exit: face-select -> ARCH -> graph drag -> release -> undo/redo works as specified,
with no regressions in current tool journeys.

### Phase 3: Camera manipulator and hardening

- Add camera projection/hit testing/ray-axis solve and edge-on diagnostics.
- Complete focus/session/tool cancellation, keyboard exact entry, accessibility,
  all-pane consistency, and genuine X11 input coverage.
- Measure 32/256-brush interaction latency and optimize localized preview if needed.

Exit: grid and camera acceptance criteria pass on the pinned displayed environment;
performance and residual platform limits are recorded.

### Phase 4: Follow-ups, separately scoped

- Texture-lock or deliberate per-facet UV fitting.
- Persistent parametric ARCH metadata with compatibility policy.
- Multi-brush hollow doorway/ring generator.
- Multi-face/batch crowns, elliptical profiles, asymmetric spring heights, and custom
  segment distribution.
- Optional smoothing integration at bake time.

## 17. Open Product Questions

Repository evidence cannot decide these questions. Defaults below govern v1 unless
product direction changes before implementation.

1. Does "arch" mean the specified convex crown, or a hollow doorway/opening made
   from multiple brushes? **Default:** convex crown; hollow arch is separate scope.
2. Should the selected face become the crown surface, or identify the front/profile
   plane for an arch generated along brush depth? **Default:** selected face becomes
   the crown facets.
3. Is destructive standard `.map` output acceptable, or must amount/axis/segments
   remain editable after save? **Default:** destructive, ordinary planes, undo only.
4. Should facet count be user-visible? **Default:** toolbar integer `3..32`, value 8.
5. Should default span be the shorter face dimension or follow active view/world up?
   **Default:** shorter dimension with deterministic tie-break and explicit swap.
6. Should curvature depth snap to grid? **Default:** continuous; geometry is often
   unusably coarse if amount is constrained by the current 16-unit default grid.
7. Is a semicircle the maximum, or should over-semicircular/elliptical crowns be
   supported? **Default:** circular depth capped at half-width.
8. Must classic UVs be seamless or texture-locked across generated facets?
   **Default:** preserve source fields exactly and accept visible seams in v1.
9. Should the default preview appear immediately on tool entry or only after first
   drag? **Default:** immediate 50%-or-two-grid-steps preview, no document mutation.
10. Should ARCH remain active after commit? **Default:** yes, with brush-only
    selection and a prompt to choose another face.
11. Should arbitrary rectangular faces on rotated/oblique brushes be supported at
    launch? **Default:** yes; frame is face-local and native double precision.
12. Is keyboard exact entry required for first release? **Default:** yes for
    accessibility, using the same preview and commit path.

## 18. Definition of Done

The feature is done when the native API, grid and camera interactions, exact
candidate preview, atomic history, persistence, diagnostics, and cancellation
behavior satisfy this PRD; all existing strict repository gates plus new ARCH native,
document, editor, displayed, genuine-input, and performance tests pass on the pinned
Linux/Godot baseline; implementation documents are updated; and no unresolved
Question 1 or 2 remains.
