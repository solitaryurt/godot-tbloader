@tool
extends VBoxContainer

const Session = preload("res://addons/tbloader/src/editor/map_session.gd")
const Graph = preload("res://addons/tbloader/src/editor/graph_view.gd")
const Camera = preload("res://addons/tbloader/src/editor/camera_view.gd")
const Browser = preload("res://addons/tbloader/src/editor/material_browser.gd")
const BakeAction = preload("res://addons/tbloader/src/editor/bake_action.gd")
const UVPane = preload("res://addons/tbloader/src/editor/uv_pane.gd")
const EntityPane = preload("res://addons/tbloader/src/editor/entity_pane.gd")
const POINT_ENTITY_CLASSES := ["info_player_start", "light", "player", "target_speaker"]
const BRUSH_ENTITY_CLASSES := ["area", "func_group", "nocollision", "trigger_location"]
const BAKED_STATE_META := &"_tbloader_editor_baked_state"
const BAKED_STATE_RECORD_LIMIT := 128

const PANE_TYPES := ["Camera", "Top Grid", "Front Grid", "Side Grid", "UV", "Entities"]

var plugin: EditorPlugin
var session: RefCounted
var graph_a: Control
var graph_b: Control
var graph_c: Control
var graphs: Array[Control] = []
var cameras: Array[Control] = []
var uv_panes: Array[Control] = []
var entity_panes: Array[Control] = []
var active_graph: Control
var camera_view: Control
var material_workspace: Control
var browser: Control
var bottom_uv_pane: Control
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
var visibility_buttons: Dictionary = {}
var loader_actions: Dictionary = {}
var tokens: Array = []
var material_cache: Dictionary = {}
var texture_sizes: Dictionary = {}
var material_generation = 0
var rebuild_on_save: BaseButton
var texture_root: LineEdit
var scene_tabs: TabBar
var document_tabs: TabBar
var file_menu: MenuButton
var layout_menu: MenuButton
var camera_behavior_button: Button
var workspace: HSplitContainer
var left_views: VSplitContainer
var right_views: VSplitContainer
var view_slots: Array[Control] = []
var slot_menus: Array[MenuButton] = []
var slot_views: Array = [null, null, null, null]
var slot_types: Array[String] = ["Camera", "Side Grid", "Top Grid", "Front Grid"]
var view_parking: Control
var view_layout = 3
var radiant_camera_behavior := false
var camera_slot = 0 # Compatibility alias; pane placement is now slot-owned.
var syncing_view_splits = false
var sessions: Array[RefCounted] = [] # Documents outlive expirable history payloads.
var scene_sessions: Dictionary = {}
var watched_loaders: Dictionary = {}
var scene_active = false
var discovery_queued = false
var discovered_scene_id = 0
var changing_scene_tabs = false
var changing_document_tabs = false
var last_standalone: WeakRef = weakref(null)
var last_bake_action: WeakRef = weakref(null)
var discard_on_replace: RefCounted
var history_total_budget = 128 * 1024 * 1024
var history_session_budget = 64 * 1024 * 1024
var history_action_budget = 128
var resolver_config: Array = []
var shutting_down = false
const RECOVERY_PATH = "user://tbloader-map-recovery.json"
const RECOVERY_META = "tbloader_map_recovery"
const RECOVERY_VERSION = 2
var scan_delay = -1.0
var fallback_entity_pane: Control
var cut_points: Array[Vector3] = []
var cut_plane_points: Array[Vector3] = []
var cut_flip := false
var mutation_preview_owner: WeakRef = weakref(null)
var mutation_preview_generation := 0
var mutation_preview_pending := false
var mutation_preview_queued: Dictionary = {}
var mutation_preview_queued_owner: WeakRef = weakref(null)
var mutation_preview_coalesced := 0
var mutation_preview_flushes := 0
var entity_menu: PopupMenu
var entity_menu_actions: Dictionary = {}
var entity_menu_session: WeakRef = weakref(null)
var entity_menu_point := Vector3.ZERO

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	texture_field = bottom_uv_pane.texture_field
	uv_fields.assign([bottom_uv_pane.shift_x, bottom_uv_pane.shift_y, bottom_uv_pane.rotation_field,
		bottom_uv_pane.scale_x, bottom_uv_pane.scale_y])
	uv_label = bottom_uv_pane.status_label
	scene_tabs = TabBar.new()
	scene_tabs.name = "SceneLoaderTabs"
	scene_tabs.tab_changed.connect(scene_tab_changed)
	scene_tabs.hide()
	add_child(scene_tabs)
	document_tabs = TabBar.new()
	document_tabs.name = "MapDocumentTabs"
	document_tabs.tooltip_text = "Open Map documents"
	document_tabs.tab_changed.connect(document_tab_changed)
	document_tabs.tab_button_pressed.connect(close_document_tab)
	add_child(document_tabs)
	var toolbar = HFlowContainer.new()
	toolbar.name = "MapToolbar"
	add_child(toolbar)
	var file_group := toolbar_group(toolbar)
	file_menu = MenuButton.new()
	file_menu.icon = editor_icon("GuiTabMenu")
	file_menu.tooltip_text = "Map file commands (Ctrl+O / Ctrl+S / Ctrl+Shift+S)"
	file_menu.accessibility_name = "Map file commands"
	file_menu.theme_type_variation = "FlatMenuButton"
	file_menu.get_popup().add_item("Open…", 0)
	file_menu.get_popup().add_item("Save", 1)
	file_menu.get_popup().add_item("Save As…", 2)
	file_menu.get_popup().id_pressed.connect(file_menu_command)
	file_group.add_child(file_menu)
	var mode_group := toolbar_group(toolbar)
	var exclusive_tools := ButtonGroup.new()
	var tool_shortcuts := {"Brush": "Q", "Cut": "X", "Rotate": "R", "Face": "F", "Edge": "E", "Vertex": "V"}
	var tool_icons := {
		"Select": editor_icon("ToolSelect"), "Brush": custom_icon("brush"), "Cut": custom_icon("cut"),
		"Rotate": editor_icon("ToolRotate"), "Face": custom_icon("face"), "Edge": custom_icon("edge"),
		"Vertex": custom_icon("vertex"), "Texture": custom_icon("texture"),
	}
	for mode in ["Select", "Brush", "Cut", "Rotate", "Face", "Edge", "Vertex", "Texture"]:
		var value: String = mode
		var hint: String = "%s Tool" % mode
		if tool_shortcuts.has(mode):
			hint += " (%s)" % tool_shortcuts[mode]
		var control := icon_button(mode_group, mode, hint, tool_icons[mode], func(): set_tool(value), true)
		control.button_group = exclusive_tools
		tool_buttons[mode] = control
	var loader_group := toolbar_group(toolbar)
	loader_actions.BindLoader = icon_button(loader_group, "BindLoader", "Bind selected TBLoader", custom_icon("bind_loader"), bind_selected)
	loader_actions.DetachLoader = icon_button(loader_group, "DetachLoader", "Detach from TBLoader", custom_icon("detach_loader"), detach)
	loader_actions.UpdateLoaderPath = icon_button(loader_group, "UpdateLoaderPath", "Update loader map path", custom_icon("update_loader_path"), update_loader_path)
	loader_actions.BuildMeshes = icon_button(loader_group, "BuildMeshes", "Build Meshes from saved map", editor_icon("Bake"), bake)
	icon_button(loader_group, "Materials", "Open Map Materials", editor_icon("StandardMaterial3D"), func(): plugin.show_materials())
	icon_button(loader_group, "UVBottomPanel", "Open UV bottom panel (S)", editor_icon("Texture2D"), func(): plugin.show_uv())
	icon_button(loader_group, "EntitiesBottomPanel", "Open Entities bottom panel (N)", editor_icon("Object"), show_entities)
	rebuild_on_save = icon_button(loader_group, "BuildMeshesOnSave", "Build meshes on save", custom_icon("bake_on_save"), func(): pass, true)
	rebuild_on_save.button_pressed = false
	var layout_group := toolbar_group(toolbar)
	layout_menu = MenuButton.new()
	layout_menu.theme_type_variation = "FlatMenuButton"
	layout_menu.tooltip_text = "Viewport layout"
	layout_menu.accessibility_name = "Viewport layout"
	for count in [2, 3, 4]:
		layout_menu.get_popup().add_radio_check_item("%d Views" % count, count)
	layout_menu.get_popup().id_pressed.connect(layout_menu_command)
	layout_group.add_child(layout_menu)
	camera_behavior_button = Button.new()
	camera_behavior_button.name = "CameraBehavior"
	camera_behavior_button.toggle_mode = true
	camera_behavior_button.theme_type_variation = "FlatButton"
	camera_behavior_button.toggled.connect(set_radiant_camera_behavior)
	layout_group.add_child(camera_behavior_button)
	update_camera_behavior_button()
	binding_label = Label.new()
	add_child(binding_label)
	var geometry_group := toolbar_group(toolbar)
	icon_button(geometry_group, "Clip", "Apply clip (Enter)", custom_icon("clip"), func(): apply_clip(false))
	icon_button(geometry_group, "Split", "Split brushes (Shift+Enter)", custom_icon("split"), func(): apply_clip(true))
	icon_button(geometry_group, "Flip", "Flip clipping side (Ctrl+Enter)", editor_icon("FlipWinding"), flip_clip)
	var sides = SpinBox.new()
	sides.min_value = 3
	sides.max_value = 62
	sides.value = 5
	sides.prefix = "Sides "
	sides.tooltip_text = "Prism sides (Ctrl+3 through Ctrl+9 creates directly)"
	geometry_group.add_child(sides)
	icon_button(geometry_group, "Prism", "Create prism", editor_icon("PrismMesh"), func(): make_prism(int(sides.value)))
	icon_button(geometry_group, "Merge", "Merge selected convex brushes", editor_icon("Merge"), merge_selection)
	var filter_group := toolbar_group(toolbar)
	for entry in [["Entities", "entities", "hide_entities"], ["Caulk", "caulk", "hide_caulk"], ["Clips", "clips", "hide_clips"], ["HintSkip", "hint_skip", "hide_hint_skip"]]:
		var category: String = entry[1]
		var control := icon_button(filter_group, "Hide%s" % entry[0], "Hide %s in all map views; this does not edit the map" % entry[0].to_lower(),
			custom_icon(entry[2]), func(): session.set_visibility_filter(category, not session.visibility_filters[category]), true)
		visibility_buttons[category] = control
	workspace = HSplitContainer.new()
	workspace.name = "MapViewWorkspace"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.drag_area_highlight_in_editor = true
	workspace.drag_nested_intersections = true
	add_child(workspace)
	left_views = VSplitContainer.new()
	left_views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_views.drag_nested_intersections = true
	left_views.dragged.connect(func(offset: int): sync_view_splits(left_views, offset))
	workspace.add_child(left_views)
	right_views = VSplitContainer.new()
	right_views.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_views.drag_nested_intersections = true
	right_views.dragged.connect(func(offset: int): sync_view_splits(right_views, offset))
	workspace.add_child(right_views)
	for index in 4:
		var slot := Control.new()
		slot.name = "ViewSlot%d" % index
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		(left_views if index < 2 else right_views).add_child(slot)
		view_slots.append(slot)
		var pane_menu := MenuButton.new()
		pane_menu.name = "PaneMenu%d" % index
		pane_menu.icon = editor_icon("GuiTabMenu")
		pane_menu.tooltip_text = "Choose pane type"
		pane_menu.accessibility_name = "Pane type for slot %d" % (index + 1)
		pane_menu.theme_type_variation = "FlatMenuButton"
		pane_menu.set_anchors_preset(Control.PRESET_TOP_LEFT)
		pane_menu.offset_left = 2
		pane_menu.offset_top = 2
		pane_menu.offset_right = 30
		pane_menu.offset_bottom = 26
		for pane_index in PANE_TYPES.size():
			pane_menu.get_popup().add_radio_check_item(PANE_TYPES[pane_index], pane_index)
		var pane_icons := [editor_icon("Camera3D"), custom_icon("grid_xy"), custom_icon("grid_xz"),
			custom_icon("grid_yz"), editor_icon("Texture2D"), editor_icon("Object")]
		for pane_index in PANE_TYPES.size():
			pane_menu.get_popup().set_item_icon(pane_index, pane_icons[pane_index])
		pane_menu.get_popup().id_pressed.connect(slot_menu_command.bind(index))
		slot.add_child(pane_menu)
		slot_menus.append(pane_menu)
	view_parking = Control.new()
	view_parking.name = "UnusedViews"
	view_parking.hide()
	add_child(view_parking)
	for index in 4:
		set_slot_type(index, slot_types[index])
	active_graph = graph_a
	apply_layout(3)
	status = Label.new()
	add_child(status)
	notice = Label.new()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice.text = "Drag empty grid: cuboid • RMB click: add entity • RMB drag: pan • S: UV • N: Entities • H: hide • Space: clone"
	add_child(notice)
	build_dialogs()
	build_entity_menu()
	set_session(Session.new())
	configure_browser(texture_root.text)
	set_tool("Brush")
	restore_recovery()
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			cancel_interaction())

