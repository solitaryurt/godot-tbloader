# Map editor implementation contract and progress

Phases 0–1, 2026-09-13. Specification: [MAP_EDITOR_PRD.md](MAP_EDITOR_PRD.md), especially
§§6–8 and 14–16. **API v1 is frozen; the Phase 1 subset is implemented below.**
Brush operations and draw/preview payloads remain Phase 2. Changes require updating
this document and its consumers together.

## Phase 0 gate / environment

- [x] Existing extension built before feature changes; bounded `-j2`.
- [x] Real extension loaded and cube baked in pinned headless runtime.
- [x] Real editor addon lifecycle and editor-manager history smoke passed.
- [x] Assertion failure, error-with-exit-zero, missing marker and timeout rejected.
- [x] Disposable first-party project, maps, input hashes and retained failure logs.
- [x] Document/editor ownership, API, identity, snapshots and preview contracts.
- [x] Display feasibility established using existing X11 display `:0`.
- [x] Phase 1: transactional document, semantic persistence, identity and ownership gate.
- [ ] Phases 2–6: brush operations, authoring UI, integration and full acceptance.

Supported **tested baseline**: Linux x86_64, Godot
`4.8.dev.custom_build.3924ec46f`, executable
`/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64`; Python 3.14.4, SCons 4.4.0.
Vendored binding API is 4.2.2; manifest's historical 4.1 minimum is not a tested
compatibility claim. Older engines and other platforms remain unverified. The
map editor targets this pinned engine first; do not infer 4.1 support for new APIs.

### Reproducible evidence

Commands run from repo root (`GODOT_BIN` is the absolute executable above):

| Command | Result |
|---|---|
| `timeout 180s scons platform=linux target=template_debug arch=x86_64 -j2` | Initial binding compilation hit timeout (124), no compiler error |
| `timeout 600s scons platform=linux target=template_debug arch=x86_64 -j2` | Resumed original baseline build, exit 0 |
| `timeout 120s scons platform=linux target=template_debug arch=x86_64 -j2` | Target-qualified debug library linked, exit 0 |
| `timeout 900s scons platform=linux target=template_debug arch=x86_64 -j2` | Resumption verification: debug library up to date, exit 0; `/tmp/opencode/tbloader-phase0-build.log` |
| `python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite document` | PASS, 86 checks, exit 0 |
| `python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite editor` | PASS, 19 checks, exit 0 |
| `python -m unittest discover -s tests/map_editor -p test_harness.py -v` | PASS, four real-engine negative probes, each runner exit 1 |
| `DISPLAY=:0 python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite ui` | PASS, 22 checks, exit 0; rendered editor PNG |

Logs/screenshots are local ignored `tests/map_editor/artifacts/` outputs; each
`result.json` identifies input/library hashes, and step JSON records exact process
arguments, status and timing. UI smoke establishes rendering feasibility only.
Initial successful runs: `document-lfkf0kjz`, `editor-t_xhpt21`, `ui-t8c7omnm`;
the UI capture was subsequently delayed to avoid the startup progress overlay.
Negative probes: `negative-{assertion,engine-error,missing-marker,timeout}-*`.

Resumption reran all four gates successfully: `document-arctq__3` (86 checks),
`editor-sl_egs73` (19), `ui-nr3aoz3m` (22; screenshot visually inspected), and all
four negative probes (unittest exit 0; every probe runner exit 1). Negative summary:
`/tmp/opencode/tbloader-phase0-negative.log`. Commands above used the pinned engine
via explicit `--godot`, and `GODOT_BIN` for unittest. The runner now prefers X11
when `DISPLAY` is set, making the documented UI command deterministic even when
`WAYLAND_DISPLAY` is also inherited.

### Baseline findings and boundaries

- Existing untracked `src/smooth_mesh_instance_3d.{cpp,h}` are independent smoothing
  work. The source glob includes the `.cpp`, which compiled successfully but is
  not registered in `src/main.cpp`. No exclusion/workaround or edits were needed.
  `.idea/` and separate `PRD.md` are unrelated; none are included in this commit.
