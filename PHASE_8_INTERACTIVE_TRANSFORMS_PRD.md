# Phase 8: Interactive Graph Scale and Skew PRD

**Status:** Implementation-ready proposal, dependent on Phase 7
**Date:** 2026-09-18
**Product area:** Radiant Map editor, interactive graph transforms
**Related documents:** `PHASE_7_TRANSFORM_COMMANDS_PRD.md`, `MAP_EDITOR_PRD.md`, `MAP_EDITOR_IMPLEMENTATION.md`, `MAP_EDITOR_UI_IMPLEMENTATION.md`, `MAP_EDITOR_PERFORMANCE.md`, `HISTORY_NAVIGATION_PRD.md`, `tests/map_editor/README.md`

## 1. Summary

Add interactive scale and skew gestures to 2D graph panes after Phase 7's typed
native transform APIs ship. A brush selection receives one merged projected
selection rectangle with edge/corner scale handles and separate skew handles.
Dragging computes a fixed press-time pivot and candidate bounds, requests exact
native preview geometry, displays that preview in every camera pane and the active
graph, and commits exactly one session transaction on a valid release.

The feature explicitly supports crossing the pivot: a dragged scale handle may pass
through the fixed pivot and produce a negative factor/reflection. The handle has an
invalid dead zone at zero scale; native determinant and brush validation remain
authoritative. Invalid candidates show visible feedback and never commit.

## 2. Problem

Phase 7 makes scale and skew deterministic but dialog-driven. Iterative level design
also needs direct manipulation in orthographic panes. Existing graph gestures cover
move, rotation, and component resize, but they do not expose merged-selection scale
or skew geometry. Implementing these as screen-only overlays would diverge from
native geometry validation, camera preview, cancellation, and history semantics.

The interaction also has ambiguous cases that must be settled before implementation:
which bounds own the handles, where the pivot stays, what Shift means, what happens
at and beyond the center, how invalid previews look, and whether focus loss or tab
switch commits. This PRD fixes those contracts.

## 3. Goals

- Display one merged selection rectangle for all selected brushes in each graph.
- Provide edge and corner scale handles and unambiguous skew handles.
- Derive scale/skew from press-time source bounds and a fixed pivot.
- Support Shift constraints with deterministic world-space math.
- Support intentional center crossing and reflection while rejecting zero scale.
- Use Phase 7 native preview and commit methods without duplicate geometry math.
- Render exact candidate geometry in all camera panes during the gesture.
- Commit one transaction on valid release and none on invalid/cancelled release.
- Define Escape, focus, tab, tool, selection, and application-focus cancellation.
- Preserve accessibility, platform input behavior, and large-selection performance.

## 4. Non-Goals

- 3D camera scale/skew manipulators or camera-initiated scale/skew gestures.
- A custom pivot, pivot handle, pivot movement, or persisted pivot.
- Texture lock or any UV metadata adjustment.
- Point-entity affine transforms; point entities are excluded from these gestures.
- Patch transforms, component scale/skew, face extrusion, taper/perspective transforms,
  arbitrary affine cages, vertex snapping, or proportional editing.
- Scaling the graph view, grid, workzone, camera, entity icons, or editor chrome.
- Multi-touch transform gestures.
- Replacing Phase 7 numeric dialogs or repeat commands.

## 5. Prerequisite and Existing Architecture

Phase 8 may begin only after Phase 7 provides validated typed
`scale_brushes`/`preview_scale_brushes` and
`skew_brushes`/`preview_skew_brushes`, shared affine math, negative-determinant
winding correction, merged native bounds, and exact preview/commit parity.

Relevant current behavior:

- `graph_view.gd` is a `Control` with layered drawing, orthographic projection
  helpers, native selection hit tests, grid snapping, gesture state, focus-loss
  cancellation, host-observed gesture cancellation for central Escape, and
  release-time transactions.
- `graph_view.gd::update_exact_preview()` already calls native preview methods for
  move, rotate, resize, and component gestures.
- `map_editor.gd::queue_mutation_preview()` keeps only the latest successful native
  candidate and dispatches at most once per frame. `broadcast_mutation_preview()`
  sends candidate dictionaries to every registered camera pane.
