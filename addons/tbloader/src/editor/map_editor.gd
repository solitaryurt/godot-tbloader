@tool
extends VBoxContainer

const Session = preload("res://addons/tbloader/src/editor/map_session.gd")
const Graph = preload("res://addons/tbloader/src/editor/graph_view.gd")
const Camera = preload("res://addons/tbloader/src/editor/camera_view.gd")
const Browser = preload("res://addons/tbloader/src/editor/material_browser.gd")
const BakeAction = preload("res://addons/tbloader/src/editor/bake_action.gd")

var plugin: EditorPlugin
var session: RefCounted
var graph_a: Control
var graph_b: Control
var active_graph: Control
var camera_view: Control
var browser: Control
var status: Label
var notice: Label
var binding_label: Label
var texture_field: LineEdit
var uv_fields: Array[SpinBox] = []
var uv_apply: Button
var uv_label: Label
var inspector: Window
var entity_list: Tree
var entity_key: LineEdit
var entity_value: LineEdit
var entity_class: LineEdit
var file_dialog: FileDialog
var dirty_dialog: ConfirmationDialog
var pending: Callable
var save_then_pending = false
var dialog_operation = ""
var tool = "Brush"
var tool_buttons: Dictionary = {}
var tokens: Array = []
var material_cache: Dictionary = {}
var texture_sizes: Dictionary = {}
var rebuild_on_save: CheckBox
var texture_root: LineEdit
var session_picker: OptionButton
var sessions: Array[WeakRef] = []
var scan_delay = -1.0

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var files = HFlowContainer.new()
	add_child(files)
	for entry in [["New", "new"], ["Open…", "open"], ["Save", "save"], ["Save As…", "save_as"]]:
		var command: String = entry[1]
		button(files, entry[0], func(): file_command(command))
	button(files, "Bind selected loader", bind_selected)
	button(files, "Detach", detach)
	button(files, "Update loader path", update_loader_path)
	button(files, "Bake saved map", bake)
	rebuild_on_save = CheckBox.new()
	rebuild_on_save.text = "Bake on save"
	rebuild_on_save.button_pressed = true
	files.add_child(rebuild_on_save)
	session_picker = OptionButton.new()
	session_picker.tooltip_text = "Sessions retained by Map undo history"
	session_picker.item_selected.connect(func(index):
		var origin = session_picker.get_item_metadata(index).get_ref()
		if origin != null:
			set_session(origin))
	files.add_child(session_picker)
	binding_label = Label.new()
	add_child(binding_label)
	var tools = HFlowContainer.new()
	add_child(tools)
	for mode in ["Select", "Brush", "Cut", "Face", "Edge", "Vertex", "Texture"]:
		var value: String = mode
		var control = button(tools, mode, func(): set_tool(value))
		control.toggle_mode = true
		tool_buttons[mode] = control
	button(tools, "Clip", func(): active_graph.apply_clip(false))
	button(tools, "Split", func(): active_graph.apply_clip(true))
	button(tools, "Flip", func(): active_graph.clip_flip = not active_graph.clip_flip; set_status("Clip side flipped"))
	var sides = SpinBox.new()
	sides.min_value = 3
	sides.max_value = 62
	sides.value = 5
	sides.prefix = "Sides "
	tools.add_child(sides)
	button(tools, "Prism", func(): make_prism(int(sides.value)))
	button(tools, "Entity (N)", show_entities)
	var quad = HSplitContainer.new()
	quad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	quad.split_offset = 0
	add_child(quad)
	var left = VSplitContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.split_offset = 0
	quad.add_child(left)
	var right = VSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.split_offset = 0
	quad.add_child(right)
	camera_view = Camera.new()
	camera_view.host = self
	camera_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(camera_view)
	var materials = VBoxContainer.new()
	materials.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials.custom_minimum_size = Vector2(300, 200)
	left.add_child(materials)
	var root_row = HBoxContainer.new()
	materials.add_child(root_row)
	var label = Label.new()
	label.text = "Texture root"
	root_row.add_child(label)
	texture_root = LineEdit.new()
	texture_root.text = "res://textures"
	texture_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_row.add_child(texture_root)
	texture_root.text_submitted.connect(func(path): configure_browser(path))
	button(root_row, "Set", func(): configure_browser(texture_root.text))
	browser = Browser.new()
	browser.custom_minimum_size.y = 300
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials.add_child(browser)
	browser.resource_selected.connect(material_selected)
	browser.mapping_changed.connect(refresh_materials)
	browser.index_changed.connect(func(_count): refresh_materials())
	var surface = HBoxContainer.new()
	materials.add_child(surface)
	texture_field = LineEdit.new()
	texture_field.placeholder_text = "Map shader token"
	texture_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	surface.add_child(texture_field)
	button(surface, "Assign", assign_texture)
	var uv_row = GridContainer.new()
	uv_row.columns = 3
	materials.add_child(uv_row)
	for name_value in ["U ", "V ", "R ", "SU ", "SV "]:
		var spin = SpinBox.new()
		spin.min_value = -65536
		spin.max_value = 65536
		spin.step = 0.125
		spin.prefix = name_value
		spin.custom_minimum_size.x = 68
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		uv_row.add_child(spin)
		uv_fields.append(spin)
	uv_fields[3].value = 1
	uv_fields[4].value = 1
	uv_apply = button(uv_row, "UV Apply", apply_uv)
	uv_label = Label.new()
	materials.add_child(uv_label)
	graph_a = Graph.new()
	graph_a.host = self
	graph_a.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(graph_a)
	graph_b = Graph.new()
	graph_b.host = self
	graph_b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_b.orientation = 1
	right.add_child(graph_b)
	active_graph = graph_a
	status = Label.new()
	add_child(status)
	notice = Label.new()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.text = "Drag empty grid: cuboid • Shift click: select • RMB: pan • Shift RMB: box • H: hide • Space: clone"
	add_child(notice)
	build_dialogs()
	set_session(Session.new())
	configure_browser(texture_root.text)
	set_tool("Brush")
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			cancel_interaction())