func create_material_workspace() -> Control:
	if material_workspace != null:
		return material_workspace
	material_workspace = VBoxContainer.new()
	material_workspace.name = "MapMaterialAuthoring"
	material_workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	material_workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var root_row = HBoxContainer.new()
	material_workspace.add_child(root_row)
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
	browser.custom_minimum_size.y = 180
	browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	material_workspace.add_child(split)
	split.add_child(browser)
	browser.resource_selected.connect(material_selected)
	browser.mapping_changed.connect(queue_material_refresh)
	browser.index_changed.connect(func(_count): queue_material_refresh())
	bottom_uv_pane = UVPane.new()
	bottom_uv_pane.custom_minimum_size.x = 360
	bottom_uv_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_uv_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bottom_uv_pane.texture_token_requested.connect(uv_texture_requested)
	bottom_uv_pane.uv_transform_requested.connect(apply_uv_transform)
	bottom_uv_pane.match_grid_requested.connect(match_uv_grid)
	bottom_uv_pane.texture_axis_requested.connect(unsupported_uv_axis)
	bottom_uv_pane.reset_requested.connect(reset_uv)
	bottom_uv_pane.fit_requested.connect(unsupported_uv_fit)
	split.add_child(bottom_uv_pane)
	return material_workspace

func button(parent: Node, text: String, callback: Callable) -> Button:
	var control = Button.new()
	control.text = text
	control.pressed.connect(callback)
	parent.add_child(control)
	return control

func editor_icon(name: String) -> Texture2D:
	return plugin.get_editor_interface().get_base_control().get_theme_icon(name, "EditorIcons")

func custom_icon(name: String) -> Texture2D:
	var path := "res://addons/tbloader/icons/map_toolbar/%s.svg" % name
	var svg := FileAccess.get_file_as_string(path)
	if svg.is_empty():
		return editor_icon("Node3D")
	var neutral := plugin.get_editor_interface().get_base_control().get_theme_color("font_color", "Button").to_html(false)
	var image := Image.new()
	if image.load_svg_from_string(svg.replace("#e0e0e0", "#%s" % neutral), plugin.get_editor_interface().get_editor_scale()) != OK:
		return editor_icon("Node3D")
	return ImageTexture.create_from_image(image)

func toolbar_group(parent: Control) -> HBoxContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "PanelContainerButtonGroup"
	parent.add_child(panel)
	var row := HBoxContainer.new()
	panel.add_child(row)
	return row

func icon_button(parent: Control, name_value: String, hint: String, icon: Texture2D, callback: Callable, toggle := false) -> Button:
	var control := Button.new()
	control.name = name_value
	control.icon = icon
	control.tooltip_text = hint
	control.accessibility_name = hint.get_slice(" (", 0)
	control.theme_type_variation = "FlatButton"
	control.toggle_mode = toggle
	control.pressed.connect(callback)
	parent.add_child(control)
	return control


func build_entity_menu() -> void:
	entity_menu = PopupMenu.new()
	entity_menu.name = "GridEntityMenu"
	entity_menu.id_pressed.connect(entity_menu_selected)
	add_child(entity_menu)


func open_entity_menu(graph: Control, screen_position: Vector2) -> void:
	if not is_instance_valid(graph) or session == null:
		return
	var point: Vector3 = graph.unproject(screen_position)
	point[graph.orientation] = session.workzone.get_center()[graph.orientation]
	entity_menu_point = graph.snap_point(point)
	entity_menu_session = weakref(session)
	entity_menu_actions.clear()
	entity_menu.clear()
	var id := 1
	for classname in POINT_ENTITY_CLASSES:
		entity_menu.add_item("Point: " + classname, id)
		entity_menu_actions[id] = {"kind": "point", "classname": classname}
		id += 1
	entity_menu.add_separator("Brush entities")
	for classname in BRUSH_ENTITY_CLASSES:
		entity_menu.add_item("Brush: " + classname, id)
		entity_menu.set_item_disabled(entity_menu.get_item_index(id), session.selected.is_empty())
		entity_menu_actions[id] = {"kind": "brush", "classname": classname}
		id += 1
	var popup_position := Vector2i(graph.get_screen_transform() * screen_position)
	entity_menu.popup(Rect2i(popup_position, Vector2i(300, 0)))


func entity_menu_selected(id: int) -> void:
	var origin = entity_menu_session.get_ref()
	if origin == null or origin != session or not entity_menu_actions.has(id):
		return
	var action: Dictionary = entity_menu_actions[id]
	var classname: String = action.classname
	if action.kind == "point":
		var point := entity_menu_point
		origin.transact("Create %s point entity" % classname, func():
			var result: Dictionary = origin.document.create_point_entity(classname, point)
			if result.ok:
				origin.select(PackedInt64Array(), PackedInt64Array([result.value]))
			return result)
	else:
		var brush_ids: PackedInt64Array = origin.selected.duplicate()
		if brush_ids.is_empty():
			set_status("Select one or more brushes before creating a brush entity.")
			return
		origin.transact("Create %s brush entity" % classname,
			func(): return origin.document.group_brushes(brush_ids, classname))

func visible_graphs() -> Array[Control]:
	return graphs.filter(func(graph): return graph.is_inside_tree() and graph.is_visible_in_tree())

func camera_moved(position: Vector3, direction: Vector3) -> void:
	for graph in graphs:
		graph.set_camera_pose(position, direction)

func apply_dense_translation(movement: Vector3) -> void:
	for graph in graphs:
		graph.apply_dense_translation(movement)

func broadcast_mutation_preview(result: Dictionary, owner: Object) -> bool:
	# A synchronous broadcast supersedes any coalesced gesture preview still
	# waiting for its deferred dispatch; drop the stale queue first.
	mutation_preview_generation += 1
	mutation_preview_pending = false
	mutation_preview_queued = {}
	mutation_preview_queued_owner = weakref(null)
	if not result.get("ok", false):
		clear_mutation_preview(owner)
		session.report(result)
		return false
	mutation_preview_owner = weakref(owner)
	for camera in cameras:
		camera.set_candidate_preview(result.get("value", []))
	return true

func queue_mutation_preview(result: Dictionary, owner: Object) -> bool:
	# High-frequency gesture path: keep only the latest preview and dispatch
	# once per frame, mirroring camera preview_grid_move's deferred pattern.
	if not result.get("ok", false):
		mutation_preview_queued = {}
		mutation_preview_queued_owner = weakref(null)
		return broadcast_mutation_preview(result, owner)
	mutation_preview_queued = result
	mutation_preview_queued_owner = weakref(owner)
	mutation_preview_coalesced += 1
	if mutation_preview_pending:
		return true
	mutation_preview_pending = true
	call_deferred("_flush_mutation_preview", mutation_preview_generation)
	return true

func _flush_mutation_preview(generation: int) -> void:
	if generation != mutation_preview_generation:
		return
	mutation_preview_pending = false
	if mutation_preview_queued.is_empty():
		return
	var result: Dictionary = mutation_preview_queued
	mutation_preview_queued = {}
	var owner: Object = mutation_preview_queued_owner.get_ref()
	mutation_preview_queued_owner = weakref(null)
	mutation_preview_flushes += 1
	# Flush through the synchronous worker without re-invalidating the queue:
	# the pending state was already consumed above.
	if not result.get("ok", false):
		clear_mutation_preview(owner)
		session.report(result)
		return
	mutation_preview_owner = weakref(owner)
	for camera in cameras:
		camera.set_candidate_preview(result.get("value", []))

