# Phase 6: `func_group` Layers PRD

**Status:** Implementation-ready proposal  
**Date:** 2026-09-18  
**Product area:** Radiant Map editor organization, ownership, and visibility  
**Related documents:** `MAP_EDITOR_PRD.md`, `MAP_EDITOR_IMPLEMENTATION.md`, `MAP_EDITOR_UI_IMPLEMENTATION.md`, `HISTORY_NAVIGATION_PRD.md`, `WORLDSPAWN_CHUNKING_PRD.md`, `addons/tbloader/Usage.md`

## Summary

Add a flat Layers pane for world geometry using ordinary `.map` ownership. The
existing `worldspawn` is the permanent **Worldspawn** default layer and every
`func_group` entity is a layer. A layer name is its authored `targetname`, with a
stable UI fallback when absent. Users can create, rename, activate, show/hide,
lock, search, count, isolate, select, add/remove members, and delete layers.

Layer membership and names are ordinary `.map` content and participate in Map
undo/redo, save, clipboard, and recovery. Eye, lock, active-layer, isolation, and
search state are transient per open session. V1 layers never own point entities
or brushes belonging to gameplay brush entities.

## Problem

The editor exposes raw entity grouping but not an organization workflow.
`group_brushes(ids, classname)` cannot create an empty entity and always creates
a new owner. `return_brushes_to_worldspawn(ids)` cannot move brushes to an
existing `func_group`. Owner information is embedded in full entity/draw arrays,
and session visibility currently distinguishes only manually hidden brushes,
material/entity filters, and point markers.

Using sidecar metadata or comments would split authoring state from the `.map`
format and existing ownership semantics. Treating all entities as layers would
also let organizational actions accidentally move gameplay entities or alter
their behavior. The missing product boundary is a flat, world-geometry-only view
over `worldspawn` and `func_group`.

## Goals

- Represent layers entirely through existing `worldspawn`/`func_group` ownership.
- Make an empty `func_group` creatable and editable.
- Move eligible brushes atomically to an existing eligible owner while retaining
  brush IDs and geometry.
- Provide efficient owner/layer queries and indexes in the native document.
- Make new world brushes use the active owner.
- Keep layer visibility, isolation, locking, active state, and search transient
  and independent from authored map content and other visibility reasons.
- Preserve deterministic behavior through duplicate, clipboard, split, merge,
  undo/redo, load/save, and deletion.
- Prevent layer UI from changing point entities or gameplay brush entities.

## Non-goals

- Hierarchical, nested, parent/child, or folder layers.
- Named selection sets or a brush belonging to multiple layers.
- Region/portal/streaming semantics or compile-time visibility control.
- Metadata comments, editor-only entity keys, sidecar files, or project settings
  that encode membership.
- Point-entity layering.
- Treating gameplay brush entities such as `area`, `trigger_location`,
  `func_detail`, or `nocollision` as layers.
- Converting gameplay entities to `func_group`, or moving their brushes through
  layer commands.
- Patch membership editing in v1.
- Persisting eye, lock, active, isolation, or search state to `.map` content.
- Replacing the Entities pane or hiding `func_group` from ordinary entity editing.

## UX Contract

### Layer identity and rows

- The first row is the unique `worldspawn`, labeled **Worldspawn**. It cannot be
  renamed, deleted, or reordered and is the default active layer.
- Every entity whose first `classname` value is exactly `func_group` is one row,
  including empty groups loaded from disk or created in the pane.
- Display name is the first `targetname` value when non-empty. Otherwise use
  `Unnamed Layer #<entity_id>`. The fallback is presentation only and is never
  written automatically.
- Duplicate names are allowed. Tooltips and accessible descriptions include the
  entity ID, classname, and brush count so rows remain distinguishable.
- Count is the number of owned brushes, not patches or entities.

### Row controls and commands

- Each row exposes eye, lock, active radio, name, and brush count.
- Toolbar/context commands expose **New Layer**, **Rename**, **Select Members**,
  **Add Selection**, **Remove Selection**, **Show Only**, **Show All**, and
  **Delete Layer**. Search filters rows by case-insensitive display-name substring
  without changing geometry visibility or active layer.
- **New Layer** creates an empty `func_group`, assigns the entered name as
  `targetname` when non-empty, makes it active, and starts with eye on and lock
  off. Cancel creates nothing.
- Inline rename edits `targetname`; an empty committed value removes all
  `targetname` epairs and returns to the fallback label. Worldspawn rename is
  unavailable.
