# Phase 7: Command-First Transform Commands PRD

**Status:** Implementation-ready proposal
**Date:** 2026-09-18
**Product area:** Radiant Map editor, brush transforms
**Related documents:** `MAP_EDITOR_PRD.md`, `MAP_EDITOR_IMPLEMENTATION.md`, `MAP_EDITOR_UI_IMPLEMENTATION.md`, `MAP_EDITOR_PERFORMANCE.md`, `HISTORY_NAVIGATION_PRD.md`, `tests/map_editor/README.md`, `PHASE_8_INTERACTIVE_TRANSFORMS_PRD.md`

## 1. Summary

Add command-first brush transforms to the Map editor: world-axis and active-grid
mirrors, exact quarter turns, numeric rotation, keyboard nudging, numeric uniform
or nonuniform scale, numeric skew, repeat, and duplicate-and-repeat. Every brush
Phase 7 command transform uses the center of the merged selected-brush bounds as
its pivot unless the command is a translation. Phase 8 interactive gestures may
pass their documented opposite-handle/edge pivots to the same typed native APIs.

Expose typed native methods for each product operation while routing them through
one private, validated double-precision affine implementation. Preview and commit
must use the same staging and validation logic. A transform is atomic across the
complete brush selection, keeps face texture metadata unchanged, and uses texture
lock off. Point entities support nudge only in this phase.

## 2. Problem

The editor currently supports grid/camera translation and arbitrary drag rotation,
backed by `translate_brushes`, `rotate_brushes`, and matching native preview APIs.
It does not offer discoverable transform commands, numeric entry, reflection,
scale, skew, or a repeat workflow. The existing rotation path applies trigonometry
to supporting-plane points independently in preview and commit, so it is not a
sufficient contract for exact quarter turns or a general affine feature family.

Users consequently cannot perform common deterministic construction operations
without manipulating individual components. Ad hoc implementations would risk
different preview and commit geometry, inward plane winding after reflection,
partial multi-selection edits, accidental UV changes, and inconsistent history.

## 3. Goals

- Provide menu-driven mirror, rotate, nudge, scale, skew, repeat, and
  duplicate-and-repeat commands.
- Make exact 90-degree rotations free of trigonometric residue.
- Keep a single native validation and transformation kernel behind typed APIs.
- Use the merged selected-brush bounds center as the Phase 7 command pivot.
- Correct face point winding for every negative-determinant transform.
- Validate the whole selection and commit it atomically as one history event.
- Guarantee that successful preview geometry exactly equals committed draw data.
- Preserve face material, UV projection metadata, shifts, rotation, scales, and
  surface flags byte-for-byte.
- Make keyboard behavior explicit on Linux, Windows, and macOS.
- Store repeat state in the active `map_session.gd` session, not globally.
- Extend native, document, editor, displayed UI, and OS-input coverage.

## 4. Non-Goals

- Interactive scale or skew handles; those are Phase 8.
- 3D camera manipulators for scale or skew.
- A custom/user-positioned pivot.
- Texture lock or compensation of UV metadata for moved geometry.
- Affine rotation, scale, mirror, or skew of point entities.
- Patch transforms, component transforms beyond existing component translation,
  entity angle/property rewriting, or brush-entity origin synthesis.
- Local/object axes, arbitrary axis-angle rotation, transform matrices in the UI,
  transform stacks, or destructive vertex welding.
- Persisting repeat state across document close, plugin reload, or editor restart.
- Exposing a generic matrix/affine mutation API to GDScript.

## 5. Current Architecture and Constraints

- `src/map_document_ops.cpp` implements local brush mutations through
  `local_brush_transaction()`. It copies only selected brush records, validates
  rebuilt editor geometry, and installs all changed records in one commit.
- `translate_brushes()` has a retained-geometry fast path. `rotate_brushes()` uses
  the same local transaction but directly applies sine/cosine to every supporting
  plane point. Both are `POSITIONS` mutations and preserve topology tokens.
- `preview_translate_brushes()` and `preview_rotate_brushes()` stage selected
  fragments and return exact candidate draw dictionaries without changing text,
  IDs, revisions, dirty state, history, or prepared caches.
