# TBLoader Hotspot Texturing PRD

Status: Draft

Audience: implementation engineer / LLM

Related documents:

- `MAP_EDITOR_PRD.md` defines the in-Godot `.map` authoring workflow.
- `MAP_EDITOR_IMPLEMENTATION.md` documents the current native document and editor architecture.
- `MAP_EDITOR_UI_IMPLEMENTATION.md` documents current editor behavior and validation.

## 1. Problem

Texture sheets and trim sheets contain many reusable regions, but the Map Editor
currently treats each texture as one repeating surface. A mapper must manually
calculate UV shift, scale, and rotation whenever a brush face should use one
specific panel, trim, doorway, floor tile, or other region of a sheet.

This makes atlas-based environment art slower and less consistent than hotspot
workflows available in tools such as Scythe or Hammer 2. It is especially costly
when applying coordinated regions to many faces or repeatedly using the same
texture sheets across maps.

Users need to define meaningful regions once, collect them into a reusable
project library, and apply them directly or automatically to selected brush
faces.

## 2. Product Outcome

Add **Hotspot Texturing** to the Map Editor.

A mapper can define named rectangular regions on a texture sheet, select brush
faces, and apply a region with a chosen fitting policy. The editor can also rank
compatible regions using face dimensions, aspect ratio, orientation, and tags.

The operation assigns the texture token and writes ordinary `.map` face UV
projection values. Hotspot metadata remains external to the `.map`, preserving
compatibility with existing map tools and the TBLoader build path.

## 3. Goals

- Define, edit, preview, and remove rectangular hotspots on texture sheets.
- Store hotspot sets as project assets suitable for source control.
- Browse hotspots by texture, name, tag, compatibility, favorite, and recent use.
- Apply one hotspot to explicitly selected faces.
- Treat every face of selected brushes as a target when no face components are
  selected, matching the current material-assignment target behavior.
- Support direct selection and smart matching workflows.
- Assign texture and UV projection as one atomic, undoable operation.
- Respect texel density, padding, orientation, rotation, mirroring, and fit policy.
- Prevent sampling bleed at hotspot boundaries.
- Preserve `.map` round-tripping and the existing material resolver.
- Remain responsive while painting or applying hotspots to many faces.
- Provide a foundation for future whole-brush presets and trim workflows.

## 4. Non-goals

- Do not add arbitrary per-vertex UVs to convex brush faces.
- Do not deform or warp a hotspot to match every corner of an irregular polygon.
- Do not embed hotspot definitions in `.map` comments or entity properties.
- Do not change runtime material lookup or the mesh baking contract.
- Do not automatically modify source textures.
- Do not pack textures or generate an atlas in the first delivery.
- Do not make patch control-point UV editing part of the first delivery.
- Do not infer semantic tags from image content in the first delivery.
- Do not guarantee seamless continuity across unrelated or non-coplanar faces in
  the first delivery.
- Do not copy implementation code from external editors.

## 5. Current Behavior And Constraints

### 5.1 Selection and assignment

The editor already represents face targets using brush ID, face index, topology
revision, and component kind. Explicit face components are used when present;
otherwise all faces belonging to selected brushes become targets.

Material assignment can target complete brushes or individual faces. UV editing
uses the same effective face selection and records changes through the existing
session transaction and undo system.

Hotspot texturing must extend this behavior rather than introduce a second
selection model.

### 5.2 Brush UV representation

A brush face stores a planar affine projection:

- classic projection: shift, rotation, and two scale values;
- Valve projection: explicit U and V world-space axes and offsets, plus scale;
- generated face windings derive their UVs from those projection values.

This representation can place a projected face inside a rectangular atlas
region, including rotation and mirroring. It cannot independently position each
polygon corner. Irregular faces therefore use projected bounds, not arbitrary
mesh unwrapping.

Classic UV projection is writable today. Valve UV values can be queried but are
currently read-only through `TBMapDocument::set_face_uv()`. Complete Hammer-style
alignment on sloped surfaces requires writable Valve axes.

### 5.3 Texture dimensions

UV generation depends on resolved texture dimensions. The editor already sends
resolved dimensions to the native document. An unresolved texture currently
falls back to `1x1`, which is not sufficient for hotspot application.

Hotspot application must require a known positive source size matching the
definition, or present an explicit recoverable warning.

