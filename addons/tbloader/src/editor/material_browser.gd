@tool
extends Control
## Texture-root metadata index. Only explicit selection loads a resource; visible
## rows ask EditorResourcePreview for thumbnails. No dependency on TBMapDocument.

signal resource_selected(resource: Resource, path: String, suggested_token: String, mapping: Dictionary)
signal index_changed(count: int)
signal mapping_changed

# Keep this order in sync with Builder::load_and_cache_map_textures().
const TEXTURE_EXTENSIONS = ["png", "dds", "tga", "jpg", "jpeg", "bmp", "webp", "exr", "hdr"]
const SCAN_BUDGET = 256
const PREVIEW_LIMIT = 8

var _filesystem: Object
var _previewer: Object
var _texture_root := ""
var _direct_material_lookup := false
var _entries: Dictionary = {}
var _all_files: Dictionary = {}
var _folders: Dictionary = {}
var _staged_entries: Dictionary = {}
var _staged_files: Dictionary = {}
var _staged_folders: Dictionary = {}
var _scan_stack: Array = []
var _refresh_pending := false
var _refresh_delay := 0.0
var _preview_delay := 0.0
var _generation := 0
var _pending_previews: Dictionary = {}
var _requested_previews: Dictionary = {}
var _query := ""
var _folder := "res://"
var _selected_path := ""
var _visible_paths: Array[String] = []
var _folder_items: Dictionary = {}
var _updating := false
var _search: LineEdit
var _folder_tree: Tree
var _breadcrumbs: HBoxContainer
var _list: ItemList
var _status: Label


## editor_filesystem is normally EditorInterface.get_resource_filesystem().
## Optional previewer injection supports standalone hosts and isolated tests.
## Enable direct_material_lookup only when Builder supports exact .tres/.res paths.
func configure(editor_filesystem: Object, texture_root: String, previewer: Object = null,
		direct_material_lookup: bool = false) -> void:
	_disconnect_filesystem()
	_filesystem = editor_filesystem
	_previewer = previewer
	if _previewer == null and Engine.is_editor_hint():
		_previewer = EditorInterface.get_resource_previewer()
	_direct_material_lookup = direct_material_lookup
	set_texture_root(texture_root)
	_connect_filesystem()
	request_refresh()


func _enter_tree() -> void:
	_connect_filesystem()
	request_refresh()


func _ready() -> void:
	if _search == null:
		_build_ui()


func _exit_tree() -> void:
	_disconnect_filesystem()
	_generation += 1
	_pending_previews.clear()
	_requested_previews.clear()
	_scan_stack.clear()


func _connect_filesystem() -> void:
	if is_instance_valid(_filesystem) and not _filesystem.is_connected("filesystem_changed", request_refresh):
		_filesystem.connect("filesystem_changed", request_refresh)


func _disconnect_filesystem() -> void:
	if is_instance_valid(_filesystem) and _filesystem.is_connected("filesystem_changed", request_refresh):
		_filesystem.disconnect("filesystem_changed", request_refresh)


func set_texture_root(texture_root: String) -> void:
	var normalized := _normalize_folder(texture_root) if not texture_root.is_empty() else ""
	if normalized == _texture_root:
		return
	_texture_root = normalized
	_folder = _texture_root if _texture_root.begins_with("res://") else "res://"
	_selected_path = ""
	_update_status()
	request_refresh()


func request_refresh() -> void:
	_refresh_pending = true
	_refresh_delay = 0.15


## Explicit Refresh also asks the editor to discover changes on disk. Filesystem
## notifications use request_refresh instead, avoiding a scan/notification loop.
func rescan_project() -> void:
	if is_instance_valid(_filesystem) and not _filesystem.is_scanning():
		_filesystem.scan()
	request_refresh()


func is_refreshing() -> bool:
	return _refresh_pending or not _scan_stack.is_empty()


func set_search(query: String) -> void:
	_query = query.strip_edges().to_lower()
	if _search != null and _search.text != query:
		_search.text = query
	_rebuild_list()