- `src/map/map_edit.cpp::lm_edit_rotate_brush()` is the older full-edit preview
  rotation helper. It transforms only plane points and intentionally leaves texture
  and surface metadata owned by the original face.
- `map_session.gd::transact()` is the editor atomic/history boundary. It restores
  its captured native state when a multi-call operation fails.
- `graph_view.gd` already derives a merged selection center and sends exact native
  previews to `map_editor.gd`. The editor coalesces high-frequency previews and
  broadcasts candidates to every camera pane.
- `camera_view.gd` builds shared candidate hull and edge meshes from native draw
  dictionaries. Candidate preview is disposable and commits only on release.
- `map_editor.gd::route_key()` owns Map-pane shortcuts and resolves pane-sensitive
  targets from Phase 2's `active_slot`/active grid. It deliberately yields to text
  fields (including embedded SpinBox editors), dialogs, the material browser, and
  unrelated editor UI.

## 6. UX Contract

### 6.1 Transform menu

Populate Phase 3's reserved **Transform** file-menu and grid-context-menu submenu and command-ID range. Its
items and all transform shortcuts call Phase 3's central
`dispatch_map_command(command_id)` path. A `MenuButton` named
`TransformMenu` may also be added in a normal toolbar group after the mode tools and
before loader actions as an affordance that opens the same command model; it must
not own divergent callbacks. Use the editor transform icon, the `FlatMenuButton`
variation, tooltip **Transform selected brushes**, and accessibility name
**Transform selected brushes**.

Rebuild enabled states when the popup opens. Menu layout:

```text
Mirror X
Mirror Y
Mirror Z
Mirror Horizontal                 Ctrl/Cmd+Shift+H
Mirror Vertical                   Ctrl/Cmd+Shift+V
--------------------------------
Rotate +90 degrees                Ctrl/Cmd+Shift+]
Rotate -90 degrees                Ctrl/Cmd+Shift+[
Rotate Numeric...
Scale Numeric...
Skew Numeric...
--------------------------------
Repeat Transform                  Ctrl/Cmd+Shift+R
Duplicate and Repeat              Ctrl/Cmd+Shift+D
```

- World X/Y/Z commands work when a supported Map pane is active.
- Horizontal/vertical and quarter-turn commands require `active_slot` to contain
  a grid pane; that pane is the active grid.
  Horizontal maps to `graph.axes().x`, vertical maps to `graph.axes().y`, and
  quarter turns rotate about `graph.orientation`.
- `+90` is counterclockwise in the active grid as rendered; `-90` is clockwise.
  The graph's screen Y inversion must be accounted for rather than guessed from
  raw pointer coordinates.
- Brush-only commands are disabled when no brushes are selected. A simultaneous
  point selection is ignored by brush-only commands and remains selected.
- Commands requiring a grid are disabled, not silently redirected to the last grid,
  when `active_slot` contains Camera, UV, Entities, or Layers.
- Layer-locked brushes are unselectable under Phase 6. If stale/supplied IDs include
  a locked member, the UI command rejects the complete transform with a clear notice;
  it never filters and transforms only an unlocked subset. Native APIs still validate
  every supplied brush ID and remain independent of transient lock state.
- Disabled items expose the reason through the existing status/tooltip style.

### 6.2 Nudge

- Nudge is **not** Alt+Arrow. Phase 2 consumes Alt+Arrow for pane movement.
  Phase 7 must choose a later chord; until then nudge is menu-only.
- Left/right use the grid's projected horizontal world axis. Up/down use its
  projected vertical world axis, with Up moving toward the top of the rendered
  graph. The hidden axis delta is zero.
- Nudge is one transaction per non-echo key press. Key repeat from the OS is
  intentionally ignored by the existing `event.echo` guard.
- If brushes and points are selected, both move in one session transaction. Any
  invalid brush or point rolls the complete mixed operation back.
- When `active_slot` is not a grid, the future nudge chord is not consumed
  because a deterministic projection axis is unavailable.

### 6.3 Numeric dialog

