@tool
extends VBoxContainer

class PaneHeader extends Control:
	var title: String

	func _init(value: String) -> void:
		title = value
		custom_minimum_size.y = 36.0
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.1, 0.14, 0.95))
		draw_string(ThemeDB.fallback_font, Vector2(38, 23), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("b9cfdf"))

var session: RefCounted
var selected_layer_id: int = -1
var search_field: LineEdit
var layer_tree: Tree
var status_label: Label
var new_button: Button
var rename_button: Button
var select_button: Button
var add_button: Button
var remove_button: Button
var show_only_button: Button
var show_all_button: Button
var delete_button: Button
var context_menu: PopupMenu
var new_dialog: ConfirmationDialog
var new_name_field: LineEdit
var delete_dialog: ConfirmationDialog
var rename_dialog: ConfirmationDialog
var rename_field: LineEdit
var _refreshing := false
var _pending_focus_id := -1

func _ready() -> void:
	if layer_tree == null:
		_build_ui()
	refresh()

func set_session(value: RefCounted) -> void:
	if session != null and session.changed.is_connected(_session_changed):
		session.changed.disconnect(_session_changed)
	session = value
	if session != null and not session.changed.is_connected(_session_changed):
		session.changed.connect(_session_changed)
	refresh()

func clear() -> void:
	set_session(null)

func _session_changed() -> void:
	if session != null and session.change_kind == "brush_translation":
		return
	refresh()

func refresh() -> void:
	if layer_tree == null:
		return
	_refreshing = true
	var keep_id := selected_layer_id if _pending_focus_id < 0 else _pending_focus_id
	_pending_focus_id = -1
	layer_tree.clear()
	var root := layer_tree.create_item()
	var layers: Array = session.layers() if session != null else []
	var query := ""
	if session != null:
		query = String(session.layer_search)
		if search_field != null and search_field.text != query:
			search_field.text = query
	var query_folded := query.to_lower()
	var selected_item: TreeItem = null
	var first_visible: TreeItem = null
	var next_after_missing: TreeItem = null
	var seen_keep := false
	for layer in layers:
		var display: String = session.layer_display_name(layer)
		if not query_folded.is_empty() and not display.to_lower().contains(query_folded):
			continue
		var item := layer_tree.create_item(root)
		_configure_row(item, layer, display)
		if first_visible == null:
			first_visible = item
		if int(layer.id) == keep_id:
			selected_item = item
			seen_keep = true
		elif not seen_keep:
			next_after_missing = item
	if selected_item == null:
		selected_item = next_after_missing if next_after_missing != null else first_visible
	if selected_item != null:
		selected_item.select(3)
		selected_layer_id = int(selected_item.get_metadata(3))
		layer_tree.scroll_to_item(selected_item)
	elif layers.is_empty():
		selected_layer_id = -1
	else:
		selected_layer_id = int(layers[0].id)
	_refresh_commands()
	_refreshing = false

func _configure_row(item: TreeItem, layer: Dictionary, display: String) -> void:
	var entity_id := int(layer.id)
	var brush_count := int(layer.brush_count)
	var visible: bool = session.layer_visible(entity_id)
	var locked: bool = session.is_layer_locked(entity_id)
	var active: bool = session.active_layer_id == entity_id
	item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
	item.set_checked(0, visible)
	item.set_editable(0, true)
	item.set_tooltip_text(0, ("Hide %s" if visible else "Show %s") % display)
	item.set_text(0, "")
	item.set_cell_mode(1, TreeItem.CELL_MODE_CHECK)
	item.set_checked(1, locked)
	item.set_editable(1, true)
	item.set_tooltip_text(1, ("Unlock %s" if locked else "Lock %s") % display)
	item.set_cell_mode(2, TreeItem.CELL_MODE_CHECK)
	item.set_checked(2, active)
	item.set_editable(2, true)
	item.set_tooltip_text(2, "Active layer: %s" % display)
	item.set_text(3, display)
	item.set_editable(3, false)
	item.set_metadata(3, entity_id)
	item.set_text(4, str(brush_count))
	item.set_selectable(4, false)
	var state := "visible" if visible else "hidden"
	state += ", locked" if locked else ", unlocked"
	if active:
		state += ", active"
	var accessible := "Layer %s, %d brushes, %s" % [display, brush_count, state]
	item.set_tooltip_text(3, "%s. Entity %d, %s" % [accessible, entity_id, layer.classname])
	if int(layer.patch_count) > 0:
		item.set_custom_color(3, Color(0.95, 0.78, 0.4))
		item.set_tooltip_text(3, item.get_tooltip_text(3) + "; owns patches — Delete Layer disabled")