- Linux library names now include `template_debug`/`template_release`, selected
  by manifest debug/release feature tags. Only debug was built/tested. Old binaries
  remain untouched; the harness copies only the debug artifact.
- Fresh `--headless --editor --import` exited -6 after scan/layout, with no stderr;
  GDB caught SIGSEGV during teardown (stripped engine, unresolved frames). Existing
  imported projects exited normally. Waiting for scan plus settled editor startup
  before explicit quit avoids this observed failure; runner still rejects crashes.
- Missing checker originally printed a native diagnostic even though geometry
  checks passed. Supplying a real generated/imported PNG resolved it. Stderr is
  deliberately strict, including warnings; no errors are allowlisted.
- PATH lacks Godot/Xvfb/xdotool, but live X11 and Wayland sockets exist. X11 `:0`
  with compatibility rendering works without system modifications. Wayland
  `wayland-1` reached NVIDIA RTX 3090 OpenGL then emitted GLES3 allocation/shader
  errors and crashed (see `ui-vx00cpkh`). Use X11 for future display acceptance.
- No memory-checker run or performance claim yet. Current bake has no structured
  success result and clears children before parse. Empty-worldspawn bake may
  dereference a null generated container (`Builder::build_entity`); do not use
  current bake as the validation API. Fix/verify at the appropriate later gate.
- This session had no subagent tool; implementation/integration review performed
  directly. Independent delegated review remains for the next integration point.

## Native ownership and identity

`TBMapDocument : RefCounted`, registered at SCENE initialization, owns one editable
map and all entity/brush/face/patch allocations. No pointers or mutable native
arrays escape. Ordered epairs and source primitive ownership/order are preserved.
All coordinates are map space. Preview/bake alone convert `(x,y,z)` to `(y,z,x)/s`
with positive inverse scale `s` (default 38). Geometry is disposable derived data.

Parse/mutation/restore operate on candidates; validate, build geometry, then swap
atomically. Failures preserve content, path, baseline, IDs, revisions and caches.
Free old caches before changing topology counts, or track independent allocation
counts. Cleanup is null-safe/idempotent and covers partial parse; no shallow copies.

IDs are positive signed-64-bit document-local handles (`0` invalid), monotonic,
never array offsets or reused during a document lifetime. Use `PackedInt64Array`
for batches. Entities, brushes and patches have IDs; duplicate/paste/split allocate
fresh primitive IDs. Deletion cannot retarget survivors. New/load/import replaces
the identity namespace; successful replacement changes an opaque document epoch.
Undo snapshots are valid only for their originating epoch. Allocation high-water
marks never move backward on undo, preventing abandoned redo IDs being reused.

Component handle: `{brush_id:int, topology_revision:int, kind:StringName,
index:int}`. Face/edge/vertex indices refer to current draw data. Topology revisions
are monotonic cache tokens; topology change/restore regenerates them. Clear stale
components unless an explicit, validated remap exists. Brush IDs survive restore.

## API v1 (supersedes tentative PRD §7 return signatures)

Every fallible command returns a **Dictionary Result**, avoiding bool/void/sentinel
ambiguity. All schema keys below are mandatory; copied return data is caller-owned.

```text
Result = {ok:bool, changed:bool, value:Variant, error:Dictionary}
success: error={}, value as below (null when no value)
failure: ok=false, changed=false, value=null,
  error={code:StringName, message:String, operation:StringName,
         path:String, line:int, column:int, entity_id:int, brush_id:int, face:int}
```

Error codes: `IO_NOT_FOUND`, `IO_READ`, `IO_WRITE`, `EXTERNAL_CHANGE`, `PARSE_ERROR`,
`UNSUPPORTED_SYNTAX`, `INVALID_ARGUMENT`, `INVALID_ID`, `STALE_COMPONENT`,
`INVALID_GEOMETRY`, `UNSUPPORTED_PROJECTION`, `SNAPSHOT_MISMATCH`, `LIMIT_EXCEEDED`.
Locations are 1-based, 0 if unknown; absent IDs are 0, absent face is -1. Expected
user input errors return diagnostics rather than `push_error`/assert/crash.