- `camera_view.gd::set_candidate_preview()` renders exact candidate hulls and edges,
  reuses buffers when topology signatures match, and shows an offscreen indicator.
- Synthetic releases and application/window focus loss currently cancel rather than
  commit. This safety rule remains authoritative.
- `map_session.gd::transact()` records one content event and rolls back a failed
  multi-call operation.

## 6. UX Contract

### 6.1 Activation

Add **Scale** and **Skew** exclusive tools to the existing mode toolbar after Rotate
and before component tools. Use editor/custom icons consistent with the current flat
icon buttons.

- Scale shortcut: plain `T` within the Radiant input boundary; it activates Scale
  for the pane in Phase 2's `active_slot`.
- Skew shortcut: plain `K` under the same routing and targeting boundary.
- Tooltips: **Scale Tool (T)** and **Skew Tool (K)**.
- Accessibility names: **Scale tool** and **Skew tool**.
- Camera panes may activate the tool through shortcuts/buttons, but initiation is
  available only in graph panes. A camera shows no manipulator and does not consume
  pointer drags as scale/skew.
- Text fields, embedded SpinBox editors, browser controls, popups, and dialogs keep
  `T`/`K` and editing input; incidental keyboard focus never retargets a tool or
  transform away from `active_slot`.
- Entering either tool clears component selection and cancels all disposable previews
  through existing `set_tool()` behavior.

### 6.2 Merged selection rectangle

For one or more selected, unlocked brushes, each visible graph projects current
native merged 3D bounds onto its two visible axes and draws one normalized rectangle. Point entity
selection does not contribute. Hidden selected brushes do contribute because the
selection, not visibility filters, defines the transform target. Phase 6 layer-locked
brushes cannot remain selected and never contribute.

- Draw a 2 px selection outline above selected geometry.
- Draw four square edge scale handles at edge centers and four square corner scale
  handles in Scale mode.
- Draw four diamond skew handles outside edge centers in Skew mode. Offset them by
  12 editor-scaled pixels from the rectangle so they cannot be mistaken for scale
  handles or component points.
- Handle hit target is at least 16x16 editor-scaled pixels even if the visible mark
  is smaller.
- Existing pane controls, orientation gizmo, frame button, and pane menu take pointer
  priority over transform handles.
- For a projected zero-width/height selection, draw the rectangle but suppress
  handles requiring that zero span. No gesture may divide by a zero source span.

### 6.3 Scale behavior

At press in the graph at `active_slot`, capture target brush IDs, source merged
bounds, graph orientation, visible axes, dragged handle role, fixed pivot, document
epoch/state generation, selection generation, and current grid.

- Corner handle: scales both visible axes; hidden-axis factor is 1.
- Edge handle: scales only the perpendicular visible axis; the other visible and
  hidden-axis factors are 1.
- Default pivot is the opposite corner for a corner handle and the center of the
  opposite edge for an edge handle. It remains fixed for the gesture.
- Candidate handle world position is grid-snapped on affected axes before factors
  are calculated.
- Factor is signed `(candidate - pivot) / (source_handle - pivot)` per affected axis.
- Candidate bounds are derived from the transformed source bounds, normalized for
  drawing, and never become the next calculation's source. This avoids cumulative
  drift.

Holding Shift during a corner drag locks the projected aspect ratio: choose the
affected axis with the larger absolute departure from factor 1 and apply that same
signed factor to both visible axes. Shift does not alter edge-handle behavior. The
constraint is recomputed from original press state whenever Shift changes.

### 6.4 Center crossing and mirror policy

Center crossing is supported, not clamped. The press-time pivot stays fixed. When a
candidate handle crosses it on an affected axis, that axis factor becomes negative;
Phase 7 determinant/winding correction produces the reflection.

- `abs(factor) < 1e-9` is an invalid dead zone, including exact contact with pivot.
- While invalid, retain the last pointer/candidate bounds overlay in error styling,
  clear exact camera candidates, and show **Invalid transform: scale cannot cross
  zero. Continue dragging or press Escape.**