Use one reusable `ConfirmationDialog` named `TransformDialog`, with a title and
fields changed by mode. It is modal and follows existing editor scaling.

- **Rotate Numeric:** axis option X/Y/Z and signed degrees field. Initial axis is
  the `active_slot` grid's hidden axis when available, otherwise Z. Initial angle
  is 90.
- **Scale Numeric:** mode toggle **Uniform** / **Per Axis**. Uniform exposes one
  factor; per-axis exposes X/Y/Z factors. Initial values are 1.
- **Skew Numeric:** distinct **Source axis** and **Destination axis** options plus
  a dimensionless factor. The equation is `destination += factor * source_offset`.
  Equal axes are invalid. Initial factor is 0.
- Every field has a visible label and accessibility name. Axis meaning and units
  are textual; color is not the only indication.
- Enter/Return applies only when valid. Escape and the dialog Cancel button close
  without preview, mutation, history, or repeat-state changes.
- Validation appears inline and disables Apply. Native failure after Apply leaves
  the dialog open and reports the native error.
- Opening a transform dialog first cancels any graph/camera gesture preview.

### 6.4 Platform shortcuts

Use `event.is_command_or_control_pressed()` for shortcuts documented as Ctrl/Cmd.
Use physical arrow and bracket keycodes so keyboard-layout text does not alter the
operation. Alt means Option on macOS through Godot's `alt_pressed` flag.

Do not register global editor shortcuts. Route within the existing Radiant input
boundary and target `active_slot`, preserving text-field, embedded SpinBox editor,
browser, popup, and modal-dialog exclusions regardless of which child has keyboard
focus. Phase 2 owns Alt+Arrow for pane movement. Nudge has no keyboard chord in
this phase until a non-colliding binding is chosen; the menu remains the
discoverable fallback.

### 6.5 Completion and errors

- A successful changed command creates exactly one history event and updates the
  repeat descriptor.
- A valid no-op creates no history event and does not replace the prior descriptor.
- A failure changes no document, selection, history, or repeat descriptor.
- Use concise labels: **Mirror map selection**, **Rotate map selection**, **Nudge
  map selection**, **Scale map selection**, **Skew map selection**, **Repeat map
  transform**, and **Duplicate and repeat map transform**.

## 7. Functional Requirements

### FR-1 Typed native surface

Bind typed methods on `TBMapDocument`:

```cpp
Dictionary get_brush_bounds(const PackedInt64Array &ids) const;
Dictionary mirror_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis);
Dictionary rotate_brushes_quarter(const PackedInt64Array &ids, Vector3 pivot, int axis, int quarter_turns);
Dictionary rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians);
Dictionary scale_brushes(const PackedInt64Array &ids, Vector3 pivot, Vector3 factors);
Dictionary skew_brushes(const PackedInt64Array &ids, Vector3 pivot, int source_axis, int destination_axis, double factor);
Dictionary preview_mirror_brushes(... ) const;
Dictionary preview_rotate_brushes_quarter(... ) const;
Dictionary preview_rotate_brushes(... ) const;
Dictionary preview_scale_brushes(... ) const;
Dictionary preview_skew_brushes(... ) const;
```

The ellipsized preview signatures match their commit counterparts. Do not bind a
generic `Transform3D`, `Basis`, matrix, or Dictionary transform method. Translation
keeps its existing typed methods and fast path.

### FR-2 Selection bounds and pivot

`get_brush_bounds()` validates and deduplicates every ID, reads current compact
geometry, and returns `{ok, changed: false, value: AABB}`. Empty input fails with
`INVALID_ARGUMENT`; an unknown ID fails with `INVALID_ID`.

The session resolves the pivot immediately before preview or commit as
`bounds.position + bounds.size * 0.5`. It never averages brush centers. Repeat and
duplicate-and-repeat recompute the pivot from their current target selection. The
pivot is captured once for an operation so selection/cache notifications cannot
change it midway.

### FR-3 Internal affine helper

Add an internal value type using doubles:

```cpp
struct LMEditAffine {
    double linear[3][3];
    vec3 translation;
};
```