| Methods (argument names/types from PRD §7 unless specified) | Result.value |
|---|---|
| `new_map()`, `load_map(path)`, `import_text(text)` | null; replace on success |
| `save_map(path)` | null; temporary-file/atomic replacement, external-change check |
| `rebuild()` | null; cache only, does not dirty content |
| `export_text()` | String; deterministic semantic `.map` text |
| `snapshot()` / `restore_snapshot(snapshot:Dictionary)` | snapshot Dictionary / null |
| `export_selection(ids:PackedInt64Array)` | String; selected brushes and owning entity epairs |
| `import_selection(text:String)` | PackedInt64Array of fresh brush IDs, pasted in place |
| `create_cuboid(mins,maxs,texture)` | int new brush ID (worldspawn by default) |
| `duplicate_brushes(ids)`, `clip_brushes(ids,p0,p1,p2,split)` | PackedInt64Array; new clones / all surviving result brushes |
| `delete_brushes(ids)`, `translate_brushes(ids,delta)`, `make_prism(id,sides,axis)` | null |
| `translate_face(id,face,delta,topology_revision:int)` | null |
| `translate_vertices(id,vertex_indices,delta,topology_revision:int)` | null |
| `set_brush_texture(ids,name)` | null |
| `set_face_texture(id,face,name,topology_revision:int)` | null |
| `get_face_uv(id,face,topology_revision:int)` | UV Dictionary |
| `set_face_uv(id,face,shift,rotation,scale,topology_revision:int)` | null; reject Valve edits |
| `set_texture_sizes(sizes:Dictionary)` | null; texture-name -> positive Vector2i; cache only |

Infallible copied queries: `is_dirty()->bool`, `get_path()->String`,
`get_revision()->int`, `get_epoch()->int`, `get_draw_data()->Array[Dictionary]`,
`get_preview_data()->Array[Dictionary]`, `get_texture_names()->PackedStringArray`.
Phase 1 adds `get_entities()->Array[Dictionary]`; concrete ordered ownership/epair
schema is specified in the Phase 1 handoff below.
`get_face_uv` value includes `projection` (`classic`/`valve`), `shift:Vector2`,
`rotation:float`, `scale:Vector2`, `u_axis:Vector3`, `v_axis:Vector3`; Valve retains
axes and offsets exactly. Scale zero/nonfinite arguments are rejected.

Batch IDs deduplicate preserving first occurrence; any invalid ID rejects the
whole batch. Empty batches and unchanged content succeed with `changed=false`;
failed/no-op commands emit no content signal or history entry. Selection import
rejects unsupported selected primitives; worldspawn brushes merge into worldspawn,
other owning entities are copied with ordered epairs and fresh entity IDs.
Plain `import_text` is a whole-document replacement, never an undo mechanism.

`map_changed(revision:int)` fires once per content/identity commit (including
restore), after caches are consistent; revisions monotonically increase even on
undo. `preview_changed()` covers texture-size/cache-only changes; `dirty_changed`
fires only when dirty toggles. `changed` describes actual document/cache change,
not file bytes written. Saving does not create geometry history.

## Snapshots, save baseline and editor state

Native snapshot value: `{schema:1, epoch:int, text:String, identities:Dictionary}`.
Identities describe ordered entity IDs and each entity's ordered brush/patch IDs,
not pointers; text/identity shape mismatch rejects restore atomically. Snapshot
does **not** include path, saved baseline, revision counter or geometry caches.
Restore preserves path and the most recent successful save baseline. Dirty compares
canonical semantic content to that baseline, not monotonically increasing revision.
New is an untitled worldspawn and needs saving; load is clean; import is untitled
and unsaved. Failed Save As never changes path/baseline or an existing file.

Editor snapshot envelope: `{native:Dictionary, selected_brush_ids:PackedInt64Array,
components:Array, workzone:AABB}`. A restore validates/prunes selection, updates
topology tokens, clears unsupported component remaps, and restores workzone.
Hidden brush IDs are independent document-session state: no `.map`, dirty or
geometry history change. Retain surviving hidden IDs across undo/rebuild; exclude
hidden brushes from selection, editing and all preview/picking, but save/bake all.

## Draw and preview payloads