- Continuing through the dead zone into a valid negative factor resumes exact native
  preview. No intermediate commit occurs.
- On crossing, normalized screen bounds may swap sides. Keep the logical dragged
  handle attached to the pointer and draw a small **Mirrored** text badge; do not
  silently switch to a different handle role or move the pivot.
- Releasing in the dead zone or on any invalid native candidate cancels with no
  transaction. It does not commit the last valid preview.

### 6.5 Skew behavior

A skew handle on one edge moves parallel to that edge. The edge's perpendicular
world axis is the source axis; its parallel world axis is the destination axis.

Example in XY: dragging the top/bottom skew handle horizontally applies source Y to
destination X. Dragging left/right vertically applies source X to destination Y.

- Pivot is the center of the opposite edge and remains fixed.
- Factor is signed parallel displacement divided by the press-time perpendicular
  distance from source edge to pivot.
- Snap the displaced handle coordinate to the current world grid before deriving the
  factor. Do not directly snap the dimensionless factor.
- Holding Shift snaps the shear angle `atan(factor)` to 15-degree increments, then
  uses `tan(snapped_angle)` as the candidate factor.
- Candidate bounds are calculated by transforming all four projected source corners,
  then taking their normalized bounds. The overlay also draws the candidate
  parallelogram so skew is not misrepresented as only an AABB.
- Crossing the pivot is valid for skew because shear determinant remains +1. Native
  finite/bounds/geometry validation still applies.

### 6.6 Preview and visual feedback

- The initiating `active_slot` graph draws source bounds, fixed pivot crosshair, a
  line from pivot to the dragged handle, candidate bounds, and candidate
  outline/parallelogram.
- Valid state uses the current orange candidate color. Mirrored state adds text and
  a dashed pivot-crossing indicator. Invalid state uses the theme error color plus
  text/icon; it must not rely on color alone.
- The initiating `active_slot` graph draws transformed selected edges from the exact
  native candidate, not a screen-space approximation. Source selected geometry is
  dimmed.
- All registered camera panes receive the same exact native candidate dictionaries
  through `queue_mutation_preview()`. Hidden/visible candidate passes and offscreen
  indicators continue to work.
- Other graph panes redraw source selection and may draw the candidate projected from
  the exact returned vertices. They do not independently rerun native preview.
- If native preview fails, clear candidate geometry from every pane immediately,
  preserve the invalid overlay in the initiating graph, and report at most once per
  distinct error/code/parameter state rather than once per mouse event.

### 6.7 Release, cancellation, focus, and tabs

A valid changed release calls exactly one `map_session.gd::transact()` using the same
captured IDs, pivot, axes, and final parameters. Commit revalidates against current
state. Clear preview after transaction completion.

Cancel without commit on:

- Escape.
- Right-click during a scale/skew gesture.
- initiating graph focus exit;
- application or window focus loss;
- synthetic/internal mouse release or release received while window lacks focus;
- document/session tab change or close;
- graph orientation or layout/pane-type change;
- tool change;
- selection generation, document epoch, or source state generation mismatch;
- opening a modal dialog or history navigation;
- plugin disable or control pre-delete.

Tab and Shift+Tab focus navigation do not start a gesture. If pressed during an
active gesture they cancel first, then normal focus traversal proceeds. Escape is
consumed when it cancels a gesture, so it does not also clear selection or change
tools. A normal valid primary-button release is the only commit trigger.

## 7. Functional Requirements

### FR-1 Selection eligibility

Handles require at least one live brush and no component selection. Point entities
may remain selected but are not transformed. If there are only points, show no
handles. Gesture targets are captured brush IDs and cannot expand/shrink mid-drag.
Every target must also be unlocked under Phase 6. Locking a layer immediately prunes
its brush/component selections and cancels a gesture that captured one of its IDs.
If stale captured/supplied IDs are locked at preview or commit, reject the complete
UI operation; never transform only the unlocked subset. Native APIs continue to
validate all supplied IDs independently of transient lock state.

### FR-2 Press-time state

