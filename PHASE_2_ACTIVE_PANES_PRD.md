# Phase 2: Active Panes PRD

## Status

Implementation-ready proposal.

## Date

2026-09-18

## Product area

Radiant Map editor, multi-pane workspace activation and keyboard routing.

## Related documents

- `PHASE_1_PER_DOCUMENT_HISTORY_PRD.md`: active-document Map undo/redo behavior that pane routing must preserve.
- `HISTORY_NAVIGATION_PRD.md`: future enhanced Map history navigation; not part of pane activation.
- `MAP_EDITOR_UI_IMPLEMENTATION.md`: existing workspace and pane UI context.
- `tests/map_editor/window_input.md`: genuine displayed-editor input boundary and current evidence.

## Summary

Introduce transient `active_slot` state for the four workspace slots. Hovering a visible pane, clicking within it, or focusing one of its descendants activates that slot. The active slot receives a 1 px editor-theme accent border and is the target for pane-sensitive keyboard commands. Alt+Arrow moves to the visible neighbor in that screen direction.

`active_graph` remains as a compatibility alias derived from or assigning `active_slot`; `active_slot` becomes authoritative. Activation is never persisted. Pane maximize is deferred to Phase 4.

## Problem

The workspace can contain duplicate cameras, duplicate grids, UV panes, and entity panes, but current command targeting is split between keyboard focus and `active_graph`. Only grids explicitly update `active_graph`; camera and form controls can hold focus without a unified active-pane indicator. This makes the target of orientation, framing, cloning, camera, and future pane commands unclear, especially after hover, pane replacement, layout changes, or interaction with nested controls.

## Goals

- Maintain one authoritative active visible workspace slot.
- Activate panes predictably by hover, pointer press, or descendant focus.
- Show a clear 1 px theme-accent border without changing workspace geometry.
- Route pane-sensitive keyboard commands to the active pane while preserving global Map commands.
- Never steal editing shortcuts from text fields, modal dialogs, browser controls, or active gestures.
- Move among visible panes with Alt+Arrow in screen space.
- Preserve source compatibility for existing `active_graph` reads and assignments.
- Keep activation transient and independent of workspace serialization.

## Non-goals

- Maximizing, soloing, restoring, or popping out a pane; maximize is Phase 4.
- Persisting active slot in `workspace_state()`, project metadata, recovery, or editor settings.
- Reordering slots or changing the current 2/3/4-view layouts and splitter behavior.
- Adding pane tabs or drag-and-drop pane movement. Phase 6 adds Layers as the
  seventh registered pane type; Phase 2's registry and routing contract must
  accommodate it without implementing the Layers feature here.
- Changing map selection, document history, save state, camera transforms, grid origins, UV values, or entity selection merely because activation changes.
- Defining global shortcuts while Radiant is hidden or a non-Radiant editor screen owns input.

## UX contract

- Exactly one visible workspace slot is active whenever at least one slot is visible.
- Moving the pointer into a visible slot activates it immediately, including over its pane menu or a nested pane control. Hover does not grab keyboard focus.
- A pointer press inside a visible slot confirms activation before the pane handles the press.
- Focus entering any descendant of a visible slot activates that slot. Focus leaving a slot does not clear activation.
- The active slot has a 1 px border using the editor theme's accent color. Inactive slots have a transparent 1 px border so activation causes no relayout.
- The border surrounds the slot, including pane chrome, and is drawn below the slot's menu/input layer. It must not intercept pointer input.
- Alt+Left/Right/Up/Down activates the visible neighbor in that screen direction on the 2x2 slot grid (`0` top-left, `2` top-right, `1` bottom-left, `3` bottom-right). Hidden layout slots are skipped. If no neighbor exists in that direction, wrap to the farthest visible slot on the opposite side of the same row or column. If that axis has only one visible slot, the key is ignored.
- Cycling focuses the pane root only when it is focusable and no text/control editor currently needs protection; it otherwise changes active indication without forcing focus into a child field.
- Plain and modified Map commands continue to work only in the existing Radiant input boundary. Pane-sensitive commands resolve their target from `active_slot`, not from stale `active_graph` or incidental focus.
- No maximize affordance or double-click maximize behavior is added in this phase.