## Folder filters include descendants. Search and folder filtering intersect.
func set_folder(path: String) -> bool:
	var normalized := _normalize_folder(path)
	if normalized != "res://" and not _folders.has(normalized):
		return false
	_folder = normalized
	if _folder_items.has(_folder):
		_updating = true
		_folder_items[_folder].select(0)
		_updating = false
	_rebuild_breadcrumbs()
	_rebuild_list()
	return true


func _normalize_folder(path: String) -> String:
	var normalized := path.simplify_path()
	return normalized if normalized == "res://" else normalized.trim_suffix("/")


func _inside_texture_root(path: String) -> bool:
	if not _texture_root.begins_with("res://"):
		return false
	return _texture_root == "res://" or path == _texture_root or path.begins_with(_texture_root + "/")


func focus_search() -> void:
	if _search != null:
		_search.grab_focus()
		_search.select_all()


func has_browser_focus() -> bool:
	var focused := get_viewport().gui_get_focus_owner()
	return focused == self or (focused != null and is_ancestor_of(focused))


func get_index_entries() -> Array:
	return _entries.values().duplicate(true)


func get_visible_paths() -> Array[String]:
	return _visible_paths.duplicate()


func get_selected_path() -> String:
	return _selected_path


## Updates the visual selection without loading or emitting resource_selected.
func highlight_path(path: String) -> void:
	_selected_path = path if _entries.has(path) else ""
	if _list != null:
		_list.deselect_all()
		var index := _visible_paths.find(_selected_path)
		if index >= 0:
			_list.select(index)
	_update_status()


## Mapping never guesses an absolute/project-wide shader for an unbound loader.
## An unresolved result may still carry a candidate token for display, NOT assignment.
func get_mapping(path: String) -> Dictionary:
	var result := {"path": path, "token": "", "resolved": false, "reason": "Resource is not indexed"}
	if not _entries.has(path):
		return result
	result["kind"] = _entries[path].kind
	if not _texture_root.begins_with("res://"):
		result.reason = "Bind a loader with a project texture root"
		return result
	var prefix := _texture_root if _texture_root.ends_with("/") else _texture_root + "/"
	if not path.begins_with(prefix):
		result.reason = "Resource is outside the bound texture root"
		return result
	var relative := path.trim_prefix(prefix)
	var material: bool = _entries[path].kind == "Material"
	result.token = relative if material else relative.get_basename()
	for character in [" ", "\t", "\n", "\r", "\"", "\\", "(", ")", "{", "}", "[", "]"]:
		if character in result.token:
			result.reason = "Resource path cannot be represented as a bare map shader token"
			return result
	if material:
		if not _direct_material_lookup:
			result.reason = "Builder requires direct native material lookup for extension-bearing tokens"
			return result
	else:
		if path.get_extension() not in TEXTURE_EXTENSIONS or not ClassDB.is_parent_class(_entries[path].type, "Texture2D"):
			result.reason = "Texture is indexed but its format/type is unsupported by Builder"
			return result
		var base := prefix + str(result.token)
		for extension in ["material", "tres"]:
			if _all_files.has(base + "." + extension):
				result.reason = "Builder material lookup shadows this texture: " + base + "." + extension
				return result
		for extension in TEXTURE_EXTENSIONS:
			var candidate: String = base + "." + extension
			if _all_files.has(candidate):
				if candidate != path:
					result.reason = "Builder texture extension precedence selects " + candidate
					return result
				break
	result.resolved = true
	result.reason = ""
	return result


## Metadata-only token -> resource path table for the camera/material resolver.
func get_shader_mappings() -> Dictionary:
	var mappings := {}
	for path in _entries:
		var mapping := get_mapping(path)
		if mapping.resolved:
			mappings[mapping.token] = path
	return mappings


## Explicit selection is the only synchronous ResourceLoader.load in this control.
## Emits even for unresolved resources; host must check mapping.resolved.
func select_path(path: String) -> bool:
	if not _entries.has(path) or not ResourceLoader.exists(path):
		return false
	var resource := ResourceLoader.load(path)
	if not (resource is Material or resource is Texture):
		if _status != null:
			_status.text = "Could not load material/texture: " + path
		return false
	_selected_path = path
	var index := _visible_paths.find(path)
	if index >= 0 and _list != null:
		_list.select(index)
	_update_status()
	var mapping := get_mapping(path)
	resource_selected.emit(resource, path, mapping.token, mapping)
	return true