The gesture owns an immutable start-state dictionary with IDs, source AABB, projected
source corners, pivot, handle, axes, orientation, grid, epoch, state generation, and
selection generation. Pointer updates derive from it. Do not use mutable displayed
candidate bounds as input.

### FR-3 Exact native preview

Every rendered-frame update that has newer valid pointer parameters calls the
appropriate Phase 7 preview API with typed factors/axes. Raw pointer events only
replace the queued latest parameters; they do not each invoke native preview. The
native result is the geometry oracle. No GDScript-transformed edge may be presented
as an exact candidate if native validation has not succeeded.

### FR-4 Coalescing and stale work

Keep only the latest pointer parameters and perform at most one native preview and
one camera broadcast per frame. Tag queued work with a gesture generation. Ignore
callbacks whose generation, owner, session, epoch, state, selection, or orientation
does not match current gesture state.

### FR-5 Commit parity

Before commit, synchronously evaluate/flush the final release position if it differs
from the last previewed input. Commit only that parameter set. The Phase 7 commit API
must produce draw geometry equal to the final successful native preview. A failed
commit leaves no content/history change and reports the error.

### FR-6 Single transaction

One valid release creates one history event named **Scale map selection** or **Skew
map selection**. Pointer motion creates none. No-op factor `(1,1,1)` or skew 0 creates
none. Invalid release and every cancellation path create none.

### FR-7 Repeat integration

After a changed commit, set the Phase 7 session repeat descriptor to exact final
scale factors or ordered skew axes/factor. Preview, invalid release, and cancellation
do not alter it. Repeating later uses current selection bounds as specified by Phase
7, not this gesture's pivot.

### FR-8 Center crossing

Negative scale factors are valid and invoke Phase 7 reflection behavior. Near-zero
factors are invalid. Releasing invalid never falls back to last valid parameters.

### FR-9 Candidate bounds

Scale candidate bounds use affine-transformed source AABB corners. Skew candidate
bounds use all four projected source corners; graph drawing includes the resulting
parallelogram. Native candidate brush AABBs remain authoritative for content/camera
framing and may be tighter/different from simple aggregate projections only within
floating-point equality expectations.

### FR-10 View synchronization

Every camera pane and visible graph observes the same gesture generation. Cancelling
or committing clears candidates from all panes. Offscreen/parked panes must not
retain visible or allocated stale candidate state when reattached.

### FR-11 Input ownership

Handle hit-testing occurs only for the graph in `active_slot` and only on primary-button press.
Once captured, the initiating graph owns motion/release until commit/cancel. Other
panes cannot steal or complete the gesture.

### FR-12 Native errors

Distinguish UI dead-zone invalidity from native `INVALID_ARGUMENT`,
`INVALID_GEOMETRY`, `INVALID_ID`, and `LIMIT_EXCEEDED`. All block commit. Repeated
identical errors are debounced for status/accessibility announcements.

## 8. Architecture and Native Math

### 8.1 Scale derivation

Let `h0` be the press-time handle coordinate, `c` the fixed pivot, and `h1` the
snapped candidate coordinate. For each affected world axis:

```text
factor = (h1 - c) / (h0 - c)
```

The denominator must be finite and have magnitude at least `1e-9`. Unaffected axes
are exactly 1. Pass the resulting `Vector3` and pivot to Phase 7. Do not compose
incremental matrices.

### 8.2 Skew derivation

Let `s` be the source (perpendicular) axis, `d` the destination (parallel) axis,
`edge_s` the source edge coordinate, and `candidate_d - source_d` its snapped parallel
displacement:

```text
factor = (candidate_d - source_d) / (edge_s - pivot_s)
p'[d] = p[d] + factor * (p[s] - pivot[s])
```

Axis order and sign are determined from graph world axes, not screen labels. Shift
angle snapping occurs after raw factor calculation.

### 8.3 Pivots

Pivots are interaction-specific opposite handle/edge anchors, not Phase 7's numeric
command center pivot. This is not a custom pivot feature because users cannot move or
persist it. Native APIs already accept typed pivots; repeat intentionally recomputes
the Phase 7 merged-bounds center.

### 8.4 Validation boundary