func _refresh_commands() -> void:
	var layer: Dictionary = session.layer_by_id(selected_layer_id) if session != null else {}
	var is_world: bool = not layer.is_empty() and String(layer.classname) == "worldspawn"
	var has_layer: bool = not layer.is_empty()
	var has_patches: bool = has_layer and int(layer.patch_count) > 0
	rename_button.disabled = not has_layer or is_world
	select_button.disabled = not has_layer
	add_button.disabled = session == null or session.selected.is_empty() or not has_layer
	remove_button.disabled = not has_layer or is_world or session == null or session.selected.is_empty()
	show_only_button.disabled = not has_layer
	show_all_button.disabled = session == null or session.isolated_layer_id == 0
	delete_button.disabled = not has_layer or is_world or has_patches
	if status_label != null:
		if has_layer:
			var warning := " • patch warning: Delete disabled" if has_patches else ""
			status_label.text = "%s • %d brushes%s" % [session.layer_display_name(layer), int(layer.brush_count), warning]
		else:
			status_label.text = "No layers"

func _build_ui() -> void:
	name = "LayersPane"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _is_layout_pane():
		var header := PaneHeader.new("Layers")
		header.name = "PaneHeader"
		add_child(header)
	search_field = LineEdit.new()
	search_field.name = "LayerSearch"
	search_field.placeholder_text = "Search layers"
	search_field.accessibility_name = "Search layers"
	search_field.text_changed.connect(_search_changed)
	add_child(search_field)
	layer_tree = Tree.new()
	layer_tree.name = "LayerTree"
	layer_tree.accessibility_name = "Layers"
	layer_tree.columns = 5
	layer_tree.hide_root = true
	layer_tree.select_mode = Tree.SELECT_ROW
	layer_tree.set_column_title(0, "Eye")
	layer_tree.set_column_title(1, "Lock")
	layer_tree.set_column_title(2, "Active")
	layer_tree.set_column_title(3, "Name")
	layer_tree.set_column_title(4, "Count")
	layer_tree.set_column_titles_visible(true)
	layer_tree.set_column_expand(0, false)
	layer_tree.set_column_expand(1, false)
	layer_tree.set_column_expand(2, false)
	layer_tree.set_column_expand(3, true)
	layer_tree.set_column_expand(4, false)
	layer_tree.set_column_custom_minimum_width(0, 36)
	layer_tree.set_column_custom_minimum_width(1, 36)
	layer_tree.set_column_custom_minimum_width(2, 52)
	layer_tree.set_column_custom_minimum_width(4, 48)
	layer_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layer_tree.item_selected.connect(_row_selected)
	layer_tree.item_mouse_selected.connect(_row_mouse_selected)
	layer_tree.item_edited.connect(_row_edited)
	layer_tree.gui_input.connect(_tree_gui_input)
	add_child(layer_tree)
	var commands := HBoxContainer.new()
	add_child(commands)
	new_button = _add_button(commands, "New Layer", _request_new_layer)
	rename_button = _add_button(commands, "Rename", _request_rename)
	select_button = _add_button(commands, "Select Members", _select_members)
	add_button = _add_button(commands, "Add Selection", _add_selection)
	remove_button = _add_button(commands, "Remove Selection", _remove_selection)
	show_only_button = _add_button(commands, "Show Only", _show_only)
	show_all_button = _add_button(commands, "Show All", _show_all)
	delete_button = _add_button(commands, "Delete Layer", _request_delete)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)
	context_menu = PopupMenu.new()
	context_menu.add_item("New Layer", 0)
	context_menu.add_item("Rename", 1)
	context_menu.add_item("Select Members", 2)
	context_menu.add_item("Add Selection", 3)
	context_menu.add_item("Remove Selection", 4)
	context_menu.add_item("Show Only", 5)
	context_menu.add_item("Show All", 6)
	context_menu.add_item("Delete Layer", 7)
	context_menu.id_pressed.connect(_context_chosen)
	add_child(context_menu)
	new_dialog = ConfirmationDialog.new()
	new_dialog.title = "New Layer"
	new_dialog.ok_button_text = "Create"
	new_name_field = LineEdit.new()
	new_name_field.placeholder_text = "Layer name"
	new_name_field.accessibility_name = "New layer name"
	new_dialog.add_child(new_name_field)
	new_dialog.confirmed.connect(_create_layer_confirmed)
	add_child(new_dialog)
	rename_dialog = ConfirmationDialog.new()
	rename_dialog.title = "Rename Layer"
	rename_field = LineEdit.new()
	rename_field.accessibility_name = "Rename layer"
	rename_dialog.add_child(rename_field)
	rename_dialog.confirmed.connect(_rename_confirmed)
	add_child(rename_dialog)
	delete_dialog = ConfirmationDialog.new()
	delete_dialog.title = "Delete Layer"
	delete_dialog.dialog_text = "Move owned brushes to Worldspawn and delete this layer?"
	delete_dialog.confirmed.connect(_delete_confirmed)
	add_child(delete_dialog)

func _is_layout_pane() -> bool:
	var parent := get_parent()
	return parent != null and String(parent.name).begins_with("ViewSlot")

func _add_button(parent: Control, text_value: String, callback: Callable) -> Button:
	var control := Button.new()
	control.text = text_value
	control.accessibility_name = text_value
	control.tooltip_text = text_value
	control.pressed.connect(callback)
	parent.add_child(control)
	return control

func _search_changed(value: String) -> void:
	if session == null or _refreshing:
		return
	session.set_layer_search(value)

