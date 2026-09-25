# Phase 4: Pane Maximization PRD

## Status

Implementation-ready; depends on the Phase 2 active-slot contract. F12 is a
Phase 4 `route_key()` command, not a Phase 3 file-menu item.

## Date

2026-09-18.

## Product area

Radiant Map editor workspace layout in `addons/tbloader/src/editor/map_editor.gd`.

## Related documents

- `PHASE_3_PANE_CONTEXT_MENU_PRD.md`
- `PHASE_2_ACTIVE_PANES_PRD.md`
- `MAP_EDITOR_UI_IMPLEMENTATION.md`
- `HISTORY_NAVIGATION_PRD.md`
- `tests/map_editor/window_input.md`
- `PHASE_5_ESCAPE_STATE_MACHINE_PRD.md`

## Summary

Add workspace-local maximization of the active pane. F12 expands one configured
slot to the full Map workspace by hiding the other slots and the unused splitter
column. F12 again restores the exact 2/3/4 layout and splitter offsets.

This is not OS fullscreen and does not hide Godot editor chrome, Map tabs,
toolbar, status, or bottom panels. Maximization is transient UI state and is not
written to workspace persistence or recovery.

## Problem

Detailed camera, grid, UV, entity, and Layers work can be constrained by a multi-pane
layout. Changing to a smaller layout loses the user's current layout choice and
does not express the intent to inspect one pane temporarily. Manually dragging
splitters is slower and cannot reliably restore exact offsets. A maximize mode
must also remain coherent when pane navigation, pane replacement, or layout
changes occur.

## Goals

- Maximize the active visible slot inside `MapViewWorkspace` with F12.
- Preserve configured layout, pane instances, pane view state, and all split
  offsets exactly.
- Hide every other slot and the entirely unused left/right splitter column.
- Keep the maximized pane's menu, controls, focus, and active border visible.
- Transfer maximization when Previous/Next Pane activates another slot.
- Keep maximization when the maximized slot's pane type is replaced.
- Exit maximization when the user selects a different 2/3/4 layout.
- Keep state transient and out of persistence/recovery.

## Non-goals

- OS fullscreen, borderless windows, exclusive display modes, or Godot editor
  distraction-free mode.
- Hiding Map editor toolbar, tabs, status, notice, or bottom panels.
- Detaching a pane into another window or reparenting pane instances.
- Persisting maximization across plugin disable, editor restart, project switch,
  workspace restore, or recovery.
- Animating the transition.
- Assigning Escape behavior in this phase; Phase 5 owns Escape priority
  integration.
- Changing the 2/3/4 layout geometry or adding a one-pane persisted layout.

## UX contract

### Entry and exit

- F12 maximizes `active_slot` when it is visible in the current underlying
  layout.
- While maximized, F12 from any Map pane restores the underlying layout.
- Maximization affects only the Map workspace. All surrounding Godot and Map
  editor chrome remains unchanged.
- The maximized slot keeps the active border and receives focus after the
  transition. Focus should return to the previously focused descendant when it
  remains valid after pane replacement; otherwise focus the new pane root or its
  first focusable child.
- The maximized slot's accessible description includes **maximized**; there is
  no Maximize/Restore menu item. Slot pane menus stay pane-type pickers. The
  toolbar file menu does not list this command.

### Visibility by layout

Underlying layout membership remains:

| Layout | Normal visible slots | Maximized behavior |
|---|---|---|
| 2 views | `[0, 2]` | Show only target 0 or 2; hide the other column completely. Both vertical siblings are hidden except the target. |
| 3 views | `[0, 2, 3]` | Target 0 hides the right column. Target 2 or 3 hides the left column and the other right sibling. Slot 1 remains layout-ineligible. |
| 4 views | `[0, 2, 1, 3]` | Show only the target; hide its vertical sibling and the opposite column. |

The owning `VSplitContainer` remains visible so the target keeps normal
container sizing. The opposite `VSplitContainer` is hidden, removing the unused
`HSplitContainer` column and divider. In the owning column, only the target slot
is visible, removing the unused vertical divider.

### State transitions

- **Enter:** save no duplicate layout state; set `maximized_slot` to the active
  layout-visible slot and apply derived visibility.
- **Restore:** set `maximized_slot = -1` and derive normal visibility from
  `view_layout`.
- **Previous/Next while maximized:** choose the adjacent slot from the underlying
  layout's normal visible order, set it active, set `maximized_slot` to it, and
  remain maximized. This can cross columns.
- **Replace pane in maximized slot:** keep that slot maximized and active. The new
  pane fills the workspace.
