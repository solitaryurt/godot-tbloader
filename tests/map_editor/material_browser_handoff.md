# Standalone material browser handoff

`addons/tbloader/src/editor/material_browser.gd` is a reusable `@tool Control`
hosted by the contextual Map Materials bottom panel. Instantiate with
`preload(...).new()` and give it expanding size flags in the host layout.

```gdscript
browser.configure(EditorInterface.get_resource_filesystem(), loader.texture_path)
browser.resource_selected.connect(_on_browser_resource_selected)

func _on_browser_resource_selected(resource: Resource, path: String,
        suggested_token: String, mapping: Dictionary) -> void:
    if not mapping.resolved:
        return # Display mapping.reason; leave the document shader unchanged.
    # Host updates its current texture / surface field. Any assignment to the
    # document belongs to the host's undo transaction, not the browser.
```

## Public contract

- `configure(filesystem: Object, texture_root: String, previewer: Object = null,
  direct_material_lookup: bool = false)`: accepts real `EditorFileSystem` and
  optional `EditorResourcePreview`; automatically uses the editor previewer in
  editor mode. Reconfiguration disconnects the previous filesystem.
- `set_texture_root(path)`: update/detach loader binding without reindexing;
  empty root means unresolved. `res://` is a supported root.
- `request_refresh()`: coalesced, metadata-only reindex; filesystem notifications
  use this. `rescan_project()`/Refresh also asks EditorFileSystem to scan disk.
- `set_search(query)`: case-insensitive filename/full-path substring search.
  `set_folder(path) -> bool`: folder plus descendants, intersected with search.
  Tree selection and clickable breadcrumbs use the same filter.
- `get_index_entries()`, `get_visible_paths()`, `get_selected_path()`,
  `is_refreshing()`: independent snapshot/query helpers.
- `get_mapping(path) -> Dictionary`: `path`, `token`, `resolved`, `reason`, and
  `kind` when indexed. An unresolved candidate token is **not assignable**.
- `get_shader_mappings() -> Dictionary`: resolved token → project resource path,
  metadata only; host owns shader-to-preview material conversion/caching.
- `select_path(path) -> bool`: loads only this resource and emits
  `resource_selected(resource, path, suggested_token, mapping)`, including when
  mapping is unresolved. Refresh/filter/root changes do not emit assignment.
- `index_changed(count)`, `mapping_changed`: invalidate host resolver metadata.
- `focus_search()`, `has_browser_focus()`: host graph shortcut handlers should
  return when browser owns focus. Browser uses normal GUI focus/input and no
  global shortcut interception.

## Builder mapping gate

At implementation time `Builder::material_path` (`src/builder.cpp`) tries
`texture_root/token.material`, then `texture_root/token.tres`. It does **not**
try an exact extension-bearing `.tres`/`.res` path. Native Material suggestions
retain their extension, but default to unresolved with that reason. Pass
`direct_material_lookup = true` only once native lookup supports those exact
paths. This flag describes a native capability; it does not change native code.

Texture tokens drop their extension. Mapping follows Builder's ordered formats
`png, dds, tga, jpg, jpeg, bmp, webp, exr, hdr`, rejecting another extension's
precedence and legacy material-file shadowing. Other Godot textures remain
searchable with an explicit unsupported mapping. Resources outside the bound
root and paths unsuitable for bare `.map` tokens are explicitly unresolved.

## Verification

```bash
python tests/map_editor/material_browser_runner.py \
  --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64
```

Independent runner stages only these browser scripts and generated fixtures in
`/tmp/opencode/material-browser-*`, with complete logs and 90-second process
timeouts. No native library or shared test project changes/builds are needed.
Runtime `SceneTree` suite uses filesystem/preview doubles for deterministic
coalescing, 1,510-entry indexing, mapping, search/tree/breadcrumb/focus, selection,
lazy scrolling, stale callbacks, refresh and teardown checks. It loads actual
Material fixtures on selection. A deliberate failure verifies nonzero exit.
The editor-plugin probe separately exercises real EditorFileSystem import,
standalone/binary Material discovery, and live add/remove refresh. Output must
contain exactly one completion marker and no engine/script error diagnostics.

Limits: headless tests establish behavior, not visual thumbnail quality or full
bottom-panel presentation. Indexing is budgeted at 256 metadata operations/frame;
filter/list rebuilding is linear in project resource count. At most eight
thumbnail requests are pending per index generation, for visible rows only;
the editor owns thumbnail generation/caching. Standalone non-editor hosts must
provide a previewer for thumbnails. Preview material conversion, texture-size
lookup, document assignment/undo and native bake parity belong to the host.