- Active owner determines ownership only for newly drawn/newly created cuboids and
  pasted neutral world geometry. Reshaping an existing brush with prism controls
  preserves its owner. Selecting a layer does not select its members.
- **Select Members** replaces brush selection with visible, unlocked members.
  Shift activation adds those members. Hidden or locked members are reported but
  not selected. Point and component selection clear through normal primitive
  selection rules.
- **Add Selection** moves selected eligible brushes into the row's owner.
- **Remove Selection** is available only on a `func_group` row and moves selected
  eligible members of that row to worldspawn. It does not move selected brushes
  from another layer.
- **Show Only** isolates one owner without modifying eye toggles, manual hidden
  IDs, material filters, or entity filters. **Show All** clears only isolation.
- **Delete Layer** confirms when non-empty, atomically moves all owned brushes to
  worldspawn, deletes the now-empty `func_group`, sets Worldspawn active if the
  deleted layer was active, and removes its transient state. It never deletes
  geometry.

### Eligibility and feedback

- An eligible brush is currently owned by `worldspawn` or `func_group`.
- A destination owner is the unique `worldspawn` or a `func_group`.
- If any supplied ID is unknown, a patch, a point entity, or a brush owned by any
  other classname, the entire move fails with no mutation. A mixed eligible and
  ineligible spatial selection rejects the whole UI move with a clear notice that
  identifies the ineligible category; neither UI nor native code moves a subset.
- Lock prevents spatial picking, selection, component handles, transforms,
  texture/entity mutation through brush selection, deletion, and adding/removing
  members. It does not hide geometry or block selecting the layer row.
- Enabling lock immediately prunes that layer's brushes and components from the
  current selection through one normal selection notification. Locked members are
  thereafter unselectable. Native mutation APIs still validate every supplied ID
  normally, but UI transform/edit commands reject locked targets and never silently
  transform a locked subset or rely on stale selection.
- Active, eye, and lock are independent. A hidden layer may be active. If the
  active layer is locked, creation/paste fails with an actionable notice rather
  than silently using another owner. A brush created in a hidden active layer is
  authored there but immediately pruned from visible selection.

## Functional Requirements

### Authored layer data

- Membership is the brush's owning entity in canonical `.map` source.
- Name is the `func_group` entity's `targetname` epair.
- Create, rename, move, remove, and delete run through
  `map_session.gd::transact()` with one user-facing history event each.
- Brush IDs survive ownership moves and layer deletion/rehome. Owner entity IDs
  survive rename and membership changes.
- Saving/reopening reproduces layer rows, names, order, and membership from map
  content without migration or hidden metadata.
- General Entities-pane edits to `classname` or `targetname` immediately rebuild
  the layer model. Existing worldspawn identity validation remains unchanged.

### Transient session state

- Add per-session `active_layer_id`, `layer_hidden`, `layer_locked`,
  `isolated_layer_id`, and `layer_search` state.
- Initialize active to worldspawn on New/load/import/recovery. Initialize all
  eyes visible, all locks off, no isolation, and empty search.
- These values do not dirty the document, add history events, move the history
  cursor, serialize to `.map`, or enter recovery content. They survive switching
  between open document tabs during the process lifetime and disappear when the
  session closes.
- On content change/history restore, prune dead IDs. If active dies or no longer
  qualifies, use worldspawn. New/restored `func_group` IDs default visible and
  unlocked. Isolation clears if its owner dies.

### Independent visibility reasons

- Effective brush visibility is the conjunction of existing manual brush hidden
  state, material/entity filters, layer eye state, and current layer isolation.
- Store each reason separately. Toggling an eye never adds IDs to `hidden`,
  changes a quick filter, clears isolation, or edits map content.
- **Show Only** never rewrites eye state. Clearing isolation restores the exact
  prior result of eyes, manual hidden brushes, and filters.
- Hidden-by-layer brushes and their components are pruned from active selection
  using the same notification path as existing filters. Point markers are never
  affected by layer eyes/isolation; the existing entity filter remains their
  only category-level visibility control.
- Locking a layer uses the same immediate selection/component-pruning path, without
  changing visibility. All selection producers consult both effective visibility
  and layer lock before adding a brush or component.
- Camera preview chunk preparation receives the effective hidden brush IDs, or a
  native owner mask if profiling proves that cheaper. Ray, graph, paint-select,
  box-select, overlays, and component handles use the same effective predicate.

### Clipboard, duplicate, split, and merge

