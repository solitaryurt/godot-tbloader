@tool
extends EditorPlugin
class_name TBPlugin

const MAIN_SCREEN_NAME := "Radiant"
const TBLoaderInspector = preload("res://addons/tbloader/src/editor/tbloader_inspector.gd")
const STEAM_AUDIO_MATERIAL_PATH := "res://resources/steam_audio_materials"

var map_control: Control = null
var editing_loader: WeakRef = weakref(null)
var inspector_plugin: EditorInspectorPlugin = null
var materials_panel: Control = null
var materials_tree: Tree = null
var materials_grid: ItemList = null
var materials_button: Button = null
var material_picker_button: Button = null
var materials_search: LineEdit = null
var materials_context_picker: OptionButton = null
var open_context_scene_button: Button = null
var materials_count_label: Label = null
var materials_context_label: Label = null
var built_materials_page: Control = null
var material_entries: Array = []
var material_contexts: Dictionary = {}
var active_context_key := ""
var pending_context_key := ""
var materials_preview_generation := 0
var uv_panel: Control = null
var entities_panel: Control = null
var entities_pane: Control = null
var map_editor: Control = null
var map_screen_active = false
var spatial_actions: Dictionary = {}

func _enter_tree():
	set_input_event_forwarding_always_enabled()
	map_control = create_map_control()
	map_control.set_visible(false)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, map_control)

	map_editor = preload("res://addons/tbloader/src/editor/map_editor.gd").new()
	map_editor.plugin = self
	map_editor.visibility_changed.connect(update_materials_context)
	inspector_plugin = TBLoaderInspector.new(self)
	add_inspector_plugin(inspector_plugin)
	materials_panel = create_materials_panel()
	add_control_to_bottom_panel(materials_panel, "Map Materials")
	uv_panel = map_editor.create_material_workspace()
	add_control_to_bottom_panel(uv_panel, "UV")
	entities_panel = create_entities_panel()
	add_control_to_bottom_panel(entities_panel, "Entities")
	get_editor_interface().get_editor_main_screen().add_child(map_editor)
	map_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	map_editor.hide()
	scene_changed.connect(edited_scene_changed)
	get_tree().node_added.connect(scene_tree_changed)
	get_tree().node_removed.connect(scene_tree_changed)
	get_tree().node_renamed.connect(scene_node_renamed)
	get_editor_interface().get_selection().selection_changed.connect(spatial_selection_changed)
	spatial_selection_changed()

func _exit_tree():
	materials_preview_generation += 1
	if inspector_plugin != null:
		remove_inspector_plugin(inspector_plugin)
		inspector_plugin = null
	if entities_pane != null:
		entities_pane.clear()
	map_editor.store_recovery()
	map_editor.shutdown()
	if scene_changed.is_connected(edited_scene_changed):
		scene_changed.disconnect(edited_scene_changed)
	if get_tree().node_added.is_connected(scene_tree_changed):
		get_tree().node_added.disconnect(scene_tree_changed)
	if get_tree().node_removed.is_connected(scene_tree_changed):
		get_tree().node_removed.disconnect(scene_tree_changed)
	if get_tree().node_renamed.is_connected(scene_node_renamed):
		get_tree().node_renamed.disconnect(scene_node_renamed)
	get_editor_interface().get_selection().selection_changed.disconnect(spatial_selection_changed)
	# Pinned 4.8's legacy main-screen adapter detaches its generated EditorDock
	# on plugin disable without freeing it. Dispose only that detached wrapper.
	var wrapper = get_meta("_dock", null)
	if is_instance_valid(wrapper) and not wrapper.is_inside_tree():
		wrapper.queue_free()
	map_editor.queue_free()
	map_editor = null
	remove_control_from_bottom_panel(entities_panel)
	entities_panel.queue_free()
	entities_panel = null
	entities_pane = null
	remove_control_from_bottom_panel(uv_panel)
	uv_panel.queue_free()
	uv_panel = null
	remove_control_from_bottom_panel(materials_panel)
	materials_panel.queue_free()
	materials_panel = null

	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, map_control)
	map_control.queue_free()
	map_control = null

func _handles(_object):
	# A main-screen plugin that handles TBLoader would auto-switch tabs on scene
	# selection. The independent spatial-selection signal owns this toolbar.
	return false