GDScript checks denominator/dead zone and finite pointer math to avoid pointless
calls. Native Phase 7 checks IDs, axes, coefficients, determinant, coordinate bounds,
closed geometry, and document size for both preview and commit.

## 9. Detailed Implementation by File

### `addons/tbloader/src/editor/graph_view.gd`

- Add scale/skew handle descriptors and deterministic drawing/hit-test helpers.
- Add gesture fields for immutable start state, latest pointer parameters, final
  successful candidate, validity/error, and generation.
- Extend `begin_left`, mouse motion, `finish_left`, `cancel`, tool chrome drawing,
  and `update_exact_preview` for `scale` and `skew` gestures.
- Project exact candidate edges returned by native preview for graph rendering.
- Add pivot/candidate overlays, Shift constraints, center-crossing badge, dead-zone
  feedback, and error debounce.
- Never mix these handles with existing silhouette/component resize handles.

### `addons/tbloader/src/editor/graph_view_layer.gd`

- Route selection/tool-layer draw calls for handles and exact candidate overlays.
- Preserve retained static geometry; gesture redraw must affect selection/tool layers
  only.

### `addons/tbloader/src/editor/map_editor.gd`

- Add Scale/Skew toolbar buttons, icons, plain-key routing, and notices.
- Resolve shortcut/tool targets from `active_slot` and its active grid, never from
  whichever child control happens to own keyboard focus; preserve all protected
  text/browser/popup/dialog guards.
- Extend mutation-preview coordination so one exact candidate can also be projected
  by all graph panes without repeated native calls.
- Cancel gestures before session/tab/layout/pane/tool/history/modal transitions.
- Ensure pending preview is synchronously resolved for a normal release and stale
  deferred callbacks cannot repopulate panes afterward.

### `addons/tbloader/src/editor/map_session.gd`

- Add transaction dispatch for captured-ID scale/skew commits and successful repeat
  descriptor updates.
- Validate captured session/epoch/selection generation before dispatch.
- Do not add point-entity calls to these transactions.

### `addons/tbloader/src/editor/camera_view.gd`

- Reuse `set_candidate_preview()`; add no pointer manipulator.
- Verify topology-buffer fast path handles scale/skew positions and reflections.
- Clear candidate buffers/indicator on owner cancellation, tab replacement, and
  parked-pane lifecycle.

### `src/map/map_edit.h`, `src/map/map_edit.cpp`, `src/map_document.h`,
### `src/map_document_ops.cpp`, and `src/map_document.cpp`

- No new transform algorithm is expected beyond Phase 7.
- Fix only parity/validation defects exposed by gesture tests; do not add a second
  interactive-only native API.
- If coalescing measurement requires it, add counters without changing Result data.

### `tests/map_editor/document_suite.gd`

- Reuse Phase 7 parity tests with interactive pivots/factors, negative crossing,
  near-zero invalid values, skew signs, and final-release recomputation fixtures.

### `tests/map_editor/editor_suite.gd`

- Test handle layout/hit targets, merged bounds, each graph orientation, pivots,
  candidate math, Shift transitions, invalid overlays, all-pane broadcast, one-step
  history, repeat updates, and every programmatic cancellation path.

### `tests/map_editor/window_input_observer.gd` and OS-input runner files

- Add genuine pointer drags across handles/pivot, modifier changes during drag,
  Escape/right-click/focus loss/synthetic release/tab traversal, and release commit
  assertions.

### `tests/map_editor/current_editor_performance_probe.gd`

- Measure 32- and 256-brush scale/skew pointer streams, native preview count, camera
  mesh uploads, graph redraws, frame latency, retained candidate bytes, cancellation,
  and single commit.

## 10. Validation

- At gesture start, require live nonempty brush selection, nonzero projected source
  span for the chosen handle, finite bounds/pivot, and matching session generations.
- During motion, reject non-finite pointer math and scale dead-zone factors before
  native preview.
- Native preview validates complete selected geometry. One invalid brush invalidates
  the entire candidate.
- On release, require current session, epoch, state generation, selection generation,
  orientation, and target IDs to equal captured values.
