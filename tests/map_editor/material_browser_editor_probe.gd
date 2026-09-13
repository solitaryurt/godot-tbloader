@tool
extends EditorPlugin

const Browser = preload("res://material_browser.gd")
var browser: Control
var failures := 0
var changes := 0

func _enter_tree() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr("MATERIAL_BROWSER_FAIL: " + message)

func wait_for_index() -> void:
	for i in range(600):
		await get_tree().process_frame
		if changes > 0 and not browser.is_refreshing():
			return
	check(false, "editor index timeout")

func _run() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	browser = Browser.new()
	browser.configure(fs, "res://textures", null, true)
	browser.index_changed.connect(func(_count: int): changes += 1)
	add_control_to_bottom_panel(browser, "Material Browser Probe")
	await wait_for_index()
	var paths: Array = browser.get_index_entries().map(func(entry: Dictionary): return entry.path)
	check(not paths.has("res://art/other.tres"), "real EditorFileSystem excludes resources outside texture root")
	check(paths.has("res://textures/brick.png"), "real EditorFileSystem indexes imported texture")
	check(not paths.has("res://textures/plain.tres"), "real EditorFileSystem excludes ordinary Resource")
	check(browser.get_mapping("res://textures/brick.png").resolved, "real imported texture resolves")
	var material := ShaderMaterial.new()
	check(ResourceSaver.save(material, "res://textures/added.res") == OK, "save binary fixture")
	changes = 0
	fs.scan()
	await wait_for_index()
	paths = browser.get_index_entries().map(func(entry: Dictionary): return entry.path)
	check(paths.has("res://textures/added.res"), "real filesystem addition indexes binary ShaderMaterial")
	check(browser.select_path("res://textures/added.res"), "real binary Material selected")
	check(DirAccess.remove_absolute("res://textures/added.res") == OK, "remove binary fixture")
	changes = 0
	fs.scan()
	await wait_for_index()
	paths = browser.get_index_entries().map(func(entry: Dictionary): return entry.path)
	check(not paths.has("res://textures/added.res") and browser.get_selected_path().is_empty(), "real filesystem removal clears index and selection")
	remove_control_from_bottom_panel(browser)
	browser.queue_free()
	await get_tree().process_frame
	if failures == 0:
		print("MATERIAL_BROWSER_EDITOR_PASS")
	get_tree().quit(0 if failures == 0 else 1)

func _exit_tree() -> void:
	if is_instance_valid(browser) and not browser.is_queued_for_deletion():
		remove_control_from_bottom_panel(browser)
		browser.queue_free()