- Duplicate preserves each source brush's owner. It does not use the active
  layer and does not create a new `func_group`.
- Prism operations that reshape an existing brush preserve that brush's owner.
  Only a newly drawn or newly created cuboid uses the active layer owner.
- Split/clip pieces remain under the source brush's owner. Generated piece IDs
  are new as today; unchanged pieces retain IDs.
- Merge is allowed only when all brushes have the same owner. Cross-layer merge
  is rejected atomically with a layer-specific UI notice; users must move them
  to one layer first. The merged brush retains that owner.
- Copying worldspawn/`func_group` brushes serializes them as neutral worldspawn
  clipboard geometry, not as copied layer entities or `targetname` metadata.
  Thus copying members cannot create layers on paste.
- Copying a gameplay brush entity retains its ordinary owner epairs and remains
  gameplay-owned on paste; it is not redirected by active layer.
- Pasting neutral world geometry assigns all imported brushes to the active
  eligible owner in one native commit. A locked active owner rejects the paste.
  Clipboard parse or eligibility failure is atomic.
- A selection spanning multiple world layers copies brushes in deterministic
  selected order into one neutral worldspawn clipboard entity. Relative geometry
  and face data remain unchanged.

### Empty groups, patches, and imported maps

- Empty `func_group` entities are valid, listed, saved, copied only through full
  map save (not brush clipboard), undoable, and deletable without confirmation.
- Every imported `func_group` is listed even if it has unknown epairs or no
  brushes. Unknown/duplicate epairs retain their existing parser/writer behavior.
- Patches are not counted, selected, moved, hidden, or locked by the Layers pane
  in v1. A `func_group` that owns any patch displays a warning and **Delete
  Layer** is disabled/rejected so no patch or unknown source text is lost. Its
  brushes may still be moved individually.
- Multiple malformed worldspawns remain governed by parser/document policy; the
  layer feature does not invent merge or repair behavior.

## Architecture And Data Model

### Native source of truth

`TBMapDocument` remains authoritative. Extend its live index with owner metadata
derived whenever `rebuild_live_index()` runs:

```cpp
struct OwnerIndexEntry {
    int entity_index;
    int64_t entity_id;
    StringName classname;
};
std::unordered_map<int64_t, OwnerIndexEntry> brush_owners;
std::unordered_map<int64_t, int> entity_indices;
```

The existing `LiveLocation` already identifies a brush's entity; the additional
maps make public owner queries explicit and avoid repeated scans/string parsing.
They are rebuilt atomically with the live ID index and never outlive the current
map generation.

Native APIs use the existing result dictionary shape
`{ok, changed, value, error}`:

```text
create_func_group(targetname: String) -> int entity_id
move_brushes_to_owner(ids: PackedInt64Array, owner_id: int) -> PackedInt64Array
get_world_geometry_owners() -> Array[Dictionary]
get_brush_owner(brush_id: int) -> Dictionary
create_cuboid(mins, maxs, texture, owner_id: int = 0) -> int brush_id
import_selection(text: String, world_owner_id: int = 0) -> PackedInt64Array
```

`owner_id == 0` means the document's worldspawn for creation/import compatibility.
Owner descriptors are copied values:

```text
{
  id: int,
  classname: "worldspawn" | "func_group",
  targetname: String,
  brush_ids: PackedInt64Array,
  brush_count: int,
  patch_count: int,
  source_index: int
}
```

`get_world_geometry_owners()` returns worldspawn first, then `func_group` entities
in source order, including empty groups. `get_brush_owner()` returns owner ID,
classname, eligibility, and source indexes for one brush; unknown IDs fail with
`INVALID_ID`.

### Mutation contracts

- `create_func_group()` validates `targetname` with the existing epair rules,
  allocates one entity ID, writes `classname=func_group`, writes `targetname` only
  when non-empty, appends in entity source order, and commits once.
- `move_brushes_to_owner()` validates every ID and the target before editing.
  Source and target must be worldspawn/`func_group`; duplicate IDs are
  deduplicated in first-occurrence order. Brushes already in the target retain
  their positions. Moved brushes are removed from sources and appended to the
  target in request order. Empty source `func_group` entities remain. An all-
  target request is a no-op. IDs, faces, materials, and topology remain stable.
- Layer deletion uses one purpose-specific native operation
  `delete_func_group_layer(entity_id)` or an equivalently atomic staged edit; it
  validates `func_group`, rejects patches, appends brushes to worldspawn in
  source order, and removes the entity in one commit. Do not compose two
  user-visible native commits around `delete_entities()`.