func flush_mutation_preview_now() -> bool:
	if not mutation_preview_pending or mutation_preview_queued.is_empty():
		return false
	_flush_mutation_preview(mutation_preview_generation)
	return true

func clear_mutation_preview(owner: Object = null) -> void:
	var current = mutation_preview_owner.get_ref()
	if owner != null and current != null and current != owner:
		return
	mutation_preview_generation += 1
	mutation_preview_pending = false
	mutation_preview_queued = {}
	mutation_preview_queued_owner = weakref(null)
	mutation_preview_owner = weakref(null)
	for camera in cameras:
		camera.clear_candidate_preview()

func set_cut_points(value: Array, hidden_axis := -1, camera_direction := Vector3.ZERO) -> void:
	cut_points.assign(value)
	rebuild_cut_plane(hidden_axis, camera_direction)
	refresh_cut_views()

func add_cut_point(point: Vector3, hidden_axis := -1, camera_direction := Vector3.ZERO) -> void:
	var max_points := 2 if hidden_axis >= 0 else 3
	if cut_points.size() >= max_points:
		cut_points.clear()
	cut_points.append(point)
	rebuild_cut_plane(hidden_axis, camera_direction)
	refresh_cut_views()

func clear_cut_state() -> void:
	cut_points.clear()
	cut_plane_points.clear()
	cut_flip = false
	clear_mutation_preview()
	refresh_cut_views()

func flip_clip() -> void:
	if tool != "Cut" or cut_plane_points.size() != 3:
		set_status("Place two or three clip points first.")
		return
	cut_flip = not cut_flip
	preview_clip(false)
	refresh_cut_views()
	set_status("Clip side flipped")

func rebuild_cut_plane(hidden_axis := -1, camera_direction := Vector3.ZERO) -> void:
	cut_plane_points.clear()
	if cut_points.size() < 2:
		return
	var p := cut_points[0]
	var q := cut_points[1]
	var r := cut_points[2] if cut_points.size() > 2 else p
	if cut_points.size() == 2:
		var extent := maxf(p.distance_to(q), session.grid)
		var direction := Vector3.ZERO
		if hidden_axis >= 0:
			direction[hidden_axis] = 1.0
		else:
			var view_direction := camera_direction.normalized()
			if not view_direction.is_zero_approx():
				var dominant_axis := 0
				for candidate in [1, 2]:
					if absf(view_direction[candidate]) > absf(view_direction[dominant_axis]):
						dominant_axis = candidate
				direction[dominant_axis] = signf(view_direction[dominant_axis])
			if direction.is_zero_approx() or (q - p).normalized().cross(direction).length_squared() < 0.0001:
				var axis := 0
				for candidate in [1, 2]:
					if absf((q - p).normalized()[candidate]) < absf((q - p).normalized()[axis]):
						axis = candidate
				direction = Vector3.ZERO
				direction[axis] = 1.0
		r = p - direction * extent
	if (q - p).cross(r - p).length_squared() >= 0.00000001:
		cut_plane_points.assign([p, q, r])

func cut_plane() -> Array[Vector3]:
	return cut_plane_points.duplicate()

func preview_clip(split: bool, owner: Object = null) -> bool:
	var plane := cut_plane()
	if plane.is_empty() or session.selected.is_empty():
		clear_mutation_preview(owner)
		return false
	return broadcast_mutation_preview(session.document.preview_clip_brushes(session.selected,
		plane[0], plane[1], plane[2], split, cut_flip), owner if owner != null else self)

func apply_clip(split: bool) -> void:
	var plane := cut_plane()
	if tool != "Cut" or plane.is_empty():
		set_status("Place two or three clip points first.")
		return
	var p := plane[0]
	var q := plane[1]
	var r := plane[2]
	if cut_flip:
		var swap := q
		q = r
		r = swap
	if session.transact("Split map brushes" if split else "Clip map brushes", func():
		var result: Dictionary = session.document.clip_brushes(session.selected, p, q, r, split)
		if result.ok:
			session.select(result.value)
		return result):
		clear_cut_state()

func refresh_cut_views() -> void:
	for graph in graphs:
		graph.queue_selection_redraw()
	for camera in cameras:
		camera.rebuild_cut_overlay()

func layout_menu_command(id: int) -> void:
	apply_layout(id)

func set_radiant_camera_behavior(enabled: bool) -> void:
	cancel_interaction()
	radiant_camera_behavior = enabled
	update_camera_behavior_button()
	for camera in cameras:
		camera.set_radiant_camera_behavior(enabled)

func update_camera_behavior_button() -> void:
	if camera_behavior_button == null:
		return
	camera_behavior_button.set_pressed_no_signal(radiant_camera_behavior)
	camera_behavior_button.text = "Radiant Camera" if radiant_camera_behavior else "Godot Camera"
	camera_behavior_button.tooltip_text = ("Use Radiant camera controls: RMB click toggles fly, RMB drag pans"
		if radiant_camera_behavior else "Use Godot 3D editor camera controls: hold RMB to freelook, MMB to orbit")
	camera_behavior_button.accessibility_name = camera_behavior_button.text

func slot_menu_command(pane_id: int, slot: int) -> void:
	if pane_id >= 0 and pane_id < PANE_TYPES.size():
		set_slot_type(slot, PANE_TYPES[pane_id])

func pane_orientation(type: String) -> int:
	return {"Top Grid": 2, "Front Grid": 1, "Side Grid": 0}.get(type, -1)

func create_pane(type: String) -> Control:
	var pane: Control
	if type == "Camera":
		pane = Camera.new()
		pane.host = self
		pane.radiant_camera_behavior = radiant_camera_behavior
		pane.camera_moved.connect(camera_moved)
	elif type.ends_with(" Grid"):
		pane = Graph.new()
		pane.host = self
		pane.orientation = pane_orientation(type)
	elif type == "UV":
		pane = UVPane.new()
		pane.texture_token_requested.connect(uv_texture_requested)
		pane.uv_transform_requested.connect(apply_uv_transform)
		pane.match_grid_requested.connect(match_uv_grid)
		pane.texture_axis_requested.connect(unsupported_uv_axis)
		pane.reset_requested.connect(reset_uv)
		pane.fit_requested.connect(unsupported_uv_fit)
	elif type == "Entities":
		pane = EntityPane.new()
		pane.set_session(session)
	else:
		return null
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return pane

func set_slot_type(slot: int, type: String) -> void:
	if slot < 0 or slot >= view_slots.size() or not PANE_TYPES.has(type):
		return
	if slot_views[slot] != null and slot_types[slot] == type:
		update_slot_menu(slot)
		return
	cancel_interaction()
	var old: Control = slot_views[slot]
	if is_instance_valid(old):
		view_slots[slot].remove_child(old)
		old.queue_free()
	var pane := create_pane(type)
	slot_types[slot] = type
	slot_views[slot] = pane
	view_slots[slot].add_child(pane)
	pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view_slots[slot].move_child(slot_menus[slot], -1)
	if pane.get_script() == UVPane:
		for control in pane.find_children("*", "Button", true, false):
			if control.text in ["Width", "Height", "Fit"]:
				control.disabled = true
				control.tooltip_text = "Requires a native face-fit projection operation"
	rebuild_pane_collections()
	update_slot_menu(slot)
	if session != null:
		refresh()

func update_slot_menu(slot: int) -> void:
	if slot < 0 or slot >= slot_menus.size():
		return
	var popup := slot_menus[slot].get_popup()
	for index in popup.item_count:
		popup.set_item_checked(index, popup.get_item_text(index) == slot_types[slot])
	var pane_icons := {
		"Camera": editor_icon("Camera3D"),
		"Top Grid": custom_icon("grid_xy"),
		"Front Grid": custom_icon("grid_xz"),
		"Side Grid": custom_icon("grid_yz"),
		"UV": editor_icon("Texture2D"),
		"Entities": editor_icon("Object"),
	}
	slot_menus[slot].icon = pane_icons[slot_types[slot]]
	slot_menus[slot].tooltip_text = "%s; choose pane type" % slot_types[slot]

func rebuild_pane_collections() -> void:
	cameras.clear()
	graphs.clear()
	uv_panes.clear()
	entity_panes.clear()
	for pane in slot_views:
		if not is_instance_valid(pane):
			continue
		if pane.get_script() == Camera:
			cameras.append(pane)
		elif pane.get_script() == Graph:
			graphs.append(pane)
		elif pane.get_script() == UVPane:
			uv_panes.append(pane)
		elif pane.get_script() == EntityPane:
			entity_panes.append(pane)
	graphs.sort_custom(func(a, b): return a.orientation > b.orientation)
	camera_view = cameras[0] if not cameras.is_empty() else null
	graph_a = graphs[0] if graphs.size() > 0 else null
	graph_b = graphs[1] if graphs.size() > 1 else null
	graph_c = graphs[2] if graphs.size() > 2 else null
	if not is_instance_valid(active_graph) or not graphs.has(active_graph):
		active_graph = graph_a
	for graph in graphs:
		graph.set_camera_views(cameras)
	camera_slot = slot_types.find("Camera")

func sync_view_splits(source: SplitContainer, offset: int) -> void:
	if syncing_view_splits or view_layout != 4:
		return
	syncing_view_splits = true
	(left_views if source == right_views else right_views).split_offset = offset
	syncing_view_splits = false

func apply_layout(mode: int, _legacy_camera_slot := -1) -> void:
	if not mode in [2, 3, 4]:
		return
	if workspace.is_inside_tree():
		cancel_interaction()
	view_layout = mode
	var visible_slots := [0, 2] if mode == 2 else ([0, 2, 3] if mode == 3 else [0, 1, 2, 3])
	for index in view_slots.size():
		view_slots[index].visible = visible_slots.has(index)
	if mode == 4:
		right_views.split_offset = left_views.split_offset
	var shown_graphs := visible_graphs()
	if not shown_graphs.is_empty() and not shown_graphs.has(active_graph):
		active_graph = shown_graphs[0]
	update_layout_menus()
	refresh_status()