### 5.4 Document edits

Native surface operations currently canonicalize and reparse the map. Applying
texture and UV changes one face at a time would create unnecessary work and
intermediate document states. Hotspot application therefore requires a native
batch operation that validates all targets before committing once.

## 6. Terminology

| Term | Meaning |
|---|---|
| Texture sheet | One source texture containing multiple useful regions. |
| Hotspot | A named rectangular region of a texture sheet and its matching metadata. |
| Hotspot set | All hotspot definitions associated with one texture token and source size. |
| Target | A selected brush face eligible for hotspot application. |
| Face frame | The planar U/V basis used to measure and project one target face. |
| Fit policy | The rule used to map projected face bounds into a hotspot rectangle. |
| Smart Match | Ranking compatible hotspots independently for each target face. |
| Brush preset | A future rule set that assigns different hotspot roles to faces of one brush. |

## 7. Primary Workflows

### 7.1 Create a hotspot set

1. Open a texture in the material browser.
2. Choose **Create Hotspot Set**.
3. Confirm the map texture token and detected source dimensions.
4. Draw one or more rectangles on the texture.
5. Name and configure each rectangle.
6. Save the set as a project asset.

Creating a hotspot set does not modify the texture, map document, selection, or
undo history.

### 7.2 Apply one hotspot to selected faces

1. Select one or more face components.
2. Select a hotspot from the active set.
3. Choose a fit policy and optional rotation or mirroring.
4. Preview the result on the current selection.
5. Apply.

The editor assigns the hotspot set's texture token and computes a UV transform
for each face. All targets commit as one undo action.

### 7.3 Apply to selected brushes

1. Select one or more brushes without selecting face components.
2. Select a hotspot.
3. Apply to Selection.

All faces of the selected brushes become targets. The same hotspot is fitted
independently to each face. This is deterministic manual application, not Smart
Match.

### 7.4 Smart Match

1. Select faces or brushes.
2. Choose one hotspot set or library filter.
3. Enable **Compatible only** and review ranked candidates.
4. Choose **Smart Apply**.
5. Review the preview and confirm.

Smart Match scores every target independently. The UI must explain why the
winning hotspot was selected and allow the user to cycle to the next compatible
candidate before committing.

### 7.5 Paint hotspots

The existing Texture Tool gains an active hotspot state. A face click applies the
active hotspot; a drag may paint it across newly encountered faces. One completed
gesture is one undo action.

Exact modifiers must be selected after checking existing camera, component
selection, and material-paint bindings. Hotspot input must not shadow selection,
camera navigation, clipping, or component editing controls.

The tool should support these actions without requiring fixed initial bindings:

- apply the active hotspot;
- sample a face's texture and recognized hotspot;
- cycle compatible candidates;
- temporarily suppress Smart Match;
- apply only to the newly entered face during a paint gesture.

## 8. Hotspot Editor

### 8.1 Layout

Provide a dedicated bottom panel or a mode within the UV workspace containing:

- the complete texture at pixel-accurate aspect ratio;
- zoom and pan controls;
- optional pixel, power-of-two, and custom grid overlays;
- hotspot rectangle overlays, labels, and selection handles;
- a properties inspector for the selected hotspot;
- face preview using the current map selection;
- validation and save status.

The editor must remain useful on narrow layouts and must not require a floating
window for ordinary editing.

### 8.2 Rectangle editing

Users can:

- drag to create a rectangle;
- move and resize selected rectangles;
- enter exact X, Y, width, and height values;
- snap edges to pixels or a configured grid;
- duplicate and delete rectangles;
- multi-select rectangles for shared property edits;
- temporarily hide labels and non-selected rectangles;
- zoom to a rectangle or the full sheet.

Pixel coordinates are authoritative. Normalized UV bounds are derived using the
declared source dimensions.

### 8.3 Hotspot properties

Each hotspot supports:

- stable ID;
- display name;
- pixel rectangle;
- tags;
- optional role;
- edge padding in pixels;
- priority;
- enabled state;
- allowed rotations;
- horizontal and vertical mirroring permissions;
- default fit policy;
- optional preferred world width and height;
- optional minimum and maximum aspect ratio;
- optional orientation filter;
- optional notes.

Roles are conventional project-defined strings such as `wall`, `floor`,
`ceiling`, `trim`, `beam`, `door`, or `panel`. The file format must not hard-code
that vocabulary.