Draw data is PRD §7's brush dictionary plus `entity_id:int` and
`topology_revision:int`. `vertices` are unique winding points, `edges` are endpoint
pairs; `faces` retain index/winding/center/normal/texture. Add
`edge_vertex_indices:PackedInt32Array` (index pairs into vertices) and each face's
`vertex_indices:PackedInt32Array` so component handles are unambiguous.

Preview data groups triangles by exact texture name:

```text
{texture:String, texture_size:Vector2i,
 vertices:PackedVector3Array, normals:PackedVector3Array, uvs:PackedVector2Array,
 indices:PackedInt32Array, triangle_brush_ids:PackedInt64Array,
 triangle_face_indices:PackedInt32Array}
```

Positions/normals remain map-space, indexed triangles have Godot clockwise winding
after axis permutation, normals point outward, UVs are normalized using existing
classic/Valve geo functions. Every triangle has owning brush/face IDs; vertices
may be duplicated at UV/normal seams. Texture dimensions are resolved before geo
generation with the bake-compatible 1x1 nonzero fallback. Texture-size changes
invalidate preview without dirtying map content. Patches must persist; v1 may omit
patch drawing (explicit capability, not silent loss on save). Preview contains all
brushes; the UI filters by triangle IDs using its hidden set.

## Editor binding and history routing

- A plugin-owned RefCounted session owns the native document, selection, workzone,
  hidden IDs and explicit weak loader binding. Spatial selection only updates the
  existing toolbar. Opening/binding requires an explicit loader choice and dirty
  resolution; selection changes never replace a document. Loader deletion/scene
  close detaches binding and preserves the session.
- **Map document edits use EditorUndoRedoManager GLOBAL_HISTORY for both bound
  and standalone sessions**, with the originating session as `custom_context`.
  `.map` content is external to the scene; a RefCounted naturally routes globally,
  as the smoke test verifies. Do not invent numeric per-document editor histories
  or infer context from the currently selected loader. Shared global ordering is
  intentional; every callback targets its originating session/epoch, never the
  active document. Background session restores update that session's dirty state.
- Only loader path changes and bake-scene changes use scene history with explicit
  scene-root context. Validate the target scene is current before committing; a
  scene switch cancels a pending scene operation. Content saved, content baked and
  live document revisions are tracked separately. Automatic bake remains disabled
  until Phase 4 provides validation, result reporting and scene dirty integration.
- Gestures work against a before snapshot; motion is preview. Valid completion
  records before/after once with MERGE_DISABLE and `commit_action(false)` if already
  applied. Cancel restores before; invalid/no-op gestures add nothing. No double
  execution. One Map-view shortcut router consumes Ctrl+Z/Y and invokes the intended
  global history exactly once; text fields/dialogs retain their own undo. Outside
  Map focus use Godot's normal routing. Verify actual shortcut dispatch in Phase 3.
- History callbacks reference lightweight session action tokens. Keep originating
  sessions/snapshots while their history is usable, even after opening another map;
  changing a session's epoch retires its old tokens. Budget: 64 MiB snapshot bytes
  and 128 actions per session, 128 MiB total plugin retained history. Evict oldest
  map tokens at the limit, release payloads, and report an explicit expired-history
  status if such a token is invoked. Never redirect to a newer document and never
  clear shared global/scene history just to dispose Map entries. Teardown retires
  tokens, cancels gestures, disconnects signals and releases preview/document data.
  Phase 3 must test replacement, scene switches, retired tokens and focus routing.

## Phase 1 implementation / handoff

Implemented at SCENE initialization: `TBMapDocument : RefCounted` in
`src/map_document.{h,cpp}`. Construction creates an unsaved worldspawn.

### Actual bound surface

- Result commands: `new_map`, `load_map`, `import_text`, `save_map`, `export_text`,
  `snapshot`, `restore_snapshot`, `rebuild`.
- Copied queries: `is_dirty`, `get_path`, `get_revision`, `get_epoch`,
  `get_texture_names`, plus **`get_entities()->Array[Dictionary]`**.