func update_layout_menus() -> void:
	if layout_menu == null:
		return
	layout_menu.icon = editor_icon({2: "Panels2Alt", 3: "Panels3Alt", 4: "Panels4"}[view_layout])
	for index in layout_menu.get_popup().item_count:
		layout_menu.get_popup().set_item_checked(index, layout_menu.get_popup().get_item_id(index) == view_layout)
	for slot in slot_menus.size():
		update_slot_menu(slot)

func workspace_state() -> Dictionary:
	var slots: Array = []
	for index in slot_views.size():
		var pane: Control = slot_views[index]
		var pane_state := {"type": slot_types[index]}
		if pane.get_script() == Graph:
			pane_state.merge({"orientation": pane.orientation, "origin": pane.origin, "zoom": pane.zoom, "view_states": pane.view_states})
		elif pane.get_script() == Camera and pane.camera != null:
			pane_state.merge({"camera_transform": pane.camera.transform, "camera_target": pane.orbit_target, "camera_distance": pane.orbit_distance,
				"preview_sunlight": pane.preview_sunlight_enabled, "preview_environment": pane.preview_environment_enabled,
				"camera_grid_visible": pane.camera_grid_visible})
		slots.append(pane_state)
	return {
		"layout": view_layout,
		"radiant_camera_behavior": radiant_camera_behavior,
		"workspace_split": workspace.split_offset,
		"left_split": left_views.split_offset,
		"right_split": right_views.split_offset,
		"slots": slots,
	}

func restore_workspace_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	set_radiant_camera_behavior(bool(state.get("radiant_camera_behavior", false)))
	var mode := int(state.get("layout", 3))
	var slots: Array = state.get("slots", [])
	if slots.is_empty():
		# Migrate the one-camera workspace saved by the immediately preceding editor.
		var legacy_slot := int(state.get("camera_slot", 0))
		if mode != 4:
			legacy_slot = 0 if legacy_slot == 0 else 2
		var legacy_types: Array[String] = ["Top Grid", "Side Grid", "Front Grid", "Side Grid"]
		legacy_types[clampi(legacy_slot, 0, 3)] = "Camera"
		for index in 4:
			set_slot_type(index, legacy_types[index])
	else:
		for index in mini(4, slots.size()):
			set_slot_type(index, str(slots[index].get("type", slot_types[index])))
	apply_layout(mode)
	workspace.split_offset = int(state.get("workspace_split", 0))
	left_views.split_offset = int(state.get("left_split", 0))
	right_views.split_offset = int(state.get("right_split", 0))
	if slots.is_empty():
		var legacy_graphs: Array = state.get("graphs", [])
		for index in mini(graphs.size(), legacy_graphs.size()):
			var graph_state: Dictionary = legacy_graphs[index]
			graphs[index].orientation = int(graph_state.get("orientation", graphs[index].orientation))
			graphs[index].origin = graph_state.get("origin", Vector3.ZERO)
			graphs[index].zoom = float(graph_state.get("zoom", 1.0))
			graphs[index].view_states = graph_state.get("view_states", {})
			graphs[index].update_orientation_gizmo()
		if camera_view != null and state.has("camera_transform"):
			camera_view.camera.transform = state.camera_transform
			camera_view.orbit_target = state.get("camera_target", camera_view.orbit_target)
			camera_view.orbit_distance = float(state.get("camera_distance", camera_view.orbit_distance))
			camera_view.camera_transform_changed()
	else:
		for index in mini(slot_views.size(), slots.size()):
			var pane: Control = slot_views[index]
			var pane_state: Dictionary = slots[index]
			if pane.get_script() == Graph:
				pane.orientation = int(pane_state.get("orientation", pane.orientation))
				pane.origin = pane_state.get("origin", Vector3.ZERO)
				pane.zoom = float(pane_state.get("zoom", 1.0))
				pane.view_states = pane_state.get("view_states", {})
				pane.update_orientation_gizmo()
			elif pane.get_script() == Camera and pane_state.has("camera_transform"):
				pane.camera.transform = pane_state.camera_transform
				pane.orbit_target = pane_state.get("camera_target", pane.orbit_target)
				pane.orbit_distance = float(pane_state.get("camera_distance", pane.orbit_distance))
				pane.set_preview_sunlight(bool(pane_state.get("preview_sunlight", pane.preview_sunlight_enabled)))
				pane.set_preview_environment(bool(pane_state.get("preview_environment", pane.preview_environment_enabled)))
				pane.set_camera_grid_visible(bool(pane_state.get("camera_grid_visible", pane.camera_grid_visible)))
				pane.camera_transform_changed()
	refresh()

func file_menu_command(id: int) -> void:
	match id:
		0:
			file_command("open")
		1:
			file_command("save")
		2:
			file_command("save_as")

func set_session(value: RefCounted) -> void:
	cancel_interaction()
	session = value
	sync_baked_state(session)
	if not session.scene_managed:
		last_standalone = weakref(session)
	session.save_enabled = true
	session.manager = plugin.get_undo_redo()
	if not sessions.has(session):
		session.changed.connect(_session_changed.bind(session))
		session.message.connect(set_status)
		session.action_recorded.connect(retain_action)
		sessions.append(session)
	clear_cut_state()
	for pane in entity_panes:
		pane.set_session(session)
	if fallback_entity_pane != null:
		fallback_entity_pane.set_session(session)
	texture_field.text = session.texture
	sync_resolver()
	refresh()
	plugin.update_bottom_panel_sessions()

func _session_changed(origin: RefCounted) -> void:
	sync_baked_state(origin)
	if origin == session:
		if origin.change_kind == "selection":
			refresh_selection()
		elif origin.change_kind == "visibility":
			refresh_visibility()
		elif origin.change_kind == "brush_translation":
			for graph in graphs:
				graph.queue_static_redraw()
				graph.queue_selection_redraw()
			for camera in cameras:
				camera.refresh()
			refresh_status()
		else:
			refresh()
	else:
		# Global undo can dirty a retained document without changing the active view.
		refresh_status()

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
		if total > history_total_budget or (same and (local > history_session_budget or count > history_action_budget)):
			total -= item.bytes
			if same:
				local -= item.bytes
				count -= 1
			item.retire()
	tokens = tokens.filter(func(item): return item.session != null)

func cancel_interaction() -> void:
	clear_mutation_preview()
	for graph in graphs:
		graph.cancel()
	for camera in cameras:
		camera.cancel_interaction()

func set_status(text: String) -> void:
	if notice != null:
		notice.text = text

func sync_baked_state(origin: RefCounted) -> Dictionary:
	var state: Dictionary = origin.get_meta(BAKED_STATE_META, {
		"observed_text": "", "current_records": [], "records": [],
	})
	var records: Array = state.get("records", [])
	if records.size() > BAKED_STATE_RECORD_LIMIT:
		records = records.slice(records.size() - BAKED_STATE_RECORD_LIMIT)
		state.records = records
	if state.observed_text == origin.baked_text:
		origin.set_meta(BAKED_STATE_META, state)
		return state
	state.observed_text = origin.baked_text
	state.current_records = []
	if not origin.baked_text.is_empty():
		for record in records:
			if record.text == origin.baked_text:
				state.current_records.append(record)
	origin.set_meta(BAKED_STATE_META, state)
	return state

func remember_baked_state(origin: RefCounted, text: String) -> void:
	var state: Dictionary = sync_baked_state(origin)
	var records: Array = state.records
	var record := {"text": text, "epoch": origin.document.get_epoch(),
		"generation": origin.document.get_state_generation()}
	var known := false
	for existing in records:
		if existing.text == text and existing.epoch == record.epoch and existing.generation == record.generation:
			known = true
			break
	if not known:
		records.append(record)
		if records.size() > BAKED_STATE_RECORD_LIMIT:
			records.pop_front()
	state.records = records
	state.observed_text = text
	state.current_records = records.filter(func(existing): return existing.text == text)
	origin.set_meta(BAKED_STATE_META, state)

func baked_state_is_current(origin: RefCounted, state: Dictionary) -> bool:
	var epoch: int = origin.document.get_epoch()
	var generation: int = origin.document.get_state_generation()
	return state.current_records.any(func(record): return record.epoch == epoch and record.generation == generation)

func refresh_status() -> void:
	if session == null or status == null:
		return
	var baked_state: Dictionary = sync_baked_state(session)
	var baked = "meshes never built" if session.baked_text.is_empty() else ("meshes current" if baked_state_is_current(session, baked_state) else "meshes stale")
	var orientation: String = ["Side", "Front", "Top"][active_graph.orientation] if is_instance_valid(active_graph) else "No grid"
	status.text = "%s • %s • grid %.3f • %s • %s • %d selected • %d hidden" % ["UNSAVED" if session.has_unsaved_changes() else "saved", baked, session.grid, tool, orientation, session.selected.size() + session.points.size(), session.hidden_count()]
	for category in visibility_buttons:
		visibility_buttons[category].set_pressed_no_signal(session.visibility_filters[category])
	var loader = session.loader.get_ref()
	binding_label.text = "Bound: %s — %s" % [loader.name, loader.map_resource] if is_instance_valid(loader) else "Standalone document • Select a TBLoader, then explicitly Bind"
	update_loader_action_state()
	changing_document_tabs = true
	document_tabs.clear_tabs()
	for origin in sessions:
		if origin.scene_managed and origin.scene.get_ref() == null:
			continue
		var filename: String = origin.document.get_path().get_file()
		if not origin.recovery_source.is_empty():
			filename = "Recovered " + origin.recovery_source.get_file()
		document_tabs.add_tab((filename if filename else "Untitled") + (" *" if origin.has_unsaved_changes() else ""))
		var index = document_tabs.tab_count - 1
		document_tabs.set_tab_metadata(index, weakref(origin))
		document_tabs.set_tab_button_icon(index, editor_icon("Close"))
		var path: String = origin.document.get_path()
		document_tabs.set_tab_tooltip(index, path if not path.is_empty() else "Untitled Map document")
		if origin == session:
			document_tabs.current_tab = index
	document_tabs.add_tab("+")
	document_tabs.set_tab_tooltip(document_tabs.tab_count - 1, "New Map document")
	changing_document_tabs = false

