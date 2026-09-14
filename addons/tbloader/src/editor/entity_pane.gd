@tool
extends VBoxContainer

signal entity_selected(entity_id: int)

var selected_entity_id: int = -1
var session: RefCounted

var entity_list: ItemList
var property_tree: Tree
var key_field: LineEdit
var value_field: LineEdit
var class_field: LineEdit
var set_button: Button
var remove_button: Button
var group_button: Button
var delete_button: Button
var status_label: Label

var _refreshing := false

func _ready() -> void:
	if entity_list == null:
		_build_ui()
	refresh()

# Rebinding never changes session.selected/session.points. This pane has its own
# stable entity ID so list navigation remains independent of spatial selection.
func set_session(value: RefCounted) -> void:
	if session != null and session.changed.is_connected(_session_changed):
		session.changed.disconnect(_session_changed)
	session = value
	if session != null and not session.changed.is_connected(_session_changed):
		session.changed.connect(_session_changed)
	refresh()

func clear() -> void:
	set_session(null)

func refresh() -> void:
	if entity_list == null:
		return
	_refreshing = true
	entity_list.clear()
	var entities: Array = session.entity_data() if session != null else []
	var selected_index := -1
	var active_valid := false
	for entity in entities:
		var classname := _first_value(entity.epairs, "classname")
		var label := "%s  #%d" % [classname if not classname.is_empty() else "<no classname>", entity.id]
		entity_list.add_item(label)
		var index := entity_list.item_count - 1
		entity_list.set_item_metadata(index, int(entity.id))
		entity_list.set_item_tooltip(index, "Entity %d" % entity.id)
		if int(entity.id) == selected_entity_id:
			selected_index = index
			active_valid = true
	if not active_valid:
		selected_entity_id = int(entities[0].id) if not entities.is_empty() else -1
		selected_index = 0 if not entities.is_empty() else -1
	if selected_index >= 0:
		entity_list.select(selected_index)
	_refresh_properties(entities)
	_refreshing = false

func set_selected_entity_id(entity_id: int) -> bool:
	if session == null:
		return false
	for entity in session.entity_data():
		if int(entity.id) == entity_id:
			selected_entity_id = entity_id
			refresh()
			entity_selected.emit(entity_id)
			return true
	return false

func _session_changed() -> void:
	refresh()

func _build_ui() -> void:
	name = "EntityPane"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	entity_list = ItemList.new()
	entity_list.custom_minimum_size.x = 170.0
	entity_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	entity_list.item_selected.connect(_entity_item_selected)
	split.add_child(entity_list)
	property_tree = Tree.new()
	property_tree.columns = 2
	property_tree.hide_root = true
	property_tree.set_column_title(0, "Key")
	property_tree.set_column_title(1, "Value")
	property_tree.set_column_titles_visible(true)
	property_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	property_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	property_tree.item_selected.connect(_property_selected)
	split.add_child(property_tree)

	var edit_row := HBoxContainer.new()
	add_child(edit_row)
	key_field = LineEdit.new()
	key_field.placeholder_text = "Key"
	key_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_row.add_child(key_field)
	value_field = LineEdit.new()
	value_field.placeholder_text = "Value"
	value_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_field.text_submitted.connect(func(_value): _set_property())
	edit_row.add_child(value_field)
	set_button = _add_button(edit_row, "Set", _set_property)
	remove_button = _add_button(edit_row, "Remove", _remove_property)

	var create_row := HBoxContainer.new()
	add_child(create_row)
	class_field = LineEdit.new()
	class_field.text = "info_player_start"
	class_field.placeholder_text = "Entity classname"
	class_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_row.add_child(class_field)
	_add_button(create_row, "Create Point", _create_point)
	group_button = _add_button(create_row, "Group Selected", _group_selected)
	delete_button = _add_button(create_row, "Delete", _delete_entity)
	delete_button.tooltip_text = "Delete this entity and return its brushes to worldspawn"

	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

func _refresh_properties(entities: Array) -> void:
	property_tree.clear()
	var root := property_tree.create_item()
	var active: Dictionary = {}
	for entity in entities:
		if int(entity.id) == selected_entity_id:
			active = entity
			break
	if not active.is_empty():
		for pair in active.epairs:
			var row := property_tree.create_item(root)
			row.set_text(0, pair.key)
			row.set_text(1, pair.value)
			row.set_metadata(0, pair.key)
			row.set_metadata(1, pair.value)
	var classname := _first_value(active.get("epairs", []), "classname")
	var has_entity := selected_entity_id >= 0
	set_button.disabled = not has_entity
	remove_button.disabled = not has_entity
	delete_button.disabled = not has_entity or classname == "worldspawn"
	group_button.disabled = session == null or session.selected.is_empty()
	status_label.text = "%d entities; active #%d" % [entities.size(), selected_entity_id] if has_entity else "%d entities" % entities.size()

func _entity_item_selected(index: int) -> void:
	if _refreshing:
		return
	selected_entity_id = int(entity_list.get_item_metadata(index))
	_refresh_properties(session.entity_data())
	entity_selected.emit(selected_entity_id)

func _property_selected() -> void:
	var row := property_tree.get_selected()
	if row == null or row.get_metadata(0) == null:
		return
	key_field.text = str(row.get_metadata(0))
	value_field.text = str(row.get_metadata(1))

func _set_property() -> void:
	if session == null or selected_entity_id < 0:
		return
	var entity_id := selected_entity_id
	var key := key_field.text
	var value := value_field.text
	session.transact("Edit map entity property", func():
		return session.document.set_entity_property(entity_id, key, value))

func _remove_property() -> void:
	if session == null or selected_entity_id < 0:
		return
	var entity_id := selected_entity_id
	var key := key_field.text
	session.transact("Remove map entity property", func():
		return session.document.remove_entity_property(entity_id, key))

func _create_point() -> void:
	if session == null:
		return
	var position: Vector3 = session.workzone.get_center().snapped(Vector3.ONE * session.grid)
	var created_id := -1
	if session.transact("Create map point entity", func():
		var result: Dictionary = session.document.create_point_entity(class_field.text, position)
		if result.ok:
			created_id = int(result.value)
		return result):
		set_selected_entity_id(created_id)

func _group_selected() -> void:
	if session == null or session.selected.is_empty():
		return
	var ids: PackedInt64Array = session.selected.duplicate()
	var created_id := -1
	if session.transact("Create map brush entity", func():
		var result: Dictionary = session.document.group_brushes(ids, class_field.text)
		if result.ok and result.value != null:
			created_id = int(result.value)
		return result) and created_id >= 0:
		set_selected_entity_id(created_id)

func _delete_entity() -> void:
	if session == null or selected_entity_id < 0:
		return
	var entity_id := selected_entity_id
	if session.transact("Delete map entity", func():
		return session.document.delete_entities(PackedInt64Array([entity_id]), false)):
		selected_entity_id = -1
		refresh()

func _first_value(epairs: Array, key: String) -> String:
	for pair in epairs:
		if pair.key == key:
			return pair.value
	return ""

func _add_button(parent: Control, text_value: String, callback: Callable) -> Button:
	var control := Button.new()
	control.text = text_value
	control.pressed.connect(callback)
	parent.add_child(control)
	return control
