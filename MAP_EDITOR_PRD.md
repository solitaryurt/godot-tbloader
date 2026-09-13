# TBLoader Map Editor PRD

Status: Phases 0–1 implemented and tested on pinned Linux/Godot; brush operations/UI phases pending. See [implementation contract and progress](MAP_EDITOR_IMPLEMENTATION.md) for actual API scope and platform limits.  
Audience: implementation LLM / engineer  
Repo: `godot-tbloader`  
Related but separate: `PRD.md` (import overrides, smoothing, materials). This document is the **in-Godot `.map` authoring** product. Do not treat generated `MeshInstance3D` / collision nodes as the source of truth.

---

## 1. Problem

Level geometry is authored in Radiant / TrenchBroom as Quake 3-style `.map` files, then imported through TBLoader. That split is the bottleneck:

- Brush editing, clipping, UV work, and texture assignment happen in an external editor.
- TBLoader only **bakes** the file into Godot nodes (`build_meshes()`), then discards the brush document.
- Desired Godot-only extensions (smoothed normals, gameplay surfaces, etc.) have no live brush/face selection to hang off.

We want a Godot editor tab that can **open, edit, and save `.map` files** with Radiant-like graph-view UX, then still bake through the existing TBLoader pipeline.

Success looks like: a mapper can block out, clip, texture, and UV a map without leaving Godot, save a round-trippable `.map`, and press Build Meshes.

---

## 2. Goals

- Replace NetRadiant/TrenchBroom for the core brush workflow inside the Godot editor.
- Keep `.map` as the editable source format (classic Q3 faces + Valve 220 + patches preserved).
- Match NetRadiant **graph view** mouse semantics closely enough that Radiant users are productive.
- Assign textures to brushes and faces; edit UV shift / scale / rotate (Valve axes later).
- Clip/split convex brushes.
- Select, move, copy/paste, clone, delete brushes; create cuboids and N-sided prisms.
- Leave the existing bake path (`TBLoader::build_meshes`) intact.
- Quad workspace: camera, project material browser, and two independently orientable grid views. Ctrl+Tab cycles the focused grid through Top/Front/Side.
- Right-click enters camera fly mode; project-wide material search and folder navigation; an N-key Radiant-style entity inspector supporting point and brush entities.
- Be extensible later (phong/smoothing, entity tools, q3map2, patches as first-class edits).

## 3. Non-goals (this delivery)

- Do not copy or link NetRadiant Custom source (GPL). Reimplement from behavior.
- Do not fork the Godot engine. Use `EditorPlugin` with `_has_main_screen() == true`.
- Do not make baked meshes the document. No “edit ArrayMesh then guess a .map”.
- Do not implement the full Radiant product (complete FGD browser, patch editing, CSG subtract, texture lock, q3map2 compile, pointfile) in v1. Basic entity authoring and the N inspector are required.
- Do not replace `PRD.md` override/smoothing work; that applies **after** bake. Map Editor writes `.map`; smoothing can come later as bake-time or document-time.

---

## 4. Current TBLoader (what to reuse)

Bake is one-way today:

1. `TBLoader::build_meshes()` in `src/tb_loader.cpp` — clears children, constructs `Builder`.
2. `Builder::load_map()` in `src/builder.cpp` — `FileAccess` + `LMMapParser::load_from_godot_file`, texture size cache, `LMGeoGenerator::run()`.
3. `Builder::build_map()` — entities to Godot nodes.
4. `Builder::lm_transform()` — map `(x,y,z)` → Godot `Vector3(y, z, x) / inverse_scale` (default scale 38).
5. `Builder::build_entity_mesh()` — per-texture `ArrayMesh` on `MeshInstance3D`; collision split by texture name into `StaticBody3D` / `Area3D` + `CollisionShape3D`.

Map core (MIT, vendored libmap-style):

| Piece | Path | Role |
|---|---|---|
| Face | `src/map/face.h` | 3 plane points, `plane_normal` / `plane_dist`, `texture_idx`, classic UV, Valve UV, `uv_extra` (rot, scale), `surface_flags` |
| Brush | `src/map/brush.h` | Face array + center. Convex hull, not a mesh. |
| Entity | `src/map/entity.h` | Ordered epairs, brushes, patches |
| Parser | `src/map/map_parser.cpp` | Entities, brushes, Valve 220, patch parsing, Q3 content/surface/value flags (`commit_face`); patch preservation and parse validation need fixes before editor use |
| Geo | `src/map/geo_generator.cpp` | `generate_brush_vertices`: face-triple intersect, `vertex_in_hull`, winding sort, fan indices |
| UVs | `geo_generator.cpp` `get_standard_uv` / `get_valve_uv` (~530) | Shift/rotate/scale and Valve axis projection |
| Data | `src/map/map_data.h` | Texture registry, entities, generated `entity_geo` |
| Plugin UI | `addons/tbloader/src/plugin.gd` | Spatial-editor “Build Meshes” + Map Materials when a `TBLoader` is selected |

**Gaps to add:** transactional parser with diagnostics, lossless semantic patch representation, `.map` writer, safe geometry-cache ownership, undoable document, editor tab, clip/prism/component handles. `LMGeoGenerator::run()` currently allocates `entity_geo` without freeing previous geometry. Free old caches **before** topology counts change, or give caches independent allocation counts; traversing old allocations using new document counts is unsafe.

Round-trip means preserving supported map semantics, not original whitespace/comments. Preserve ordered epairs, entity/brush ownership, face projection kind, optional flags (including absent versus explicit zero), patch definition kind, header fields, subdivisions, and control-point positions/UVs. The current patch parser resets its `patchDef3` discriminator and the model omits some header data; a writer alone cannot meet this requirement. Preserve unsupported blocks verbatim or reject the load with a diagnostic; never silently drop them and allow saving.

Parser face line (write must match `commit_face` / token scopes):

```
( x0 y0 z0 ) ( x1 y1 z1 ) ( x2 y2 z2 ) shader shift_u shift_v rot scale_u scale_v [contents surface value]
```

Valve:

