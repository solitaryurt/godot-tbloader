@tool
extends EditorPlugin

const Checks = preload("res://checks.gd")
var checks = Checks.new()

func _enter_tree() -> void:
	call_deferred("run")

func find_tb_plugin(node: Node) -> EditorPlugin:
	if node is EditorPlugin and node.get_script() != null:
		if node.get_script().resource_path == "res://addons/tbloader/src/plugin.gd":
			return node
	for child in node.get_children():
		var found = find_tb_plugin(child)
		if found != null:
			return found
	return null

func run() -> void:
	var suite = OS.get_environment("TB_TEST_SUITE")
	# Let first-import editor work settle before shutdown (4.8.dev --import can
	# crash during teardown immediately after the first filesystem scan).
	if suite == "import":
		for frame in 5:
			await get_tree().process_frame
		while EditorInterface.get_resource_filesystem().is_scanning():
			await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
		print("TB_TEST_COMPLETE:import:PASS")
		get_tree().quit(0)
		return
	if suite not in ["editor", "ui"]:
		return
	for frame in 5:
		await get_tree().process_frame
	checks.check(Engine.is_editor_hint(), "actual editor mode")
	checks.check(ClassDB.class_exists("TBLoader"), "native registration in editor")
	checks.check(EditorInterface.is_plugin_enabled("tbloader"), "actual addon enabled")
	var plugin = find_tb_plugin(get_tree().root)
	if not checks.check(plugin != null, "actual addon entered editor tree"):
		checks.finish(get_tree(), suite)
		return
	var loader = ClassDB.instantiate("TBLoader")
	checks.check(plugin._handles(loader), "addon handles TBLoader")
	plugin._edit(loader)
	plugin._make_visible(true)
	checks.check(plugin.map_control.visible, "Build Meshes toolbar visibility callback")
	checks.check(plugin.map_control.get_child(0).text == "Build Meshes", "existing build button")
	checks.check(plugin.materials_panel.is_inside_tree(), "Map Materials panel attached")
	checks.check(plugin.materials_count_label.text == "0 unique materials", "materials refresh on loader edit")
	plugin._make_visible(false)
	checks.check(not plugin.map_control.visible, "toolbar hides")
	plugin._edit(null)
	loader.free()
	# Exercise the real editor manager, with explicit RefCounted/global context.
	# Phase 3 extends this to real document callbacks and scene switches.
	var context = RefCounted.new()
	context.set_meta("value", 0)
	var manager = get_undo_redo()
	manager.create_action("TB baseline history", UndoRedo.MERGE_DISABLE, context)
	manager.add_do_method(context, "set_meta", "value", 1)
	manager.add_undo_method(context, "set_meta", "value", 0)
	manager.commit_action()
	var history_id = manager.get_object_history_id(context)
	checks.check(history_id == EditorUndoRedoManager.GLOBAL_HISTORY, "RefCounted routes to global history")
	var history = manager.get_history_undo_redo(history_id)
	checks.check(context.get_meta("value") == 1, "editor action executes")
	checks.check(history.undo(), "editor history undo succeeds")
	checks.check(context.get_meta("value") == 0, "editor undo callback")
	checks.check(history.redo(), "editor history redo succeeds")
	checks.check(context.get_meta("value") == 1, "editor redo callback")
	# Safe only because this is a disposable project with no user history.
	manager.clear_history(history_id, false)
	var old_toolbar = weakref(plugin.map_control)
	var old_panel = weakref(plugin.materials_panel)
	EditorInterface.set_plugin_enabled("tbloader", false)
	await get_tree().process_frame
	await get_tree().process_frame
	checks.check(old_toolbar.get_ref() == null, "disable frees toolbar")
	checks.check(old_panel.get_ref() == null, "disable frees materials panel")
	EditorInterface.set_plugin_enabled("tbloader", true)
	await get_tree().process_frame
	plugin = find_tb_plugin(get_tree().root)
	checks.check(plugin != null and plugin.map_control.is_inside_tree(), "re-enable attaches new toolbar")
	if suite == "ui":
		checks.check(DisplayServer.get_name() != "headless", "display-backed editor")
		# Allow the startup progress overlay to close before capturing the editor.
		await get_tree().create_timer(1.0).timeout
		plugin.show_materials()
		await RenderingServer.frame_post_draw
		var image = EditorInterface.get_base_control().get_viewport().get_texture().get_image()
		checks.check(not image.is_empty(), "rendered editor image")
		checks.check(image.save_png("res://editor-smoke.png") == OK, "editor screenshot saved")
	checks.finish(get_tree(), suite)