- Signals: `map_changed(revision:int)`, `dirty_changed(dirty:bool)`,
  `preview_changed()`; failure/no-op restore emits nothing. Rebuild replaces caches,
  refreshes topology tokens and emits preview only. Save reports path/baseline
  changes without changing content revision or emitting a map-history signal.
- No brush-mutation, selection-clipboard, face-UV, draw or preview methods are bound
  yet. They are Phase 2 work, rather than placeholder implementations.

Snapshot identity schema is now concrete:

```text
identities = {entities: [{id:int, primitives: [{kind:StringName, id:int}, ...]}, ...]}
kind = "brush" | "patch"; primitive arrays follow source order.
get_entities() returns that entities array with epairs:[{key:String,value:String}]
on each entity, including duplicate keys and empty/unknown properties.
```

Entity/brush/patch IDs share one positive, monotonic lifetime allocator. Issued-ID
kind checks reject forged, duplicate, cross-kind and foreign-epoch snapshot handles.
Epochs are process-unique across document objects; replacement clears the issued
namespace but never resets the lifetime high-water mark. Restore keeps the latest
save baseline/path and compares normalized semantic text to determine dirty state.
It validates all metadata on a candidate before swapping. Snapshot dictionaries and
queries are freshly allocated; caller changes cannot mutate the live document.

### Parser, writer and ownership

- Replaced the old token-state parser with bounded recursive descent, shared by
  document and bake. `LMMapParser::load_from_text`, `load_from_path` and
  `load_from_godot_file` return bool and expose `LMParseError`. Parsing never clears
  its destination until the full candidate succeeds. Expected errors return
  diagnostics; document operations do not print engine errors.
- Handles whitespace-independent punctuation, line/block comments, long quoted or
  bare tokens, escaped quote/backslash, UTF-8/BOM, and EOF without a final newline.
  Invalid UTF-8, embedded NUL, nonfinite/malformed numbers, zero scales, incomplete
  flags/grids, unknown primitive blocks and incomplete entities are rejected.
  Diagnostic columns count UTF-8 bytes, starting at 1; geometry diagnostics without
  a source token use 0. Unknown escape sequences retain their literal backslash.
- Preserves classic/Valve projection, absent versus explicit-zero flags, all signed
  32-bit flag values, ordered epairs, owner entities, and interleaved brush/patch
  order. Patch model now retains def2/def3, all three trailing header fields,
  subdivisions and every position/UV. Writer is locale-independent, uses 17-digit
  double precision and quotes/escapes names deterministically.
- Explicit bounds: input and canonical output 16 MiB; decoded token 64 KiB; 65,536
  entities; 64 faces/brush; odd patch dimensions 3..31; subdivisions 0..32;
  numeric magnitude <=1e9 (flags instead use signed int32); absolute texture scale
  >=1e-9. Aggregate work estimate <=8,000,000 (`faces³` per brush plus
  `width*height*33²` per patch). Unsupported excess returns `LIMIT_EXCEEDED`.
- Document candidates build geometry with 1x1 texture fallback and validate finite
  brush positions/UVs, nonempty faces, paired hull edges and positive volume.
  Patches are preserved and tessellated for native cache/bake; patch display is not
  exposed in this phase. No performance/scaling claim is made.
- `LMMapData` is noncopyable and destroys its own allocations; `swap` transfers
  ownership. Null-safe, repeatable `map_data_free_geometry` uses cache-owned
  entity/brush/face/patch counts, independent of mutable source topology. `run()`
  frees prior geometry. Bake's empty-worldspawn null dereference and detached empty
  mesh leak were fixed and covered by the runtime gate.

### Persistence platform boundary

POSIX saving uses an exclusive sibling `mkstemp`, complete checked writes, `fsync`,
checked close, a second destination-byte check, and atomic `rename`; failures unlink
the temporary file and preserve path/baseline/content. Existing permission bits are
retained. External changes/removal compare exact loaded/saved bytes, including
formatting-only edits. Path aliases resolve to their target; saving through symlinks
preserves the link. A failed Save As cannot change the document path.

The tested platform is Linux. Windows currently returns a structured `IO_WRITE`
for save (atomic replacement backend still needed); macOS POSIX code is untested.
External-change checks detect changes before and during a save; there is no
cross-process compare-and-swap filesystem primitive or cooperative editor locking.
This is atomic replacement, not a claim of crash-durable parent-directory metadata.