## Functional requirements

1. Add `active_slot: int`, constrained to a valid visible index or `-1` before workspace initialization.
2. Add one `set_active_slot(slot, request_focus := false)` path. It validates visibility, updates borders, updates compatible aliases/status, and optionally focuses a suitable pane root without changing document state.
3. Connect each `ViewSlot0` through `ViewSlot3` to hover and pointer activation. Observe viewport GUI focus changes and map a focus owner to its ancestor slot.
4. The pane registry contains seven stable types: Camera, Top Grid, Front Grid,
   Side Grid, UV, Entities, and Layers. Activation must work for every registered
   type, including duplicate pane types; Layers may remain unavailable until Phase
   6 lands but reserves pane type ID `6` now.
5. `set_slot_type()` keeps the replaced slot active when it was active. The new pane becomes the active target; no freed pane reference survives.
6. `apply_layout()` preserves `active_slot` if it remains visible. Otherwise it selects the first visible slot in row-major screen order `[0, 2, 1, 3]`.
7. `active_graph` becomes a compatibility property: reading returns the active slot's `Graph` pane or `null`; assigning a live graph activates the slot containing that graph; assigning `null` must not invalidate a valid `active_slot`.
8. Replace production assignments such as `host.active_graph = self` with the alias or direct slot activation without maintaining a second source of truth.
9. `route_key()` derives the active pane and active graph from `active_slot`. Global document commands may run from supported pane roots; graph-only commands run only when the active pane is a graph, camera-only commands run only when it is a camera, and Layers commands run only when the active pane is Layers.
10. Alt+Arrow pane movement is consumed only when Radiant is visible, no protected text/modal/browser surface owns input, and no graph/camera gesture, fly capture, or mouse-button interaction is active. Phase 7 nudge is rebound off Alt+Arrow.
11. Pane cycling cancels no in-progress gesture because cycling is rejected while a gesture is active. It creates no Map action and emits no session change.
12. Existing protections remain: `LineEdit`, `TextEdit`, material-browser focus, `file_dialog`, `dirty_dialog`, and `inspector`. Extend descendant checks to editable `SpinBox` line edits and UV/Entity pane fields through the generic text-control rule.
13. `workspace_state()` and `restore_workspace_state()` must neither write nor read `active_slot`. Restore chooses a valid active slot from the resulting visible layout.
14. Active-border and cycle state are test-observable without test code mutating production controls or synthesizing events.

## Architecture/data model

`map_editor.gd` is the single owner:

```text
active_slot: int = -1
visual_slot_order: [0, 2, 1, 3]

active_pane() -> slot_views[active_slot] or null
visible_slot_order() -> visual_slot_order filtered by ViewSlot.visible
slot_for_control(control) -> nearest ViewSlot ancestor index or -1
set_active_slot(index, request_focus := false)
move_active_slot(direction)  # Vector2i left/right/up/down with row/column wrap

active_graph:
  get -> active_pane() when its script is Graph, otherwise null
  set(graph) -> activate slot_views.find(graph) when graph is live
```

Each slot receives a non-interactive full-rect border layer or panel style with a constant 1 px transparent border. Activation changes only its border color. Use the editor base control's theme accent color, with the existing `editor_color()` helper and a documented fallback. Do not add an image asset or hard-coded pane-type color.

Input remains centralized in `map_editor.gd::_input()`/`route_key()`. Pane classes continue to own gesture mechanics and call the host router, but target selection comes from `active_slot`. A helper must classify protected focus and active interactions before pane cycling or command routing. This avoids duplicating shortcut policy across seven pane types.

## Detailed implementation by file