- Rename uses `set_entity_property()`/`remove_entity_property()` inside one
  session transaction after confirming the target remains a `func_group`.
- Create/import owner parameters validate before staging and commit once. They
  must not create in worldspawn and then issue a second ownership commit.

### Session and pane model

`map_session.gd` caches owner descriptors by document generation and derives
brush-to-layer IDs from native owner results. It exposes semantic methods such as
`layers()`, `layer_for_brush()`, `layer_visible()`, `layer_locked()`,
`set_active_layer()`, `set_layer_eye()`, `set_layer_lock()`, `show_only_layer()`,
and `clear_layer_isolation()`.

`layers_pane.gd` is a view/controller over those methods. It never mutates the
document directly and never infers eligibility from display labels. Multiple
pane instances share the session model and refresh from `session.changed`.

## Detailed Implementation By File / Native API

| File / symbol | Required implementation |
|---|---|
| `src/map_document.h` | Declare owner index records and the create/move/query/delete APIs; extend create/import signatures with optional eligible owner. |
| `src/map_document.cpp::rebuild_live_index()` | Build entity and brush-owner indexes together with `live_ids`; clear/rebuild them on every map replacement/restore. |
| `src/map_document.cpp::get_entities()` / `_bind_methods()` | Bind new APIs and retain copied, pointer-free dictionaries. Existing entity schema remains compatible. |
| `src/map_document_ops.cpp` | Implement strict eligibility validation, empty `func_group` creation, stable reparenting, atomic layer deletion, owner-aware creation/import, and precise `INVALID_ID`, `INVALID_ARGUMENT`, `INELIGIBLE_OWNER`, `LOCKED_LAYER`-independent native errors. Lock remains UI/session policy. |
| `src/map/map_edit.h/.cpp` | Reuse `LMEditEntity`/`LMMapEdit`; add a small owner lookup/move helper only if it removes duplicated staged-edit scans. Preserve primitive/source order and unknown epairs. |
| `addons/tbloader/src/editor/map_session.gd` | Add transient layer state, owner cache, generation pruning, effective visibility/lock predicates, member selection helpers, and active-owner wrappers for create/paste. Keep state out of history envelopes and recovery. |
| `addons/tbloader/src/editor/layers_pane.gd` | New themed pane with search, virtualized/list rows, eye/lock/active controls, counts, inline rename, command buttons/context menu, confirmations, accessibility names, and status/error feedback. |
| `addons/tbloader/src/editor/map_editor.gd::_ready()` | Register Layers as the seventh slot pane type at the Phase 2/3-reserved ID `6`, instantiate it through the existing pane registry, route commands through transactions, and use active owner only for new brush/cuboid creation and neutral paste. Do not create a separate Layers bottom panel. |
| `map_editor.gd::set_session()` / `_session_changed()` | Rebind every Layers pane; distinguish layer-state visibility refresh from authored ownership/entity refresh. |
| `addons/tbloader/src/editor/graph_view.gd` | Exclude locked layers from hit, box/paint selection, direct manipulation, and component handles; create brushes through active owner. |
| `addons/tbloader/src/editor/camera_view.gd` | Apply effective layer visibility and locking to render chunks, ray selection, paint selection, overlays, and component handles. |
| `addons/tbloader/src/plugin.gd` | No Layers bottom-panel registration. Ensure plugin teardown cleans up Layers pane instances through the existing slot workspace lifecycle. |
| `tests/map_editor/native_document_test.cpp` | Add low-level ownership/index/order/ID and round-trip assertions under ASan/UBSan/leak gates. |
| `tests/map_editor/document_suite.gd` | Test every native API, validation failure, no-op, canonical serialization, history state restore, clipboard rule, patch guard, and large-owner query. |
| `tests/map_editor/editor_suite.gd` | Test session state, pane controls, transactions, history, visibility independence, locks, active owner, tabs, and all edit semantics. |
| `tests/map_editor/window_input_observer.gd` | Expose read-only layer rows/control rectangles, active/eye/lock/isolation state, counts, and effective visible IDs. |
| `tests/map_editor/window_input_runner.py` | Add real keyboard/mouse create, rename, eye, lock, search, show-only, assignment, and delete journeys. |

## Edge Cases

- Missing/empty `targetname` uses fallback; duplicate and Unicode names are
  allowed under existing epair limits. Search uses Godot case folding.