```
( ... ) ( ... ) ( ... ) shader [ ux uy uz uoff ] [ vx vy vz voff ] rot scale_u scale_v [contents surface value]
```

Plane normal convention in parser (`commit_face`):

```
v0v1 = v1 - v0
v1v2 = v2 - v1
normal = normalize(cross(v1v2, v0v1))
dist = dot(normal, v0)
```

Use this exact convention for created faces.

---

## 5. Behavioral reference (NetRadiant Custom)

Path: `/mnt/data/code/netradiant-custom` (or `../netradiant-custom` from this repo). **Read-only reference. GPL — do not copy code.**

| Concern | Files |
|---|---|
| Ortho views, mapping, pan/zoom, new-brush drag | `radiant/xywindow.cpp`, `xywindow.h` |
| View types | `include/qerplugin.h` `VIEWTYPE` / `NDIM1NDIM2` |
| Select / box / modifiers | `radiant/selection.cpp` |
| QE4 move / silhouette resize | `radiant/selection_mtor_drag.cpp` |
| Clipper points | `radiant/selection_mtor_clip.cpp`, `clippertool.cpp` |
| Split/clip algorithm | `radiant/csg.cpp` `BrushSplitByPlaneSelected` (~753) |
| Cuboid / prism prefabs | `radiant/brushmanip.cpp` `Scene_BrushResize_Cuboid`, `BrushMakeSided` |
| Copy/paste/clone/workzone | `radiant/select.cpp` |
| Texture assign | `radiant/select.cpp` `Select_SetShader`, `brushmanip.cpp` `FaceSetShader` |
| UV inspector | `radiant/surfacedialog.cpp`, `texwindow.cpp` |
| Grid keys | `radiant/grid.cpp` |
| Tools / modes | `radiant/tools.cpp` |
| Brush = planes + derived windings | `radiant/brush.h`, `brush.cpp`, `winding.h` |
| Map write tokens | `radiant/brushtokens.h` (classic Q3 exporter) |

### 5.1 View model

`VIEWTYPE`: `YZ=0` Side, `XZ=1` Front, `XY=2` Top. **The enum value is the hidden axis.**

```
nDim1 = (viewtype == YZ) ? 1 : 0   // Y or X
nDim2 = (viewtype == XY) ? 1 : 2   // Y or Z
```

Document space is **Quake/map space** (X right, Y forward, Z up). Convert with `lm_transform` only for the 3D camera preview and for `build_meshes()`.

Screen mapping (`XYWnd::XY_ToPoint`): widget origin top-left; Y flipped so top of widget is +nDim2.

```
nx = (2x / width) - 1
ny = (2y / height) - 1
world[nDim1] = origin[nDim1] +  nx * (width  / 2 / scale)
world[nDim2] = origin[nDim2] + -ny * (height / 2 / scale)
world[hidden] = 0  // filled from workzone / selection when needed
```

`scale` = pixels per map unit.

### 5.2 Mouse (ortho) — steal list first, then select/manipulate

Dispatch is first-match (`XYWnd::XY_MouseDown`). Simultaneous buttons ignored.

| Input | Behavior |
|---|---|
| Wheel | Zoom toward cursor (pref on). Factor 5/4 in, 4/5 out. |
| RMB drag, no mods | Pan. Zero movement on release → context menu (v1: skip menu). |
| Alt+RMB drag | Drag-zoom (optional v1). |
| LMB, no mods, **empty selection**, not clipper | New-brush drag. |
| LMB click that produces a degenerate cuboid | Tunnel into **select**, do not create a brush. |
| LMB on selected brush body | Translate in view plane (hidden axis locked), snap to grid. Shift: axis constrain. Ctrl: snap AABB edges to grid. |
| LMB on 2D silhouette (miss body, hit edge-on face) | QE4 resize: temporarily select those faces, translate planes in view plane, clear temp components on mouse up. |
| Shift+LMB | Additive / paint select primitives. |
| Ctrl+LMB | Face select outside clipper mode. In clipper mode, LMB places clip points. Quick clipper is deferred to avoid modifier ambiguity. |
| Shift+RMB drag | Box select. Device-space drag direction: right+up select, left+down deselect, other diagonals toggle. |
| Ctrl+MMB / MMB | Camera place/orient (camera view only; skip in v1 graph if needed). |

Hit radius ~12 px. Movement threshold before a click becomes a drag: small NDC epsilon (~0.5% of view).

Chase-mouse while LMB-creating near view edge: nice-to-have, not v1 required.

### 5.3 Brush creation

Only when selection is empty and clipper is off.

1. Snap press point to grid.
2. Do **not** insert a brush on mouse-down.
3. After drag exceeds snap / pixel threshold, insert a **cuboid** via 6 planes, select it, shader = current texture (or `common/caulk`).
4. Hidden-axis thickness = **workzone** AABB on that axis, snapped. Default workzone ±64 if nothing selected. If max≤min, thickness = grid size.
5. Shift: square in view plane. Ctrl: cube (square + hidden axis = that size).
6. If any axis still min==max after snap → abort (click-select instead).

N-sided brushes are **not** drag-created. Convert selected brush AABB with `Ctrl+3`…`Ctrl+9` to an N-gonal prism (axis = hidden axis of the **active** ortho view, or Z if unspecified).

### 5.4 Selection and edit keys

| Key | Action |
|---|---|
| Click empty | Deselect (cycle mode: clicking already-selected cycles depth — v1 may eReplace only). |
| Shift click | Add/remove. |
| H | Hide selected brushes in all Map editor views and clear their selection. |
| Shift+H | Unhide all hidden brushes in the active document. |
| Ctrl+Tab | Cycle the focused grid orientation XY → XZ → YZ → XY; preserve other panes and cancel any in-progress gesture first. |
| N | Open/focus the entity inspector for the selected entities or owners of selected brushes; with no selection inspect worldspawn. |
| V / E / F | Vertex / edge / face component mode. Emptying selection returns to primitive. |
| Esc | Clear components, then leave component mode, then clear primitives. |
| Space | Clone with one-grid nudge along the active view's horizontal map axis. Clones select; originals deselect. Ctrl+V remains paste-in-place. |
| Ctrl+C / Ctrl+V | Clipboard as `.map` text of selection; paste **in place**. |
| Delete / Backspace / Z | Delete selection. (Z is Radiant delete; in Godot Z is often undo — **use Delete/Backspace for delete, Ctrl+Z/Y for undo/redo**.) |
| 1–9 | Grid 1,2,4,8,16,32,64,128,256 |
| [ ] | Grid down / up through `{0.125 … 1024}` powers of two |
| Q | Drag tool (default). v1 has no transform gizmo. |
| X | Clipper mode |
| Enter | Clip (discard front) |
| Shift+Enter | Split (keep both) |
| Ctrl+Enter | Flip clip side |
| Ctrl+3…9 | Make selected brush N-sided prism |
| Ctrl+Z / Ctrl+Y | Undo / redo |