func document_tab_changed(index: int) -> void:
	if changing_document_tabs or index < 0 or index >= document_tabs.tab_count:
		return
	if index == document_tabs.tab_count - 1:
		set_session(Session.new())
		return
	var reference = document_tabs.get_tab_metadata(index)
	var origin = reference.get_ref() if reference is WeakRef else null
	if origin != null and origin != session:
		set_session(origin)

func close_document_tab(index: int) -> void:
	if index < 0 or index >= document_tabs.tab_count - 1:
		return
	var reference = document_tabs.get_tab_metadata(index)
	var origin = reference.get_ref() if reference is WeakRef else null
	if origin == null or not sessions.has(origin):
		return
	if origin.has_unsaved_changes():
		if origin != session:
			set_session(origin)
		request_replace(close_document.bind(origin))
	else:
		close_document(origin)

func close_document(origin: RefCounted) -> void:
	if origin == null or not sessions.has(origin):
		return
	var replacement = session if session != origin else adjacent_session(origin)
	sessions.erase(origin)
	for id in scene_sessions.keys():
		if scene_sessions[id] == origin:
			scene_sessions.erase(id)
	if last_standalone.get_ref() == origin:
		last_standalone = weakref(null)
	for token in tokens:
		if token.session == origin:
			token.retire()
	tokens = tokens.filter(func(token): return token.session != null)
	origin.dispose()
	discard_on_replace = null
	set_session(replacement if replacement != null else Session.new())

func adjacent_session(origin: RefCounted) -> RefCounted:
	var index := sessions.find(origin)
	for offset in range(1, sessions.size()):
		for candidate_index in [index - offset, index + offset]:
			if candidate_index < 0 or candidate_index >= sessions.size():
				continue
			var candidate = sessions[candidate_index]
			if not candidate.scene_managed or candidate.scene.get_ref() != null:
				return candidate
	return null

func refresh() -> void:
	if session == null:
		return
	for graph in graphs:
		graph.queue_view_redraw()
	sync_texture_sizes()
	for camera in cameras:
		camera.refresh()
	refresh_status()
	var face_selection := face_selection_snapshot()
	refresh_uv(face_selection)
	sync_material_selection(face_selection)
	for pane in entity_panes:
		pane.refresh()
	if inspector != null and inspector.visible:
		fallback_entity_pane.refresh()

func refresh_selection() -> void:
	for graph in graphs:
		graph.queue_selection_redraw()
	for camera in cameras:
		camera.refresh_selection()
	if tool == "Cut" and cut_plane_points.size() == 3:
		preview_clip(false)
	refresh_status()
	var face_selection := face_selection_snapshot()
	refresh_uv(face_selection)
	sync_material_selection(face_selection)
	for pane in entity_panes:
		pane.refresh_selection()
	if inspector != null and inspector.visible:
		fallback_entity_pane.refresh_selection()

func refresh_visibility() -> void:
	for graph in graphs:
		graph.queue_view_redraw()
	for camera in cameras:
		camera.refresh()
	refresh_status()
	var face_selection := face_selection_snapshot()
	refresh_uv(face_selection)
	sync_material_selection(face_selection)

func set_tool(value: String) -> void:
	var leaving_cut := tool == "Cut" and value != "Cut"
	cancel_interaction()
	if leaving_cut:
		clear_cut_state()
	tool = value
	if session != null:
		session.components.clear()
		session._sync_selection_generation()
	for key in tool_buttons:
		tool_buttons[key].button_pressed = key == tool
	if session != null:
		session.notify_changed("selection")
	else:
		refresh()

func route_key(event: InputEventKey, graph: Control) -> bool:
	if not event.pressed or event.echo or cameras.any(func(camera): return camera.flying):
		return false
	var focus = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or browser.has_browser_focus() or file_dialog.visible or dirty_dialog.visible or inspector.visible:
		return false
	var plain_shortcut := not event.ctrl_pressed and not event.alt_pressed and not event.shift_pressed and not event.meta_pressed
	if is_visible_in_tree() and plain_shortcut and event.keycode in [KEY_S, KEY_N]:
		if event.keycode == KEY_S:
			plugin.toggle_uv()
		else:
			toggle_entities()
		return true
	if not is_visible_in_tree() or (not graphs.has(focus) and not cameras.has(focus)):
		return false
	if graphs.has(focus):
		graph = focus
	elif cameras.has(focus):
		graph = null
	if is_instance_valid(graph):
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
				if is_instance_valid(graph):
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
				flip_clip()
			_:
				if key >= KEY_3 and key <= KEY_9:
					make_prism(key - KEY_0)
				else:
					return false
	else:
		match key:
			KEY_ESCAPE:
				if is_instance_valid(graph) and graph.gesture != "":
					graph.cancel()
				elif cameras.any(func(camera): return camera.camera_gesture != ""):
					cancel_interaction()
				elif not session.selected.is_empty() or not session.points.is_empty() or not session.components.is_empty():
					session.select(PackedInt64Array())
				elif tool != "Brush":
					set_tool("Brush")
				else:
					session.select(PackedInt64Array())
			KEY_H:
				session.hide_selection(event.shift_pressed)
			KEY_SPACE:
				if is_instance_valid(graph):
					clone_selection(graph.axes().x)
			KEY_DELETE, KEY_BACKSPACE:
				delete_selection()
			KEY_X:
				set_tool("Brush" if tool == "Cut" else "Cut")
			KEY_Q:
				set_tool("Brush")
			KEY_R:
				set_tool("Rotate")
			KEY_F:
				set_tool("Face")
			KEY_G:
				if cameras.has(focus):
					focus.toggle_surface_grid()
				else:
					return false
			KEY_E:
				set_tool("Edge")
			KEY_V:
				set_tool("Vertex")
			KEY_ENTER:
				apply_clip(event.shift_pressed)
			KEY_BRACKETLEFT:
				session.grid = maxf(0.125, session.grid / 2)
				for view in graphs:
					view.queue_static_redraw()
			KEY_BRACKETRIGHT:
				session.grid = minf(1024, session.grid * 2)
				for view in graphs:
					view.queue_static_redraw()
			_:
				if key >= KEY_1 and key <= KEY_9:
					session.grid = pow(2, key - KEY_1)
					for view in graphs:
						view.queue_static_redraw()
				else:
					return false
	for view in graphs:
		view.queue_selection_redraw()
	refresh_status()
	return true

func active_camera_direction() -> Vector3:
	var focus = get_viewport().gui_get_focus_owner()
	if cameras.has(focus):
		return focus.camera_map_direction()
	return camera_view.camera_map_direction() if is_instance_valid(camera_view) else Vector3.BACK

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
			return session.translate_brushes(session.selected, movement)
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
	if not is_instance_valid(active_graph):
		set_status("A grid pane is required to choose the prism axis.")
		return
	session.transact("Make %d-sided map prism" % sides, func():
		for id in session.selected:
			var result: Dictionary = session.document.make_prism(id, sides, active_graph.orientation)
			if not result.ok:
				return result
		return session.success())

func merge_selection() -> void:
	var ids: PackedInt64Array = session.selected.duplicate()
	session.transact("Merge map brushes", func():
		var result: Dictionary = session.document.merge_brushes(ids)
		if result.ok and result.changed:
			session.select(PackedInt64Array([int(result.value)]))
		return result)

func configure_browser(root: String) -> void:
	var loader = session.loader.get_ref()
	if is_instance_valid(loader) and root != loader.texture_path:
		set_status("Bound materials use the loader's Texture Path; edit it in the scene Inspector.")
		root = loader.texture_path
	else:
		session.texture_root = root
	sync_resolver(true)

func sync_resolver(force = false) -> void:
	var loader = session.loader.get_ref()
	var root: String = loader.texture_path if is_instance_valid(loader) else session.texture_root
	var config: Array = [root]
	if is_instance_valid(loader):
		config.append_array([loader.get_instance_id(), loader.texture_material_template, loader.texture_material_texture_path])
	if not force and config == resolver_config:
		return
	resolver_config = config
	if is_instance_valid(loader):
		var template: Material = loader.texture_material_template
		if template != null and not template.changed.is_connected(refresh_materials):
			template.changed.connect(refresh_materials)
	texture_root.text = root
	var probe = ClassDB.instantiate("TBLoader")
	var direct: bool = probe.has_method("resolve_material")
	probe.free()
	browser.configure(EditorInterface.get_resource_filesystem(), root, null, direct)
	refresh_materials()

func resolve_token(token: String) -> Dictionary:
	var resolver = session.loader.get_ref()
	var temporary = not is_instance_valid(resolver)
	if temporary:
		resolver = ClassDB.instantiate("TBLoader")
		resolver.texture_path = session.texture_root
	var result: Dictionary = resolver.call("resolve_material", token) if resolver.has_method("resolve_material") else {}
	if temporary:
		resolver.free()
	return result

func material_selected(_resource: Resource, path: String, token: String, mapping: Dictionary) -> void:
	sync_resolver()
	if not mapping.get("resolved", false):
		set_status("Cannot assign resource outside the loader Texture Path: " + path)
		return
	var result = resolve_token(token)
	if not result.get("resolved", false) or result.get("resource_path", "") != path:
		set_status("Cannot resolve selected resource: " + path)
		return
	texture_field.text = token
	session.texture = token
	var face_selection := face_selection_snapshot()
	if not face_selection.targets.is_empty():
		assign_texture(face_selection.targets)
		set_status("%s → %s • Applied to selection" % [path, token])
	else:
		set_status("%s → %s • Select geometry to apply" % [path, token])

func preview_opacity(render_category: String) -> float:
	return {"caulk": 0.26, "clip": 0.36, "entity": 0.48}.get(render_category, 1.0)

func preview_material(token: String, render_category := "opaque") -> Material:
	sync_resolver()
	var cache_key := token if render_category == "opaque" else token + "|" + render_category
	if material_cache.has(cache_key):
		return material_cache[cache_key]
	var material: Material
	var resolved = resolve_token(token)
	texture_sizes[token] = resolved.get("texture_size", Vector2i.ONE)
	if resolved.get("material") is Material:
		material = resolved.material.duplicate()
	if material == null:
		material = StandardMaterial3D.new()
		material.albedo_color = Color("8ba4b6")
	if material is BaseMaterial3D:
		material.vertex_color_use_as_albedo = true
		if render_category != "opaque":
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
			material.albedo_color.a *= preview_opacity(render_category)
	material_cache[cache_key] = material
	return material