- Re-evaluate the exact release position synchronously. A stale prior candidate is
  never committed.
- Commit uses typed native APIs and must pass fresh native validation.
- Invalid state clears exact candidates everywhere and keeps only the initiating
  graph's explanatory overlay.

## 11. UV and Texture Semantics

Texture lock remains explicitly **off**. Interactive transforms inherit Phase 7:

- Face texture/material token, classic shifts, Valve axes/offsets, UV rotation,
  scales, and surface flags remain unchanged.
- Negative scale winding correction changes only supporting-plane point order.
- Preview renders native candidate geometry with unchanged metadata and therefore
  must visually match committed texture behavior.
- No modifier temporarily enables texture lock.

## 12. Edge Cases

- One brush and many brushes use the same merged rectangle contract.
- Point-only selection has no handles; mixed selection transforms brushes only.
- Component selection suppresses whole-selection scale/skew handles.
- Hidden selected brushes affect bounds and transform even if not drawn normally.
- Locked layer members are immediately pruned and produce no handles. Locking after
  gesture start cancels it; stale locked IDs reject preview/commit atomically rather
  than producing a partial transform.
- Zero projected span suppresses affected handles and avoids division by zero.
- Very small on-screen bounds retain 16 px hit targets; overlapping handles resolve
  corner before edge, nearest distance, then stable handle order.
- Pointer crosses one scale pivot axis: one negative factor and reflection.
- Shift corner crosses both axes: the chosen signed uniform factor applies to both,
  equivalent to projected 180-degree inversion rather than a one-axis mirror.
- Release exactly at/near pivot: invalid and no commit.
- Pointer leaves the control while captured: continue only while application/window
  focus remains valid; focus loss cancels.
- Native candidate fails after previously valid motion: clear prior candidate and
  never commit it on release.
- Grid changes by shortcut during drag: cancel rather than change captured snapping.
- Orientation, layout, tool, selection, tab, history, or document changes: cancel.
- Candidate is entirely offscreen in a camera: retain existing edge indicator.
- Negative determinant changes candidate winding/topology signature values but not
  brush IDs or face counts; camera buffer reuse must remain correct.
- No-op release after moving away and returning: no history/repeat update.

## 13. Accessibility and Platform Requirements

- Tool buttons, handle purpose, current pivot, candidate factors/skew, mirrored
  status, and invalid reason have accessible text.
- On keyboard focus of a graph in Scale/Skew mode, status text describes available
  mouse handles and the numeric Transform menu alternative. Handles themselves are
  pointer targets in this phase; full keyboard geometric manipulation remains via
  Phase 7 commands/dialogs.
- Error and mirrored states use text/shape plus color with sufficient theme contrast.
- Handle and line widths scale with editor UI scale and remain usable at 100%/200%.
- Test left/right mouse configurations as Godot primary/secondary button semantics
  permit; do not infer platform from raw OS button numbering.
- Shift modifier transitions must work on X11/Xwayland, Windows, and macOS event
  models. No compositor/system configuration changes are part of rollout.
- Screen reader announcements for repeated invalid motion are debounced.

## 14. Performance Requirements

- Handle bounds computation is O(selected brushes) only when selection/document
  generation changes, not every draw call.
- Pointer motion stores latest parameters; native preview and all-pane broadcast run
  at most once per rendered frame.
- One native candidate is shared by all graph/camera panes. Pane count must not
  multiply native transform/rebuild work.
- Static graph edge buffers are not rebuilt during preview. Redraw only selection
  and tool overlays plus candidate buffers.
- Camera candidate topology buffers use the existing transform-only fast path when
  face/edge counts are unchanged, including reflected candidates.
- Cancellation frees/hides candidate state and prevents deferred stale uploads.
- For controlled 60 Hz tests with 256 selected simple brushes, record p50/p95 input-
  to-preview latency and require no worse than 10% regression from Phase 7's
  equivalent numeric preview workload plus measured overlay cost. Any missed target
  blocks rollout until profiled; do not reduce validation or preview exactness.

## 15. Test Plan

### Math/document tests