| File / symbol | Required change |
|---|---|
| `addons/tbloader/src/editor/map_editor.gd` state declarations | Add authoritative `active_slot`, visual order, slot-border references, and the computed `active_graph` compatibility property. Remove the standalone mutable `active_graph` source of truth. |
| `map_editor.gd::_ready()` slot construction | Add the 1 px non-interactive border for each `ViewSlot`; connect slot `mouse_entered`/`gui_input` activation and the viewport's GUI focus-change signal; initialize activation after pane creation and layout application. |
| `map_editor.gd` new activation helpers | Implement visible order, control-to-slot ancestry, active pane/graph/camera queries, border refresh, activation, protected-focus detection, active-interaction detection, and wrapped cycling. |
| `map_editor.gd::set_slot_type()` / `rebuild_pane_collections()` | Preserve slot identity across pane replacement, avoid selecting a fallback graph as separate state, and keep aliases/collections free of queued-for-deletion panes. |
| `map_editor.gd::apply_layout()` | Keep the active slot when visible or select the first visible slot in row-major visual order; refresh borders and command status. |
| `map_editor.gd::route_key()` / `_input()` | Handle Alt+Arrow pane movement before pane-specific commands; route commands through the active pane while retaining text/dialog/browser/inspector and gesture protections. |
| `map_editor.gd::workspace_state()` / `restore_workspace_state()` | Explicitly leave `active_slot` out of serialized workspace data and choose a valid transient slot after restore. |
| `addons/tbloader/src/editor/graph_view.gd::_ready()` / `_gui_input()` | Keep existing focus and pointer behavior, but route activation through the host alias/helper; ensure graph press/focus still activates its containing slot before command handling. No geometry/gesture change. |
| `addons/tbloader/src/editor/camera_view.gd::_ready()` / `_gui_input()` | Ensure camera focus/pointer paths activate their slot before camera handling and pass the active pane context to the host router. Preserve fly/capture and gesture cancellation behavior. |
| `addons/tbloader/src/editor/uv_pane.gd` and `entity_pane.gd` | No pane-specific shortcut implementation expected. Verify descendant focus and hover are sufficient; add only an activation hook if Godot signal ordering proves central slot/focus observation insufficient. |
| `addons/tbloader/src/editor/layers_pane.gd` | Phase 6 implementation. Register as pane type ID `6`; use the same descendant-focus activation and generic protected-text handling as other panes. |
| `tests/map_editor/editor_suite.gd` | Add deterministic activation, border, visual-order cycling, alias, pane replacement, layout fallback, routing protection, transient persistence, and no-history tests. Replace assertions that assign `active_graph = null` with alias-compatible expectations where needed. |
| `tests/map_editor/window_input_observer.gd` | Read-only report `active_slot`, active pane type, visible slot order, and slot rectangles/border-active flags. Do not call production setters or alter focus. |
| `tests/map_editor/window_input_runner.py` | Add genuine pointer hover/click and Alt+Arrow journeys, including nested fields, dialogs, gesture rejection, wrap, and screenshot evidence for the accent border. |

No native C++ file, `map_session.gd`, `map_action.gd`, recovery schema, icon asset, or scene-history code should change for Phase 2.

## Edge cases

- Before `_ready()` completes, `active_slot == -1` and alias reads return `null` safely.
- Hover over a slot menu activates the slot but does not open the menu or steal focus.
- A child popup outside the slot rectangle does not activate another slot; modal/dialog protection wins.
- If the active pane is replaced in place, the same slot remains active even when its type changes from graph to camera/UV/entity.
- If a layout hides the active slot, activation moves to the first slot in filtered visual order. Re-expanding does not resurrect the previously hidden active slot.
- Duplicate grid orientations and duplicate cameras remain distinguishable by slot index, not pane type or collection sort order.
- When UV or Entity is active and a child text field has focus, letters, Delete, clipboard, undo/redo, and arrow keys remain with the field/control.
- During graph drag, camera gesture, camera freelook/fly, splitter drag, or held mouse interaction, cycling is ignored and not consumed if another owner should finish the gesture.
- If the active pane is UV, Entities, or Layers, graph-only commands such as Space clone-axis selection and graph-oriented prism creation do nothing rather than falling back to an unrelated grid.
- If a queued-for-deletion pane was active, alias resolution uses current `slot_views` and never returns the stale instance.
- Hover events generated while Radiant is hidden do not alter command routing; layout visibility still determines the next valid slot when shown.