Provide internal construction/application functions in `map_edit.h/.cpp`. The
document has private `transform_brushes()` and `preview_transform_brushes()` helpers
that accept a validated `LMEditAffine`, operation name, and typed operation data.
Only typed public methods construct an affine.

For each supporting-plane point, compute `p' = linear * p + translation` in double
precision. Transform all selected drafts before any state is installed. Rebuild and
validate through the existing compact editor geometry path.

### FR-4 Exact quarter rotations

Quarter turns normalize modulo four. Use exact integer axis-permutation/sign
coefficients around the pivot, not `sin()`/`cos()`, so coefficients contain no
trigonometric residue. Zero modulo four is an exact no-op. Four successive quarter
turns restore the same geometry semantically within canonical serialization
precision; bit-identical floating-point plane coordinates are not guaranteed around
an arbitrary non-exact pivot.

Arbitrary numeric rotation remains radians at the native boundary, normalizes with
`remainder`, and constructs its affine once. Preview and commit share that affine
constructor. Angles equivalent to a quarter turn are not silently coerced to the
exact API; UI quarter commands call `rotate_brushes_quarter()` explicitly.

### FR-5 Mirror

Mirror negates one coordinate relative to the pivot: `p'[axis] = 2*pivot[axis] -
p[axis]`. World and grid mirror commands differ only in axis selection. A mirror has
determinant -1 and must invoke winding correction.

### FR-6 Scale

Scale uses `p' = pivot + factors * (p - pivot)`. Uniform scale sends the same factor
on all axes. Nonuniform scale sends independently entered factors. Negative factors
are supported and deliberately create reflections. A zero or near-zero factor is
invalid; no flattening operation is provided.

### FR-7 Skew

For distinct source `s` and destination `d`, skew uses:

```text
p'[d] = p[d] + factor * (p[s] - pivot[s])
p'[other axes] = p[other axes]
```

This shear has determinant +1. Axis order is semantically significant and is stored
exactly in repeat state.

### FR-8 Reflection winding correction

After transforming all three supporting points of a face, if the affine determinant
is negative, swap `plane_points.v1` and `plane_points.v2` exactly once. This retains
the repository's outward-normal convention (`(p2-p0) x (p1-p0)`) after reflection.
Do not reorder faces or copy metadata from another face.

### FR-9 Atomicity and identity

Deduplicate IDs in source/document order. Validate all IDs and arguments before
mutation. Build and validate all selected brushes before installing any record.
Failure leaves canonical text, state generation, revision, topology revision,
stable IDs, dirty state, caches, history, and selection unchanged.

Affine brush transforms are position-domain edits and retain each brush ID, owner,
face order, and topology token. Negative determinant alone is not topology change;
the supporting-point swap is representation correction.

### FR-10 Preview/commit parity

Each preview calls the same affine constructor, point transform, determinant test,
winding correction, and geometry validation as commit. Preview returns the existing
candidate draw schema and mutates no document state. Given the same source state,
IDs, pivot, and typed parameters, every candidate field equals `get_draw_data()` for
the committed brushes, not merely approximately where the Variant values are exact.

### FR-11 Point entities

Only nudge may transform selected point entities in Phase 7, using the existing
`translate_point_entities()`. Mirror, rotate, scale, skew, repeat, and
duplicate-and-repeat target brushes only. The UI must not imply that selected points
were transformed. Mixed nudge uses `map_session.gd::transact()` rollback to preserve
atomicity across the native brush and point calls.

### FR-12 Repeat descriptor

Each session owns `last_transform: Dictionary = {}`. Its closed schema is:

```text
{kind: "translate", delta: Vector3}
{kind: "mirror", axis: int}
{kind: "quarter_rotate", axis: int, quarter_turns: int}
{kind: "rotate", axis: int, radians: float}
{kind: "scale", factors: Vector3}
{kind: "skew", source_axis: int, destination_axis: int, factor: float}
```

Do not store target IDs, pivot, AABB, callable, document reference, or preview data.
Set it only after a changed, successful explicit transform. Repeat itself also
counts as successful use but leaves the descriptor semantically unchanged.