func _make_visible(visible: bool):
	map_screen_active = visible
	if map_editor != null:
		map_editor.set_visible(visible)
		map_editor.set_scene_active(visible)
	update_materials_context()
	if not visible:
		refresh_materials()

func _get_window_layout(configuration: ConfigFile) -> void:
	if map_editor != null and map_editor.is_node_ready():
		configuration.set_value("TBLoader", "map_workspace", map_editor.workspace_state())

func _set_window_layout(configuration: ConfigFile) -> void:
	if map_editor != null and map_editor.is_node_ready() and configuration.has_section_key("TBLoader", "map_workspace"):
		map_editor.restore_workspace_state(configuration.get_value("TBLoader", "map_workspace", {}))

func edited_scene_changed(_root: Node) -> void:
	if map_screen_active and map_editor != null:
		map_editor.queue_scene_discovery()
	discover_open_scene_loaders()
	if not pending_context_key.is_empty():
		call_deferred("restore_pending_context")
	else:
		update_open_context_scene_button()

func scene_tree_changed(node: Node) -> void:
	if not map_screen_active or map_editor == null:
		return
	var root = get_editor_interface().get_edited_scene_root()
	if root != null and node is TBLoader:
		map_editor.queue_scene_discovery()

func scene_node_renamed(node: Node) -> void:
	if not map_screen_active or map_editor == null:
		return
	var root = get_editor_interface().get_edited_scene_root()
	if root != null and (node == root or root.is_ancestor_of(node)):
		map_editor.queue_scene_discovery()

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return MAIN_SCREEN_NAME

func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("GridMap", "EditorIcons")

func _get_unsaved_status(_for_scene: String) -> String:
	return map_editor.unsaved_status() if map_editor != null else ""

func _save_external_data() -> void:
	if map_editor != null:
		map_editor.save_all(true)

func spatial_selection_changed() -> void:
	var nodes = get_editor_interface().get_selection().get_selected_nodes()
	var loader = nodes[0] if nodes.size() == 1 and nodes[0] is TBLoader else null
	_edit(loader)
	update_spatial_toolbar()

func _edit(object):
	editing_loader = weakref(object)
	update_spatial_toolbar()
	if map_editor != null and map_editor.has_method("update_loader_action_state"):
		map_editor.update_loader_action_state()
	update_materials_context()
	if not map_screen_active:
		refresh_materials()

func create_map_control() -> Control:
	var button_build_meshes = Button.new()
	button_build_meshes.flat = true
	button_build_meshes.text = "Build Meshes"
	button_build_meshes.tooltip_text = "Build Meshes for the selected TBLoader"
	button_build_meshes.accessibility_name = "Build Meshes"
	button_build_meshes.connect("pressed", Callable(self, "build_meshes"))
	spatial_actions.BuildMeshes = button_build_meshes

	materials_button = Button.new()
	materials_button.flat = true
	materials_button.text = "Map Materials"
	materials_button.connect("pressed", Callable(self, "show_materials"))

	var ret = HBoxContainer.new()
	ret.add_child(button_build_meshes)
	ret.add_child(materials_button)
	var open_button = Button.new()
	open_button.flat = true
	open_button.icon = get_editor_interface().get_base_control().get_theme_icon("GridMap", "EditorIcons")
	open_button.tooltip_text = "Open Radiant Editor"
	open_button.accessibility_name = "Open Radiant Editor"
	open_button.pressed.connect(open_in_map_editor)
	spatial_actions.OpenRadiantEditor = open_button
	ret.add_child(open_button)
	return ret

func update_spatial_toolbar() -> void:
	if map_control == null:
		return
	map_control.visible = true
	var loader = editing_loader.get_ref()
	var root = get_editor_interface().get_edited_scene_root()
	var has_loader: bool = is_instance_valid(loader) and loader is TBLoader and root != null and (root == loader or root.is_ancestor_of(loader))
	spatial_actions.BuildMeshes.disabled = not has_loader
	spatial_actions.OpenRadiantEditor.disabled = not has_loader
	materials_button.disabled = not has_loader