func button(parent: Node, text: String, callback: Callable) -> Button:
	var control = Button.new()
	control.text = text
	control.pressed.connect(callback)
	parent.add_child(control)
	return control

func set_session(value: RefCounted) -> void:
	cancel_interaction()
	session = value
	session.manager = plugin.get_undo_redo()
	if not session.changed.is_connected(refresh):
		session.changed.connect(refresh)
		session.message.connect(set_status)
		session.action_recorded.connect(retain_action)
		sessions.append(weakref(session))
	graph_a.clip_points.clear()
	graph_b.clip_points.clear()
	texture_field.text = session.texture
	refresh()

func retain_action(token: RefCounted) -> void:
	token.reporter = Callable(self, "set_status")
	tokens.append(token)
	var total = 0
	var local = 0
	var count = 0
	for item in tokens:
		total += item.bytes
		if item.session == token.session:
			local += item.bytes
			count += 1
	for item in tokens:
		var same: bool = item.session == token.session
		if total > 128 * 1024 * 1024 or (same and (local > 64 * 1024 * 1024 or count > 128)):
			total -= item.bytes
			if same:
				local -= item.bytes
				count -= 1
			item.retire()
	tokens = tokens.filter(func(item): return item.session != null)

func cancel_interaction() -> void:
	if graph_a != null:
		graph_a.cancel()
		graph_b.cancel()
	if camera_view != null:
		camera_view.stop_fly()

func set_status(text: String) -> void:
	if notice != null:
		notice.text = text