Clear it on New/Open, native epoch replacement, session disposal, and document
close. Keep it across selection changes, save, history navigation within the same
epoch, and tab switches. It is not part of content history and is not restored by
undo/redo.

### FR-13 Repeat and duplicate-and-repeat

Repeat applies the descriptor to the current brush selection. Translation reuses
its world delta; pivoted commands recompute current merged bounds center. It is
disabled for empty brush selection or absent descriptor.

Duplicate-and-repeat requires a brush selection and descriptor. In one
`transact()` callback, duplicate selected brushes, select only the returned IDs,
recompute their merged pivot, and apply the descriptor. Failure restores document
and selection. It creates one history event. Translation does not receive the old
clone helper's additional grid offset; the repeated descriptor is the only movement.

### FR-14 Existing behavior

Existing graph/camera move and rotate gestures continue to work. Existing
`rotate_brushes()` remains source-compatible but is refactored onto the affine
kernel. Existing Space clone remains unchanged and does not set repeat state.

## 8. Architecture and Native Math

### 8.1 Construction

Construct every affine in native doubles. Validate axis indices before indexing.
Compose pivoted transforms as translation within the affine, not as three rounded
Godot `Vector3` operations. A linear transform `L` around pivot `c` has translation
`c - L*c`.

Compute determinant from the 3x3 linear part. Reject non-finite coefficients,
translation, determinant, and transformed points. Require `abs(det) >= 1e-12`.
Scale additionally requires every `abs(factor) >= 1e-9`. All coefficients,
parameters, pivot coordinates, and resulting coordinates must have absolute value
at most `1e9`, matching the current document bound.

### 8.2 Validation result codes

- `INVALID_ID`: any target is not a live brush.
- `INVALID_ARGUMENT`: empty bounds query, bad axis, equal skew axes, non-finite or
  out-of-range value, singular/near-singular affine, or out-of-bounds point.
- `INVALID_GEOMETRY`: transformed candidate is not a finite closed solid with
  nonempty faces.
- `LIMIT_EXCEEDED`: canonical text would exceed the existing 16 MiB limit.

Return the standard Result dictionary and include operation-specific operation names
such as `scale_brushes` and `preview_scale_brushes`.

### 8.3 Dirty domains and cache behavior

Use `LMEditorBrushDirtyDomain::POSITIONS`. Recompute plane normals/distances and
compact geometry for non-translation affine edits. Do not claim topology dirty.
Retain existing spatial/preview cache transition behavior and document-change
mementos. Translation continues using its specialized geometry and session draw
cache patch paths; do not regress it to the general affine rebuild.

## 9. Detailed Implementation by File

### `src/map/map_edit.h`

- Declare `LMEditAffine` and internal constructors/application helpers.
- Document double precision, pivot composition, determinant, and negative-winding
  correction.
- Retain `lm_edit_rotate_brush()` as a compatibility wrapper over affine application
  or replace its internal callers with the new helper without exposing it to Godot.

### `src/map/map_edit.cpp`

- Implement matrix-vector application, determinant, exact quarter-turn matrices,
  arbitrary world-axis rotation, mirror, scale, and skew constructors.
- Implement one brush application loop that transforms supporting points and swaps
  v1/v2 on negative determinant.
- Ensure construction does not alter any `LMEditFace` member except plane points.

### `src/map_document.h`

- Declare the typed public bounds/commit/preview APIs in FR-1.
- Declare private affine commit/preview helpers; keep `LMEditAffine` native-only.

### `src/map_document_ops.cpp`

- Implement `get_brush_bounds()` from current compact geometry.
- Refactor arbitrary rotation and preview onto the affine helpers.
- Add mirror, exact quarter rotation, scale, skew, and preview counterparts.
- Keep commit on `local_brush_transaction()` and preview on staged fragments.
- Centralize affine and transformed-point validation so preview and commit cannot
  diverge.
- Preserve materials and all face metadata by mutating only draft plane points.

### `src/map_document.cpp`

- Bind every typed API with explicit parameter names.
- Do not bind the internal affine type or generic helper.