func open_in_map_editor(loader = null) -> void:
	var target = loader if loader != null else editing_loader.get_ref()
	get_editor_interface().set_main_screen_editor(MAIN_SCREEN_NAME)
	if not is_instance_valid(target) or not target is TBLoader or map_editor == null:
		return
	if map_editor.has_method("bind_loader"):
		map_editor.call("bind_loader", target)
	else:
		# Compatibility until map_editor exposes bind_loader(loader).
		var selected_loader := editing_loader
		editing_loader = weakref(target)
		map_editor.bind_selected()
		editing_loader = selected_loader
	update_materials_context()

func build_meshes():
	var loader = editing_loader.get_ref()
	if loader == null:
		return
	var root = get_editor_interface().get_edited_scene_root()
	if root == null or (loader != root and not root.is_ancestor_of(loader)):
		return
	if not loader.has_method("build_meshes_checked"):
		map_editor.set_status("Checked Build Meshes API unavailable; mesh build deferred.")
		return
	if loader == map_editor.session.loader.get_ref():
		map_editor.bake()
		return
	map_editor.commit_bake(loader)
	refresh_materials()

func add_steam_audio_geometry(loader: Node) -> void:
	if not ClassDB.class_exists(&"SteamAudioGeometry"):
		return
	var materials := {}
	for filename in DirAccess.get_files_at(STEAM_AUDIO_MATERIAL_PATH):
		if filename.get_extension().to_lower() != "tres":
			continue
		var material := ResourceLoader.load(STEAM_AUDIO_MATERIAL_PATH.path_join(filename))
		if material != null:
			materials[filename.get_basename().to_lower()] = material
	for shape in loader.find_children("*", "CollisionShape3D", true, true):
		var parts: PackedStringArray = String(shape.get_parent().name).split("_")
		if parts.size() < 5 or parts[0] != "entity" or parts[2] != "geometry" or parts[-1] != "col":
			continue
		var material_name := parts[3].to_lower()
		if not materials.has(material_name):
			push_warning("SteamAudioMaterial '%s' not found for %s." % [material_name, shape.get_path()])
			continue
		var geometry := ClassDB.instantiate(&"SteamAudioGeometry") as Node
		if geometry == null:
			push_warning("SteamAudioGeometry could not be instantiated.")
			return
		geometry.name = "SteamAudioGeometry"
		shape.add_child(geometry)
		geometry.owner = shape.owner
		geometry.set("material", materials[material_name])
	add_steam_audio_probe_volume(loader)

func add_steam_audio_probe_volume(loader: Node, probe_volume: Node3D = null) -> void:
	if probe_volume == null:
		if not ClassDB.class_exists(&"SteamAudioProbeVolume"):
			return
		probe_volume = ClassDB.instantiate(&"SteamAudioProbeVolume") as Node3D
		if probe_volume == null:
			push_warning("SteamAudioProbeVolume could not be instantiated.")
			return
	var map_bounds := AABB()
	var has_bounds := false
	for child in loader.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var mesh_bounds: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		map_bounds = map_bounds.merge(mesh_bounds) if has_bounds else mesh_bounds
		has_bounds = true
	if not has_bounds:
		push_warning("SteamAudioProbeVolume was not created because the map has no mesh bounds.")
		return
	probe_volume.name = "SteamAudioProbeVolume"
	loader.add_child(probe_volume)
	probe_volume.owner = loader.owner if loader.owner != null else loader
	probe_volume.global_transform = Transform3D(Basis.IDENTITY, map_bounds.get_center())
	probe_volume.set("size", map_bounds.size)
	probe_volume.set("spacing", 3.0)
	probe_volume.set("bake_threads", OS.get_processor_count())
	probe_volume.set("reflection_threads", OS.get_processor_count())
	probe_volume.call("generate_probes")

