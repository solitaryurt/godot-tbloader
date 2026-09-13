# Map editor UI implementation and handoff

## Progress — 2026-09-13

- Implemented real Map main screen, camera/materials left and independent Top/Front
  grids right, resizable splitters, per-orientation pan/zoom, shared fractional grid.
- Graph handlers implement cuboid creation, click/Shift/directional box selection,
  rigid translation, silhouette plane resize, clone/paste/delete, hide/reveal,
  cancellation, axis constraint and AABB alignment.
- Native snapshots are committed to the real EditorUndoRedoManager global history
  with originating RefCounted sessions. Motion is a disposable visual preview;
  completion is one transaction, cancellation/no-op adds nothing. Tokens retain
  sessions across Open/New, with 128 actions/64 MiB per session and 128 MiB total.
  Budgets count serialized snapshot envelopes (including identities/selection).
  Eviction releases payloads and reports expiration when a token is invoked.
  A strong session registry owns documents independently of expirable snapshots;
  the picker exposes retained documents and background undo updates unsaved
  reporting and Save All. Discard retires saving only after successful replacement;
  resuming, editing or restoring history reactivates the document.
- Real indexed material browser reused without modification; shader assignment,
  classic UV controls, resolved texture dimensions and textured camera preview.
- N inspector edits ordered keyvals on worldspawn/selected owners/points; point
  and brush entity creation, point picking/movement, ownership and deletion.
- New/Open/Save/Save As, Save/Discard/Cancel replacement prompt, native external
  conflict reporting, Save All and editor unsaved-status hooks.
- Explicit loader binding is separate from spatial selection and toolbar.
  Checked bake is capability-gated, verifies scene/loader/path and clean saved
  source, reports saved versus baked states and marks successful bake scene dirty.
  Both the Map Bake button and legacy spatial Build Meshes use **scene history**
  with packed before/after generated-child snapshots and validated weak targets.
  Explicit loader-path changes also use scene history. Global Map undo remains
  independent from these scene operations.
- Phase 5 graph/component/clipper/prism acceptance is complete on the pinned engine.
  Shift-click adds/toggles face, edge and vertex selections; Alt-click cycles
  overlapping handles (Shift+Alt adds the far-side handle). Dragging a selected
  handle moves the whole group, with Shift axis constraint applied after snapping.
  Selected components have distinct face outlines/fills, edge lines and handles.
- Native `translate_components` validates every token, unions shared vertices and
  stages all selected brushes before one commit. Face groups move supporting planes;
  vertex/edge groups retain incident planar convex topology. Invalid later brushes
  leave all content, revision, cache, selection and history untouched.
- Clip caps are fresh `common/caulk` faces with classic identity UV and no inherited
  flags. Surviving source planes, texture/projection/UV/flags are preserved exactly.
  Component undo/redo rebinds indices only against the matching native snapshot;
  successful vertex/edge edits resolve moved positions, and stale live tokens reject.

## Architecture / ownership

| File under `addons/tbloader/src/` | Responsibility |
|---|---|
| `plugin.gd` | Main-screen lifecycle, independent spatial toolbar and legacy materials, editor save hooks |
| `editor/map_editor.gd` | Quad layout, shortcut router, dialogs, binding, materials/UV and entity inspector, history budget, document ownership and recovery |
| `editor/map_session.gd` | Native document, selection/hidden/workzone, transactions and snapshot envelopes |
| `editor/map_action.gd` | Retainable/expirable originating-session history token |
| `editor/bake_action.gd` | Scene-history packed child snapshots, weak loader/scene targets, ownership restoration |
| `editor/graph_view.gd` | Map-space projection, drawing, picking, preview gestures, tools |
| `editor/camera_view.gd` | Disposable triangle preview, map-to-Godot conversion, ray picking and captured fly input |
| `editor/material_browser.gd` | Independently delivered browser; consumed through documented API |

`.map` remains canonical. Preview and baked nodes never feed edits back into the
document. Phase 5 integrates the native batch API and shared document acceptance.
This harness offers no subagent tool; UI implementation/testing is performed directly.