func refresh_status() -> void:
	if session == null or status == null:
		return
	var path: String = session.document.get_path()
	var baked = "never baked" if session.baked_text.is_empty() else ("baked current" if session.baked_text == session.document.export_text().value else "bake stale")
	status.text = "%s%s • %s • grid %.3f • %s • %s • %d selected • %d hidden" % [path if path else "Untitled.map", " * UNSAVED" if session.document.is_dirty() else " • saved", baked, session.grid, tool, ["Side", "Front", "Top"][active_graph.orientation], session.selected.size() + session.points.size(), session.hidden.size()]
	var loader = session.loader.get_ref()
	binding_label.text = "Bound: %s — %s" % [loader.name, loader.map_resource] if is_instance_valid(loader) else "Standalone document • Select a TBLoader, then explicitly Bind"
	session_picker.clear()
	sessions = sessions.filter(func(reference): return reference.get_ref() != null)
	for reference in sessions:
		var origin = reference.get_ref()
		if origin == null:
			continue
		var filename: String = origin.document.get_path().get_file()
		session_picker.add_item((filename if filename else "Untitled") + (" *" if origin.document.is_dirty() else ""))
		var index = session_picker.item_count - 1
		session_picker.set_item_metadata(index, reference)
		if origin == session:
			session_picker.select(index)

func refresh() -> void:
	graph_a.queue_redraw()
	graph_b.queue_redraw()
	sync_texture_sizes()
	camera_view.refresh()
	refresh_status()
	refresh_uv()
	if inspector.visible:
		refresh_entities()

func set_tool(value: String) -> void:
	cancel_interaction()
	tool = value
	if session != null:
		session.components.clear()
	for key in tool_buttons:
		tool_buttons[key].button_pressed = key == tool
	refresh()

func route_key(event: InputEventKey, graph: Control) -> bool:
	if not event.pressed or event.echo or camera_view.flying:
		return false
	var focus = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or browser.has_browser_focus() or file_dialog.visible or dirty_dialog.visible or inspector.visible:
		return false
	if not is_visible_in_tree() or (focus != graph_a and focus != graph_b and focus != camera_view):
		return false
	if focus == graph_a or focus == graph_b:
		graph = focus
	active_graph = graph
	var key = event.keycode
	if event.ctrl_pressed:
		match key:
			KEY_Z, KEY_Y:
				cancel_interaction()
				var history = plugin.get_undo_redo().get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
				if key == KEY_Y or event.shift_pressed:
					history.redo()
				else:
					history.undo()
			KEY_TAB:
				graph.cycle_orientation()
			KEY_C:
				var result: Dictionary = session.document.export_selection(session.selected)
				if session.report(result):
					DisplayServer.clipboard_set(result.value)
			KEY_V:
				paste_text(DisplayServer.clipboard_get())
			KEY_S:
				file_command("save_as" if event.shift_pressed else "save")
			KEY_N:
				file_command("new")
			KEY_O:
				file_command("open")
			KEY_ENTER:
				graph.clip_flip = not graph.clip_flip
				set_status("Clip side flipped")
			_:
				if key >= KEY_3 and key <= KEY_9:
					make_prism(key - KEY_0)
				else:
					return false
	else:
		match key:
			KEY_ESCAPE:
				if graph.gesture != "":
					graph.cancel()
				elif not session.components.is_empty():
					session.components.clear()
					session.changed.emit()
				elif tool != "Brush":
					set_tool("Brush")
				else:
					session.select(PackedInt64Array())
			KEY_H:
				session.hide_selection(event.shift_pressed)
			KEY_SPACE:
				clone_selection(graph.axes().x)
			KEY_DELETE, KEY_BACKSPACE:
				delete_selection()
			KEY_N:
				show_entities()
			KEY_X:
				set_tool("Cut")
			KEY_Q:
				set_tool("Brush")
			KEY_F:
				set_tool("Face")
			KEY_E:
				set_tool("Edge")
			KEY_V:
				set_tool("Vertex")
			KEY_ENTER:
				graph.apply_clip(event.shift_pressed)
			KEY_BRACKETLEFT:
				session.grid = maxf(0.125, session.grid / 2)
			KEY_BRACKETRIGHT:
				session.grid = minf(1024, session.grid * 2)
			_:
				if key >= KEY_1 and key <= KEY_9:
					session.grid = pow(2, key - KEY_1)
				else:
					return false
	graph_a.queue_redraw()
	graph_b.queue_redraw()
	refresh_status()
	return true

func _input(event: InputEvent) -> void:
	# Early, single router prevents the editor's scene shortcut from also firing.
	if event is InputEventKey and route_key(event, active_graph):
		get_viewport().set_input_as_handled()