func _row_selected() -> void:
	if _refreshing:
		return
	var item := layer_tree.get_selected()
	if item == null:
		return
	selected_layer_id = int(item.get_metadata(3))
	_refresh_commands()

func _row_mouse_selected(position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_row_selected()
		context_menu.position = Vector2i(layer_tree.get_screen_position() + position)
		context_menu.popup()

func _row_edited() -> void:
	if session == null or _refreshing:
		return
	var item := layer_tree.get_edited()
	if item == null:
		return
	var entity_id := int(item.get_metadata(3))
	match layer_tree.get_edited_column():
		0:
			session.set_layer_eye(entity_id, item.is_checked(0))
		1:
			session.set_layer_lock(entity_id, item.is_checked(1))
		2:
			if item.is_checked(2):
				session.set_active_layer(entity_id)
			else:
				item.set_checked(2, session.active_layer_id == entity_id)

func _tree_gui_input(event: InputEvent) -> void:
	if session == null or not event is InputEventKey or not event.pressed:
		return
	var item := layer_tree.get_selected()
	if item == null:
		return
	var entity_id := int(item.get_metadata(3))
	match event.keycode:
		KEY_H:
			session.set_layer_eye(entity_id, not session.layer_visible(entity_id))
			accept_event()
		KEY_L:
			session.set_layer_lock(entity_id, not session.is_layer_locked(entity_id))
			accept_event()
		KEY_A:
			session.set_active_layer(entity_id)
			accept_event()
		KEY_F2:
			_request_rename()
			accept_event()
		KEY_DELETE:
			_request_delete()
			accept_event()
		KEY_MENU:
			context_menu.popup()
			accept_event()

func _context_chosen(id: int) -> void:
	match id:
		0:
			_request_new_layer()
		1:
			_request_rename()
		2:
			_select_members()
		3:
			_add_selection()
		4:
			_remove_selection()
		5:
			_show_only()
		6:
			_show_all()
		7:
			_request_delete()

func _request_new_layer() -> void:
	if session == null:
		return
	new_name_field.text = ""
	new_dialog.popup_centered()
	new_name_field.grab_focus()

func _create_layer_confirmed() -> void:
	create_named_layer(new_name_field.text)

func create_named_layer(targetname: String) -> void:
	if session == null:
		return
	if session.create_layer(targetname):
		selected_layer_id = session.active_layer_id
		_pending_focus_id = selected_layer_id
		refresh()

func _request_rename() -> void:
	if session == null:
		return
	var layer: Dictionary = session.layer_by_id(selected_layer_id)
	if layer.is_empty() or String(layer.classname) == "worldspawn":
		return
	rename_field.text = String(layer.get("targetname", ""))
	rename_dialog.popup_centered()
	rename_field.grab_focus()

func _rename_confirmed() -> void:
	rename_selected(rename_field.text)

func rename_selected(targetname: String) -> void:
	if session == null:
		return
	_pending_focus_id = selected_layer_id
	session.rename_layer(selected_layer_id, targetname)

func _select_members() -> void:
	if session == null:
		return
	session.select_layer_members(selected_layer_id, Input.is_key_pressed(KEY_SHIFT))

func select_members(add := false) -> void:
	if session == null:
		return
	session.select_layer_members(selected_layer_id, add)

func _add_selection() -> void:
	if session == null:
		return
	session.move_selection_to_layer(selected_layer_id)

func _remove_selection() -> void:
	if session == null:
		return
	session.remove_selection_from_layer(selected_layer_id)

func _show_only() -> void:
	if session == null:
		return
	session.show_only_layer(selected_layer_id)

func _show_all() -> void:
	if session == null:
		return
	session.clear_layer_isolation()

func _request_delete() -> void:
	if session == null:
		return
	var layer: Dictionary = session.layer_by_id(selected_layer_id)
	if layer.is_empty() or String(layer.classname) == "worldspawn":
		return
	if int(layer.patch_count) > 0:
		session.message.emit("Cannot delete a func_group that owns patches.")
		return
	if int(layer.brush_count) == 0:
		_delete_confirmed()
		return
	delete_dialog.dialog_text = "Move %d brushes to Worldspawn and delete %s?" % [int(layer.brush_count), session.layer_display_name(layer)]
	delete_dialog.popup_centered()

func _delete_confirmed() -> void:
	delete_selected()

func delete_selected() -> void:
	if session == null:
		return
	var layer: Dictionary = session.layer_by_id(selected_layer_id)
	if layer.is_empty():
		return
	var next_id: int = _worldspawn_or_next_id(selected_layer_id)
	if session.delete_layer(selected_layer_id):
		selected_layer_id = next_id
		_pending_focus_id = next_id
		refresh()

func _worldspawn_or_next_id(deleted_id: int) -> int:
	var layers: Array = session.layers()
	var next_id: int = session.worldspawn_layer_id()
	var found := false
	for layer in layers:
		if int(layer.id) == deleted_id:
			found = true
			continue
		if found:
			return int(layer.id)
		next_id = int(layer.id)
	return next_id