func _process(delta: float) -> void:
	if _refresh_pending:
		_refresh_delay -= delta
		if _refresh_delay <= 0.0 and is_instance_valid(_filesystem) and not _filesystem.is_scanning():
			_begin_scan()
	if not _scan_stack.is_empty() and not _refresh_pending and is_instance_valid(_filesystem) and not _filesystem.is_scanning():
		_scan_step()
	_preview_delay -= delta
	if _preview_delay <= 0.0:
		_preview_delay = 0.15
		_request_visible_previews()


func _begin_scan() -> void:
	_refresh_pending = false
	_scan_stack.clear()
	_staged_entries = {}
	_staged_files = {}
	_staged_folders = {}
	var directory: Object = _filesystem.get_filesystem()
	if directory != null:
		_scan_stack.append({"directory": directory, "file": 0, "child": 0})
	else:
		_publish_index()


func _scan_step() -> void:
	var budget := SCAN_BUDGET
	while budget > 0 and not _scan_stack.is_empty():
		budget -= 1
		var frame: Dictionary = _scan_stack.back()
		var directory: Object = frame.directory
		var directory_path := _normalize_folder(directory.get_path())
		if _inside_texture_root(directory_path):
			_staged_folders[directory_path] = true
		if frame.file < directory.get_file_count():
			var index: int = frame.file
			frame.file += 1
			var path: String = directory.get_file_path(index)
			var type: String = directory.get_file_type(index)
			if not _inside_texture_root(path):
				continue
			_staged_files[path] = type
			var is_material := ClassDB.is_parent_class(type, "Material") and path.get_extension() in ["tres", "res", "material"]
			if is_material or ClassDB.is_parent_class(type, "Texture"):
				_staged_entries[path] = {"path": path, "name": path.get_file(), "type": type,
					"kind": "Material" if is_material else "Texture"}
		elif frame.child < directory.get_subdir_count():
			var child: Object = directory.get_subdir(frame.child)
			frame.child += 1
			_scan_stack.append({"directory": child, "file": 0, "child": 0})
		else:
			_scan_stack.pop_back()
	if _scan_stack.is_empty():
		_publish_index()


func _publish_index() -> void:
	_entries = _staged_entries
	_all_files = _staged_files
	_folders = _staged_folders
	_folders.erase("res:")
	_folders["res://"] = true
	if not _entries.has(_selected_path):
		_selected_path = ""
	while not _folders.has(_folder) and _folder != "res://":
		_folder = _folder.get_base_dir()
	_generation += 1
	_pending_previews.clear()
	_rebuild_folders()
	_rebuild_list()
	index_changed.emit(_entries.size())
	mapping_changed.emit()


func _build_ui() -> void:
	var layout := VBoxContainer.new()
	add_child(layout)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var header := HBoxContainer.new()
	layout.add_child(header)
	_search = LineEdit.new()
	_search.name = "MaterialSearch"
	_search.placeholder_text = "Search material name or res:// path"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(set_search)
	header.add_child(_search)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.pressed.connect(rescan_project)
	header.add_child(refresh)
	_breadcrumbs = HBoxContainer.new()
	var breadcrumb_scroll := ScrollContainer.new()
	breadcrumb_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(breadcrumb_scroll)
	breadcrumb_scroll.add_child(_breadcrumbs)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(split)
	_folder_tree = Tree.new()
	_folder_tree.name = "MaterialFolders"
	_folder_tree.custom_minimum_size.x = 110
	_folder_tree.item_selected.connect(_folder_selected)
	split.add_child(_folder_tree)
	_list = ItemList.new()
	_list.name = "MaterialList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.fixed_icon_size = Vector2i(96, 96)
	_list.fixed_column_width = 132
	_list.same_column_width = true
	_list.max_columns = 0
	_list.max_text_lines = 2
	_list.item_selected.connect(func(index: int): select_path(_visible_paths[index]))
	split.add_child(_list)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(_status)
	_search.text = _query
	_rebuild_folders()
	_rebuild_list()