func clone_selection(axis: int) -> void:
	session.transact("Clone map brushes", func():
		var result: Dictionary = session.document.duplicate_brushes(session.selected)
		if result.ok and not result.value.is_empty():
			session.select(result.value)
			var movement = Vector3.ZERO
			movement[axis] = session.grid
			return session.document.translate_brushes(session.selected, movement)
		return result)

func paste_text(text: String) -> void:
	session.transact("Paste map brushes", func():
		var result: Dictionary = session.document.import_selection(text)
		if result.ok and not result.value.is_empty():
			session.select(result.value)
		return result)

func delete_selection() -> void:
	session.transact("Delete map selection", func():
		var result: Dictionary = session.document.delete_brushes(session.selected)
		if result.ok:
			result = session.document.delete_entities(session.points, true)
		return result)

func make_prism(sides: int) -> void:
	session.transact("Make %d-sided map prism" % sides, func():
		for id in session.selected:
			var result: Dictionary = session.document.make_prism(id, sides, active_graph.orientation)
			if not result.ok:
				return result
		return session.success())

func configure_browser(root: String) -> void:
	texture_root.text = root
	var probe = ClassDB.instantiate("TBLoader")
	var direct: bool = probe.has_method("resolve_material")
	probe.free()
	browser.configure(EditorInterface.get_resource_filesystem(), root, null, direct)
	refresh_materials()

func material_selected(_resource: Resource, path: String, token: String, mapping: Dictionary) -> void:
	if not mapping.resolved:
		# Native exact project tokens cover resources outside the legacy root.
		var resolver = ClassDB.instantiate("TBLoader")
		var result: Dictionary = resolver.call("resolve_material", path) if resolver.has_method("resolve_material") else {}
		resolver.free()
		if not result.get("resolved", false):
			set_status("%s: %s" % [path, mapping.reason])
			return
		token = path
	texture_field.text = token
	session.texture = token
	set_status("%s → %s • Assign applies to the selection" % [path, token])

func preview_material(token: String) -> Material:
	if material_cache.has(token):
		return material_cache[token]
	var material: Material
	var resolver = session.loader.get_ref()
	var temporary = not is_instance_valid(resolver)
	if temporary:
		resolver = ClassDB.instantiate("TBLoader")
		resolver.texture_path = texture_root.text
	if resolver.has_method("resolve_material"):
		var resolved: Dictionary = resolver.call("resolve_material", token)
		texture_sizes[token] = resolved.get("texture_size", Vector2i.ONE)
		if resolved.get("material") is Material:
			material = resolved.material.duplicate()
	if temporary:
		resolver.free()
	var mappings: Dictionary = browser.get_shader_mappings()
	if material == null and mappings.has(token):
		var resource = load(mappings[token])
		if resource is Material:
			material = resource.duplicate()
		elif resource is Texture2D:
			material = StandardMaterial3D.new()
			material.albedo_texture = resource
	if material == null:
		material = StandardMaterial3D.new()
		material.albedo_color = Color("8ba4b6")
	if material is BaseMaterial3D:
		material.vertex_color_use_as_albedo = true
	material_cache[token] = material
	return material

func refresh_materials() -> void:
	material_cache.clear()
	texture_sizes.clear()
	if session == null:
		return
	sync_texture_sizes()
	camera_view.refresh()

func sync_texture_sizes() -> void:
	var sizes: Dictionary = {}
	for token in session.document.get_texture_names():
		var material = preview_material(token)
		if texture_sizes.has(token):
			sizes[token] = texture_sizes[token]
			continue
		var texture: Texture2D
		if material is BaseMaterial3D:
			texture = material.albedo_texture
		else:
			var loader = session.loader.get_ref()
			if is_instance_valid(loader):
				var resource = material.get(loader.texture_material_texture_path)
				if resource is Texture2D:
					texture = resource
		if texture != null:
			sizes[token] = Vector2i(texture.get_size())
	session.document.set_texture_sizes(sizes)

func face_targets() -> Array:
	var faces: Array = []
	if not session.components.is_empty():
		for component in session.components:
			if component.kind == "face":
				faces.append(component.duplicate())
	else:
		for id in session.selected:
			var brush: Dictionary = session.brush(id)
			for face in brush.faces:
				faces.append({"brush_id": id, "index": face.index, "topology_revision": brush.topology_revision, "kind": "face"})
	return faces