Workzone updates to selection AABB whenever selection changes (`Selection_UpdateWorkzone`).

#### Temporary brush visibility

- H applies to one or multiple selected brushes. In component mode it hides the owning brushes and clears their component selections.
- Hidden brushes are omitted from graph outlines, camera preview, click/component picking, and box/paint selection. Visible geometry behind them remains pickable.
- Shift+H reveals all hidden brushes in the active document without automatically selecting them. Either action is a no-op when there is nothing to hide/reveal.
- Visibility is document-session editor state keyed by stable brush IDs. It does not dirty or modify the `.map`, delete geometry, or exclude brushes from save/bake. Newly opened documents start with all brushes visible.
- Preserve hidden state for surviving brush IDs across geometry undo/redo and rebuilds. Hidden brushes cannot remain active edit targets. Visibility shortcuts obey the same view-focus rules as other graph shortcuts.

#### Grid snapping

- Grid snapping is enabled by default for brush creation, translation, silhouette resize, component manipulation, and clip-point placement. The active grid step is shared by all three graph views; changing it does not modify existing geometry.
- New cuboid bounds snap to map-space grid coordinates. Translation uses a snapped delta measured from the gesture's original position, never accumulated rounded mouse-motion deltas. Move multi-brush selections as a rigid group, preserving brush shapes and relative offsets.
- Already aligned brushes remain aligned during ordinary translation. Imported off-grid geometry retains its offsets under grid-step translation; Ctrl-drag aligns the selection AABB reference edges to the grid using one shared translation, rather than independently rounding every vertex.
- Resize and component tools snap their manipulated target/reference to the grid while maintaining valid planar convex brushes. Sloped faces and prism vertices are not independently rounded into a different shape. Reject invalid snapped edits atomically.
- Snapping must work with negative coordinates and fractional grid steps, preserve the hidden axis during ordinary ortho movement, and remain independent of zoom. Display the current step in map units.

### 5.5 Clipper

- Up to 3 points; in 2D default **2 points**, third synthesized: `p2 = p0 - viewdir * |p1-p0|` with `viewdir` quantized to the view’s hidden axis.
- Points snap to grid. Hidden-axis coord from selection AABB near/far extents.
- Next click after max points overwrites from 0.
- Clip: for each selected brush, classify verts vs plane. If straddles: `addPlane(p0,p1,p2)` and drop faces with &lt;3 winding verts. If entirely in **front**: delete brush. Front = discarded side; flip inverts.
- Split: copy brush; original gets `(p0,p1,p2)`, clone gets reversed `(p0,p2,p1)`; both kept; clone selected.
- New faces: caulk (`common/caulk`) by default.
- This is half-space intersection on a convex brush, **not** triangle splitting. See `csg.cpp`.

### 5.6 Textures and UVs

`Select_SetShader` (`select.cpp` ~489):

- Primitive mode: set shader on **every face** of selected brushes.
- Component/face mode: set shader on **selected faces only**.

Same branch for texdef (shift/scale/rotate).

v1 Surface panel:

- Texture name line edit + Assign to selection.
- Shift U/V, rotation, scale U/V.
- Apply writes `LMFace.uv_standard` + `uv_extra` (classic). Preserve Valve faces as Valve; do not silently convert.
- Classic-only controls are disabled for Valve faces until equivalent axis/offset transformations are implemented. Mixed selections must clearly indicate unsupported projection editing; shader assignment remains available.
- Default new-face UV: shift 0,0 rot 0 scale 1,1. Never write scale 0.

Preview UVs must use `get_standard_uv` / `get_valve_uv` so bake matches editor. Resolve texture dimensions before generating geometry, with the same nonzero fallback as `Builder::load_map`; newly registered textures currently have zero dimensions. Provide preview triangle indices, normals, and UVs in addition to outline data.

---

## 6. Architecture

```
TBMapDocument (GDExtension, RefCounted)
  owns editable map: entities, brushes, faces, patches (map space)
  load / save / export_text / import_text
  mutate: cuboid, translate, clip, prism, texture, UV, duplicate, delete
  rebuild windings via LMGeoGenerator after mutations
  emit map_changed

TBLoader (existing Node3D)
  unchanged bake to MeshInstance3D + collision
  Map Editor reads/writes loader.map_resource and may call build_meshes() after save

EditorPlugin (GDScript)
  main screen tab "Map"
  2×2: Camera (SubViewport, Godot space), material browser, two graph Controls (map space)
  each graph independently cycles Top/Front/Side with Ctrl+Tab
  texture/UV controls and N entity inspector
  toolbar: Select, Brush, Cut, Face, Vertex, Texture
```

Rules:

- Canonical coordinates: **Quake/map**. Godot conversion only at preview/build.
- Generated preview meshes are cache. Undo snapshots the document (`export_text()` is acceptable v1).
- Existing `plugin.gd` `_handles(TBLoader)` + `_make_visible` must **not** also drive the main screen. Selecting a TBLoader must not overlay the Map tab on the 3D editor. Use `selection_changed` for the spatial “Build Meshes” bar; `_make_visible` only for the Map tab.
- Register `TBMapDocument` at `MODULE_INITIALIZATION_LEVEL_SCENE` in `src/main.cpp`.
- `SConstruct` already compiles `src/*.cpp` and `src/map/*.cpp`.

Suggested new native files (names flexible):

