@tool
extends EditorPlugin
class_name TBPlugin

const MAIN_SCREEN_NAME := "Radiant"
const TBLoaderInspector = preload("res://addons/tbloader/src/editor/tbloader_inspector.gd")

var map_control: Control = null
var editing_loader: WeakRef = weakref(null)
var inspector_plugin: EditorInspectorPlugin = null
var materials_panel: Control = null
var materials_tree: Tree = null
var materials_grid: ItemList = null
var materials_button: Button = null
var materials_count_label: Label = null
var materials_context_label: Label = null
var built_materials_page: Control = null
var materials_preview_generation := 0
var uv_panel: Control = null
var entities_panel: Control = null
var entities_pane: Control = null
var map_editor: Control = null
var map_screen_active = false
var spatial_actions: Dictionary = {}

func _enter_tree():
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
	open_button.text = "Open Radiant Editor"
	open_button.tooltip_text = "Open the selected TBLoader in the Radiant Editor"
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

func create_materials_panel() -> Control:
	var panel = VBoxContainer.new()
	panel.custom_minimum_size.y = 220
	materials_context_label = Label.new()
	materials_context_label.name = "MaterialContext"
	panel.add_child(materials_context_label)
	built_materials_page = VBoxContainer.new()
	built_materials_page.name = "BuiltMaterials"
	built_materials_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(built_materials_page)

	var header = HBoxContainer.new()
	materials_count_label = Label.new()
	materials_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(materials_count_label)
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
	update_materials_context()
	refresh_materials()
	make_bottom_panel_item_visible(materials_panel)

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
	materials_preview_generation += 1
	materials_tree.clear()
	materials_grid.clear()
	var root = materials_tree.create_item()
	var loader = material_loader()
	if not is_instance_valid(loader):
		materials_count_label.text = "Bind a Radiant session or select a TBLoader to view its materials."
		materials_button.text = "Map Materials"
		return
	var materials = {}
	for mesh_instance in loader.find_children("*", "MeshInstance3D", true, false):
		add_material(materials, mesh_instance.material_override, loader)
		if mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var material = mesh_instance.get_surface_override_material(surface_index)
			if material == null:
				material = mesh_instance.mesh.surface_get_material(surface_index)
			add_material(materials, material, loader)
	var entries = materials.values()
	entries.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	for entry in entries:
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
	var count = entries.size()
	materials_count_label.text = "%d unique material%s" % [count, "" if count == 1 else "s"]
	materials_button.text = "Map Materials (%d)" % count

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