func assign_texture() -> void:
	session.texture = texture_field.text.strip_edges()
	var targets = face_targets()
	var component_mode: bool = not session.components.is_empty()
	session.transact("Assign map material", func():
		if not component_mode:
			return session.document.set_brush_texture(session.selected, session.texture)
		for target in targets:
			var validation: Dictionary = session.document.get_face_uv(target.brush_id, target.index, target.topology_revision)
			if not validation.ok:
				return validation
		for target in targets:
			var brush: Dictionary = session.brush(target.brush_id)
			var result: Dictionary = session.document.set_face_texture(target.brush_id, target.index, session.texture, brush.topology_revision)
			if not result.ok:
				return result
		session.rebind_components() # Surface edits preserve face order and geometry.
		return session.success())
	refresh_materials()

func refresh_uv() -> void:
	var targets = face_targets()
	var valve = false
	var mixed = false
	var first: Dictionary = {}
	for target in targets:
		var result: Dictionary = session.document.get_face_uv(target.brush_id, target.index, target.topology_revision)
		if not result.ok:
			continue
		var uv: Dictionary = result.value
		valve = valve or uv.projection == "valve"
		if first.is_empty():
			first = uv
		elif first.shift != uv.shift or first.rotation != uv.rotation or first.scale != uv.scale:
			mixed = true
	uv_apply.disabled = valve or targets.is_empty()
	uv_label.text = "Valve / mixed projection: UV editing unavailable" if valve else ("Mixed UVs — Apply replaces selected values" if mixed else "Classic UV • %d faces" % targets.size())
	for field in uv_fields:
		field.editable = not valve
	if not first.is_empty():
		var values = [first.shift.x, first.shift.y, first.rotation, first.scale.x, first.scale.y]
		for i in values.size():
			uv_fields[i].set_value_no_signal(values[i])

func apply_uv() -> void:
	var targets = face_targets()
	var shift = Vector2(uv_fields[0].value, uv_fields[1].value)
	var rotation = uv_fields[2].value
	var scale_value = Vector2(uv_fields[3].value, uv_fields[4].value)
	session.transact("Edit map UV", func():
		for target in targets:
			var validation: Dictionary = session.document.get_face_uv(target.brush_id, target.index, target.topology_revision)
			if not validation.ok:
				return validation
		for target in targets:
			var revision: int = session.brush(target.brush_id).topology_revision
			var result: Dictionary = session.document.set_face_uv(target.brush_id, target.index, shift, rotation, scale_value, revision)
			if not result.ok:
				return result
		session.rebind_components()
		return session.success())