func refresh_materials() -> void:
	material_cache.clear()
	texture_sizes.clear()
	material_generation += 1
	if session == null:
		return
	sync_texture_sizes()
	for camera in cameras:
		if is_instance_valid(camera) and camera.is_inside_tree():
			camera.refresh()

func queue_material_refresh() -> void:
	if not is_node_ready() or is_queued_for_deletion():
		return
	if not has_meta("material_refresh_queued"):
		set_meta("material_refresh_queued", true)
		call_deferred("flush_material_refresh")

func flush_material_refresh() -> void:
	remove_meta("material_refresh_queued")
	refresh_materials()
	sync_material_selection()

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
	var selection := face_selection_snapshot()
	return selection.get("requested_targets", selection.targets)

func face_selection_snapshot() -> Dictionary:
	var targets: Array = []
	if not session.components.is_empty():
		for component in session.components:
			if component.kind != "face":
				continue
			targets.append(component.duplicate())
	else:
		for id in session.selected:
			var brush: Dictionary = session.brush(id)
			for face in brush.faces:
				targets.append({"brush_id": id, "index": face.index, "topology_revision": brush.topology_revision, "kind": "face"})
	var result: Dictionary = session.document.summarize_faces(targets)
	return result.value if result.ok else {"targets": [], "requested_targets": targets, "textures": PackedStringArray(),
		"unique_textures": PackedStringArray(), "first": {}, "texture": "", "valve": false, "mixed": false}

func sync_material_selection(selection: Dictionary = {}) -> void:
	if browser == null or session == null:
		return
	if selection.is_empty():
		selection = face_selection_snapshot()
	var selected_tokens: PackedStringArray = selection.unique_textures
	if selected_tokens.size() != 1:
		browser.highlight_path("")
		if selected_tokens.size() > 1:
			uv_label.text += " • Mixed materials"
		return
	var resolved := selection_material_resolution(selection, selected_tokens[0])
	browser.highlight_path(resolved.get("resource_path", "") if resolved.get("resolved", false) else "")

func assign_texture(targets = null) -> void:
	session.texture = texture_field.text.strip_edges()
	if targets == null:
		targets = face_targets()
	var component_mode: bool = not session.components.is_empty()
	session.transact("Assign map material", func():
		if not component_mode:
			return session.document.set_brush_texture(session.selected, session.texture)
		var edits: Array = []
		for target in targets:
			edits.append({"brush_id": target.brush_id, "face": target.index,
				"topology_revision": target.topology_revision, "texture": session.texture})
		return session.apply_face_edits(edits))
	refresh_materials()

func refresh_uv(selection: Dictionary = {}) -> void:
	if selection.is_empty():
		selection = face_selection_snapshot()
	var targets: Array = selection.targets
	var valve: bool = selection.valve
	var mixed: bool = selection.mixed
	var first: Dictionary = selection.first
	var texture: String = selection.texture
	uv_label.text = "Valve / mixed projection: UV editing unavailable" if valve else ("Mixed UVs — edits replace selected values" if mixed else "Classic UV • %d faces" % targets.size())
	for field in uv_fields:
		field.editable = not valve
	if not first.is_empty():
		var values = [first.shift.x, first.shift.y, first.rotation, first.scale.x, first.scale.y]
		for i in values.size():
			uv_fields[i].set_value_no_signal(values[i])
	var pane_state: Dictionary = {
		"texture": texture,
		"shift": first.get("shift", Vector2.ZERO),
		"rotation": first.get("rotation", 0.0),
		"scale": first.get("scale", Vector2.ONE),
		"projection": first.get("projection", "classic"),
		"mixed": mixed,
		"editable": not targets.is_empty(),
		"texture_editable": not targets.is_empty(),
	}
	var preview := uv_preview(targets, texture, selection)
	pane_state.merge(preview)
	bottom_uv_pane.set_state(pane_state)
	for pane in uv_panes:
		pane.set_state(pane_state)

func face_texture(target: Dictionary) -> String:
	var brush: Dictionary = session.brush(target.brush_id)
	if target.index >= 0 and target.index < brush.get("faces", []).size():
		var indexed_face: Dictionary = brush.faces[target.index]
		if indexed_face.index == target.index:
			return indexed_face.texture
	for face in brush.get("faces", []):
		if face.index == target.index:
			return face.texture
	return ""

func selection_material_resolution(selection: Dictionary, texture: String) -> Dictionary:
	if selection.get("resolved_token", "") != texture:
		selection.resolved_token = texture
		selection.resolved_material = resolve_token(texture)
	return selection.resolved_material

func uv_preview(targets: Array, texture: String, selection: Dictionary = {}) -> Dictionary:
	var triangles: PackedVector2Array = session.document.get_face_preview_uvs(targets, texture) if not targets.is_empty() and not texture.is_empty() else PackedVector2Array()
	var resolved := selection_material_resolution(selection, texture) if not texture.is_empty() else {}
	var material: Material = resolved.get("material")
	var preview_texture: Texture2D
	if material is BaseMaterial3D:
		preview_texture = material.albedo_texture
	elif material != null:
		var loader = session.loader.get_ref()
		if is_instance_valid(loader):
			var candidate = material.get(loader.texture_material_texture_path)
			if candidate is Texture2D:
				preview_texture = candidate
	return {"texture_resource": preview_texture, "triangle_uvs": triangles}

func apply_uv() -> void:
	var shift = Vector2(uv_fields[0].value, uv_fields[1].value)
	var rotation = uv_fields[2].value
	var scale_value = Vector2(uv_fields[3].value, uv_fields[4].value)
	apply_uv_transform(shift, rotation, scale_value)

func apply_uv_transform(shift: Vector2, rotation: float, scale_value: Vector2, targets = null) -> void:
	if targets == null:
		targets = face_targets()
	session.transact("Edit map UV", func():
		var edits: Array = []
		for target in targets:
			edits.append({"brush_id": target.brush_id, "face": target.index,
				"topology_revision": target.topology_revision,
				"uv": {"shift": shift, "rotation": rotation, "scale": scale_value}})
		return session.apply_face_edits(edits))

func uv_texture_requested(token: String) -> void:
	texture_field.text = token
	assign_texture()

func match_uv_grid() -> void:
	var targets := face_targets()
	if targets.is_empty():
		return
	var result: Dictionary = session.document.get_face_uv(targets[0].brush_id, targets[0].index, targets[0].topology_revision)
	if result.ok:
		var uv: Dictionary = result.value
		apply_uv_transform(uv.shift.snapped(Vector2.ONE * session.grid), uv.rotation, uv.scale, targets)

func reset_uv() -> void:
	apply_uv_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func unsupported_uv_axis(_axis: String) -> void:
	set_status("Width and Height fitting require native face projection support.")

func unsupported_uv_fit(_scale: Vector2) -> void:
	set_status("UV fitting requires native face projection support.")

func build_dialogs() -> void:
	file_dialog = FileDialog.new()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.map ; Quake map"])
	file_dialog.size = Vector2i(800, 550)
	add_child(file_dialog)
	file_dialog.file_selected.connect(file_selected)
	file_dialog.canceled.connect(func(): pending = Callable(); save_then_pending = false; discard_on_replace = null)
	dirty_dialog = ConfirmationDialog.new()
	dirty_dialog.title = "Unsaved map"
	dirty_dialog.dialog_text = "Save changes to the current .map before continuing?"
	dirty_dialog.ok_button_text = "Save"
	dirty_dialog.add_button("Discard", false, "discard")
	dirty_dialog.confirmed.connect(func(): save_then_pending = true; file_command("save"))
	dirty_dialog.custom_action.connect(func(_action): discard_on_replace = session; dirty_dialog.hide(); run_pending())
	dirty_dialog.canceled.connect(func(): pending = Callable())
	add_child(dirty_dialog)
	inspector = Window.new()
	inspector.hide()
	inspector.transient = true
	inspector.title = "Map entities — ordered key / values"
	inspector.size = Vector2i(660, 480)
	inspector.close_requested.connect(inspector.hide)
	add_child(inspector)
	fallback_entity_pane = EntityPane.new()
	fallback_entity_pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inspector.add_child(fallback_entity_pane)
	entity_list = fallback_entity_pane.property_tree
	entity_key = fallback_entity_pane.key_field
	entity_value = fallback_entity_pane.value_field
	entity_class = fallback_entity_pane.class_field

func show_entities() -> void:
	cancel_interaction()
	var targets: PackedInt64Array = session.entity_targets()
	plugin.show_entities_panel()
	if plugin.entities_pane != null and not targets.is_empty():
		plugin.entities_pane.set_selected_entity_id(targets[0])

func toggle_entities() -> void:
	cancel_interaction()
	var targets: PackedInt64Array = session.entity_targets()
	if plugin.toggle_entities_panel() and plugin.entities_pane != null and not targets.is_empty():
		plugin.entities_pane.set_selected_entity_id(targets[0])

func refresh_entities() -> void:
	var targets: PackedInt64Array = session.entity_targets()
	fallback_entity_pane.set_session(session)
	if not targets.is_empty():
		fallback_entity_pane.set_selected_entity_id(targets[0])
	inspector.title = "Map entities — %d target(s); Set edits first key, Remove deletes all duplicates" % targets.size()

func entity_row_selected() -> void:
	fallback_entity_pane._property_selected()

func edit_property(remove: bool) -> void:
	var ids: PackedInt64Array = session.entity_targets()
	if ids.is_empty():
		return
	fallback_entity_pane.set_selected_entity_id(ids[0])
	if remove:
		fallback_entity_pane._remove_property()
	else:
		fallback_entity_pane._set_property()

func create_point() -> void:
	var before: PackedInt64Array = PackedInt64Array(session.entity_data().map(func(entity): return entity.id))
	fallback_entity_pane._create_point()
	for entity in session.entity_data():
		if not before.has(entity.id):
			session.select(PackedInt64Array(), PackedInt64Array([entity.id]))
			break