### Entity-authoring extension point (Phase 4)

The N inspector must consume ordered epairs and stable entity IDs from
`get_entities`, including owners of selected primitives; no selection targets
worldspawn. Point origin/classname are ordinary preserved epairs. Future
create/move/property-edit/reparent/delete commands must use candidates and the same
Result/snapshot/dirty/ID pipeline; do not use array offsets as identities or mutate
the copied query dictionaries expecting native changes. Preserve unknown/duplicate
properties deliberately when designing mixed-value editing. Ownership changes must
update both entity arrays and `LMEntity::primitives` source-order entries. Entity
markers, editable epairs/ownership, N routing and associated undo remain Phase 4.

### Verification and next gate

- Real pinned-engine document suite: semantic preservation, lifecycle, malformed
  rejection, copied ownership data, epoch/identity snapshots, dirty undo/redo,
  failed saves/rename cleanup/external changes, plus real cube and empty-map bake.
  Canonical saved classic/Valve/ownership fixtures each bake 12 triangles; saved
  def2/def3 patches bake 80 triangles, including the preserved 4x6 subdivisions.
- `bash tests/map_editor/run_native_tests.sh`: standalone production parser/writer/
  model/geometry sources with Clang ASan+UBSan+LSan, no suppressions. Field-by-field
  semantic comparison, every fixture truncation prefix, deterministic byte mutation
  corpus, 500 load/reset cycles and 1,000 rebuilds pass. Tests explicitly dispose
  caches while source entity counts differ, then double-free/reset safely.
  Instrumentation covers native map ownership; the engine and RefCounted wrapper
  are exercised by the real runtime but are not sanitizer-instrumented here.
- Build and suite logs: `/tmp/opencode/tbloader-phase1-{build,document,editor,ui,native,negative}.log`.
  The sanitizer binary is `/tmp/opencode/tbloader-native-document` and the checked-in
  script records its full compiler invocation. No instrumented addon is substituted
  into the normal extension build.
- Independent subagent review could not run: this harness exposes no delegation
  tool. Integration review was performed directly; coordinator review remains useful.

Final recorded evidence (commands run from repository root):

| Gate | Result / retained artifacts |
|---|---|
| `timeout 600s scons platform=linux target=template_debug arch=x86_64 -j2` | PASS, exit 0; final source-built debug library |
| `python tests/map_editor/run_tests.py --godot "$GODOT_BIN" --suite document` | PASS, **609 checks**, `tests/map_editor/artifacts/document-wy5ehnpl/` |
| Same runner, `--suite editor` | PASS, **19 checks**, `artifacts/editor-86p_87l0/` |
| `DISPLAY=:0` with same runner, `--suite ui` | PASS, **22 checks**, `artifacts/ui-x62ljq1k/`; baseline display smoke only |
| `GODOT_BIN=... python -m unittest discover -s tests/map_editor -p test_harness.py -v` | PASS, one unittest covering four real-engine negative probes; each probe runner correctly failed |
| `timeout 180s bash tests/map_editor/run_native_tests.sh` | PASS, ASan+UBSan+LSan, no suppressions or reported defects/leaks |

`GODOT_BIN` remains `/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64`.
Runtime artifacts retain exact commands and input/library SHA-256 hashes. The first
extended run detected empty-bake RID/ObjectDB leaks despite 552 successful checks;
the strict runner rejected it, and the detached-mesh fix resolved it. No diagnostic
was allowlisted. Release, Windows and macOS builds were not exercised.

Next gate: Phase 2 validated brush operations and map-space draw/preview payloads.
Start with `src/map_document.{h,cpp}`, `src/map/{map_data,map_parser,map_writer}.*`,
`src/map/{entity,brush,patch,entity_geometry}.h`, and
`tests/map_editor/{document_suite.gd,native_document_test.cpp}`. Keep issued IDs
across deletion/restore and advance allocation high-water marks on every new
primitive; keep cache-only changes out of geometry history. Full Phase 6 interaction
and representative-map performance measurements remain incomplete.