- **Replace a hidden slot programmatically:** keep the current target maximized;
  the replacement appears when restored or navigated to.
- **Layout command while maximized:** exit maximization first, apply the requested
  layout, and show its normal slots. Even selecting the same layout explicitly
  exits maximization.
- **Workspace restore:** exit maximization before applying persisted state.
- **Session/document switch:** keep workspace maximization because pane layout is
  shared by documents; refresh pane content in place.
- **Plugin hide/disable:** cancel interaction/capture. The in-memory value may be
  cleared immediately and is never restored on enable.

### Escape

Phase 4 does not bind Escape. Phase 5 inserts **restore maximized pane** after
closing a popup/dialog, stopping captured navigation, and canceling one active
gesture, but before clearing cut state, selection, or tool state. It must call
Phase 4's idempotent `restore_panes()` rather than restore a stale serialized
workspace snapshot. Until Phase 5 lands, Escape retains current behavior and
only F12/menu restores panes.

## Functional requirements

1. Store `maximized_slot: int = -1`. A non-negative value must be a member of
   `layout_slot_indices(view_layout)` and identify the sole visible slot.
2. `toggle_maximized_slot(slot := active_slot)` is the only toggle entry point.
   It rejects invalid/hidden slots, cancels active interaction/camera capture,
   activates the target, and applies visibility once.
3. `restore_panes()` is idempotent. Calling it when not maximized changes
   nothing; calling it while maximized restores normal visibility exactly once.
4. `apply_workspace_visibility()` derives all slot/container visibility from
   `view_layout` and `maximized_slot`; no caller hand-edits a subset of controls.
5. Entering or leaving maximization must not modify `workspace.split_offset`,
   `left_views.split_offset`, or `right_views.split_offset`.
6. No pane is reparented, recreated, serialized, or parked as part of maximize or
   restore. Existing graph origin/zoom/orientation, camera transform/options, UV
   state, Entities row selection, and child focus state survive.
7. The active border remains around the maximized slot. Hidden slots have no
   active border exposed to accessibility or drawing.
8. F12 is routed only while the Map main screen is visible and focus is in a Map
   pane or its non-text descendant. A focused text editor or other Phase 2
   protected surface keeps all key handling, including F12; leave that editor
   and press F12 to restore.
9. F12 is not a file-menu or pane-menu accelerator. Slot type-picker popups and
   the toolbar file menu must not also toggle maximization.
10. Layout changes always leave `maximized_slot == -1`, including an explicit
    command selecting the already configured layout.
11. `workspace_state()` omits maximization. `restore_workspace_state()` clears
    it before changing pane types/layout and restores only persisted offsets and
    normal layout.
12. Previous/Next uses underlying normal layout membership, not currently
    visible controls, so cycling works while only one pane is shown.

## Architecture/data model

Add one transient field and derive visibility rather than snapshotting controls:

```gdscript
var maximized_slot := -1

func layout_slot_indices(mode: int = view_layout) -> Array[int]:
    return [0, 2] if mode == 2 else ([0, 2, 3] if mode == 3 else [0, 2, 1, 3])
```

`apply_workspace_visibility()` computes:

```text
normal_slots = layout_slot_indices(view_layout)
shown_slots = [maximized_slot] if maximized_slot >= 0 else normal_slots
left_used = shown_slots contains 0 or 1
right_used = shown_slots contains 2 or 3
```

It sets each `view_slots[index].visible`, then `left_views.visible` and
`right_views.visible`. Visibility is the only maximize mechanism. Because split
offset properties are never assigned, restore naturally uses their exact prior
values. `sync_view_splits()` remains disabled outside normal four-view operation
and should additionally return while maximized so a resize notification cannot
copy an offset during transition.

Use Phase 2's `active_slot` as the target and Phase 3's central command
dispatcher for F12. Do not infer the active slot from `active_graph`,
`camera_view`, array ordering, or focus after the popup has opened.

## Detailed implementation by file

### `addons/tbloader/src/editor/map_editor.gd`

- Add `maximized_slot`, `layout_slot_indices()`,
  `apply_workspace_visibility()`, `is_slot_maximized()`,
  `toggle_maximized_slot()`, and `restore_panes()`.
- Refactor `apply_layout()` to clear maximization and call the shared visibility
  derivation. Preserve its cancel, four-view split synchronization, active-slot
  correction, menu update, and status refresh responsibilities.
- Update `sync_view_splits()` to no-op while maximized.
- Update `set_slot_type()` so replacing the maximized target keeps the slot,
  menu, active border, and maximize state while safely moving focus to the new
  pane.