### `addons/tbloader/src/editor/map_session.gd`

- Add session-owned `last_transform` and clear it at the lifecycle boundaries in
  FR-12.
- Add small dispatch methods to resolve bounds/pivot and invoke typed native APIs.
- Add `perform_transform(descriptor, preview := false)` with strict descriptor
  schema checking; this is UI dispatch, not geometry math.
- Add atomic mixed-selection nudge and duplicate-and-repeat transaction helpers.
- Update repeat state only after a changed successful transaction.

### `addons/tbloader/src/editor/map_editor.gd`

- Populate Phase 3's file-menu Transform submenu/ID range and build `TransformDialog` using
  existing menu/dialog helpers. An optional toolbar `TransformMenu` opens the same
  command definitions and dispatcher.
- Implement menu rebuilding, commands, numeric validation, status text, and
  `active_slot`-targeted shortcut routing through Phase 3's `dispatch_map_command()`.
- Cancel active interactions before modal commands and before immediate transforms.
- Keep fields out of `route_key()` handling through the existing focus exclusions.
- Refresh all graph selections and camera content once after commit.

### `addons/tbloader/src/editor/graph_view.gd`

- Expose a tested mapping from screen horizontal/vertical direction to signed world
  axis for grid mirror and menu/future-chord nudge.
- Use the native bounds query for command pivots; retain current gesture behavior.
- Cancel disposable preview when a command starts.

### `addons/tbloader/src/editor/camera_view.gd`

- No new manipulator. Ensure command-triggered refresh clears stale candidate meshes
  and shows committed geometry in every camera pane.

### `tests/map_editor/native_document_test.cpp`

- Add standalone affine math tests independent of Godot wrappers: exact quarter
  permutations, determinant signs, winding correction, skew axis order, singular
  rejection, metadata preservation, and repeated-transform stability.

### `tests/map_editor/document_suite.gd`

- Cover all bound typed APIs, result schemas, validation, atomicity, deduplication,
  metadata, topology tokens, history mementos, and exact preview/commit equality.

### `tests/map_editor/editor_suite.gd`

- Cover menu enablement, axis mapping, pivots, dialog dispatch, history labels,
  mixed nudge rollback, repeat isolation per session, and duplicate-and-repeat.

### `tests/map_editor/window_input_observer.gd` and OS-input runner files

- Observe real shortcut routing, modal focus, Escape, Option/Alt arrows, and ensure
  one physical key press yields at most one transaction.

### `tests/map_editor/current_editor_performance_probe.gd`

- Add one-brush and 256-brush preview/commit samples for scale and skew, candidate
  broadcast counts, touched-brush counts, allocations, and frame responsiveness.

## 10. Validation

- UI validation is advisory; native validation is authoritative.
- Reject non-finite values, axis values outside 0..2, equal skew axes, factor
  magnitudes outside documented bounds, near-singular determinant, and resulting
  coordinates outside +/-`1e9`.
- Validate duplicate IDs once and transform once.
- Validate every candidate brush as closed/nonempty before installation.
- Preview failure clears all candidate panes and reports an actionable error without
  dirtying or adding history.
- Commit revalidates against current document state; it never trusts an earlier
  preview or stale bounds result.
- Numeric text is parsed using Godot numeric controls but passed as typed values;
  locale display must not produce locale-dependent native serialization.

## 11. UV and Texture Semantics

Texture lock is explicitly **off** for all Phase 7 transforms. Geometry moves under
the existing face projection metadata.

- Keep texture token/material, classic UV shifts, Valve UV axes/offsets, UV rotation,
  UV scale, and surface flags unchanged on their original face records.
- Do not rotate, scale, mirror, skew, renormalize, or compensate UV axes or offsets.
- Do not choose metadata by spatially matching transformed faces.
- Winding correction swaps only supporting-plane point v1/v2. It does not swap UV
  axes or face metadata.
- Candidate rendering may visually show changed texture placement resulting from
  unchanged metadata; this is expected and must match commit.

## 12. Edge Cases

- Empty brush selection: command disabled; direct native mutation is a no-op for
  compatibility except `get_brush_bounds`, which fails because no pivot exists.