- `src/map/map_writer.cpp` — round-trip write (faces, Valve, flags, patches, ordered epairs)
- `src/map/map_data.cpp` — add `map_data_free_geometry()` so geo can rebuild
- `src/map_document.cpp` — Godot API
- `src/map/brush_ops.cpp` — cuboid, translate, clip, prism, plane-from-points, empty-face removal

Suggested GDScript:

- `addons/tbloader/src/plugin.gd` — add main screen; keep Build Meshes
- `addons/tbloader/src/editor/map_editor.gd` — layout, document, undo, tools, workzone
- `addons/tbloader/src/editor/graph_view.gd` — NetRadiant mouse + `_draw` outlines/grid
- `addons/tbloader/src/editor/camera_view.gd` — 3D preview from document draw data

---

## 7. Native document API (contract)

Brush IDs are stable document-local 64-bit handles, independent of array position. Use `PackedInt64Array` for ID batches. Duplicate/paste/split allocate fresh IDs; deleting one brush must not retarget another brush's selection. Snapshot undo preserves IDs through accompanying identity metadata; exported `.map` text need not contain editor IDs. Component handles include the brush ID and topology revision and must be remapped or cleared after topology changes.

Minimum methods:

```
load_map(path: String) -> bool
save_map(path: String) -> bool
new_map() -> void                    # worldspawn only
export_text() -> String
import_text(text: String) -> bool
is_dirty() -> bool
get_path() -> String
rebuild() -> void                    # free geo, LMGeoGenerator::run()

get_draw_data() -> Array             # see below
get_texture_names() -> PackedStringArray

create_cuboid(mins: Vector3, maxs: Vector3, texture: String) -> int
delete_brushes(ids: PackedInt64Array) -> void
translate_brushes(ids: PackedInt64Array, delta: Vector3) -> void
duplicate_brushes(ids: PackedInt64Array) -> PackedInt64Array
make_prism(id: int, sides: int, axis: int) -> void

translate_face(id: int, face: int, delta: Vector3) -> void
translate_vertices(id: int, vertex_indices: PackedInt32Array, delta: Vector3) -> void

set_brush_texture(ids: PackedInt64Array, name: String) -> void
set_face_texture(id: int, face: int, name: String) -> void
get_face_uv(id: int, face: int) -> Dictionary
set_face_uv(id: int, face: int, shift: Vector2, rotation: float, scale: Vector2) -> void

clip_brushes(ids: PackedInt64Array, p0: Vector3, p1: Vector3, p2: Vector3, split: bool) -> PackedInt64Array
```

`get_draw_data()` element:

```
{
  id: int,
  aabb_min: Vector3, aabb_max: Vector3,   # map space
  vertices: PackedVector3Array,           # unique winding verts
  edges: PackedVector3Array,              # pairs
  faces: Array of {
    index: int,
    winding: PackedVector3Array,
    center: Vector3,
    normal: Vector3,
    texture: String
  }
}
```

Vectors in these APIs are **map space**. GDScript graph views never call `lm_transform`. Camera preview does.

This is a proposed API shape, to be frozen in Phase 0. Add structured operation/parse errors, selection clipboard export/import, identity-preserving snapshot/restore, and material-grouped preview mesh data before parallel UI implementation. Mutations must validate candidate geometry and commit atomically; a rejected operation leaves the document and undo history unchanged.

Ensure new faces call the parser’s plane recipe and `uv_extra.scale_x/y = 1`.

After clip, remove faces with winding vertex_count &lt; 3.

If map has no entities, `new_map` / first cuboid creates `worldspawn`.

Preserve patches and non-worldspawn entities on load/save even if v1 cannot edit them.

---

## 8. Editor UX requirements

### 8.1 Tab

Top-center main screen named `Map` (or `TBMap` if `Map` clashes). Icon: existing tbloader icon or `GridMap`.

Open context:

- Explicitly bind the selected `TBLoader` and load its `map_resource`. If multiple loaders exist, require an explicit choice rather than choosing the first. Keep spatial-toolbar selection separate from the document's bound loader; ordinary selection changes must not replace an open document.
- Else File → Open `.map` / New.
- Save writes the `.map`. “Rebuild on save” defaults on for a valid bound loader once the save/build integration gate passes; invoke it only after successful validation and save. Track document, saved-file, and baked-scene revisions separately.

Document lifecycle requirements:

- New/Open/replacement/close must resolve dirty work with Save/Discard/Cancel. Integrate editor exit and Save All using supported plugin lifecycle hooks; scene closure or loader deletion detaches the binding without silently destroying the open document.
- Parse into temporary storage and replace the document only on success. Use bounded/dynamic tokenization and report malformed/truncated input with useful location information.
- Save As changes the document path only on success; updating a bound loader path is explicit and marks the scene dirty.
- Save through a temporary file and atomic replacement where supported. Failed writes retain the original file and dirty state. Detect external file changes before overwriting.
- Undoing to the saved snapshot clears dirty status. Snapshot restore preserves path and saved baseline.
- Plugin teardown cancels gestures, disconnects signals, releases preview resources, and disposes document history deliberately. Re-enabling must not duplicate controls/connections.
- `build_meshes()` currently clears loader children before loading. Validate before invoking it, preserve its existing generated-child ownership contract, and report saved-map success separately from bake failure. The integration phase must establish failure reporting and scene dirty marking before enabling automatic rebuild.

Status bar: map filename/dirty state, grid size, tool, focused grid orientation, hidden count, and relevant input hints.

### 8.2 Layout

Resizable 2×2:

| Camera | Grid A (initially Top/XY) |
| Materials | Grid B (initially Front/XZ) |

The two grid panes independently cycle all three map-space orientations via Ctrl+Tab when focused. Label the active orientation and preserve each orientation's pan/zoom state. Switching orientation changes projection only, never geometry; snap/grid size remains shared. References elsewhere to Top/Front/Side mean the three supported orientations, not three simultaneously visible grids.