## Verification

Pinned engine: `/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64`.

```sh
python tests/map_editor/run_tests.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite editor --timeout 60
DISPLAY=:0 python tests/map_editor/ui_journey_runner.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite ui --timeout 90
python tests/map_editor/run_tests.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite document --timeout 90
```

Work step 1 (`72a3753`): real editor **93 checks**,
`tests/map_editor/artifacts/editor-ythtc_vp/`.

Work step 2 integration results:

| Gate | Result | Artifact beneath `tests/map_editor/artifacts/` |
|---|---|---|
| Headless editor | **149 checks**, zero failures | `editor-dyov3768/` |
| X11 display-backed editor journey | **152 checks**, zero failures | `journey-_7e2u0jq/ui-4utp7ok2/` |
| Fresh-process reopen and rebake | **8 checks**, zero failures | Same journey directory, `reopen.*` |
| Shared native document suite, unmodified | **2,307 checks**, zero failures | `document-c30ep9a9/` |

Full stdout/stderr, exact process arguments and source/library hashes are retained
by the strict harness. Summaries: `/tmp/opencode/tbloader-ui-{editor,journey,document}.log`.
Screenshot (visually inspected):
`tests/map_editor/artifacts/journey-_7e2u0jq/ui-4utp7ok2/editor-smoke.png`.
`ui_journey_runner.py` retains the staged project, saved maps, point prefab and baked
scene, then launches a separate real editor process to reopen and rebake them.

Tests use real native documents and editor history, invoke actual graph handlers,
and dispatch Ctrl+Z through the viewport. They cover both grids' focus routing,
cursor zoom, negative/fractional and rigid off-grid gestures, AABB snapping, invalid
resize/component rejection, hide/pick-through/hidden-save-and-bake, materials both
inside and outside the texture root, classic UVs, split/prism, N entity operations,
dirty prompts/conflicts, originating and expired history, fly state/movement/exits,
two explicit loaders, scene switches/deletion, checked bake failures, packed bake
scene undo/redo, legacy Build Meshes, path scene undo, and disable/re-enable.
Display tests run the same handlers with actual rendering/capture on X11; they do
not claim window-system mouse-injection or complete Phase 6 manual UX acceptance.
No errors/warnings are allowlisted.

### Phase 5 acceptance — 2026-09-13

| Gate | Result | Artifact beneath `tests/map_editor/artifacts/` |
|---|---|---|
| Native debug extension, bounded `scons ... -j2` | Build passed | `/tmp/opencode/tbloader-phase5-build.log` |
| Native document runtime | **10,528 checks**, zero failures | `document-kiyvda6t/` |
| Headless real editor | **416 checks**, zero failures | `editor-vbiq_qi7/` |
| X11 display journey | **427 checks**, zero failures | `journey-87x_6yf_/ui-jfdgft2g/` |
| Fresh-process reopen/rebake | **8 checks**, zero failures | Same journey, `reopen.*` |
| ASan/UBSan/leak detection | PASS; 500 reset, 1,000 rebuild, 200 detached edit cycles plus parser corpus | `/tmp/opencode/tbloader-phase5-native.log` |

Commands are the three runner commands above (`--timeout 90`) plus
`timeout 900s scons platform=linux target=template_debug arch=x86_64 -j2` and
`timeout 180s bash tests/map_editor/run_native_tests.sh`. Concise logs:
`/tmp/opencode/tbloader-phase5-{build,document,editor,journey,native}.log`.
Instrumentation covers production parser/writer/model/geometry/edit staging;
the Godot wrapper is verified in the real runtime, not sanitizer-instrumented.

Acceptance covers successful single tetrahedron vertex, paired cube vertices,
single edge and multi-edge/face deformation; multi-brush atomic success/rejection;
duplicate/shared handles; stale IDs/tokens (including unrelated-edit undo preventing
stale selection revival); preserved Ctrl+LMB quick-face selection;
nonplanar, collapsed and inverted edits;
axis-constrained snapping; isolated material edits and exact surviving-face UVs;
2D clip/flip/split on all axes via graph/key handlers; half-space boundary cases,
coplanar/tangent/near-degenerate and multi-brush cuts; outward planes, planar
clockwise windings, closed convex hulls and analytic volumes; all **21** N=3…9 ×
axis prism combinations and canonical round-trips; selection undo/redo and hide.