func build_dialogs() -> void:
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.map ; Quake map"])
	file_dialog.size = Vector2i(800, 550)
	add_child(file_dialog)
	file_dialog.file_selected.connect(file_selected)
	file_dialog.canceled.connect(func(): pending = Callable(); save_then_pending = false)
	dirty_dialog = ConfirmationDialog.new()
	dirty_dialog.title = "Unsaved map"
	dirty_dialog.dialog_text = "Save changes to the current .map before continuing?"
	dirty_dialog.ok_button_text = "Save"
	dirty_dialog.add_button("Discard", false, "discard")
	dirty_dialog.confirmed.connect(func(): save_then_pending = true; file_command("save"))
	dirty_dialog.custom_action.connect(func(_action): session.save_enabled = false; dirty_dialog.hide(); run_pending())
	dirty_dialog.canceled.connect(func(): pending = Callable())
	add_child(dirty_dialog)
	inspector = Window.new()
	inspector.hide()
	inspector.transient = true
	inspector.title = "Map entities — ordered key / values"
	inspector.size = Vector2i(660, 480)
	inspector.close_requested.connect(inspector.hide)
	add_child(inspector)
	var column = VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inspector.add_child(column)
	entity_list = Tree.new()
	entity_list.columns = 3
	entity_list.set_column_title(0, "Entity / key")
	entity_list.set_column_title(1, "Value (first occurrence editable)")
	entity_list.set_column_title(2, "ID")
	entity_list.set_column_titles_visible(true)
	entity_list.hide_root = true
	entity_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	entity_list.item_selected.connect(entity_row_selected)
	column.add_child(entity_list)
	var edit = HBoxContainer.new()
	column.add_child(edit)
	entity_key = LineEdit.new()
	entity_key.placeholder_text = "Key"
	entity_key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_child(entity_key)
	entity_value = LineEdit.new()
	entity_value.placeholder_text = "Value / mixed"
	entity_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_child(entity_value)
	button(edit, "Set on targets", func(): edit_property(false))
	button(edit, "Remove key", func(): edit_property(true))
	var create = HBoxContainer.new()
	column.add_child(create)
	entity_class = LineEdit.new()
	entity_class.text = "info_player_start"
	entity_class.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create.add_child(entity_class)
	button(create, "Point at workzone center", create_point)
	button(create, "Group brushes", group_brushes)
	var actions = HBoxContainer.new()
	column.add_child(actions)
	button(actions, "Return brushes to world", func(): session.transact("Ungroup map brushes", func(): return session.document.return_brushes_to_worldspawn(session.selected)))
	button(actions, "Delete entity, KEEP brushes", func(): delete_entities(false))
	button(actions, "Delete entity AND brushes", func(): delete_entities(true))

func show_entities() -> void:
	cancel_interaction()
	refresh_entities()
	if DisplayServer.get_name() == "headless":
		inspector.popup(Rect2i(Vector2i.ZERO, inspector.size))
	else:
		inspector.popup_centered()
	entity_key.grab_focus()

func refresh_entities() -> void:
	entity_list.clear()
	var root = entity_list.create_item()
	var targets: PackedInt64Array = session.entity_targets()
	for entity in session.document.get_entities():
		if not targets.has(entity.id):
			continue
		var group = entity_list.create_item(root)
		group.set_text(0, "Entity %d" % entity.id)
		group.set_text(2, str(entity.id))
		for pair in entity.epairs:
			var row = entity_list.create_item(group)
			row.set_text(0, pair.key)
			row.set_text(1, pair.value)
			row.set_metadata(0, pair.key)
	inspector.title = "Map entities — %d target(s); Set edits first key, Remove deletes all duplicates" % targets.size()

func entity_row_selected() -> void:
	var row = entity_list.get_selected()
	if row == null or row.get_metadata(0) == null:
		return
	entity_key.text = row.get_metadata(0)
	var values: Array = []
	for entity in session.document.get_entities():
		if not session.entity_targets().has(entity.id):
			continue
		var value = "<absent>"
		for pair in entity.epairs:
			if pair.key == entity_key.text:
				value = pair.value
				break
		if not values.has(value):
			values.append(value)
	entity_value.text = values[0] if values.size() == 1 and values[0] != "<absent>" else ""
	entity_value.placeholder_text = "<mixed / absent>" if values.size() != 1 else "Value"

func edit_property(remove: bool) -> void:
	var ids: PackedInt64Array = session.entity_targets()
	var key = entity_key.text
	var value = entity_value.text
	session.transact("Edit map entity property", func():
		for id in ids:
			var result: Dictionary = session.document.remove_entity_property(id, key) if remove else session.document.set_entity_property(id, key, value)
			if not result.ok:
				return result
		return session.success())

func create_point() -> void:
	var position: Vector3 = session.workzone.get_center().snapped(Vector3.ONE * session.grid)
	session.transact("Create map point entity", func():
		var result: Dictionary = session.document.create_point_entity(entity_class.text, position)
		if result.ok:
			session.select(PackedInt64Array(), PackedInt64Array([result.value]))
		return result)

func group_brushes() -> void:
	session.transact("Create map brush entity", func(): return session.document.group_brushes(session.selected, entity_class.text))

func delete_entities(delete_brushes: bool) -> void:
	var ids: PackedInt64Array = session.entity_targets()
	session.transact("Delete map entities", func(): return session.document.delete_entities(ids, delete_brushes))