### 8.4 Creation assistance

The first delivery should support fixed-grid slicing. Given a cell size, origin,
spacing, and outer margin, the editor creates one hotspot per cell for review.

Automatic image-island detection and semantic classification are future work.

### 8.5 Validation

The editor warns about:

- rectangles outside the source bounds;
- empty or sub-pixel rectangles;
- duplicate stable IDs;
- duplicate names within a set;
- padding that consumes the usable rectangle;
- unsupported rotation values;
- overlapping rectangles;
- missing or unresolved textures;
- source dimensions that differ from the saved set.

Overlap is a warning, not an error, because deliberately nested hotspots are
valid. Out-of-bounds or empty rectangles block application.

## 9. Library And Browser

### 9.1 Project storage

Hotspot sets are project assets stored beneath a configurable project directory,
with `res://hotspots/` as the default. They must be text-based, deterministic,
diffable, and independent from editor-local state.

Recommended naming:

```text
res://hotspots/industrial_walls.hotspots.json
res://hotspots/gothic_trim.hotspots.json
```

One file describes one texture token. A texture can have at most one effective
hotspot set after project resolution. Duplicate definitions produce a diagnostic
instead of silently overriding one another.

### 9.2 Personal state

Favorites, recent use, browser sorting, and panel layout are editor preferences.
They reference stable hotspot IDs and do not duplicate project definitions.

### 9.3 Browsing

The material browser should:

- mark textures with available hotspot sets;
- show hotspot thumbnails for the active texture;
- search names, tags, roles, and texture tokens;
- filter to candidates compatible with the current target faces;
- show favorites and recently used hotspots;
- retain the active hotspot while selection changes;
- clearly distinguish unresolved, invalid, and dimension-mismatched sets.

Selecting a hotspot makes its texture token the pending texture but does not
modify the map until the user applies or paints it.

## 10. Data Model

The persisted schema must be versioned. This conceptual example is normative for
the represented information, not exact serialization syntax:

```json
{
  "version": 1,
  "id": "industrial-walls",
  "texture": "textures/industrial/walls_sheet",
  "source_size": [2048, 2048],
  "hotspots": [
    {
      "id": "wall-panel-narrow",
      "name": "Wall Panel Narrow",
      "rect": [512, 0, 128, 256],
      "tags": ["wall", "vertical", "narrow"],
      "role": "wall",
      "padding": [2, 2, 2, 2],
      "priority": 0,
      "enabled": true,
      "rotations": [0, 180],
      "mirror_x": false,
      "mirror_y": false,
      "fit": "contain",
      "preferred_world_size": [64, 128],
      "aspect_range": [0.45, 0.55],
      "orientation": "vertical"
    }
  ]
}
```

Unknown optional fields may be preserved when safely possible. An unsupported
major schema version must fail with a clear diagnostic and must not be rewritten.

Texture tokens use the same canonical rules as `.map` faces. Definitions must
not depend on a resolved `.tres`, `.material`, or image extension path because
the material resolver can map one token through multiple resource forms.

## 11. Fitting And Projection

### 11.1 Face measurement

For each target, the native document must provide or internally calculate:

- ordered face winding in map space;
- face normal;
- stable planar U and V axes;
- projected minimum and maximum extents;
- projected width, height, and aspect ratio;
- orientation classification;
- current projection kind;
- current texture token and UV transform.

Dimensions are measured in map units before Godot render-space scaling.

### 11.2 Usable hotspot bounds

The usable rectangle is the pixel rectangle inset by its four padding values.
The inset must leave positive width and height. Application maps into this usable
rectangle, not the full stored rectangle.

Padding protects against filtering and mipmap bleed. It does not change the
source texture or duplicate border pixels.

### 11.3 Fit policies

The first complete delivery supports:

| Policy | Behavior |
|---|---|
| Stretch | Scale U and V independently so projected face bounds fill the hotspot. |
| Contain | Preserve aspect ratio and keep all projected bounds inside the hotspot. |
| Cover | Preserve aspect ratio and fill the hotspot, allowing projected bounds to extend beyond it. |
| Natural | Preserve configured texel density or preferred world dimensions and anchor inside the hotspot. |