Material pane: project-wide indexed browser, search field, folder tree/breadcrumbs, thumbnails, and texture/UV controls. Index standalone Godot Material resources and supported texture assets throughout `res://`, not just the bound loader's texture folder. Refresh on EditorFileSystem changes; coalesce scans and load thumbnails lazily. Search by resource name/path and navigate/filter by project folder. Preserve selection during refresh where possible. Clearly distinguish the Godot resource path from the shader token saved in `.map`; use loader texture-root-relative names when resolvable, preserve native material extensions as required by loader lookup, and report unresolved mappings rather than silently assigning a wrong shader. Material assignment is undoable; index/search/folder navigation are not document edits.

Top toolbar toggle buttons: Select, Brush, Cut, Face, Vertex, Texture. These switch mode; they do not replace the NetRadiant keybindings.

### 8.3 Graph views

2D `Control._draw`, not Godot 3D cameras.

- Grid: minor coarsen until step * scale &gt; 4 px; major until &gt; 32 px. Axis colors: nDim1 reddish, nDim2 bluish (front/side vertical = green-ish, matching Radiant).
- Brush outlines from `edges`. Selected = brighter (e.g. orange). Selected faces filled translucent. Selected verts/edges as handles.
- Clip points labeled 1/2(/3) and the clip line.
- Drag-create rubber-band cuboid outline.

### 8.4 Camera view

`SubViewport` + `Camera3D`. Vertices via `lm_transform` using the bound loader’s `map_inverse_scale` (default 38). Right-click inside the camera pane enters captured-mouse fly mode: mouse look, WASD forward/back/strafe, Q/E down/up, Shift speed boost. A second right-click or Esc exits and releases capture; tab/focus loss, dialogs, and plugin teardown always release capture and clear held keys. Fly controls are frame-rate independent and only consume input while camera mode is active. Show selected brushes highlighted and honor temporary visibility. These camera-only keys take precedence over graph tool keys while flying.

### Entity inspector (N)

- Show entity classname and ordered key/value properties; preserve unknown keys. Edit/add/remove properties through the same document undo/redo stack, with mixed values for multi-entity selection rather than silently replacing unrelated values.
- Create point entities at a snapped map-space position, display/pick markers in grids and camera, and edit `origin` consistently with movement.
- Create brush entities from selected brushes, preserving geometry and reparenting their source ownership; provide a return-to-worldspawn action. Deleting entities has explicit handling of owned brushes and is undoable.
- N targets selected entities/brush owners, or worldspawn when nothing is selected. Text entry must not trigger N/H/grid/fly shortcuts. Save/reopen preserves classnames, properties, origins, and brush ownership; bake continues using existing entity mapping behavior.
- Complete FGD schema validation and entity-link visualization remain later enhancements; basic entity creation, selection, properties, ownership, and persistence are required in this delivery.

### 8.5 Undo

Every committed user operation is wrapped in `EditorUndoRedoManager`, with explicit history/context routing for bound and standalone documents:

- do: restore after-snapshot (map text plus identity/selection metadata)
- undo: restore before-snapshot

Text-backed snapshots are acceptable until finer-grained operations exist. One drag produces one history entry; motion updates are previews. Cancellation, invalid edits, and no-ops create no entry. Avoid applying an already-previewed edit twice when committing. Restore or explicitly remap selection/workzone; callbacks target the originating document rather than whichever document is active. Test routing through actual editor undo/redo, document replacement, and scene switches. Define snapshot memory limits and history disposal.

Shortcuts operate only in the appropriate Map view context, never while typing in texture/UV fields or dialogs. Cancel active gestures on focus loss/tab changes. Route undo once through the intended history; do not let graph handlers compete with editor global shortcuts.

---

## 9. Feature set by priority

P0/P1/P2 are feature priorities. Dependency-ordered implementation phases and verification gates are in §14. The full requested core workflow includes P0 **and** P1.

### P0 — blockout and persistence milestone

- [x] `TBMapDocument` load/save/new, writer round-trip of parsed maps (classic + Valve + flags + patches + epair order; tested POSIX save)
- [ ] Geo rebuild after edit
- [ ] Map main-screen tab, 2×2 layout, grid, pan, zoom-to-cursor
- [ ] Camera + material browser + two grid panes; Ctrl+Tab orientation cycling on the focused grid
- [ ] Right-click camera fly mode with reliable input capture/release
- [ ] Project material/texture index, search, folder navigation and lazy thumbnails
- [ ] Draw all brush outlines
- [ ] Bind to selected `TBLoader.map_resource`
- [ ] Cuboid drag-create with snap, workzone thickness, Shift square, Ctrl cube, degenerate → select
- [ ] Workzone maintained from selection
- [ ] Primitive select / shift-add / box-select
- [ ] H hides selected brushes; Shift+H unhides all; hidden brushes are excluded from all Map-view picking
- [ ] Move brushes in view plane
- [ ] Silhouette face resize
- [ ] Clone (Space), copy/paste map text, delete
- [ ] Grid keys 1–9 and `[` `]`
- [ ] Default-on grid snapping with rigid multi-brush movement, negative/fractional coordinates, and zoom-independent results
- [ ] Undo/redo
- [ ] Texture assign whole brush; UV shift/scale/rotate on selected brush faces (all faces if primitive)
- [ ] Minimal textured camera preview and texture-size resolution for preview/bake UV parity
- [ ] Save `.map` and rebuild TBLoader
- [ ] N entity inspector; point/brush entity creation, property editing, ownership, and undoable persistence

### P1 — Radiant parity for graph editing

- [ ] Face / vertex / edge modes with visible handles
- [ ] Assign texture to **selected faces only**
- [ ] Clipper: 2-point 2D, Enter clip, Shift+Enter split, flip, caulk cap
- [ ] `Ctrl+3`–`9` prism
- [ ] QE4 axis constrain (Shift) and AABB snap (Ctrl) while moving
- [ ] Expanded camera/material inspection UX

### P2 — later

- [ ] Valve UV manipulator / texture lock / fit/project
- [ ] Patch display and control-point edit
- [ ] CSG subtract / merge
- [ ] Phong / explicit smooth-edge authoring (hooks: `generate_brush_vertices` already reads `_phong` / `_phong_angle`)
- [ ] `brushDef` primitives if we encounter them (parser does not support them today)