- Duplicate IDs: transform once in source order.
- Mixed brush/point selection: only nudge affects points.
- Negative one-axis scale: equivalent geometry to mirror and corrected winding.
- Two or three negative factors: determinant sign controls one correction, not the
  number of individual swaps.
- Full-turn arbitrary rotation and quarter turns modulo four: exact no-op.
- Factor 1, skew 0, translation zero: no-op and no history/repeat update.
- Very small nonzero factors below `1e-9`: reject rather than create unstable solids.
- A valid affine that collapses a particular brush because its geometry has no span
  along an affected direction: geometry validation rejects the complete selection.
- Brushes owned by different entities: allowed; ownership remains unchanged.
- Hidden selected brushes: transformed because selection, not visibility, defines
  targets. Preview may be absent from filtered views but commit remains atomic.
- Locked layer members are pruned from selection when locked. A command receiving
  stale locked IDs rejects the whole UI operation with no subset transform; direct
  native calls continue to validate supplied IDs without consulting transient locks.
- Selection changes while a dialog is open: Apply targets the live selection and
  computes live bounds; closing/opening documents closes the dialog.
- Undo/redo after repeat: history restores content/selection but not repeat state.
- Session/tab switch: dialog closes; each session retains only its own descriptor.
- Failed duplicate-and-repeat: duplicated IDs and temporary selection are rolled
  back by `transact()`.

## 13. Accessibility and Platform Requirements

- All menu rows, axis selectors, modes, factors, validation errors, and buttons have
  descriptive labels/accessibility names and keyboard focus order.
- Direction, validity, and determinant/reflection state are never color-only.
- Dialog supports keyboard traversal, Enter apply, and Escape cancel without leaking
  the key to graph shortcuts.
- Respect editor scale and translated labels; no hard-coded field widths that clip
  common 200% UI scaling.
- Test Ctrl on Linux/Windows semantics and Command on macOS logic. Test Option/Alt
  routing where the OS delivers it and retain menu access where it does not.
- Do not consume transform shortcuts outside the Radiant input boundary or while a
  protected text/browser/popup/dialog surface owns input; target `active_slot`, not
  the keyboard-focused pane.

## 14. Performance Requirements

- Cost is proportional to selected brushes/faces, not total map size.
- Preview and commit must not materialize or parse the whole canonical map for local
  transforms. Counters must show zero parser, writer, geo-generator, and deep-clone
  calls on the local path.
- Preserve translation's compact-geometry/session-cache fast path.
- Coalesce previews to at most one camera candidate upload per rendered frame.
- A 256-brush command preview must remain interactive under the existing controlled
  60 Hz probe; record p50/p95 and compare to current rotation preview rather than
  inventing an unmeasured absolute budget.
- Candidate meshes remain bounded to transformed selection geometry and are released
  on cancel/session replacement.

## 15. Test Plan

### Native math and sanitizer tests

- Test all axes and quarter counts -5..5 against exact expected coordinates.
- Test arbitrary rotations, mirrors, positive/negative scale combinations, and all
  six ordered skew axis pairs.
- Assert determinant/winding behavior and outward generated normals.
- Assert all texture/UV/surface fields are bitwise unchanged.
- Fuzz finite affine parameters around limits and run ASan/UBSan/leak checks.

### Document tests

- Multi-brush merged pivot with asymmetric bounds and mixed owners.
- Preview then commit equality for every operation and determinant sign.
- Duplicate IDs, invalid ID among valid IDs, non-finite inputs, singular factors,
  limits, invalid resulting geometry, 16 MiB limit, no-op behavior, exact undo/redo,
  dirty state, IDs, and topology tokens.
- Classic and Valve UV fixtures with non-default metadata and surface flags.
- Four quarter rotations use residue-free coefficients and restore semantically
  equivalent canonical geometry within serialization precision, including arbitrary
  floating pivots.

### Editor tests

- Menu order, labels, enabled states, accessibility properties, active-axis mapping,
  dialog defaults/validation, status errors, and history event count.