`Tile` is deferred unless the projection can guarantee that sampling remains
inside the hotspot region. Ordinary GPU wrap modes repeat the complete texture,
not one atlas sub-rectangle, so naive hotspot-local tiling is invalid.

Each policy must define a deterministic anchor. The default is center. Future
anchors may include corners and edge centers without changing the data model.

### 11.4 Rotation and mirroring

Candidate evaluation may test only rotations declared by the hotspot. The first
delivery supports multiples of 90 degrees. Mirroring is considered only when the
corresponding hotspot permission is enabled.

The application preview must make orientation visible. Smart Match cannot
silently mirror artwork.

### 11.5 Irregular faces

The projected winding's axis-aligned bounds are fitted into the hotspot. Parts of
the hotspot may remain unused for triangular or irregular faces. This is expected
brush-format behavior and must not be presented as an error.

## 12. Smart Match

### 12.1 Candidate filtering

A hotspot is incompatible when:

- it is disabled or invalid;
- its set texture cannot be resolved to the declared dimensions;
- its orientation filter rejects the face;
- the face aspect is outside its explicit aspect range for every allowed
  rotation;
- the requested role or tag filter rejects it;
- the face projection kind cannot be written.

### 12.2 Ranking

Compatible candidates receive a deterministic score based on:

- aspect-ratio error after allowed rotation;
- preferred-world-size error when configured;
- orientation agreement;
- role and tag agreement;
- hotspot priority;
- avoiding mirroring when an unmirrored candidate is equally suitable;
- stable ID as the final tie-breaker.

Score weights belong to the hotspot system configuration and must have documented
defaults. Candidate ordering must not depend on file enumeration order.

### 12.3 Explanation

The UI shows at least:

- selected candidate name;
- chosen rotation and mirroring;
- face and hotspot aspect ratios;
- fit policy;
- any preferred-size mismatch;
- why no candidate is compatible.

The mapper can cycle ranked candidates for one or all targets before confirming.

## 13. Brush Presets

Whole-brush semantic presets are a later phase built on the same hotspot model.
A preset can classify faces using normal and dimensions, then request hotspot
roles such as:

- upward face to `top` or `floor`;
- downward face to `bottom` or `ceiling`;
- near-vertical faces to `side` or `wall`;
- narrow faces to `trim`;
- end caps to `cap`.

Presets select from hotspots; they do not contain copied UV rectangles. Manual
face assignments always override automatic classification during preview.

## 14. Native Document Contract

### 14.1 Batch operation

Provide one native operation conceptually equivalent to:

```text
apply_face_hotspots(targets, applications, options)
```

Each application identifies a target, texture token, source dimensions, usable
pixel rectangle, fit policy, rotation, mirroring, and optional density or anchor.

The operation must:

1. Validate all brush IDs, face indices, and topology revisions.
2. Validate every texture token, source size, rectangle, and fitting option.
3. Reject unsupported projection kinds before changing the document.
4. Calculate all resulting projections from native face geometry.
5. Assign textures and UV projections in one mutable candidate document.
6. Commit and regenerate preview geometry once.
7. Return one success or a structured failure without partial changes.

The operation must not depend on mutable editor selection after invocation.

### 14.2 Valve projection

Writable Valve U/V axes are required before Valve faces can participate in the
complete workflow. The API must preserve finite, non-degenerate axis validation
and canonical `.map` serialization.

An MVP may support classic faces only if:

- Valve targets are rejected before mutation;
- the preview identifies unsupported targets;
- mixed classic and Valve selections do not partially apply;
- the UI does not imply that Valve support exists.

### 14.3 Preview query

The existing UV preview wraps generated coordinates into one repeating tile.
Hotspot preview requires unwrapped coordinates so that atlas placement is
visible. The preview API or editor path must expose unwrapped UVs and preserve
coordinates outside `[0, 1]` for diagnostics.

## 15. Undo, Selection, And Failure

- One button application or completed paint gesture creates one undo action.
- Undo restores every affected texture token and UV projection together.
- Redo reapplies the exact resolved applications, not a newly evaluated Smart
  Match result.
- Applying hotspots must preserve brush and component selection.
- Face targets must be validated using topology revisions before mutation.
- Surface edits that preserve face order should rebind selected components using
  the existing session mechanism.
- Any invalid target causes the complete operation to fail without document or
  history changes.
- Previewing candidates does not dirty the document or create undo history.