- Extend Phase 2 `move_active_slot()` so it uses underlying normal layout
  membership while maximized and transfers `maximized_slot` before applying
  visibility.
- Route F12 to the Phase 3 maximize command and expose the current label and
  enabled state during menu rebuild.
- Clear maximization at the start of `restore_workspace_state()` and `shutdown()`.
- Do not add a `maximized_slot` key to `workspace_state()`, recovery JSON, session,
  or editor settings.

### `addons/tbloader/src/editor/graph_view.gd`

- No maximize-specific layout logic. Existing `resized` handling redraws after
  the container expands/restores.
- Verify cancellation and redraw occur once when visibility changes.

### `addons/tbloader/src/editor/camera_view.gd`

- No maximize-specific layout logic. Existing visibility/suspension behavior
  must disable hidden camera SubViewport updates and resume the target/visible
  cameras on restore.
- Verify mouse capture/fly mode exits before maximizing or transferring.

### `addons/tbloader/src/editor/uv_pane.gd`

- No implementation change expected beyond Phase 2 activation hooks. Verify its
  controls relayout at full workspace size and preserve values/focus.

### `addons/tbloader/src/editor/entity_pane.gd`

- No implementation change expected beyond Phase 2 activation hooks. Verify its
  split offset, selected entity, fields, and list state survive.

### `addons/tbloader/src/editor/layers_pane.gd`

- Phase 6's seventh pane type uses the same slot maximize/restore behavior. Verify
  row focus, search text, active row, and scroll state survive without a separate
  bottom-panel implementation.

### `tests/map_editor/editor_suite.gd`

- Add state-transition assertions for all targets in 2/3/4 layouts.
- Record all three split offsets and pane-instance/view-state identities before
  maximize; assert exact equality after restore.
- Cover F12, menu dispatch, pane navigation transfer, pane replacement, layout
  changes, workspace restore, session switch, and repeated idempotent calls.

### `tests/map_editor/window_input_observer.gd`

- Expose read-only `maximized_slot`, active slot, slot/container visibility,
  split offsets, pane instance IDs, and command dispatch count.

### `tests/map_editor/window_input_runner.py`

- Add genuine F12 and pointer-menu journeys in two-, three-, and four-view modes.
  Capture maximized and restored screenshots and assert no duplicate toggle.

## Edge cases

### Two-view layout

- Only slots 0 and 2 are eligible. Maximizing either hides the opposite column.
- Slots 1 and 3 remain hidden before, during, and after restore.
- Previous/Next alternates between 0 and 2 and transfers maximization.

### Three-view layout

- Eligible order is 0, 2, 3; slot 1 never appears.
- Maximizing slot 0 removes the full right column and both right panes.
- Maximizing slot 2 or 3 removes the left column and hides the other right pane.
- Previous/Next wraps 0 -> 2 -> 3 -> 0 while remaining maximized.

### Four-view layout

- Any slot is eligible. The target's vertical sibling and opposite column are
  hidden; both splitter dividers disappear.
- Existing synchronized vertical offsets remain numerically unchanged.
- Previous/Next follows Phase 2's row-major `[0, 2, 1, 3]`, including
  cross-column and cross-row transfers.

### General

- If active state is stale or points to a hidden slot, entry chooses no fallback
  silently: `activate_slot()` first normalizes active state to the first normal
  visible slot, then explicit F12 may maximize it.
- Replacing the maximized pane can queue-free the old focus owner. Weak focus
  tracking must not dereference it; focus the replacement safely.
- Changing layout during camera fly, drag preview, clip preview, or popup closes
  and cancels transient interaction before visibility changes.
- A session change while maximized may rebuild camera/material content but must
  not restore other slots or alter offsets.
- A hidden camera must not continue `SubViewport.UPDATE_ALWAYS` work.
- A popup opened before a programmatic layout change must close; its stale
  maximize activation is rejected.
- Zero-size/transient resize notifications must not overwrite pane view state or
  splitter offsets.

## Accessibility/platform

- F12 has no Command/Ctrl modifier. Attach it in this phase through the host
  keyboard router; do not add a file-menu or pane-menu accelerator for it.
- The active pane's accessibility description includes **maximized** while in
  that state. Hidden slots and controls must not remain keyboard-focusable or be
  exposed as active content.
- Restore does not rely on double-clicking a splitter or pointer precision; F12
  is the keyboard-accessible path.
- Screen-reader-visible text on the maximized slot includes **maximized**; the
  active border is supplementary, not the sole state indicator.
- On laptops where F12 requires an Fn hardware modifier, the application still
  binds logical F12; remapping or media-key interception is OS/user policy.
