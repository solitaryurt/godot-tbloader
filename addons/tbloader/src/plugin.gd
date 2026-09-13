@tool
extends EditorPlugin
class_name TBPlugin

var map_control: Control = null
var editing_loader: WeakRef = weakref(null)
var materials_panel: Control = null
var materials_tree: Tree = null
var materials_grid: ItemList = null
var materials_button: Button = null
var materials_count_label: Label = null
var materials_preview_generation := 0
var map_editor: Control = null

func _enter_tree():
	map_control = create_map_control()
	map_control.set_visible(false)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, map_control)

	materials_panel = create_materials_panel()
	add_control_to_bottom_panel(materials_panel, "Map Materials")
	map_editor = preload("res://addons/tbloader/src/editor/map_editor.gd").new()
	map_editor.plugin = self
	get_editor_interface().get_editor_main_screen().add_child(map_editor)
	map_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	map_editor.hide()
	get_editor_interface().get_selection().selection_changed.connect(spatial_selection_changed)
	spatial_selection_changed()

func _exit_tree():
	materials_preview_generation += 1
	map_editor.store_recovery()
	map_editor.shutdown()
	get_editor_interface().get_selection().selection_changed.disconnect(spatial_selection_changed)
	# Pinned 4.8's legacy main-screen adapter detaches its generated EditorDock
	# on plugin disable without freeing it. Dispose only that detached wrapper.
	var wrapper = get_meta("_dock", null)
	if is_instance_valid(wrapper) and not wrapper.is_inside_tree():
		wrapper.queue_free()
	map_editor.queue_free()
	map_editor = null
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
	if map_editor != null:
		map_editor.set_visible(visible)
		if visible:
			map_editor.open_scene_map()

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "Map"

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
	map_control.visible = loader != null

func _edit(object):
	editing_loader = weakref(object)
	refresh_materials()

func create_map_control() -> Control:
	var button_build_meshes = Button.new()
	button_build_meshes.flat = true
	button_build_meshes.text = "Build Meshes"
	button_build_meshes.connect("pressed", Callable(self, "build_meshes"))

	materials_button = Button.new()
	materials_button.flat = true
	materials_button.text = "Map Materials"
	materials_button.connect("pressed", Callable(self, "show_materials"))

	var ret = HBoxContainer.new()
	ret.add_child(button_build_meshes)
	ret.add_child(materials_button)
	var open_button = Button.new()
	open_button.text = "Open in Map Editor"
	open_button.pressed.connect(func():
		get_editor_interface().set_main_screen_editor("Map")
		map_editor.bind_selected())
	ret.add_child(open_button)
	return ret

func build_meshes():
	var loader = editing_loader.get_ref()
	if loader == null:
		return
	var root = get_editor_interface().get_edited_scene_root()
	if root == null or (loader != root and not root.is_ancestor_of(loader)):
		return
	if not loader.has_method("build_meshes_checked"):
		map_editor.set_status("Checked bake API unavailable; build deferred.")
		return
	if loader == map_editor.session.loader.get_ref():
		map_editor.bake()
		return
	map_editor.commit_bake(loader)
	refresh_materials()

func create_materials_panel() -> Control:
	var panel = VBoxContainer.new()
	panel.custom_minimum_size.y = 220

	var header = HBoxContainer.new()
	materials_count_label = Label.new()
	materials_count_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(materials_count_label)

	var refresh_button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.connect("pressed", Callable(self, "refresh_materials"))
	header.add_child(refresh_button)
	var view = OptionButton.new()
	view.add_item("Grid")
	view.add_item("List")
	view.item_selected.connect(func(index: int): set_materials_grid_view(index == 0))
	header.add_child(view)
	panel.add_child(header)

	materials_tree = Tree.new()
	materials_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials_tree.hide_root = true
	materials_tree.columns = 2
	materials_tree.set_column_title(0, "Material")
	materials_tree.set_column_title(1, "Resource")
	materials_tree.set_column_titles_visible(true)
	materials_tree.set_column_expand(0, true)
	materials_tree.set_column_expand(1, true)
	materials_tree.connect("item_selected", Callable(self, "material_selected"))
	panel.add_child(materials_tree)
	materials_grid = ItemList.new()
	materials_grid.name = "MaterialGrid"
	materials_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials_grid.icon_mode = ItemList.ICON_MODE_TOP
	materials_grid.fixed_icon_size = Vector2i(112, 112)
	materials_grid.fixed_column_width = 144
	materials_grid.same_column_width = true
	materials_grid.max_text_lines = 2
	materials_grid.item_selected.connect(grid_material_selected)
	panel.add_child(materials_grid)
	set_materials_grid_view(true)

	return panel

func set_materials_grid_view(enabled: bool) -> void:
	if materials_grid != null:
		materials_grid.visible = enabled
	if materials_tree != null:
		materials_tree.visible = not enabled

func show_materials():
	refresh_materials()
	make_bottom_panel_item_visible(materials_panel)

func refresh_materials():
	if materials_tree == null or materials_grid == null:
		return

	materials_preview_generation += 1
	materials_tree.clear()
	materials_grid.clear()
	var root = materials_tree.create_item()
	var loader = editing_loader.get_ref()
	if loader == null:
		materials_count_label.text = "Select a TBLoader node to view its materials."
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

func add_material(materials: Dictionary, material: Material, loader: TBLoader):
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

	materials[key] = {
		"material": material,
		"name": name,
		"path": path if not path.is_empty() else texture_path,
	}

func material_selected():
	var item = materials_tree.get_selected()
	if item == null:
		return
	var material = item.get_metadata(0)
	if material is Material:
		get_editor_interface().edit_resource(material)

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