## Accessibility/platform

- The border is supplemental; active state must also update each slot/pane's accessibility description to include `Active pane` and its pane type/slot number.
- Do not rely on color alone. The 1 px border must respect editor scaling as a logical theme border and remain visible in light and dark themes.
- Keyboard cycling uses Command on macOS and Ctrl elsewhere through the existing command-or-control convention.
- Alt+Arrow must not interfere with text editing, item/tree navigation, popup menus, or native dialogs.
- Focus is never moved on hover. Keyboard movement may focus a focusable pane root but must not place the caret in or select a nested editor field.
- Verify Linux/X11/XWayland through the existing genuine-input harness. Alt is Option on macOS.

## Performance/memory

- Activation is O(4): update four border states and, at most, scan four slot roots.
- Hover must not call `refresh()`, rebuild geometry, update session state, serialize workspace state, or queue all-pane redraws. Queue only the affected border/accessibility update.
- Focus-owner ancestry is bounded by the shallow editor control tree and runs only on GUI focus changes.
- The border adds at most one lightweight Control/style object per slot and no textures.
- Cycling and activation allocate no persistent history snapshots and must leave `MapSession.history_action_count()` and retained bytes unchanged.

## Test plan

- In `editor_suite.gd`, assert initial active slot is valid for the default 3-view layout and exactly one border reports active.
- Emit/drive hover, click, and descendant focus for each pane type and assert the corresponding slot activates without focus stealing on hover.
- Configure duplicate grids and cameras and prove activation follows slot identity rather than orientation, type, or sorted `graphs`/`cameras` collections.
- Assert Alt+Arrow neighbor/wrap: 2-view only horizontal `[0,2]`; 4-view full 2x2; 3-view skips hidden slot 1.
- Replace the active slot's pane type and assert the slot remains active, `active_graph` changes between graph/null appropriately, and no freed instance is returned.
- Assign each live graph through the compatibility alias and assert its containing slot becomes active; assigning `null` does not clear a valid active slot.
- Verify layout changes preserve a visible active slot and choose the first visual slot when the active slot becomes hidden.
- Verify graph-only and camera-only commands target the active pane with duplicate panes present and never fall back from UV/Entities/Layers to an unrelated graph.
- Focus every current `LineEdit`/`TextEdit` class of surface, including UV SpinBox editors and entity fields; verify typing, Delete, clipboard, undo/redo, and arrows are not intercepted.
- Open `file_dialog`, `dirty_dialog`, inspector, pane popup, and material-browser search; verify activation shortcuts are protected.
- Start graph and camera gestures/fly capture and verify cycling cannot move `active_slot`, commit content, or leave held/gesture state inconsistent.
- Compare `workspace_state()` before/after activation and ensure no `active_slot` key appears. Restore the same state and assert activation is freshly selected from visible layout.
- Assert activation/cycling changes neither canonical Map text, selection, revision, dirty state, nor Map history count/cursor.
- Extend `window_input_runner.py` with real pointer movement/clicks and Alt+Arrow keys; use observer state and a screenshot to verify activation and the border under actual dispatch.

## Acceptance criteria

1. Hovering, clicking, or focusing within any visible slot makes it the sole active slot without changing document/session state.
2. The active slot has a 1 px editor-theme accent border; inactive slots retain transparent 1 px borders and pane geometry does not move.
3. Alt+Arrow activates the visible screen-space neighbor, wrapping on that row or column and ignoring axes with only one visible slot.
4. Text fields, editable SpinBoxes, browser controls, popup/modal dialogs, and inspector interactions keep their native input and do not cycle or invoke Map commands.
5. Active graph/camera gestures and fly capture cannot be redirected by pane cycling and finish/cancel under existing rules.
6. Pane-sensitive commands act on the pane in `active_slot`; unsupported pane types do not fall back to another graph or camera.
7. Existing `active_graph` reads and live-graph assignments remain functional as an alias with no independent state.
8. Pane replacement and layout changes always leave a valid visible active slot and no stale pane reference.
9. `workspace_state()` and recovery contain no active-pane field; activation is freshly established after restore/restart.
10. No maximize behavior is present; Phase 4 remains the owner of maximize/restore UX.
11. Unit/editor integration and genuine displayed-input tests pass with no Map content/history changes caused by activation.