func _rebuild_folders() -> void:
	if _folder_tree == null:
		return
	_updating = true
	_folder_tree.clear()
	_folder_items.clear()
	var root := _folder_tree.create_item()
	root.set_text(0, "res://")
	root.set_metadata(0, "res://")
	_folder_items["res://"] = root
	var paths := _folders.keys()
	paths.sort()
	for path: String in paths:
		if path == "res://":
			continue
		var parent: TreeItem = _folder_items.get(path.get_base_dir(), root)
		var item := _folder_tree.create_item(parent)
		item.set_text(0, path.get_file())
		item.set_metadata(0, path)
		item.collapsed = not (_folder == path or _folder.begins_with(path + "/"))
		_folder_items[path] = item
	var selected: TreeItem = _folder_items.get(_folder, root)
	selected.select(0)
	_updating = false
	_rebuild_breadcrumbs()


func _folder_selected() -> void:
	if not _updating and _folder_tree.get_selected() != null:
		set_folder(_folder_tree.get_selected().get_metadata(0))


func _rebuild_breadcrumbs() -> void:
	if _breadcrumbs == null:
		return
	for child in _breadcrumbs.get_children():
		_breadcrumbs.remove_child(child)
		child.queue_free()
	var paths: Array[String] = ["res://"]
	var current := "res://"
	for part in _folder.trim_prefix("res://").split("/", false):
		current = current.path_join(part)
		paths.append(current)
	for path in paths:
		var button := Button.new()
		button.text = "res://" if path == "res://" else path.get_file()
		button.tooltip_text = path
		button.flat = true
		button.pressed.connect(set_folder.bind(path))
		_breadcrumbs.add_child(button)


func _rebuild_list() -> void:
	_visible_paths.clear()
	for path: String in _entries:
		if _folder != "res://" and not path.begins_with(_folder + "/"):
			continue
		if not _query.is_empty() and not _query in path.to_lower():
			continue
		_visible_paths.append(path)
	_visible_paths.sort_custom(func(a: String, b: String): return a.naturalnocasecmp_to(b) < 0)
	_requested_previews.clear()
	if _list != null:
		_list.clear()
		for path in _visible_paths:
			var index := _list.add_item("%s\n[%s]" % [path.get_file(), _entries[path].kind])
			_list.set_item_tooltip(index, path)
			if path == _selected_path:
				_list.select(index)
	_update_status()


func _update_status() -> void:
	if _status == null:
		return
	_status.text = "%d / %d resources" % [_visible_paths.size(), _entries.size()]
	if not _selected_path.is_empty():
		var mapping := get_mapping(_selected_path)
		_status.text += "\n" + _selected_path + "\nMap token: " + str(mapping.token)
		if not mapping.resolved:
			_status.text += " — Unresolved: " + str(mapping.reason)
	_status.tooltip_text = _status.text


func _request_visible_previews() -> void:
	if _list == null or not is_visible_in_tree() or not is_instance_valid(_previewer):
		return
	var viewport_rect := Rect2(Vector2(0, _list.get_v_scroll_bar().value), _list.size)
	# Binary search avoids walking the whole project on every preview tick.
	var low := 0
	var high := _list.item_count
	while low < high:
		var middle := (low + high) / 2
		if _list.get_item_rect(middle).end.y < viewport_rect.position.y:
			low = middle + 1
		else:
			high = middle
	for index in range(low, _list.item_count):
		var rect := _list.get_item_rect(index)
		if rect.position.y > viewport_rect.end.y or _pending_previews.size() >= PREVIEW_LIMIT:
			break
		var path := _visible_paths[index]
		if rect.has_area() and rect.intersects(viewport_rect) and not _requested_previews.has(path) and not _pending_previews.has(path):
			_pending_previews[path] = _generation
			_requested_previews[path] = true
			_previewer.queue_resource_preview(path, self, "_preview_ready", _generation)


func _preview_ready(path: String, preview: Texture2D, small_preview: Texture2D, generation: Variant) -> void:
	if generation != _generation:
		return
	_pending_previews.erase(path)
	var index := _visible_paths.find(path)
	if index >= 0 and _list != null:
		_list.set_item_icon(index, preview if preview != null else small_preview)