- Put keyboard focus in a different pane and in protected text/SpinBox fields; prove
  commands target `active_slot`/its grid or are ignored, never the focus owner.
- Lock selected layers and assert immediate brush/component pruning; inject stale
  locked IDs and assert UI commands reject the whole transform with no partial edit.
- Point-only, brush-only, and mixed nudge; forced second-call failure proves rollback.
- Repeat after each transform; no-op/failure does not replace prior descriptor.
- Per-session isolation, tab switch, history navigation, epoch reset, and disposal.
- Duplicate-and-repeat creates/selects only copies and undoes in one step.
- Every camera pane receives candidate/refresh and stale previews clear.

### OS-input and displayed tests

- Real mouse opens menu/dialog and real keyboard traverses fields and cancels.
- Real Ctrl/Cmd+Shift transform shortcuts target `active_slot` only within
  the Radiant input boundary. Alt+Arrow remains Phase 2 pane movement.
- Text fields and embedded SpinBox editors receive arrows/brackets normally and are
  never transformed based on incidental keyboard focus.
- Focus loss, synthetic release, tab switch, and Escape never commit a pending
  interaction.
- Run at normal and 200% editor scale on available Linux X11/Xwayland; execute
  Windows/macOS CI smoke coverage when those runners exist.

### Performance tests

- Measure one and 256 selected brushes for preview/commit scale and skew.
- Assert touched-brush and rebuild counters, no full parse/materialization, one
  transaction, bounded candidate uploads, and no retained candidate growth.

## 16. Acceptance Criteria

- All listed commands are available and correctly enabled in the Transform menu.
- Mirrors and negative scales produce valid outward-facing brushes through explicit
  determinant-based winding correction.
- Quarter rotations use exact axis permutation/sign math.
- Every Phase 7 pivoted command uses the merged selected-brush AABB center; Phase 8
  interactive operations may pass opposite-handle/edge pivots.
- Every transform is atomic, undoable in one step, and preserves stable identity.
- Preview and commit use shared math/validation and produce equal candidate geometry.
- Face texture and UV metadata remain unchanged with texture lock off.
- Point entities move only through nudge.
- Repeat is session-owned, parameter-only, lifecycle-safe, and recomputes pivots.
- Duplicate-and-repeat is one atomic transaction and selects the copies.
- Native sanitizer, document, editor, displayed UI, OS-input, and performance suites
  pass with no new stderr, engine, script, sanitizer, or leak errors.

## 17. Dependencies and Rollout

1. Land native affine math and standalone tests behind no UI entry points.
2. Bind typed document commit/preview methods and land document parity tests.
3. Depend on Phase 2's `active_slot` routing, Phase 3's file-menu Transform
   submenu/`dispatch_map_command()`, and Phase 6's lock predicates and immediate selection pruning.
4. Add session dispatch/repeat state and editor menu/dialog/nudge commands.
5. Add OS-input and performance gates, then enable the menu by default.
6. Use this released typed API and candidate path as the prerequisite for Phase 8.

No map format migration or feature flag is required. Existing maps and history state
remain compatible because transforms change only canonical plane coordinates through
normal transactions. If performance or parity gates fail, do not expose the command;
do not retain an alternate GDScript geometry implementation.

## 18. Decisions

- Typed native operation APIs are public; the generic affine is private.
- The merged selected-brush AABB center is the only Phase 7 pivot.
- Exact quarter turns have a dedicated API and integer matrix path.
- Negative determinant is supported and corrected by one v1/v2 swap per face.
- Scale factors may be negative but may not be zero/near-zero.
- Skew is ordered source-to-destination shear with a dimensionless factor.
- Texture lock is off and all face texture metadata is unchanged.
- Brush transforms preserve topology tokens and ownership.
- Point entities support only nudge, which is menu-only until a non-colliding chord is chosen.
- Repeat stores parameters in the session, recomputes pivots, and is not content
  history or persisted state.
- Duplicate-and-repeat performs no implicit clone offset.
- Phase 2 `active_slot` grid axes define grid-relative commands; keyboard focus does
  not retarget them, and unsupported active panes do not invent axes.