- If an entity's classname changes into `func_group`, it appears with default
  transient state. If changed away, it disappears; active/isolation fall back
  safely without moving brushes.
- Mixed eligible/ineligible selections do not partially move. The pane explains
  which selected brushes belong to gameplay entities and rejects the whole move.
- Moving the same IDs repeatedly or moving an empty selection is a no-op with no
  revision/history event.
- Empty source layers remain as authored rows after all members move out.
- Deleting the active, hidden, locked, isolated, or searched layer removes all
  corresponding transient references and activates Worldspawn.
- Undoing layer deletion restores the exact entity ID, name, source position,
  brush IDs, and membership; transient eye/lock defaults apply to the restored
  ID if its prior state was pruned.
- Hidden/locked owner IDs do not accidentally apply to a future entity because
  IDs are never reused in an epoch.
- Worldspawn cannot be deleted, renamed, or removed from the owner query.
- A map with zero worldspawn uses the document's existing world creation policy;
  first creation establishes worldspawn before it can become active.
- Layer count updates after create/delete/duplicate/split/merge/paste, history
  navigation, external load, and entity property edits.
- A `func_group` with patches is visible and renameable, but delete is rejected
  and patches never disappear from save output.

## Accessibility And Platform

- Use standard Godot `LineEdit`, item/list controls, `Button`, `CheckButton` or
  equivalent accessible toggles, `PopupMenu`, and `ConfirmationDialog`.
- Every row exposes an accessible name such as
  `Layer Walls, 14 brushes, visible, unlocked, active`; icon-only controls have
  explicit names/tooltips and pressed state.
- Eye, lock, and active state cannot rely on color. Keyboard users can search,
  move row focus, toggle eye/lock, set active, invoke the context menu, rename,
  and confirm/cancel deletion.
- Focus remains on the corresponding row after refresh where its stable entity
  ID survives. Deletion moves focus to the next row or Worldspawn.
- Pane layout responds to editor scale and narrow slot widths; truncate
  names visually while preserving full tooltip/accessibility text.
- Behavior is platform-neutral. Validate Linux displayed input as the release
  gate and standard Ctrl/Cmd focus conventions on available macOS/Windows runs.

## Performance

- Native owner index rebuild is O(entities + primitives) only at existing
  structural rebuild boundaries. A brush-owner query is O(1).
- Owner list construction is O(entities + eligible brushes) and cached in the
  session by document generation. Eye, lock, active, isolation, and search do not
  serialize or rebuild native geometry.
- Visibility checks are O(1) per brush using cached owner ID sets. One layer
  toggle invalidates visibility/chunk caches once and emits one visibility
  notification.
- Row filtering is O(layer count). Use an `ItemList`/`Tree` or bounded row reuse;
  do not create per-brush controls.
- Add a fixture with thousands of brushes and hundreds of empty/non-empty groups.
  Acceptance is linear refresh, constant-time owner lookup, no per-frame full
  entity scan, and no native commit for transient controls.

## Test Plan

### Native document

- Create named/unnamed empty groups; verify epair order, IDs, source order,
  owner descriptors, canonical save/reload, and snapshot/history restoration.
- Move ordered, duplicate, mixed-source, already-target, empty, unknown, patch,
  world, `func_group`, and gameplay-owned inputs. Assert all-or-nothing behavior,
  stable brush IDs/topology, target order, emptied source retention, precise
  errors, and no-op revision behavior.
- Delete empty/non-empty layers and verify worldspawn rehome order. Reject
  worldspawn, gameplay entities, unknown IDs, and patch-owning groups atomically.
- Exercise owner-aware cuboid/import and neutral clipboard export. Verify
  gameplay brush-entity clipboard ownership remains intact.

### Session and editor integration

- Test row order/names/counts/search, duplicate names, Unicode, rename-to-empty,
  active fallback, New/load/import/recovery, tabs, and general Entities edits.
- Test eye, manual hide, each material/entity filter, and isolation in every
  combination; clearing one reason must preserve all others.
- Test lock against graph/camera click, box/paint selection, component handles,
  move/rotate/resize/texture/delete, add/remove, creation, and paste. Lock an
  already-selected layer and assert immediate brush/component pruning; pass stale
  locked IDs to UI commands and assert whole-command rejection with no partial
  transform, while direct native transform validation remains deterministic.
- Test select/add/remove members, mixed eligible/ineligible whole-move rejection,
  hidden/locked member omission, empty layers, and selection generation/refresh
  counts.