---

## 10. Implementation notes for the coding agent

1. **Steal list first.** RMB-no-mod is pan, not box select. LMB-empty is create, not select — select only if the cuboid is degenerate.
2. Keep the document in map units. Never store Godot-transformed plane points.
3. Cuboid plane points: use the same winding order as TrenchBroom/Radiant cubes so `commit_face` normals point outward. Verify with a unit cube: six faces, all windings ≥3 verts after `generate_brush_vertices`.
4. Free geometry before changing topology, unless cache allocations have independent counts. Recompute changed face planes from their points before `LMGeoGenerator::run()`. Cleanup must be null-safe, idempotent, and exercised on partially loaded documents.
5. Writer must emit Valve faces as Valve and classic as classic (`LMFace.is_valve_uv`).
6. Integer-looking floats can be written as ints; keep enough precision for non-integers.
7. Do not GPL-copy NetRadiant. Reimplement algorithms from this PRD.
8. Do not break `build_meshes()` or the Map Materials panel.
9. `plugin.gd` visibility: Map tab vs TBLoader spatial toolbar are different paths.
10. Test maps: empty new map; one cuboid save/load/bake; Valve-textured map round-trip; clip a cube in Top view; assign two textures to two faces; Ctrl+5 prism.

### Cuboid face template (map space mins→maxs)

Outward-facing points under `commit_face`'s reversed-cross convention. Verify six outward normals, eight unique vertices, twelve unique edges, bounded positive volume, and all vertices inside every half-space:

```
+X  (x1,y0,z0) (x1,y1,z1) (x1,y1,z0)
-X  (x0,y0,z1) (x0,y1,z0) (x0,y1,z1)
+Y  (x0,y1,z0) (x1,y1,z1) (x0,y1,z1)
-Y  (x0,y0,z1) (x1,y0,z0) (x0,y0,z0)
+Z  (x0,y0,z1) (x1,y1,z1) (x1,y0,z1)
-Z  (x1,y0,z0) (x0,y1,z0) (x0,y0,z0)
```

### Clip algorithm (reimplementation of `BrushSplitByPlaneSelected`)

```
P = plane3_for_points(p0, p1, p2)   # same point order as commit_face
# front: dot(P.normal, vertex) - P.dist > epsilon; inside: <= epsilon
for brush B in selection:
  classify unique verts vs P  (eps ~ 1/4096 or CMP_EPSILON)
  if straddles:
    if split:
      C = deep copy B
      C.add_face(p0, p2, p1, caulk)  # reversed
      remove empty faces on C
      insert C, select C
    B.add_face(p0, p1, p2, caulk)
    remove empty faces on B
  else if not split and entirely front:
    delete B
```

---

## 11. Acceptance criteria (P0)

- Opening the Godot editor shows a `Map` tab next to 2D/3D/Script.
- Binding a selected `TBLoader` with a valid `map_resource` loads brush outlines in Top/Front/Side; later selection changes do not replace that document.
- Dragging a box in Top with empty selection creates a grid-snapped cuboid whose thickness comes from workzone/grid; saving produces a `.map` that `build_meshes()` imports as a box.
- Click-without-drag selects; Shift-click adds; Delete removes; Ctrl+Z restores.
- Select several brushes and press H: they disappear from all four Map views and cannot be picked or box-selected. Shift+H reveals them all. Saving/baking while hidden retains every brush, and visibility changes alone do not mark the map dirty.
- With grid 16, aligned brushes create/move/resize on that grid; multi-brush translation preserves relative offsets. Repeat at negative coordinates and grid 0.5, with different zoom levels, and obtain the same map-space results.
- Moving a brush in Top does not change Z; Front does not change Y; Side does not change X.
- Assigning `textures/base_wall/example` to a selected brush writes that shader on all six faces; bake uses the same name for material lookup.
- Changing scale U on a classic-textured brush changes its face preview UVs in a way that matches a subsequent bake (`get_standard_uv`). Individual face selection is required in P1.
- A map with Valve 220 faces and a `patchDef2` loads and saves without dropping those blocks (patches may be uneditable).
- Existing “Build Meshes” button still appears when a `TBLoader` is selected in the 3D editor.

---

## 12. Risks

- Texture projection parity: editor preview vs writer vs `geo_generator` vs Radiant. Always go through existing UV functions.
- Floating-point planes: snapping, clip, and vertex drags can produce degenerate hulls. Validate boundedness, convexity, face planarity, finite values, and positive volume. Redundant empty faces may be removed after clipping; an invalid resulting solid must be rejected atomically.
- `LMMapData` malloc model is fragile; document must deep-copy brushes on duplicate/split and free geo on rebuild.
- Fixed token buffers currently accept unchecked input; bounded/dynamic tokenization and malformed-input tests are prerequisites for opening files and pasting clipboard text.
- Large maps: `get_draw_data()` + full rebuild per edit will get slow; v1 is fine for blockout-scale maps. Dirty-brush rebuild is P2.
- Godot editor shortcut conflicts (Z, Space, X, F). Prefer Radiant keys inside the Map tab when it has focus; never steal Ctrl+Z from the editor.

---

## 13. Open decisions (defaults if unimplemented)

| Topic | Default |
|---|---|
| Tab title | `Map` |
| Default shader | `common/caulk` |
| Clone nudge | One grid step on active view nDim1 after Space clone |
| Delete key | Delete / Backspace only (not Z) |
| Rebuild on save | On for a valid binding after save/build integration gate passes |
| Component vertex move | Shared-vertex/incident-face mapping; accept only validated planar convex results. Never derive a face blindly from its first three moved vertices. Reject unsupported deformation with an explanatory diagnostic. |
| Prism axis | Hidden axis of the last focused graph view |

---

## 14. Autonomous implementation phases and exit gates

Deliver P0 and P1 through the phases below. P2 remains future scope. An implementer may proceed between phases autonomously once each gate passes, fixing failures before advancing. A stub, successful compilation, or a screenshot alone does not establish feature completion.

### Phase 0 — Runnable baseline, fixtures, and frozen contracts

