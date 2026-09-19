@tool
extends EditorPlugin
## Test-only read-side bridge. No event injection, handler calls, document writes,
## focus changes, or production control setters are permitted here.

var ui: Control
var busy = false
var frame_times: Array = []
var last_frame = 0
var input_events: Array = []
var measurements: Dictionary = {}
var measurement = ""

func _enter_tree() -> void:
	if OS.get_environment("TB_TEST_SUITE") == "window_input":
		call_deferred("start")

func find_plugin(node: Node) -> EditorPlugin:
	if node is EditorPlugin and node.get_script() != null and node.get_script().resource_path == "res://addons/tbloader/src/plugin.gd":
		return node
	for child in node.get_children():
		var found = find_plugin(child)
		if found != null:
			return found
	return null

func start() -> void:
	for i in 10:
		await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	var addon = find_plugin(get_tree().root)
	ui = addon.map_editor
	RenderingServer.frame_post_draw.connect(frame_drawn)
	write_json("res://window-ready.json", {"pid": OS.get_process_id()})

func frame_drawn() -> void:
	var now = Time.get_ticks_usec()
	if last_frame:
		frame_times.append(now - last_frame)
		if not measurement.is_empty():
			measurements[measurement].append(now - last_frame)
	last_frame = now

func _input(event: InputEvent) -> void:
	if ui == null:
		return
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventMouseMotion:
		input_events.append({"usec": Time.get_ticks_usec(), "event": event.as_text(), "device": event.device})

func rect(control: Control) -> Array:
	# Control.get_screen_position uses popup-relative coordinates when subwindows
	# are embedded. Viewport screen transform includes embedded window offsets;
	# its public default excludes the native window origin on this engine pin.
	var p = Vector2(get_tree().root.position) + (control.get_viewport().get_screen_transform() * control.get_global_transform_with_canvas()).origin
	return [p.x, p.y, control.size.x, control.size.y]

func controls(node: Node, result: Array) -> void:
	if node is Control and node.is_visible_in_tree():
		if node is Button or node is LineEdit:
			result.append({"path": str(node.get_path()), "class": node.get_class(), "text": node.text, "rect": rect(node)})
		if node is TabBar:
			for i in node.tab_count:
				var tab: Rect2 = node.get_tab_rect(i)
				var base = rect(node)
				var p: Vector2 = Vector2(base[0], base[1]) + tab.position
				result.append({"path": str(node.get_path()), "class": "TabBar", "text": node.get_tab_title(i), "tooltip": node.get_tab_tooltip(i), "rect": [p.x, p.y, tab.size.x, tab.size.y]})
		if node is ItemList:
			for i in node.item_count:
				var item: Rect2 = node.get_item_rect(i)
				var base = rect(node)
				result.append({"path": str(node.get_path()), "class": "ItemList", "text": node.get_item_text(i), "rect": [base[0] + item.position.x, base[1] + item.position.y - node.get_v_scroll_bar().value, item.size.x, item.size.y]})
	for child in node.get_children(true):
		controls(child, result)

func vector(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func graph_state(graph: Control) -> Dictionary:
	return {"rect": rect(graph), "orientation": graph.orientation, "origin": vector(graph.origin), "zoom": graph.zoom,
		"gesture": graph.gesture, "delta": vector(graph.delta), "focus": graph.has_focus()}

func state() -> Dictionary:
	var buttons: Array = []
	controls(get_tree().root, buttons)
	var brushes: Array = []
	for brush in ui.session.document.get_draw_data():
		var textures: Array = []
		for face in brush.faces:
			textures.append(face.texture)
		brushes.append({"id": brush.id, "min": vector(brush.aabb_min), "max": vector(brush.aabb_max),
			"faces": brush.faces.size(), "vertices": brush.vertices.size(), "textures": textures})
	var focus = get_tree().root.gui_get_focus_owner()
	return {"pid": OS.get_process_id(), "usec": Time.get_ticks_usec(), "visible": ui.is_visible_in_tree(), "window_position": [get_tree().root.position.x, get_tree().root.position.y],
		"window_focus": get_tree().root.has_focus(), "last_frame_usec": last_frame, "controls": buttons, "a": graph_state(ui.graph_a), "b": graph_state(ui.graph_b),
		"graphs": ui.graphs.map(graph_state), "layout": ui.view_layout, "camera_slot": ui.camera_slot,
		"quad_split": rect(ui.workspace.get_drag_area_controls()[0]),
		"grid_split": rect(ui.right_views.get_drag_area_controls()[0]),
		"camera": rect(ui.camera_view), "camera_position": vector(ui.camera_view.camera.position), "flying": ui.camera_view.flying,
		"held": ui.camera_view.held, "mouse_mode": Input.mouse_mode, "triangles": ui.camera_view.triangle_count,
		"brushes": brushes, "text": ui.session.document.export_text().value, "revision": ui.session.document.get_revision(),
		"dirty": ui.session.document.is_dirty(), "path": ui.session.document.get_path(),
		"history": ui.session.history_action_count() * 1000 + ui.session.history_cursor(),
		"actions": ui.session.history_action_count(), "selected": Array(ui.session.selected), "hidden": ui.session.hidden.size(),
		"grid": ui.session.grid, "tool": ui.tool, "search": ui.browser._search.text, "search_rect": rect(ui.browser._search),
		"search_results": ui.browser.get_visible_paths(), "focus": str(focus.get_path()) if focus else "",
		"inspector": ui.inspector.visible, "entity_key": ui.entity_key.text, "entity_value": ui.entity_value.text,
		"key_rect": rect(ui.entity_key), "value_rect": rect(ui.entity_value),
		"inspector_rect": [ui.inspector.position.x, ui.inspector.position.y, ui.inspector.size.x, ui.inspector.size.y],
		"inspector_close_rect": [get_tree().root.position.x + ui.inspector.position.x + ui.inspector.size.x - 28, get_tree().root.position.y + ui.inspector.position.y - 28, 24, 24],
		"dirty_dialog": ui.dirty_dialog.visible, "file_dialog": ui.file_dialog.visible, "file_name_rect": rect(ui.file_dialog.get_line_edit()),
		"file_ok_rect": rect(ui.file_dialog.get_ok_button()), "notice": ui.notice.text}

func write_json(path: String, value: Variant) -> void:
	var file = FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)

func _process(_dt: float) -> void:
	if ui == null or busy or not FileAccess.file_exists("res://window-command.json"):
		return
	busy = true
	var request = JSON.parse_string(FileAccess.get_file_as_string("res://window-command.json"))
	DirAccess.remove_absolute("res://window-command.json")
	if request.op == "finish":
		write_json("res://window-metrics.json", {"frame_intervals_usec": frame_times, "measurements": measurements, "input_events": input_events})
		print("TB_TEST_COUNTS:window_input:%d:0" % int(request.checks))
		print("TB_TEST_COMPLETE:window_input:PASS")
		get_tree().quit(0)
		return
	if request.op == "measure":
		measurement = request.name
		if not measurement.is_empty():
			measurements[measurement] = []
	if request.op == "screenshot":
		await get_tree().process_frame
		RenderingServer.force_draw()
		var error = get_tree().root.get_texture().get_image().save_png("res://window-captures/" + request.name + ".png")
		if error != OK:
			push_error("Screenshot failed: %s" % error)
	var result = state()
	result["request"] = request.id
	write_json("res://window-state.json", result)
	busy = false