func group_brushes() -> void:
	fallback_entity_pane._group_selected()

func delete_entities(delete_brushes: bool) -> void:
	if delete_brushes:
		var ids: PackedInt64Array = session.entity_targets()
		session.transact("Delete map entities", func(): return session.document.delete_entities(ids, true))
	else:
		fallback_entity_pane._delete_entity()

func request_replace(callback: Callable) -> void:
	cancel_interaction()
	discard_on_replace = null
	pending = callback
	if session.has_unsaved_changes():
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
			set_session(Session.new())
		"open":
			show_file_dialog("open")
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
	if operation == "save" and not session.recovery_source.is_empty():
		file_dialog.current_file = session.recovery_source.get_file()
	if DisplayServer.get_name() == "headless":
		file_dialog.popup(Rect2i(Vector2i.ZERO, file_dialog.size))
	else:
		file_dialog.popup_centered()

func file_selected(path: String) -> void:
	if dialog_operation == "open":
		open_path(path)
	elif save_path(path) and save_then_pending:
		run_pending()

func open_path(path: String) -> bool:
	var existing = find_path_session(path)
	if existing != null:
		set_session(existing)
		set_status("Already open: %s" % path)
		return true
	var candidate = Session.new()
	var result: Dictionary = candidate.document.load_map(path)
	if not session.report(result):
		discard_on_replace = null
		return false
	replace_session(candidate)
	refresh_materials()
	set_status("Opened %s" % path)
	return true

func find_path_session(path: String, binding_loader: Node = null) -> RefCounted:
	if path.is_empty():
		return null
	if same_path(session.document.get_path(), path):
		var active_loader = session.loader.get_ref()
		if binding_loader == null or active_loader == null or active_loader == binding_loader:
			return session
	for origin in sessions:
		if origin == null or not same_path(origin.document.get_path(), path):
			continue
		if origin.scene_managed and origin.scene.get_ref() == null:
			continue
		var origin_loader = origin.loader.get_ref()
		if binding_loader == null or origin_loader == null or origin_loader == binding_loader:
			return origin
	return null

func set_scene_active(active: bool) -> void:
	scene_active = active
	if active:
		queue_scene_discovery()

func queue_scene_discovery() -> void:
	if not scene_active or shutting_down or discovery_queued:
		return
	discovery_queued = true
	call_deferred("discover_scene_loaders")

func discover_scene_loaders() -> void:
	if not discovery_queued:
		return
	discovery_queued = false
	if not scene_active or shutting_down or session == null:
		return
	var root = EditorInterface.get_edited_scene_root()
	discovered_scene_id = root.get_instance_id() if root != null else 0
	var all_loaders: Array[Node] = []
	if root is TBLoader:
		all_loaders.append(root)
	if root != null:
		for node in root.find_children("*", "", true, false):
			if node is TBLoader:
				all_loaders.append(node)
	watch_scene_loaders(all_loaders)
	var mapped: Array[Node] = all_loaders.filter(func(loader): return not loader.map_resource.is_empty())
	var previous_loader = session.loader.get_ref()
	var next_sessions: Dictionary = {}
	for loader in mapped:
		var id = loader.get_instance_id()
		var origin: RefCounted = scene_sessions.get(id)
		if origin == null or origin.loader.get_ref() != loader or not same_path(origin.document.get_path(), loader.map_resource):
			if origin != null:
				retire_scene_session(origin)
			origin = create_scene_session(loader, root)
		if origin != null:
			next_sessions[id] = origin
	for id in scene_sessions:
		if not next_sessions.has(id):
			retire_scene_session(scene_sessions[id])
	scene_sessions = next_sessions
	if previous_loader != null and scene_sessions.has(previous_loader.get_instance_id()):
		if session != scene_sessions[previous_loader.get_instance_id()]:
			set_session(scene_sessions[previous_loader.get_instance_id()])
	elif not mapped.is_empty() and scene_sessions.has(mapped[0].get_instance_id()):
		if session != scene_sessions[mapped[0].get_instance_id()]:
			set_session(scene_sessions[mapped[0].get_instance_id()])
	elif session.scene_managed:
		var standalone = last_standalone.get_ref()
		if standalone == null:
			standalone = Session.new()
		set_session(standalone)
	rebuild_scene_tabs(root, mapped)

func watch_scene_loaders(loaders: Array[Node]) -> void:
	var current: Dictionary = {}
	for loader in loaders:
		var id = loader.get_instance_id()
		current[id] = weakref(loader)
		if not loader.map_resource_changed.is_connected(loader_map_changed):
			loader.map_resource_changed.connect(loader_map_changed)
		if not loader.renamed.is_connected(loader_renamed):
			loader.renamed.connect(loader_renamed)
	for id in watched_loaders:
		if current.has(id):
			continue
		var loader = watched_loaders[id].get_ref()
		if is_instance_valid(loader):
			if loader.map_resource_changed.is_connected(loader_map_changed):
				loader.map_resource_changed.disconnect(loader_map_changed)
			if loader.renamed.is_connected(loader_renamed):
				loader.renamed.disconnect(loader_renamed)
	watched_loaders = current

func loader_map_changed(_path: String) -> void:
	queue_scene_discovery()

func loader_renamed() -> void:
	queue_scene_discovery()

func create_scene_session(loader: Node, root: Node) -> RefCounted:
	var candidate = find_path_session(loader.map_resource, loader)
	if candidate == null:
		candidate = Session.new()
		var result: Dictionary = candidate.document.load_map(loader.map_resource)
		if not session.report(result):
			candidate.dispose()
			return null
		candidate.scene_managed = true
	candidate.loader = weakref(loader)
	candidate.scene = weakref(root)
	candidate.was_bound = true
	return candidate

func retire_scene_session(origin: RefCounted) -> void:
	origin.loader = weakref(null)
	origin.scene = weakref(null)
	origin.was_bound = false

func rebuild_scene_tabs(root: Node, loaders: Array[Node]) -> void:
	changing_scene_tabs = true
	scene_tabs.clear_tabs()
	for loader in loaders:
		var id = loader.get_instance_id()
		if not scene_sessions.has(id):
			continue
		var relative = str(root.get_path_to(loader))
		var label = str(root.name) if relative == "." else relative
		scene_tabs.add_tab(label)
		var index = scene_tabs.tab_count - 1
		scene_tabs.set_tab_metadata(index, weakref(scene_sessions[id]))
		scene_tabs.set_tab_tooltip(index, "%s — %s" % [label, loader.map_resource])
		if scene_sessions[id] == session:
			scene_tabs.current_tab = index
	scene_tabs.visible = scene_tabs.tab_count >= 2
	changing_scene_tabs = false

func scene_tab_changed(index: int) -> void:
	if changing_scene_tabs or index < 0 or index >= scene_tabs.tab_count:
		return
	if scene_tabs.current_tab != index:
		changing_scene_tabs = true
		scene_tabs.current_tab = index
		changing_scene_tabs = false
	var origin = scene_tabs.get_tab_metadata(index).get_ref()
	if origin != null and origin != session:
		set_session(origin)

func open_scene_map() -> void:
	queue_scene_discovery()

func replace_session(candidate: RefCounted) -> void:
	if discard_on_replace != null and discard_on_replace == session:
		discard_on_replace.save_enabled = false
	discard_on_replace = null
	set_session(candidate)

func save_path(path: String, defer_bake = false) -> bool:
	var result: Dictionary = session.document.save_map(path)
	if not session.report(result):
		set_status(notice.text + " • Save As to another path or reopen the external version; current edits are retained.")
		return false
	session.recovery_source = ""
	set_status("Saved %s" % session.document.get_path())
	refresh_status()
	# Coalesce Save All notifications and avoid reentering a texture import.
	scan_delay = 0.5
	if rebuild_on_save.button_pressed and valid_binding() and same_path(session.loader.get_ref().map_resource, session.document.get_path()):
		if defer_bake:
			bake_after_external_save.call_deferred(session)
		else:
			bake()
	return true

func bake_after_external_save(origin: RefCounted) -> void:
	# EditorNode serializes before _save_external_data, then clears scene dirty.
	# Run after that entire stack and require another scene save for this bake.
	if not shutting_down and is_inside_tree() and valid_binding(origin):
		EditorInterface.mark_scene_as_unsaved()
		bake_origin(origin)

func bind_selected() -> void:
	bind_loader(plugin.editing_loader.get_ref())

func update_loader_action_state() -> void:
	if loader_actions.is_empty():
		return
	var selected = plugin.editing_loader.get_ref()
	var root = EditorInterface.get_edited_scene_root()
	var can_bind: bool = is_instance_valid(selected) and selected is TBLoader and root != null and (root == selected or root.is_ancestor_of(selected))
	loader_actions.BindLoader.disabled = not can_bind
	var bound := valid_binding()
	loader_actions.DetachLoader.disabled = not bound
	loader_actions.UpdateLoaderPath.disabled = not bound
	loader_actions.BuildMeshes.disabled = not bound
	rebuild_on_save.disabled = not bound

func bind_loader(loader: Node) -> void:
	var root = EditorInterface.get_edited_scene_root()
	if not is_instance_valid(loader) or not loader is TBLoader or root == null or not root.is_ancestor_of(loader) and root != loader:
		set_status("Choose a TBLoader in the current scene before binding.")
		return
	var id = loader.get_instance_id()
	if scene_sessions.has(id) and scene_sessions[id].loader.get_ref() == loader:
		set_session(scene_sessions[id])
		return
	var origin: RefCounted
	if loader.map_resource.is_empty():
		origin = Session.new()
	else:
		origin = find_path_session(loader.map_resource, loader)
		if origin == null:
			origin = Session.new()
			var result: Dictionary = origin.document.load_map(loader.map_resource)
			if not session.report(result):
				origin.dispose()
				return
	origin.loader = weakref(loader)
	origin.scene = weakref(root)
	origin.was_bound = true
	set_session(origin)
	if not loader.map_resource.is_empty():
		scene_sessions[id] = origin
	configure_browser(loader.texture_path)
	refresh()
	queue_scene_discovery()

func detach() -> void:
	session.loader = weakref(null)
	session.scene = weakref(null)
	session.was_bound = false
	session.baked_text = ""
	sync_baked_state(session)
	sync_resolver(true)
	refresh_status()