func create_materials_panel() -> Control:
	var panel = VBoxContainer.new()
	panel.custom_minimum_size.y = 220
	materials_context_label = Label.new()
	materials_context_label.name = "MaterialContext"
	panel.add_child(materials_context_label)
	var context_header := HBoxContainer.new()
	materials_context_picker = OptionButton.new()
	materials_context_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	materials_context_picker.item_selected.connect(material_context_selected)
	context_header.add_child(materials_context_picker)
	open_context_scene_button = Button.new()
	open_context_scene_button.text = "Open Scene"
	open_context_scene_button.visible = false
	open_context_scene_button.pressed.connect(open_context_scene)
	context_header.add_child(open_context_scene_button)
	panel.add_child(context_header)
	built_materials_page = VBoxContainer.new()
	built_materials_page.name = "BuiltMaterials"
	built_materials_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(built_materials_page)

	var header = HBoxContainer.new()
	materials_count_label = Label.new()
	materials_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(materials_count_label)
	materials_search = LineEdit.new()
	materials_search.custom_minimum_size.x = 240
	materials_search.placeholder_text = "Search materials..."
	materials_search.clear_button_enabled = true
	materials_search.text_changed.connect(filter_materials)
	header.add_child(materials_search)
	material_picker_button = Button.new()
	material_picker_button.toggle_mode = true
	material_picker_button.text = "Pick Material"
	material_picker_button.tooltip_text = "Pick a TBLoader surface material from the 3D viewport"
	material_picker_button.icon = get_editor_interface().get_base_control().get_theme_icon("ColorPick", "EditorIcons")
	header.add_child(material_picker_button)
	var refresh_button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(refresh_materials)
	header.add_child(refresh_button)
	var view = OptionButton.new()
	view.add_item("Grid")
	view.add_item("List")
	view.item_selected.connect(func(index: int): set_materials_grid_view(index == 0))
	header.add_child(view)
	built_materials_page.add_child(header)

	materials_tree = Tree.new()
	materials_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials_tree.hide_root = true
	materials_tree.columns = 2
	materials_tree.set_column_title(0, "Material")
	materials_tree.set_column_title(1, "Resource")
	materials_tree.set_column_titles_visible(true)
	materials_tree.set_column_expand(0, true)
	materials_tree.set_column_expand(1, true)
	materials_tree.item_selected.connect(material_selected)
	built_materials_page.add_child(materials_tree)
	materials_grid = ItemList.new()
	materials_grid.name = "MaterialGrid"
	materials_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials_grid.icon_mode = ItemList.ICON_MODE_TOP
	materials_grid.fixed_icon_size = Vector2i(112, 112)
	materials_grid.fixed_column_width = 144
	materials_grid.same_column_width = true
	materials_grid.max_columns = 0
	materials_grid.max_text_lines = 2
	materials_grid.item_selected.connect(grid_material_selected)
	built_materials_page.add_child(materials_grid)
	set_materials_grid_view(true)
	update_materials_context()
	return panel

func create_entities_panel() -> Control:
	var panel := VBoxContainer.new()
	panel.name = "MapEntitiesBottomPanel"
	panel.custom_minimum_size.y = 220
	entities_pane = preload("res://addons/tbloader/src/editor/entity_pane.gd").new()
	entities_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(entities_pane)
	return panel

func update_materials_context() -> void:
	if materials_context_label == null:
		return
	var loader = material_loader()
	materials_context_label.text = "Map materials • " + (loader.name if is_instance_valid(loader) else "No bound or selected TBLoader")

func material_loader():
	if map_screen_active and map_editor != null and map_editor.session != null:
		var active_loader = map_editor.session.loader.get_ref()
		if is_instance_valid(active_loader):
			return active_loader
	return editing_loader.get_ref()

func set_materials_grid_view(enabled: bool) -> void:
	materials_grid.visible = enabled
	materials_tree.visible = not enabled