## 16. Performance Requirements

- Opening the hotspot browser must not decode every project texture eagerly.
- Thumbnail loading and library indexing may be incremental and cached.
- Candidate metadata should be indexed independently from full-resolution images.
- Smart Match for 256 selected faces against 1,000 indexed hotspots should
  complete within 100 ms on the pinned development environment after indexing.
- Applying 256 faces should perform one native document commit and one preview
  regeneration.
- A paint gesture must not reapply a face already visited in that gesture.
- Repeated hover previews should not mutate or reparse the map document.

## 17. Diagnostics And Safety

Every failure must identify the hotspot set, hotspot, and target face when
applicable. Expected diagnostic categories include:

- invalid hotspot schema;
- duplicate set for texture token;
- unresolved texture token;
- source-size mismatch;
- invalid or padded-empty rectangle;
- stale face target;
- unsupported projection;
- degenerate face frame;
- invalid computed UV transform;
- document commit failure.

The last valid library index and map preview should remain usable when one hotspot
asset fails to load. Invalid assets are excluded from application rather than
silently normalized.

## 18. Delivery Phases

### Phase 1: Definitions and manual classic application

- Versioned project hotspot asset format.
- Library indexing and material-browser badge.
- Hotspot editor with manual rectangles, exact fields, padding, and validation.
- Thumbnail browsing.
- Manual application to classic-projection face selections.
- Stretch and Contain fitting.
- Atomic native batch operation and undo.
- Unwrapped UV preview.

### Phase 2: Projection completeness and painting

- Writable Valve projection axes.
- Mixed classic and Valve target support.
- Cover and Natural fitting.
- Rotation, mirroring, anchors, and preferred world dimensions.
- Texture Tool painting and face sampling.
- Fixed-grid hotspot generation.

### Phase 3: Smart Match

- Compatibility filtering and deterministic scoring.
- Candidate explanations and cycling.
- Tags, roles, orientation, aspect ranges, and priorities.
- Favorites, recent use, and Compatible-only browsing.

### Phase 4: Brush intelligence

- Brush presets and face-role classification.
- Manual override preview.
- Coordinated cap, side, top, bottom, and trim workflows.
- Optional cross-face alignment where planar projections permit it.

### Future

- Patch hotspot application through patch control-point UVs.
- Image-island detection.
- Project-assisted texture-sheet generation or packing.
- Shared team preset packages.
- More advanced seam and adjacency rules.

## 19. MVP Acceptance Criteria

The first delivery is complete when all of the following are demonstrated:

1. A user creates and saves a hotspot set for a resolved texture sheet.
2. The saved text asset reloads with stable IDs and identical pixel rectangles.
3. The material browser identifies the texture as hotspot-enabled and displays
   hotspot thumbnails.
4. A user selects one classic-projection face, previews a hotspot, and applies it.
5. The resulting face samples only the padded usable hotspot bounds under Stretch
   fitting, within floating-point tolerance.
6. Contain fitting preserves aspect ratio and remains inside the usable bounds.
7. Applying one hotspot to a multi-face or brush selection computes each face
   independently and commits one undo action.
8. The same action assigns both the hotspot texture token and UV projection.
9. Undo and redo restore texture and UV values without changing selection.
10. Invalid, stale, Valve, unresolved, or dimension-mismatched targets cause no
    partial document mutation.
11. The UV workspace displays unwrapped atlas coordinates rather than folding all
    coordinates into one tile.
12. Saving and reopening the `.map` preserves the applied texture and projection
    using ordinary supported face syntax.
13. The `.map` contains no required hotspot metadata and remains usable without
    the hotspot library.
14. Applying 256 faces uses one native document commit and meets the documented
    responsiveness target on the pinned environment.

## 20. Open Product Decisions

- Use JSON assets, Godot `Resource` assets, or a small custom text format.
- Make the hotspot editor a dedicated bottom panel or a mode of the UV pane.
- Choose default scoring weights and whether projects may override them.
- Define the default world-unit-to-pixel density for Natural fitting.
- Decide whether source-size mismatches can be explicitly migrated by scaling
  rectangles or must always be corrected manually.
- Select paint and sampling bindings after resolving conflicts with current face
  selection and camera controls.
- Decide whether the Phase 1 MVP should ship before writable Valve UV support or
  wait for projection-complete behavior.