- Escape behavior is intentionally unchanged until Phase 5 and must not be
  advertised as a restore shortcut in Phase 4.

## Performance

- Maximize/restore is O(4): update four slot visibilities and two container
  visibilities. It performs no pane recreation, document work, serialization,
  geometry rebuild, or resource scan.
- Hidden Camera panes rely on existing suspension to stop SubViewport updates.
- Trigger at most one refresh/layout pass per transition. Do not call full
  `refresh()` solely for maximization; use resize/redraw notifications already
  emitted by Godot containers.
- No duplicate snapshot of pane or splitter state is retained.

## Test plan

1. For every eligible target in layouts 2, 3, and 4, maximize and assert exactly
   one slot plus its owning column is visible; restore and assert the normal slot
   set.
2. Record `workspace`, left, and right split offsets before each transition and
   compare exact integer values during and after maximize, transfer, and restore.
3. Record pane instance IDs and Grid/Camera/UV/Entities/Layers local state; prove no
   recreation/reparenting and exact state preservation.
4. Press F12 once and assert one transition. With the toolbar file menu or a
   slot type-picker open, F12 must not double-dispatch or change pane type.
5. Navigate Previous/Next repeatedly while maximized in each layout, asserting
   documented order, wrap, focus, active border, and maximization transfer.
6. Replace the maximized pane with each other pane type and prove maximization
   remains on that slot; replace a hidden pane and prove no visibility change.
7. Select each layout command while maximized, including the current layout, and
   prove normal visibility and `maximized_slot == -1`.
8. Restore persisted workspace state while maximized and prove maximization is
   discarded while persisted layout/types/offsets apply exactly.
9. Switch Map sessions while maximized and prove maximize state stays workspace-
   local while document content updates.
10. Run displayed and genuine X11 tests with screenshots showing editor chrome
    present, active border retained, and split dividers absent in maximize mode.
11. Run existing editor, recovery, document, and window-input regression suites
    under their strict timeout/stderr rules.

## Acceptance criteria

1. F12 maximizes the active visible slot inside the Map workspace without
   entering OS or Godot fullscreen. There is no Maximize/Restore menu item.
2. Exactly one slot is visible while maximized; the opposite splitter column and
   the target's unused vertical sibling/divider are hidden.
3. Toolbar, tabs, status, notice, Godot chrome, and bottom panels remain visible.
4. F12/Restore returns the exact normal 2/3/4 slot set with unchanged workspace,
   left, and right split offsets.
5. Pane instances and their camera/grid/UV/entity/Layers state are preserved; no pane is
   recreated or reparented solely for maximize/restore.
6. Previous/Next while maximized follows underlying layout order, wraps, and
   transfers maximization and active border to the destination.
7. Replacing the maximized pane keeps the slot maximized and focuses the
   replacement; replacing a hidden pane does not expose it.
8. Any explicit layout selection exits maximization, including reselecting the
   current layout.
9. Workspace restore/recovery/restart never restores maximization, and persisted
   state contains no maximize field.
10. The active border and accessible maximized state remain present on the sole
    pane, and hidden panes are not keyboard targets.
11. Escape behavior is unchanged in Phase 4 and documented as delegated to
    Phase 5.
12. One input event causes one maximize state transition, and all existing Map
    editor regression suites pass.

## Dependencies/rollout

- Requires Phase 2's `active_slot`, row-major visible-slot ordering, focus
  protection, and active border, plus Phase 3's central pane command dispatch,
  F12 `Shortcut`, popup binding, and dynamic menu label.
- Phase 5 owns Escape-priority integration. It consumes Phase 4's query/restore
  API and must not restore a captured `workspace_state()` that would overwrite
  pane replacements made while maximized. Phase 4 ships without Escape restore
  rather than inserting a temporary conflicting rule.
- No native extension or file-format change is required.
- Deliver model/visibility tests first, then displayed tests, then genuine F12
  input. No feature flag or state migration is needed because maximization is
  transient.

## Decisions

- Maximization is workspace-local, never OS/Godot fullscreen.
- Visibility is derived from `view_layout + maximized_slot`; controls are not
  reparented and layout snapshots are not duplicated.
- All three split offsets remain live and untouched throughout the transition.
- Pane cycling transfers maximization rather than restoring the layout.
- Pane replacement keeps maximization when it occurs in the target slot.
- Every explicit layout command exits maximization.
- Session changes do not exit maximization because the workspace is shared, but
  persistence/recovery never records it.
- The active border remains visible in maximize mode.
- Escape integration is deferred to Phase 5 with an explicit priority contract.