## Rollout/dependencies

- Phase 2 depends on the existing slot-owned workspace (`view_slots`, `slot_views`, `slot_types`) and should land after Phase 1's active-document routing is validated.
- Implement central `map_editor.gd` state and tests first, then make only the necessary graph/camera hook adjustments proven by signal ordering.
- No migration or feature flag is needed because active state is transient. Existing persisted workspace dictionaries remain compatible because no key is added or consumed.
- Phase 4 maximize must use `active_slot` rather than introducing another current-pane variable, but Phase 2 must not pre-build maximize UI.

## Document tabs (same `route_key()` pass)

The plugin does **not** currently index `.map` files. Only textures are indexed, via `material_browser.gd`'s EditorFileSystem walk. Maps are opened through `FileDialog` (`*.map`). Closing the last tab always creates an untitled `Session`. Ctrl+Tab currently cycles grid orientation.

### Shortcuts

Consumed only while Radiant is visible and no protected text/modal/browser surface owns input:

| Shortcut | Action |
|---|---|
| Ctrl+Tab / Ctrl+Shift+Tab | Next/previous open Map tab. Control on every OS; never Cmd+Tab. |
| Ctrl/Cmd+T | New untitled Map tab. |
| Ctrl/Cmd+Shift+T | Reopen last closed saved Map path. |
| Ctrl/Cmd+W | Close the active Map tab. Dirty close uses the existing dialog. |

Ctrl+N remains New. Godot's scene-tab/close/reopen shortcuts are stolen only while Radiant is the main screen, matching existing Ctrl+S interception.

### Empty workspace

Closing the last tab must not call `Session.new()`. With zero sessions, hide document panes and show a start overlay:

1. **New Map**
2. **Recent** — persisted saved paths that still exist
3. **All maps** — EditorFileSystem `*.map` scan excluding Recent

Ctrl+T from empty creates untitled and dismisses the overlay. Choosing a listed path opens it. Rebuild the index like the material browser; no import plugin.

### Closed-tab stack

Remember closed saved paths, newest first. Untitled discards are not reopenable. Skip missing files. Ctrl+Shift+T on an empty stack is a no-op with the existing notice style.

## Open questions/decisions

- **Decision:** `active_slot` is authoritative; `active_graph` is only a compatibility alias.
- **Decision:** pane movement is Alt+Arrow in screen space on the 2x2 slot grid, skipping hidden slots and wrapping on the same row or column.
- **Decision:** hover activates but never grabs focus; click/focus also activate.
- **Decision:** activation is transient and excluded from all persistence and recovery payloads.
- **Decision:** the border is 1 px, theme-accent, non-interactive, and geometry-stable.
- **Decision:** unsupported commands do not fall back from UV/Entities/Layers to the last graph.
- **Decision:** maximize is deferred entirely to Phase 4.
- **Decision:** Ctrl+Tab is Map document cycling, not pane cycling. Grid orientation remains available from the pane orientation gizmo / `cycle_orientation()` until a replacement shortcut is chosen.
- **Decision:** Phase 7 nudge is rebound off Alt+Arrow.
- **Open validation:** confirm on the pinned Godot build whether parent slot `mouse_entered` and root GUI focus-change signals cover embedded `SubViewportContainer`, popup, and SpinBox focus transitions; add pane-local forwarding only where observed gaps exist.
- **Open validation:** verify the selected editor accent theme key has sufficient contrast across bundled light/dark themes and choose the closest existing editor-theme fallback without adding a custom color setting.