Visually inspected intermediate display captures in
`journey-sdnxdtxp/ui-fl12csim/project/phase5-{faces,edges,vertices,split}.png`.
The final run retains the same four capture names under
`journey-87x_6yf_/ui-jfdgft2g/project/`, plus `editor-smoke.png` at the run root.
Tests render intermediate component states as well as invoking actual handlers.

The pinned 4.8 adapter creates an `EditorDock` for legacy main screens, then only
detaches it on disable. Plugin teardown explicitly frees that detached `_dock`
wrapper; it leaves an attached, editor-owned wrapper alone at editor shutdown.

Display validation also exposed recursive importer entry during immediate Save All
filesystem scans. Saves now debounce/coalesce scanning and wait until filesystem
scan/import is idle. The screenshot gate waits for import completion and forces
one rendered frame instead of waiting indefinitely for an idle redraw signal.

### Independent-review regression fixes — 2026-09-13

All six confirmed findings are fixed in the editor layer. No native rebuild was
needed; the strict harness records the existing library hash in each result.

| Finding | Fix and regression evidence |
|---|---|
| Scene save serializes before external-save bake | External-hook saves defer baking until after `EditorNode::_save_scene` clears its saved version. The deferred operation retains its originating session and explicitly marks the scene unsaved, including after a session switch. The test calls **`EditorInterface.save_scene_as`**, checks `get_unsaved_scenes`, saves again, then compares packed mesh vertices/normals/UVs/material paths without rebaking. A fresh process repeats the comparison **before** any rebake. |
| Discard prematurely excludes active edits | Retirement occurs only after a valid replacement is installed. Dirty → Open → Discard → picker cancel / invalid path → further edit → Save All verifies exact saved text and unsaved reporting. Successful replacement, picker resume and transaction reactivation are also checked. |
| Budget eviction destroys dirty background document | Strong registry ownership survives token retirement. A real global undo dirties a background session; the test drops incidental strong references and invokes actual total-budget enforcement, verifies all payloads expired, then saves exact retained content. Controlled per-session action and byte limits exercise those enforcement branches too; production defaults remain 128 actions / 64 MiB per session and 128 MiB total snapshots. |
| Plugin disable loses unresolved documents | Before teardown, unresolved enabled sessions are atomically checkpointed as plain text records at **`user://tbloader-map-recovery.json`**, with a plain-data editor-memory fallback on I/O failure. Enable restores dirty, detached Save As copies, preserving source-path hints but never automatically overwriting originals. Actual disable/re-enable tests cover named and untitled geometry, UVs, entities and edits; canonical-file preservation; released mouse capture; freed original controls/sessions/native documents; and fresh-process disk recovery. New/load/Save As baselines, undo-to-saved content, old-snapshot rejection and unknown-ID rejection are verified. |
| Resolver caches cross session roots | Effective loader/root/template/texture-property configuration synchronizes browser/root UI and invalidates preview material and size caches on session switch, Inspector changes and detach. Template changes invalidate materials. Browser selections must resolve through the actual native resolver to the selected resource, falling back to exact project tokens when relative tokens collide. A→B→A tests use different colors and 64×32 / 16×128 dimensions with the same shader name, compare camera/bake vertex-normal-UV samples and actual material resources, and check root disagreement and detach. |
| Window focus loss commits a preview | Both graph panes cancel application/window focus notifications and reject internal or unfocused releases before gesture completion. Tests start moved drags in both panes, inject release-before-notification ordering, and dispatch viewport input followed by native propagated window notifications; content, native revision and real history version stay unchanged. |