Deliver:

- Establish the supported Godot version and pin the test executable/version. The extension advertises 4.1 minimum while vendored API metadata is 4.2.2; verify the intended compatibility baseline rather than inferring it from either file alone.
- Build the existing extension before feature changes; record baseline failures separately from regressions.
- Create a dedicated first-party Godot test project under `tests/map_editor/`, using the actual addon/native library. The existing `godot-cpp/test` project tests a different extension.
- Add fixture maps and a test runner with explicit completion markers, nonzero failure exit codes, stdout/stderr capture, and external timeouts.
- Freeze document ownership, API/error returns, snapshots/IDs, preview mesh data, loader binding, and undo history routing. Write these contracts down before assigning UI work.

Exit gate: baseline library loads in the selected Godot version; test runner demonstrates both successful execution and a deliberate assertion failure returning failure. Engine/editor errors must not be mistaken for successful completion.

### Phase 1 — Reliable editable document and map persistence

Deliver transactional parser, semantic-preserving writer, safe cache ownership, `TBMapDocument` registration, new/load/save/snapshot APIs, and dirty/saved-baseline tracking. Correct patch representation and tokenizer limitations as necessary.

Exit gate:

- Parse/write/parse semantic equality for classic and Valve faces; absent/zero/nonzero flags; ordered epairs; point/brush entities; def2/def3 patches with header fields, subdivisions and control-point UVs; fractional and negative coordinates.
- Repeated serialization is deterministic after initial normalization.
- Missing/malformed/truncated input and unsupported syntax preserve the current document on failure.
- Failed saves preserve the original file. Snapshot restoration preserves path and identity and correctly updates dirty status.
- Repeated load/reset/rebuild/destruction and partial-parse cleanup pass an available memory checker or instrumented native test target. Record instrumentation coverage and any engine-originated suppressions explicitly.

### Phase 2 — Validated brush operations

Deliver cuboid, move, plane resize, duplicate/delete, selection clipboard, texture/classic UV edits, stable IDs, draw data, and preview mesh data. Geometry operations work independently of mouse handling.

Exit gate:

- Known cuboid has 6 outward faces, 8 vertices, 12 edges, correct bounds/volume; all vertices satisfy every retained half-space.
- Translation preserves dimensions and shifts bounds by the exact requested map-space delta. Resizing changes the intended planes only.
- Batch deletion and duplication preserve surviving identities; pasted brushes receive fresh IDs and maintain entity ownership, textures, and UVs.
- Invalid/no-op operations preserve the document. Duplicate/split ownership never aliases source allocations.
- UVs are finite and use resolved texture dimensions. Classic edits and untouched Valve projections survive save/load.

### Phase 3 — Main-screen integration and graph authoring

Deliver Map tab, independent loader binding, resizable camera/material/two-grid layout, graph transforms/grid, Ctrl+Tab orientation cycling, pick/selection, workzone, create/move/resize gestures, shortcuts, and document undo/redo. Add camera preview and right-click fly mode.

Exit gate:

- Tests exercise actual graph event handlers/controller integration, not just direct native method calls: click versus drag, Shift selection, directional box selection, snapped creation, workzone thickness, move, resize, clone/paste/delete, and cancellation.
- Top/Front/Side operations preserve hidden Z/Y/X respectively. Screen-to-map-to-screen round trips and cursor-centered zoom are correct.
- Ctrl+Tab cycles only the focused grid, maintains geometry and per-orientation view state, and works repeatedly in both panes. Camera fly input only works while captured; Esc/right-click/focus loss release it and prevent stuck movement.
- H/Shift+H tests cover multi-selection, all-view visibility, picking visible brushes behind hidden ones, component selection cleanup, and unchanged map serialization/dirty state. Save/bake includes hidden brushes.
- Grid tests cover creation/move/resize, group offset preservation, imported off-grid translation, negative/fractional coordinates, and identical final geometry at different zoom levels. Add Ctrl-AABB/component/clip snapping tests with their Phase 5 tools.
- One completed drag creates one undo entry; cancel/no-op creates none. Undo/redo restores geometry and selection, including dirty-state restoration at the saved baseline.
- Headless editor-mode integration confirms class registration, main-screen lifecycle, toolbar/material-panel behavior, document-specific undo routing, loader deletion/scene changes, and disable/re-enable without duplicate controls or signal connections.

### Phase 4 — Texturing, persistence UX, and bake integration (P0 complete)

Deliver project-wide indexed material browser with search/folder navigation, surface panel, textured preview, N entity inspector and point/brush entity authoring, New/Open/Save/Save As, dirty-document handling, external-change detection, Save All integration, and save-then-build for a valid binding.

Exit gate:

- Brush texture assignment affects all intended faces; classic UV changes are visible and preview UV data matches saved/reloaded bake output within a documented tolerance. Use an asymmetric checker texture to expose rotation/axis errors.
- Save success, bake success, and stale bake state are distinguishable. Failure never causes a rebuild against a different loader.
- Editing shader/UV text does not invoke graph shortcuts. New/Open/close cancellation preserves work. Failed save and external-file-change handling are exercised.
- A fresh editor process can reopen the saved map and bake expected mesh bounds, materials, and collision. Existing Build Meshes and Map Materials still function.
- Material fixtures in different project folders appear in the index; name/path search and folder filters select the expected resources. Resource add/remove updates the browser. Assignment writes the intended map token and preview/bake resolves the same resource.
- N inspector edits worldspawn, point and brush entities. Create/move/property-edit/reparent/delete operations undo/redo correctly and survive save/reopen with correct origins and ownership; unknown properties are retained.

### Phase 5 — Clipper, prisms, and component editing (P1 complete)

Deliver face/edge/vertex picking and overlays, per-face texture assignment, clip/split/flip, N-sided prisms, axis constraint/AABB snap, and validated component deformation.

Exit gate:

- Split a known cube at its midpoint: two valid convex solids, complementary cap normals, caulk caps, and summed volume equal to the input within tolerance.
- Clip/flip retain the expected half; entirely-front/back, coplanar, tangent, near-degenerate, and multi-brush cases have explicit tested outcomes. Undo restores both topology and selection.
- For N=3 through 9 on each axis, a prism has N side faces plus two caps, expected axis/depth, valid windings, and a valid round-trip.
- Assigning a texture to one face leaves every other face unchanged.
- Vertex/edge moves use incident topology and reject nonplanar, inverted, unbounded, or zero-volume results atomically. Include valid constrained deformations and rejected single-corner quad deformations; do not claim arbitrary mesh modeling support.

### Phase 6 — Display-backed acceptance and handoff

Run the actual Godot editor with a display or suitable virtual display/software renderer. Automate repeatable input sequences and capture screenshots plus serialized map assertions. Use in-engine event injection for reproducible widget tests and window-system input where available to validate real focus/mouse capture. Headless tests do not establish visual correctness.

Required end-to-end journey:

1. Open the test scene and bind its TBLoader in the Map tab.
2. Create and move brushes in all three graph views; resize, clone, paste, and undo/redo.
3. Texture a brush, then one face; adjust classic UVs and inspect the checker preview.
4. Clip and split a brush, flip the kept side, and create a five-sided prism.
5. Save and bake; restart the editor; reopen and verify map geometry/materials and generated collision.
6. Exercise text-field focus, dialogs, tab switching, splitter resizing, loader selection changes, and plugin disable/re-enable.
7. Cycle both grids through all orientations, enter/exit camera fly mode, search materials across folders, create a point entity and a brush entity using N, then undo/redo and save/reopen those entity edits.

Exit gate: each P0/P1 requirement has passing evidence or is explicitly reported incomplete. Deliver reproducible commands, fixture list, test results, screenshot paths, known limitations, and measured performance for a small and a representative larger map (report brush/face counts, rebuild time, gesture responsiveness, and memory). Set a numerical performance budget after the baseline is measured rather than claiming arbitrary large-map support.

---

## 15. Subagent execution model

The coordinating agent owns contracts, integration, phase gates, and the completion report. Delegate independent work with explicit file ownership and expected verification; avoid concurrent edits to the same files.

| Workstream | Ownership | Dependencies |
|---|---|---|
| Native document agent | Parser/model preservation, writer, cache ownership, native document/brush operations | Phase 0 contract; geometry depends on Phase 1 |
| Editor UI agent | Graph controls, camera preview, surface panel, gesture/controller logic | Frozen API; may scaffold against a clearly labeled test double until native integration |
| Test agent | Fixtures, headless document suite, editor integration harness, interaction/acceptance automation | Frozen contracts; progressively test real native/editor implementation |
| Coordinator | Plugin registration, build configuration, cross-layer integration, lifecycle/undo decisions, acceptance tracking | Integrates completed workstreams and runs combined tests |

At each integration point, assign an independent review of the delivered changes and test coverage. Reviewers report findings; the owner fixes them. UI demonstrations using mocks do not count toward acceptance. The coordinator must run combined tests after integration; individual agent claims are not sufficient evidence.

Continue autonomously through planned P0/P1 gates; resolve ordinary implementation decisions using this document. Record deviations and rationale. Pause only for genuinely blocking environment access or a product decision that changes the requested behavior. Keep a live implementation checklist and do not mark an unchecked gate complete to move on.

---

## 16. Test environment and reproducible commands

Environment preflight on 2026-09-13:

- `scons`, `g++`, and `clang++` are available on `PATH`.
- `godot`/`godot4`, `Xvfb`/`xvfb-run`, and `xdotool` were not found on `PATH`.
- Engine location supplied after preflight: `../godot`. Confirmed `../godot/bin/godot.linuxbsd.editor.x86_64 --headless --version` runs and reports `4.8.dev.custom_build.3924ec46f`. Use this local editor executable for the initial test baseline; extension loading and compatibility still need Phase 0 verification.
- This shell has neither `DISPLAY` nor `WAYLAND_DISPLAY`. Installed `ydotool`/`grim` alone do not provide a usable editor display session.
- No first-party TBLoader test project or test runner was found. These must be delivered in Phase 0.

Use the confirmed local Godot executable and record its version with test results. Establish a usable display-backed test environment before claiming full verification. If display automation cannot be provisioned, implementation and headless tests can proceed, but Phase 6 stays incomplete.

The following commands implement the **Phase 0 harness interface**. `document` currently verifies the real TBLoader runtime before TBMapDocument exists; `editor` verifies real editor-plugin lifecycle/history; `ui` is display feasibility/editor screenshot smoke, not Phase 6 acceptance. See `tests/map_editor/README.md` for coverage and failure probes. `GODOT_BIN` is the absolute path to the pinned engine executable.

```bash
# Run from the repository root. Prepare the test project with the actual addon
# and freshly built library; isolate debug/release artifacts (names currently overlap).
export GODOT_BIN="/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64"
scons platform=linux target=template_debug arch=x86_64 -j2
python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite document
python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite editor
python -m unittest discover -s tests/map_editor -p test_harness.py -v
DISPLAY=:0 python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite ui
```

Runner obligations:

- Stage a disposable project and writable fixture copies, import resources, and load the real extension. Never mutate reference/source maps as test outputs.
- Document suite: headless runtime with assertions against native document APIs and independent geometry invariants.
- Editor suite: headless **editor mode** with a test plugin/harness that exercises editor lifecycle and undo APIs. A runtime `SceneTree` script cannot substitute for editor integration.
- UI suite: display-backed editor with rendering enabled, interaction assertions, screenshots, saved-map inspection, and fresh-process reopen/bake checks.
- Every suite enforces a timeout, requires an explicit completion marker, checks exit status and engine/script errors, and captures logs/artifacts on failure. A process exiting successfully before tests run is a failure.
- Instrument native ownership separately as needed with ASan/UBSan or an available memory checker; record the actual supported build/run invocation when established.

Original review: two independent source reviews plus environment preflight. Phase 0 subsequently built/loaded the extension and ran runtime, editor and failure-detection tests. X11 `:0` supports display-backed smoke without system modifications; Wayland `wayland-1` crashed with engine GLES3 errors. See the implementation progress document for exact results and remaining gates.