- All three graph orientations, eight scale handles, four skew handles, positive and
  negative factors, Shift factor/angle snapping, exact pivot equations, and bounds.
- Preview/commit equality, metadata preservation, reflection winding, atomic invalid
  multi-selection, no-op, and undo/redo.

### Editor tests

- Merged rectangle and handle positions for asymmetric multi-brush selection.
- Hit priority at small/overlapping bounds and no handles for zero span/points.
- Source bounds remain immutable through long back-and-forth drags.
- Center crossing invalid dead zone, resumed negative preview, badge, and release.
- Native error after valid preview clears every pane and blocks commit.
- Final release parameter flush, one transaction, exact history restoration, and
  repeat descriptor update only after success.
- Multiple visible/parked camera and graph panes share and clear one generation.

### Lifecycle and OS-input tests

- Genuine drag/release commits once.
- Escape, right-click, focus loss, synthetic release, tab switch, Ctrl+Tab, Tab,
  Shift+Tab, pane replacement, orientation change, grid shortcut, tool change,
  history navigation, modal opening, and plugin disable cancel with zero history.
- Change Shift during one drag and verify constraints update from source state.
- Drag outside pane/window and return under supported capture behavior.
- Text fields, embedded SpinBox editors, browser controls, and dialogs keep `T`, `K`,
  Shift, Tab, and Escape behavior while command targets remain tied to `active_slot`.

### Performance tests

- 32/256 brush scale and skew streams over at least 31 samples.
- Assert native preview count <= rendered preview frames, one shared broadcast per
  frame, bounded mesh uploads/redraws, no static edge rebuild, no full map parse,
  no memory growth after repeated cancel, and one release transaction.

## 16. Acceptance Criteria

- Scale and Skew tools display correct merged-selection handles in every graph
  orientation and never expose camera manipulators.
- Scale edge/corner and skew gestures use documented press-time pivots/math.
- Shift constraints are deterministic and recompute from immutable source state.
- Center crossing supports valid reflection, clearly marks it, and treats zero scale
  as invalid with no fallback commit.
- Valid motion shows exact native candidate geometry in all camera panes and graphs.
- Invalid preview provides textual feedback, clears exact candidates, and cannot
  commit.
- A valid release commits exactly one transaction matching the final preview.
- Every cancellation/focus/tab/Escape path commits nothing and clears stale previews.
- UV/texture metadata is unchanged with texture lock off.
- Point entities are never scaled or skewed.
- Functional, displayed, genuine OS-input, sanitizer, and performance suites pass.

## 17. Dependencies and Rollout

1. Complete all Phase 7 acceptance criteria and freeze typed scale/skew semantics.
2. Require Phase 2 `active_slot`/active-grid routing and Phase 6 lock predicates,
   immediate lock-selection pruning, and locked-target whole-operation rejection.
3. Land graph handle drawing/hit testing with gestures disabled from commit.
4. Connect exact native preview and all-pane generation/cancellation tests.
5. Enable commit/repeat integration after final-preview parity tests pass.
6. Run displayed and genuine OS-input lifecycle tests on Linux, then available
   Windows/macOS smoke tests.
7. Run 32/256-brush performance gates and enable tools by default.

No map migration is required. If Phase 7 parity or performance regresses, Phase 8
must remain disabled rather than falling back to approximate GDScript transforms.

## 18. Decisions

- Phase 8 is graph-initiated only; 3D camera manipulators are deferred.
- One merged selection rectangle controls all selected brushes.
- Scale corners affect two visible axes; edges affect one; hidden axis stays 1.
- The opposite handle/edge is the fixed gesture pivot. No custom pivot is exposed.
- Shift locks corner aspect ratio and snaps skew angle to 15-degree increments.
- Center crossing is allowed and produces negative scale/reflection; near-zero scale
  is an invalid dead zone.
- Releasing invalid commits nothing, never the last valid candidate.
- Exact native preview is the sole geometry oracle and is shared across all panes.
- A normal primary-button release is the only commit trigger; all focus/tab/Escape
  lifecycle transitions cancel.
- Texture lock remains off, and point entities are excluded.