Pinned-engine ordering inspected: `editor/editor_node.cpp:2527–2581` (pack/write,
external save, then saved version); `scene/main/window.cpp:906–912` (clear window
focus before notification propagation); `scene/main/viewport.cpp:764–767,2767–2787`
(drop mouse focus and synthesize releases). The pin tags those releases as internal;
`Control::_call_gui_input` filters internal events from its GDScript virtual. Tests
also inject a delivered internal release before notification to cover that ordering
explicitly. Window focus state protects delivered ordinary releases before Control
focus is cleared. These are real editor/viewport plus injected notification tests,
not a claim of full OS mouse-device automation.

| Final gate | Result | Artifact beneath `tests/map_editor/artifacts/` |
|---|---|---|
| Headless real editor | **495 checks**, zero failures | `editor-nog38j4t/` |
| X11 `DISPLAY=:0` displayed journey | **506 checks**, zero failures | `journey-gqks0dzm/ui-wsdkqq1r/` |
| Fresh-process reopen and recovery | **11 checks**, zero failures | Same journey, `reopen.*` |

Commands are the editor and UI journey commands above with `--timeout 90`.
Concise logs: `/tmp/opencode/tbloader-review-{editor,journey}.log`; full import/runtime
stdout, stderr, commands and hashes are retained in the artifact directories.
Native source/binary identity verification: `/tmp/opencode/tbloader-review-native-identity.log`.
The final `editor-smoke.png` was visually inspected. Intermediate failed runs caught
an editor-adapter reparent lifecycle issue (disposal now occurs only on explicit
plugin shutdown), a headless picker positioning issue, and a compressed-image pixel
assertion issue; all are corrected in the final gates. No diagnostic allowlists.

Recovery deliberately begins a new native epoch and does not restore history,
selection IDs, hidden state or scene binding. Bare native IDs are document-local
and can numerically coincide across documents; only matching-epoch snapshots may
restore identity. The registry retains open documents for the plugin lifetime;
snapshot budgets do not cap the current document content. Recovery checkpoints
on orderly teardown, not continuously on every edit.

## Native/material integration

The checked native API landed in `83e844a`. The host uses `resolve_material(token)`
for both preview materials and texture dimensions, matching the native bake resolver.
The browser remains unchanged. Its root-relative mappings are reused; an otherwise
unresolved project resource can be assigned as an exact `res://...` token only when
native resolution succeeds. The status line shows the actual token; the document
writer quotes it canonically. Arbitrary ShaderMaterials receive a separate selected
brush wire outline; BaseMaterial previews also use vertex tint.

Save As never rewrites a loader path automatically. Use **Update loader path** to
commit that scene change. Bake on save defaults on but runs only for a clean,
successfully saved document with the same path and valid current-scene binding.
Map-button saves bake synchronously. An enclosing Godot scene save uses the external
hook, so its bake is deferred and leaves the scene **unsaved**; save the scene again
to serialize the new generated output.
Missing point/entity prefab resources return a visible bake failure while preserving
previous output. The journey supplies `fixtures/info_player_start.tscn` deliberately.

## Remaining acceptance / limitations

- Resize/component drag previews show the drag reference rather than rebuilding a
  live hull. Geometry is validated on release; arbitrary nonplanar mesh deformation
  is intentionally rejected. General three-point placement across graph panes is
  not implemented (the Phase 5 exit gate exercises the usable two-point 2D tool).
- Brush clipboard follows the native API (point-only clipboard unsupported).
- Patch primitives persist natively but have no graph/camera drawing or editing.
- Save All can save named maps synchronously; untitled maps need a Save As dialog.
  Godot's void `_save_external_data` hook cannot veto editor shutdown after an I/O
  failure or asynchronously finish an untitled Save As. The unsaved-status prompt
  explicitly asks users to Save As before exit. Full exit-failure UX remains open.
- Loader texture-root/template/property changes invalidate preview resolution.
  Baked-current status still compares canonical document content, not every external
  resource or loader option. Broader baked-output dependency tracking remains open.
- Blockout-scale full-document snapshots/rebuilds; no large-map performance claim.
- Release/other Godot versions/other platforms, full window-system input acceptance,
  and representative-map responsiveness/memory measurements remain Phase 6 work.