func request_replace(callback: Callable) -> void:
	cancel_interaction()
	pending = callback
	if session.document.is_dirty():
		dirty_dialog.popup_centered()
	else:
		run_pending()

func run_pending() -> void:
	var callback = pending
	pending = Callable()
	save_then_pending = false
	if callback.is_valid():
		callback.call()

func file_command(command: String) -> void:
	cancel_interaction()
	match command:
		"new":
			request_replace(func(): set_session(Session.new()); detach())
		"open":
			request_replace(func(): show_file_dialog("open"))
		"save":
			if session.document.get_path().is_empty():
				show_file_dialog("save")
			elif save_path(session.document.get_path()) and save_then_pending:
				run_pending()
		"save_as":
			show_file_dialog("save")

func show_file_dialog(operation: String) -> void:
	dialog_operation = operation
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE if operation == "open" else FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.current_dir = ProjectSettings.globalize_path("res://")
	file_dialog.popup_centered()

func file_selected(path: String) -> void:
	if dialog_operation == "open":
		open_path(path)
	elif save_path(path) and save_then_pending:
		run_pending()

func open_path(path: String) -> bool:
	var candidate = Session.new()
	var result: Dictionary = candidate.document.load_map(path)
	if not session.report(result):
		return false
	set_session(candidate)
	refresh_materials()
	set_status("Opened %s" % path)
	return true

func save_path(path: String) -> bool:
	var result: Dictionary = session.document.save_map(path)
	if not session.report(result):
		set_status(notice.text + " • Save As to another path or reopen the external version; current edits are retained.")
		return false
	set_status("Saved %s" % session.document.get_path())
	refresh_status()
	# Coalesce Save All notifications and avoid reentering a texture import.
	scan_delay = 0.5
	if rebuild_on_save.button_pressed and valid_binding() and same_path(session.loader.get_ref().map_resource, session.document.get_path()):
		bake()
	return true

func bind_selected() -> void:
	var loader = plugin.editing_loader.get_ref()
	var root = EditorInterface.get_edited_scene_root()
	if not is_instance_valid(loader) or root == null or not root.is_ancestor_of(loader) and root != loader:
		set_status("Select exactly one TBLoader in the current scene before binding.")
		return
	var target = weakref(loader)
	var target_scene = weakref(root)
	request_replace(func():
		var node = target.get_ref()
		if not is_instance_valid(node) or target_scene.get_ref() != EditorInterface.get_edited_scene_root():
			set_status("Binding cancelled: target loader or scene changed.")
			return
		if node.map_resource.is_empty():
			set_session(Session.new())
		elif not open_path(node.map_resource):
			return
		session.loader = target
		session.scene = target_scene
		session.was_bound = true
		configure_browser(node.texture_path)
		refresh())

func detach() -> void:
	session.loader = weakref(null)
	session.scene = weakref(null)
	session.was_bound = false
	session.baked_text = ""
	refresh_status()

func valid_binding() -> bool:
	var loader = session.loader.get_ref()
	var root = EditorInterface.get_edited_scene_root()
	return is_instance_valid(loader) and root != null and session.scene.get_ref() == root and (root == loader or root.is_ancestor_of(loader))

func same_path(a: String, b: String) -> bool:
	return not a.is_empty() and not b.is_empty() and ProjectSettings.globalize_path(a).simplify_path() == ProjectSettings.globalize_path(b).simplify_path()