func show_materials():
	discover_open_scene_loaders()
	update_materials_context()
	refresh_materials()
	make_bottom_panel_item_visible(materials_panel)

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if material_picker_button == null or not material_picker_button.button_pressed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		material_picker_button.button_pressed = false
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hit := pick_material(camera, event.position)
		if not hit.is_empty():
			reveal_material(hit.material, hit.loader)
		else:
			push_warning("No TBLoader material found under the cursor.")
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func pick_material(camera: Camera3D, screen_position: Vector2) -> Dictionary:
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position)
	var nearest_distance := camera.far
	var nearest_material: Material = null
	var nearest_loader: TBLoader = null
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {}
	var loaders := scene_root.find_children("*", "TBLoader", true, false)
	if scene_root is TBLoader:
		loaders.push_front(scene_root)
	for loader_node in loaders:
		var loader := loader_node as TBLoader
		for mesh_node in loader.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := mesh_node as MeshInstance3D
			var mesh: Mesh = mesh_instance.mesh
			if mesh == null or not mesh_instance.is_visible_in_tree():
				continue
			var inverse_transform := mesh_instance.global_transform.affine_inverse()
			var local_origin := inverse_transform * ray_origin
			var local_direction := (inverse_transform * (ray_origin + ray_direction) - local_origin).normalized()
			if mesh.get_aabb().intersects_ray(local_origin, local_direction) == null:
				continue
			for surface_index in mesh.get_surface_count():
				if mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
					continue
				var surface_material: Material = mesh_instance.material_override
				if surface_material == null:
					surface_material = mesh_instance.get_surface_override_material(surface_index)
				if surface_material == null:
					surface_material = mesh.surface_get_material(surface_index)
				if surface_material == null:
					continue
				var arrays := mesh.surface_get_arrays(surface_index)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var element_count := indices.size() if not indices.is_empty() else vertices.size()
				for triangle_index in range(0, element_count - 2, 3):
					var index_a := indices[triangle_index] if not indices.is_empty() else triangle_index
					var index_b := indices[triangle_index + 1] if not indices.is_empty() else triangle_index + 1
					var index_c := indices[triangle_index + 2] if not indices.is_empty() else triangle_index + 2
					var intersection = Geometry3D.ray_intersects_triangle(local_origin, local_direction,
						vertices[index_a], vertices[index_b], vertices[index_c])
					if intersection == null:
						continue
					var local_hit: Vector3 = intersection
					var distance := ray_origin.distance_to(mesh_instance.global_transform * local_hit)
					if distance < nearest_distance:
						nearest_distance = distance
						nearest_material = surface_material
						nearest_loader = loader
	return {} if nearest_material == null else {"material": nearest_material, "loader": nearest_loader}

func reveal_material(material: Material, loader: TBLoader) -> void:
	material_picker_button.button_pressed = false
	editing_loader = weakref(loader)
	materials_search.text = ""
	update_materials_context()
	refresh_materials()
	make_bottom_panel_item_visible(materials_panel)
	for index in materials_grid.item_count:
		if materials_grid.get_item_metadata(index) == material:
			materials_grid.select(index)
			materials_grid.ensure_current_is_visible()
			break
	var item := materials_tree.get_root().get_first_child()
	while item != null:
		if item.get_metadata(0) == material:
			item.select(0)
			break
		item = item.get_next()
	get_editor_interface().edit_resource(material)

func show_uv() -> void:
	update_bottom_panel_sessions()
	make_bottom_panel_item_visible(uv_panel)

func toggle_uv() -> void:
	if uv_panel.is_visible_in_tree():
		hide_bottom_panel()
	else:
		show_uv()

func show_entities_panel() -> void:
	update_bottom_panel_sessions()
	make_bottom_panel_item_visible(entities_panel)
	entities_pane.entity_list.grab_focus()

func toggle_entities_panel() -> bool:
	if entities_panel.is_visible_in_tree():
		hide_bottom_panel()
		return false
	show_entities_panel()
	return true

func update_bottom_panel_sessions() -> void:
	if entities_pane != null and map_editor != null:
		entities_pane.set_session(map_editor.session)
	update_materials_context()
	refresh_materials()

func refresh_materials() -> void:
	if materials_tree == null or materials_grid == null:
		return
	material_entries.clear()
	var loader = material_loader()
	if not is_instance_valid(loader):
		if material_contexts.has(active_context_key):
			material_entries = material_contexts[active_context_key].materials
		filter_materials(materials_search.text)
		if material_entries.is_empty():
			materials_count_label.text = "Bind a Radiant session or select a TBLoader to view its materials."
			materials_button.text = "Map Materials"
		else:
			materials_button.text = "Map Materials (%d)" % material_entries.size()
		update_material_context_picker()
		return
	material_entries = collect_material_entries(loader)
	cache_material_context(loader, material_entries, true)
	update_material_context_picker()
	filter_materials(materials_search.text)
	materials_button.text = "Map Materials (%d)" % material_entries.size()

func collect_material_entries(loader: TBLoader) -> Array:
	var materials := {}
	for mesh_instance in loader.find_children("*", "MeshInstance3D", true, false):
		add_material(materials, mesh_instance.material_override, loader)
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material = mesh_instance.get_surface_override_material(surface_index)
			if material == null:
				material = mesh_instance.mesh.surface_get_material(surface_index)
			add_material(materials, material, loader)
	var entries: Array = materials.values()
	entries.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return entries