- Test duplicate/split owner retention, same-owner merge, cross-owner rejection,
  copy across layers, active-owner paste, hidden active creation, and locked active
  failure.
- Assert authored actions each add one history event; eye/lock/active/isolation/
  search add none and never dirty canonical text.

### UI and regression

- Inspect seventh-pane registration and slot replacement, theme, narrow layout, labels,
  tooltips, accessible names/states, keyboard focus retention, confirmation text,
  and error/status text.
- Drive actual pointer/keyboard journeys through displayed controls, including
  rename submit/cancel and delete confirmation.
- Run native, document, editor, toolbar, UI, recovery, window-input, real-map,
  and performance suites with strict empty-stderr/timeout rules.

## Acceptance Criteria

1. Worldspawn is always the first, permanent default row and every
   `func_group`, including an empty one, appears as exactly one flat layer.
2. Name comes only from authored `targetname`; missing/empty names use the
   documented non-authored fallback and duplicate names remain valid.
3. Native APIs create an empty `func_group`, move eligible brushes to an existing
   eligible owner, and return indexed owner data without repeated full scans.
4. Ownership moves preserve brush IDs/geometry, validate atomically, retain empty
   source groups, serialize normally, and undo/redo as one action.
5. Point entities and gameplay brush entities are never layer members or
   movable through Layers commands.
6. The Layers pane supports active, eye, lock, count, search, create, rename,
   select/add/remove members, show only/show all, and delete with accessible
   keyboard-operable controls.
7. New world brushes and neutral pasted world geometry use the active owner;
   locked active owners fail explicitly rather than falling back.
8. Duplicate and split retain source ownership; merge requires one owner;
   neutral clipboard data does not clone layer entities; gameplay clipboard data
   retains gameplay ownership. Reshaping an existing prism brush preserves its
   owner; only new/drawn cuboids use the active owner.
9. Deleting a patch-free layer atomically rehomes all brushes to worldspawn and
   deletes only the `func_group`; patch-owning deletion is rejected without loss.
10. Membership/name changes are authored, dirty, saved, recovered, and undoable.
    Eye/lock/active/isolation/search are transient and create no history.
11. Eye, isolation, manual hide, material filters, and entity filters remain
    independent and combine consistently in graph, camera, picking, and handles.
12. Owner queries and visibility checks satisfy the documented linear/O(1)
    bounds on the large grouped fixture with no per-frame entity scan.
13. Locking immediately prunes member brush/component selections; locked members
    cannot be selected, and UI edits reject stale locked targets atomically without
    transforming an unlocked subset.
14. All native, editor, displayed UI, recovery, and performance tests pass.

## Dependencies And Rollout

- Requires stable entity/brush IDs, per-document history, and existing entity
  ownership/property editing, all already present. It also depends on Phase 2's
  seven-type pane registry/`active_slot` routing and Phase 3's reserved pane ID `6`,
  menu radio, protected-focus behavior, and central dispatcher.
- Implement and test native indexes/APIs first. Land session eligibility and
  visibility next, then Layers pane controls, then active-owner creation and
  clipboard semantics.
- Rebuild the GDExtension for native API changes and update staged test artifacts
  through the repository's existing harness; do not hand-edit generated binaries.
- No map migration or feature flag is required because existing `func_group`
  content is the source of truth. Existing maps gain rows without byte changes
  until the user performs an authored action.
- Roll out with patch-owning groups read-only for deletion and explicit notices.
  Patch membership editing can be a separately specified phase.

## Decisions

- V1 layers are flat and world-geometry-only.
- Worldspawn is the default layer; every `func_group` is a layer.
- `targetname` is the only authored layer name; fallback labels are UI-only.
- Membership is ordinary entity ownership, never comments, metadata, sidecars,
  regions, or named sets.
- Only worldspawn/`func_group` brushes can move through layer commands.
- Point entities and gameplay brush entities are never layered.
- Membership and names are authored and undoable; eye, lock, active, isolation,
  and search are transient session state.
- Visibility reasons remain independent and combine by conjunction.
- Active owner controls new world brushes and neutral paste; duplicate/split
  preserve source owner, prism reshaping preserves the existing owner, and merge
  requires one owner.
- Deleting a layer rehomes brushes to worldspawn and never deletes geometry.
- Patches are preserved but not editable as layer members in v1.
- No hierarchy, named sets, region behavior, metadata comments, or sidecar file
  is introduced.