func update_loader_path() -> void:
	if not valid_binding() or session.document.get_path().is_empty():
		set_status("Save the map and bind a loader in the current scene first.")
		return
	var loader = session.loader.get_ref()
	var path: String = ProjectSettings.localize_path(session.document.get_path())
	if same_path(loader.map_resource, path):
		return
	var manager = plugin.get_undo_redo()
	manager.create_action("Set TBLoader map path", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
	manager.add_do_property(loader, "map_resource", path)
	manager.add_undo_property(loader, "map_resource", loader.map_resource)
	manager.commit_action()
	EditorInterface.mark_scene_as_unsaved()
	refresh_status()

func bake() -> bool:
	if not valid_binding():
		set_status("Bake requires the explicitly bound loader in the current scene.")
		return false
	var loader = session.loader.get_ref()
	if session.document.is_dirty() or not same_path(loader.map_resource, session.document.get_path()):
		set_status("Save first; use Update loader path explicitly if Save As changed the filename.")
		return false
	if not loader.has_method("build_meshes_checked"):
		set_status("Map saved. Checked bake API unavailable in this build; bake deferred.")
		return false
	var disk = ClassDB.instantiate("TBMapDocument")
	var loaded: Dictionary = disk.load_map(session.document.get_path())
	if not session.report(loaded):
		return false
	if disk.export_text().value != session.document.export_text().value:
		set_status("External change: saved file no longer matches this session; bake cancelled.")
		return false
	if not commit_bake(loader, session):
		return false
	refresh_status()
	set_status("Map saved and baked successfully; save the Godot scene to persist generated nodes.")
	return true

func commit_bake(loader: Node, origin: RefCounted = null) -> bool:
	var root = EditorInterface.get_edited_scene_root()
	if root == null or not is_instance_valid(loader) or (root != loader and not root.is_ancestor_of(loader)):
		set_status("Bake cancelled: loader is not in the current scene.")
		return false
	if not loader.has_method("build_meshes_checked"):
		set_status("Checked bake API unavailable in this build; bake deferred.")
		return false
	var before: PackedScene = BakeAction.capture(loader)
	if before == null:
		set_status("Could not snapshot loader children for scene undo; bake cancelled.")
		return false
	var result: Dictionary = loader.call("build_meshes_checked")
	if not session.report(result):
		return false
	var token = BakeAction.new()
	token.loader = weakref(loader)
	token.scene = weakref(root)
	token.session = weakref(origin)
	token.before = before
	token.after = BakeAction.capture(loader)
	token.before_text = origin.baked_text if origin != null else ""
	token.after_text = origin.document.export_text().value if origin != null else ""
	token.reporter = Callable(self, "set_status")
	if token.after == null:
		token.restore(false)
		set_status("Could not snapshot bake output; previous children restored.")
		return false
	if result.changed:
		var manager = plugin.get_undo_redo()
		manager.create_action("Bake TBLoader map", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
		manager.add_do_method(token, "restore", true)
		manager.add_undo_method(token, "restore", false)
		manager.add_do_reference(token)
		manager.add_undo_reference(token)
		manager.commit_action(false)
	if origin != null:
		origin.baked_text = token.after_text
	EditorInterface.mark_scene_as_unsaved()
	plugin.refresh_materials()
	set_status("Selected loader baked successfully; scene marked unsaved.")
	return true

func save_all() -> void:
	# Retained background sessions can become dirty via global undo. Save those
	# synchronously too; never redirect a save or bake through the selected loader.
	var untitled: RefCounted
	for reference in sessions:
		var origin = reference.get_ref()
		if origin == null or not origin.save_enabled or not origin.document.is_dirty():
			continue
		var path: String = origin.document.get_path()
		if path.is_empty():
			untitled = origin
		elif origin == session:
			save_path(path)
		else:
			session.report(origin.document.save_map(path))
	if untitled != null:
		set_session(untitled)
		file_command("save")
	refresh_status()

func unsaved_status() -> String:
	var paths = PackedStringArray()
	for reference in sessions:
		var origin = reference.get_ref()
		if origin != null and origin.save_enabled and origin.document.is_dirty():
			var path: String = origin.document.get_path()
			paths.append(path if path else "Untitled (use Map → Save As before exiting)")
	return "Unsaved Map documents: " + ", ".join(paths) if not paths.is_empty() else ""

func _process(delta: float) -> void:
	if session != null and session.was_bound and not valid_binding():
		detach()
	if scan_delay >= 0:
		scan_delay = maxf(0, scan_delay - delta)
		var filesystem = EditorInterface.get_resource_filesystem()
		if scan_delay == 0 and not filesystem.is_scanning() and not filesystem.is_importing():
			scan_delay = -1
			filesystem.scan()

func _exit_tree() -> void:
	cancel_interaction()
	for token in tokens:
		token.retire()
	tokens.clear()
	material_cache.clear()