func cache_material_context(loader: TBLoader, entries: Array, make_active: bool) -> String:
	var scene_root := find_scene_root(loader)
	if scene_root == null:
		return ""
	var scene_path: String = scene_root.scene_file_path
	var scene_id := scene_path if not scene_path.is_empty() else "unsaved:%d" % scene_root.get_instance_id()
	var key := "%s::%s" % [scene_id, scene_root.get_path_to(loader)]
	material_contexts[key] = {
		"scene_path": scene_path,
		"scene_root_id": scene_root.get_instance_id(),
		"scene_name": scene_root.name,
		"node_path": str(scene_root.get_path_to(loader)),
		"node_name": loader.name,
		"materials": entries.duplicate(),
	}
	if make_active:
		active_context_key = key
	return key

func discover_open_scene_loaders() -> void:
	if materials_context_picker == null:
		return
	var first_key := ""
	var preferred_key := ""
	var edited_root := get_editor_interface().get_edited_scene_root()
	for scene_root in get_editor_interface().get_open_scene_roots():
		var loaders := scene_root.find_children("*", "TBLoader", true, false)
		if scene_root is TBLoader:
			loaders.push_front(scene_root)
		for loader in loaders:
			var key := cache_material_context(loader, collect_material_entries(loader), false)
			if first_key.is_empty():
				first_key = key
			if scene_root == edited_root and preferred_key.is_empty():
				preferred_key = key
	if active_context_key.is_empty():
		active_context_key = preferred_key if not preferred_key.is_empty() else first_key
	update_material_context_picker()

func find_scene_root(node: Node) -> Node:
	for scene_root in get_editor_interface().get_open_scene_roots():
		if scene_root == node or scene_root.is_ancestor_of(node):
			return scene_root
	return null

func update_material_context_picker() -> void:
	if materials_context_picker == null:
		return
	materials_context_picker.clear()
	if material_contexts.is_empty():
		materials_context_picker.add_item("Select a TBLoader node to view its materials")
		materials_context_picker.set_item_disabled(0, true)
		open_context_scene_button.visible = false
		return
	var contexts: Array = []
	for key in material_contexts:
		var context: Dictionary = material_contexts[key]
		var is_open := find_context_root(context) != null
		var count: int = context.materials.size()
		contexts.append({"key": key, "open": is_open, "label": "%s%s > %s > %d material%s" % [
			"[Open] " if is_open else "", context.scene_name, context.node_name, count, "" if count == 1 else "s"]})
	contexts.sort_custom(func(a, b):
		if a.open != b.open:
			return a.open
		return a.label.naturalnocasecmp_to(b.label) < 0)
	var selected_index := 0
	for context in contexts:
		var index := materials_context_picker.item_count
		materials_context_picker.add_item(context.label)
		materials_context_picker.set_item_metadata(index, context.key)
		if context.key == active_context_key:
			selected_index = index
	materials_context_picker.select(selected_index)
	update_open_context_scene_button()

func material_context_selected(index: int) -> void:
	var key: String = materials_context_picker.get_item_metadata(index)
	if not material_contexts.has(key):
		return
	active_context_key = key
	var context: Dictionary = material_contexts[key]
	material_entries = context.materials
	filter_materials(materials_search.text)
	materials_button.text = "Map Materials (%d)" % material_entries.size()
	var loader := find_context_loader(context)
	if loader == null:
		editing_loader = weakref(null)
		update_open_context_scene_button()
		return
	var scene_root := find_context_root(context)
	if scene_root != get_editor_interface().get_edited_scene_root() and not context.scene_path.is_empty():
		pending_context_key = key
		get_editor_interface().open_scene_from_path(context.scene_path)
		return
	activate_context_loader(loader)

func find_context_root(context: Dictionary) -> Node:
	for scene_root in get_editor_interface().get_open_scene_roots():
		if scene_root.get_instance_id() == context.scene_root_id:
			return scene_root
	return null

func find_context_loader(context: Dictionary) -> TBLoader:
	var scene_root := find_context_root(context)
	if scene_root == null:
		return null
	var node := scene_root.get_node_or_null(NodePath(context.node_path))
	return node if node is TBLoader else null