func valid_binding(origin: RefCounted = null) -> bool:
	if origin == null:
		origin = session
	var loader = origin.loader.get_ref()
	var root = EditorInterface.get_edited_scene_root()
	return is_instance_valid(loader) and root != null and origin.scene.get_ref() == root and (root == loader or root.is_ancestor_of(loader))

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
	return bake_origin(session)

func bake_origin(origin: RefCounted) -> bool:
	if not valid_binding(origin):
		set_status("Build Meshes requires the explicitly bound loader in the current scene.")
		return false
	var loader = origin.loader.get_ref()
	if origin.document.is_dirty() or not same_path(loader.map_resource, origin.document.get_path()):
		set_status("Save first; use Update loader path explicitly if Save As changed the filename.")
		return false
	if not loader.has_method("build_meshes_checked"):
		set_status("Map saved. Checked Build Meshes API unavailable in this build; mesh build deferred.")
		return false
	var disk = ClassDB.instantiate("TBMapDocument")
	var loaded: Dictionary = disk.load_map(origin.document.get_path())
	if not session.report(loaded):
		return false
	if disk.export_text().value != origin.document.export_text().value:
		set_status("External change: saved file no longer matches this session; mesh build cancelled.")
		return false
	if not commit_bake(loader, origin):
		return false
	refresh_status()
	set_status("Map saved and meshes built successfully; save the Godot scene to persist generated nodes.")
	return true

func commit_bake(loader: Node, origin: RefCounted = null) -> bool:
	var root = EditorInterface.get_edited_scene_root()
	if root == null or not is_instance_valid(loader) or (root != loader and not root.is_ancestor_of(loader)):
		set_status("Build Meshes cancelled: loader is not in the current scene.")
		return false
	if not loader.has_method("build_meshes_checked"):
		set_status("Checked Build Meshes API unavailable in this build; mesh build deferred.")
		return false
	var before: Node = BakeAction.detach_children(loader)
	var result: Dictionary = loader.call("build_meshes_checked")
	if not session.report(result):
		BakeAction.attach_children(loader, before, root)
		before.free()
		return false
	plugin.add_steam_audio_geometry(loader)
	# The checked builder sees an intentionally empty loader, so account for a
	# previous subtree when deciding whether this scene operation changed.
	var changed: bool = result.changed or before.get_child_count() > 0
	var token = BakeAction.new()
	token.loader = weakref(loader)
	token.scene = weakref(root)
	token.session = weakref(origin)
	token.detached = before
	token.before_text = origin.baked_text if origin != null else ""
	token.after_text = origin.document.export_text().value if origin != null else ""
	token.reporter = Callable(self, "set_status")
	last_bake_action = weakref(token)
	if changed:
		var manager = plugin.get_undo_redo()
		manager.create_action("Build TBLoader meshes", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
		manager.add_do_method(token, "restore", true)
		manager.add_undo_method(token, "restore", false)
		manager.add_do_reference(token)
		manager.add_undo_reference(token)
		manager.commit_action(false)
	if origin != null:
		origin.baked_text = token.after_text
		remember_baked_state(origin, token.after_text)
	EditorInterface.mark_scene_as_unsaved()
	plugin.refresh_materials()
	set_status("Selected loader meshes built successfully; scene marked unsaved.")
	return true

func save_all(defer_bake = false) -> void:
	# Retained background sessions can become dirty via global undo. Save those
	# synchronously too; never redirect a save or bake through the selected loader.
	var untitled: RefCounted
	for origin in sessions:
		if origin == null or not origin.save_enabled or not origin.has_unsaved_changes():
			continue
		var path: String = origin.document.get_path()
		if path.is_empty():
			untitled = origin
		elif origin == session:
			save_path(path, defer_bake)
		else:
			if session.report(origin.document.save_map(path)) and rebuild_on_save.button_pressed and valid_binding(origin) and same_path(origin.loader.get_ref().map_resource, path):
				if defer_bake:
					bake_after_external_save.call_deferred(origin)
				else:
					bake_origin(origin)
	if untitled != null:
		set_session(untitled)
		file_command("save")
	refresh_status()

func unsaved_status() -> String:
	var paths = PackedStringArray()
	for origin in sessions:
		if origin != null and origin.save_enabled and origin.has_unsaved_changes():
			var path: String = origin.document.get_path()
			paths.append(path if path else "Untitled (use Radiant > Save As before exiting)")
	return "Unsaved Map documents: " + ", ".join(paths) if not paths.is_empty() else ""

func _process(delta: float) -> void:
	if scene_active:
		var root = EditorInterface.get_edited_scene_root()
		var root_id = root.get_instance_id() if root != null else 0
		if root_id != discovered_scene_id:
			queue_scene_discovery()
	if session != null and session.was_bound and not valid_binding():
		detach()
	if session != null:
		sync_resolver()
	if scan_delay >= 0:
		scan_delay = maxf(0, scan_delay - delta)
		var filesystem = EditorInterface.get_resource_filesystem()
		if scan_delay == 0 and not filesystem.is_scanning() and not filesystem.is_importing():
			scan_delay = -1
			filesystem.scan()

func _exit_tree() -> void:
	cancel_interaction()

func shutdown() -> void:
	# The editor adapter also reparents this control during registration. Only
	# explicit plugin teardown disposes documents; tree exit alone is not teardown.
	cancel_interaction()
	shutting_down = true
	for token in tokens:
		token.retire()
	tokens.clear()
	material_cache.clear()
	for origin in sessions:
		origin.dispose()
	sessions.clear()
	resolver_config.clear()
	texture_sizes.clear()
	session = null

func store_recovery() -> void:
	cancel_interaction()
	var records: Array = []
	var active_tab := -1
	for origin in sessions:
		if origin == null or not origin.save_enabled:
			continue
		var record: Dictionary
		if origin.has_unsaved_changes():
			record = {"type": "recovery", "text": origin.document.export_text().value,
				"source": origin.recovery_source if not origin.recovery_source.is_empty() else origin.document.get_path(),
				"root": origin.texture_root, "grid": origin.grid, "texture": origin.texture}
		elif not origin.scene_managed and not origin.document.get_path().is_empty():
			record = {"type": "path", "path": origin.document.get_path()}
		else:
			continue
		if origin == session:
			active_tab = records.size()
		records.append(record)
	if active_tab < 0 and not records.is_empty():
		# If the active scene/pristine tab is intentionally omitted, prefer the
		# persisted tab that occupied the same position, then the previous one.
		var active_session_index := sessions.find(session)
		var persisted_before := 0
		for index in maxi(active_session_index, 0):
			var origin = sessions[index]
			if origin != null and origin.save_enabled and (origin.has_unsaved_changes()
					or not origin.scene_managed and not origin.document.get_path().is_empty()):
				persisted_before += 1
		active_tab = mini(persisted_before, records.size() - 1)
	var manifest := {"version": RECOVERY_VERSION, "active_tab": active_tab, "tabs": records}
	# Plain data fallback survives plugin disable even if recovery storage fails.
	EditorInterface.get_base_control().set_meta(RECOVERY_META, manifest)
	var file = FileAccess.open(RECOVERY_PATH + ".tmp", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest))
		file.flush()
		var error = file.get_error()
		file.close()
		if error == OK and DirAccess.rename_absolute(RECOVERY_PATH + ".tmp", RECOVERY_PATH) == OK:
			return
	push_error("Map recovery could not be written to " + RECOVERY_PATH + "; copies retained in this editor process.")

func restore_recovery() -> void:
	var base = EditorInterface.get_base_control()
	var stored = base.get_meta(RECOVERY_META) if base.has_meta(RECOVERY_META) else null
	if stored == null and FileAccess.file_exists(RECOVERY_PATH):
		stored = JSON.parse_string(FileAccess.get_file_as_string(RECOVERY_PATH))
	var records: Array
	var active_tab := -1
	var legacy := stored is Array
	if legacy:
		records = stored
		active_tab = records.size() - 1
	elif stored is Dictionary and int(stored.get("version", 0)) == RECOVERY_VERSION and stored.get("tabs") is Array:
		records = stored.tabs
		active_tab = int(stored.get("active_tab", -1))
	else:
		return
	if records.is_empty():
		return
	# Recovery deliberately starts a new epoch. No snapshot IDs or scene targets
	# are transplanted into a new native document; Save As establishes its baseline.
	var restored: Array = []
	var restored_indices: Array[int] = []
	var recovered_any := false
	for index in records.size():
		var record = records[index]
		if not record is Dictionary:
			continue
		var candidate = Session.new()
		var record_type: String = "recovery" if legacy else record.get("type", "")
		if record_type == "path":
			var path = record.get("path", "")
			if not path is String or path.is_empty() or not FileAccess.file_exists(path):
				candidate.dispose()
				continue
			if not candidate.document.load_map(path).ok:
				candidate.dispose()
				continue
		elif record_type == "recovery":
			if not record.get("text") is String or not candidate.document.import_text(record.text).ok:
				candidate.dispose()
				continue
			candidate.recovery_source = record.get("source", "")
			candidate.texture_root = record.get("root", "res://textures")
			candidate.grid = record.get("grid", 16.0)
			candidate.texture = record.get("texture", "common/caulk")
			recovered_any = true
		else:
			candidate.dispose()
			continue
		restored.append(candidate)
		restored_indices.append(index)
	if restored.is_empty():
		return
	# Godot cannot remove individual expired global history entries. Retire their
	# payloads before recovery disposes the old sessions; callbacks remain no-ops.
	for token in tokens:
		if sessions.has(token.session):
			token.retire()
	tokens = tokens.filter(func(token): return token.session != null)
	for origin in sessions:
		origin.dispose()
	sessions.clear()
	session = null
	for candidate in restored:
		set_session(candidate)
	var selected := restored_indices.find(active_tab)
	if selected < 0:
		selected = restored_indices.find_custom(func(index): return index > active_tab)
	if selected < 0:
		selected = restored.size() - 1
	set_session(restored[selected])
	if recovered_any:
		set_status("Restored previous Map tabs, including detached unsaved copies. Use Save As to choose recovery destinations.")
	else:
		set_status("Restored previous Map tabs.")