func activate_context_loader(loader: TBLoader) -> void:
	editing_loader = weakref(loader)
	var selection := get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(loader)
	get_editor_interface().edit_node(loader)
	update_materials_context()
	refresh_materials()

func update_open_context_scene_button() -> void:
	if open_context_scene_button == null or not material_contexts.has(active_context_key):
		if open_context_scene_button != null:
			open_context_scene_button.visible = false
		return
	var context: Dictionary = material_contexts[active_context_key]
	open_context_scene_button.visible = find_context_root(context) == null and not context.scene_path.is_empty()

func open_context_scene() -> void:
	if not material_contexts.has(active_context_key):
		return
	var context: Dictionary = material_contexts[active_context_key]
	if context.scene_path.is_empty():
		return
	pending_context_key = active_context_key
	get_editor_interface().open_scene_from_path(context.scene_path)

func restore_pending_context() -> void:
	var key := pending_context_key
	pending_context_key = ""
	if not material_contexts.has(key):
		return
	active_context_key = key
	var loader := find_context_loader(material_contexts[key])
	if loader != null:
		activate_context_loader(loader)

func filter_materials(query: String) -> void:
	if materials_tree == null or materials_grid == null:
		return
	materials_preview_generation += 1
	materials_tree.clear()
	materials_grid.clear()
	var root := materials_tree.create_item()
	var normalized_query := query.strip_edges().to_lower()
	var visible_count := 0
	for entry in material_entries:
		if not normalized_query.is_empty() and normalized_query not in entry.name.to_lower() and normalized_query not in entry.path.to_lower():
			continue
		var item = materials_tree.create_item(root)
		item.set_text(0, entry.name)
		item.set_text(1, entry.path)
		item.set_metadata(0, entry.material)
		item.set_tooltip_text(0, "Show this material in the Inspector")
		var index := materials_grid.add_item(entry.name)
		materials_grid.set_item_metadata(index, entry.material)
		materials_grid.set_item_tooltip(index, entry.path if not entry.path.is_empty() else entry.name)
		EditorInterface.get_resource_previewer().queue_edited_resource_preview(
			entry.material, self, "material_preview_ready",
			{"generation": materials_preview_generation, "index": index,
				"instance_id": entry.material.get_instance_id()})
		visible_count += 1
	materials_count_label.text = "%d of %d materials" % [visible_count, material_entries.size()] if not normalized_query.is_empty() else "%d unique material%s" % [visible_count, "" if visible_count == 1 else "s"]

func add_material(materials: Dictionary, material: Material, loader: TBLoader) -> void:
	if material == null:
		return
	var path = material.resource_path
	var texture_path = ""
	var texture = material.get(loader.texture_material_texture_path)
	if texture is Texture2D:
		texture_path = texture.resource_path
	var key = path
	if key.is_empty():
		key = texture_path
	if key.is_empty() and not material.resource_name.is_empty():
		key = material.resource_name
	if key.is_empty():
		key = "instance:%d" % material.get_instance_id()
	if materials.has(key):
		return
	var name = material.resource_name
	if name.is_empty() and not path.is_empty():
		name = path.trim_prefix(loader.texture_path + "/").get_basename()
	if name.is_empty() and not texture_path.is_empty():
		name = texture_path.trim_prefix(loader.texture_path + "/").get_basename()
	if name.is_empty():
		name = material.get_class()
	materials[key] = {"material": material, "name": name,
		"path": path if not path.is_empty() else texture_path}

func material_selected() -> void:
	var item = materials_tree.get_selected()
	if item != null and item.get_metadata(0) is Material:
		get_editor_interface().edit_resource(item.get_metadata(0))

func grid_material_selected(index: int) -> void:
	var material = materials_grid.get_item_metadata(index)
	if material is Material:
		get_editor_interface().edit_resource(material)

func material_preview_ready(_path: String, preview: Texture2D, thumbnail: Texture2D, data: Variant) -> void:
	if not data is Dictionary or data.get("generation", -1) != materials_preview_generation:
		return
	var index: int = data.get("index", -1)
	if index < 0 or index >= materials_grid.item_count:
		return
	var material = materials_grid.get_item_metadata(index)
	if not material is Material or material.get_instance_id() != data.get("instance_id", 0):
		return
	var image := preview if preview != null else thumbnail
	if image != null:
		materials_grid.set_item_icon(index, image)
