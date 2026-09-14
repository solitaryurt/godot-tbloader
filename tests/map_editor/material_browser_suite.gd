extends SceneTree

const Browser = preload("res://material_browser.gd")
var failures := 0
var checks := 0
var selections: Array = []
var publications := 0

class Directory:
	extends RefCounted
	var path: String
	var files: Array
	var children: Array
	func _init(p: String, f: Array = [], c: Array = []) -> void:
		path = p
		files = f
		children = c
	func get_path() -> String: return path
	func get_file_count() -> int: return files.size()
	func get_file_path(i: int) -> String: return path.path_join(files[i][0])
	func get_file_type(i: int) -> String: return files[i][1]
	func get_subdir_count() -> int: return children.size()
	func get_subdir(i: int) -> Object: return children[i]

class Filesystem:
	extends RefCounted
	signal filesystem_changed
	var directory: Object
	var scanning := false
	var scans := 0
	var disk_scans := 0
	func is_scanning() -> bool: return scanning
	func scan() -> void:
		disk_scans += 1
		filesystem_changed.emit()
	func get_filesystem() -> Object:
		scans += 1
		return directory

class Previewer:
	extends RefCounted
	var requests: Array = []
	func queue_resource_preview(path: String, receiver: Object, method: StringName, data: Variant) -> void:
		requests.append([path, receiver, method, data])
	func complete() -> void:
		for request in requests:
			if is_instance_valid(request[1]):
				request[1].call(request[2], request[0], null, null, request[3])
		requests.clear()

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("MATERIAL_BROWSER_FAIL: " + message)

func settle(browser: Control) -> void:
	for frame in range(120):
		await process_frame
		browser._process(0.2)
		if not browser.is_refreshing():
			return
	check(false, "index did not settle")

func _run() -> void:
	var fs := Filesystem.new()
	var textures := Directory.new("res://textures", [
		["brick.png", "CompressedTexture2D"], ["brick.jpg", "CompressedTexture2D"],
		["native.tres", "StandardMaterial3D"], ["binary.res", "ShaderMaterial"],
		["plain.tres", "Resource"], ["vector.svg", "CompressedTexture2D"],
		["shadow.png", "CompressedTexture2D"], ["shadow.tres", "StandardMaterial3D"],
		["bad name.tres", "StandardMaterial3D"]])
	var outside := Directory.new("res://art", [["other.tres", "StandardMaterial3D"]])
	var prefix_sibling := Directory.new("res://textures_extra", [["other.png", "CompressedTexture2D"]])
	var huge := Directory.new("res://many")
	for i in range(1500):
		huge.files.append(["texture%04d.png" % i, "CompressedTexture2D"])
	fs.directory = Directory.new("res://", [], [textures, outside, prefix_sibling, huge])
	var previewer := Previewer.new()
	var browser := Browser.new()
	browser.size = Vector2(700, 420)
	browser.configure(fs, "res://textures/", previewer)
	browser.index_changed.connect(func(_count: int): publications += 1)
	browser.resource_selected.connect(func(resource: Resource, path: String, token: String, mapping: Dictionary): selections.append([resource, path, token, mapping]))
	root.add_child(browser)
	browser.set_process(false)
	fs.scanning = true
	browser._process(1.0)
	check(fs.scans == 0, "waits for EditorFileSystem scan")
	fs.scanning = false
	for i in range(20):
		fs.filesystem_changed.emit()
	browser._process(0.2)
	check(browser.get_index_entries().is_empty(), "large index publishes atomically across bounded steps")
	await settle(browser)
	check(fs.scans == 1 and publications == 1, "filesystem burst coalesces to one index publication")
	check(browser.get_index_entries().size() == 8, "indexes only the texture root and excludes non-Material tres")
	browser.set_kind_filter("Textures")
	check(browser.get_kind_filter() == "Textures" and browser.get_visible_paths().size() == 4
		and not browser.get_visible_paths().has("res://textures/native.tres"), "texture filter excludes Materials")
	browser.set_kind_filter("Materials")
	check(browser.get_visible_paths().size() == 4 and browser.get_visible_paths().has("res://textures/native.tres")
		and not browser.get_visible_paths().has("res://textures/brick.png"), "material filter excludes textures")
	check(selections.is_empty() and not ResourceLoader.has_cached("res://textures/native.tres"), "kind filtering neither loads nor assigns resources")
	browser.set_kind_filter("All")
	check(not ResourceLoader.has_cached("res://textures/native.tres"), "metadata indexing does not load resources")
	check(browser.get_mapping("res://textures/native.tres").token == "native.tres", "native extension retained")
	check(not browser.get_mapping("res://textures/native.tres").resolved, "legacy Builder capability is explicitly unresolved")
	check(browser.get_mapping("res://textures/brick.png").resolved, "supported texture root token resolves")
	check(browser.get_mapping("res://textures/brick.png").token == "brick", "texture extension stripped")
	check(not browser.get_mapping("res://textures/brick.jpg").resolved, "extension precedence prevents wrong texture")
	check(not browser.get_mapping("res://textures/shadow.png").resolved, "material shadow prevents wrong texture")
	check(not browser.get_mapping("res://textures/vector.svg").resolved, "unsupported Builder format remains browsable but unresolved")
	check(not browser.get_mapping("res://textures_extra/other.png").resolved, "root prefix sibling is not indexed")
	check(not browser.get_mapping("res://art/other.tres").resolved, "outside-root Material is not indexed")
	check(not browser.get_mapping("res://textures/bad name.tres").resolved, "unsafe bare map token unresolved")
	browser.highlight_path("res://textures/brick.png")
	check(browser.get_selected_path() == "res://textures/brick.png" and selections.is_empty(), "host synchronization highlights without loading or assigning")
	browser.highlight_path("")
	browser.set_search("BRICK")
	check(browser.get_visible_paths().size() == 2, "case-insensitive filename search")
	browser.set_search("res://art/")
	check(browser.get_visible_paths().is_empty(), "search cannot escape texture root")
	browser.set_folder("res://textures")
	check(browser.get_visible_paths().is_empty(), "folder and query filters intersect")
	browser.set_search("")
	check(browser.get_visible_paths().size() == 8, "folder includes only its resources")
	check(not browser.set_folder("res://missing"), "invalid folder rejected")
	browser._breadcrumbs.get_child(0).pressed.emit()
	check(browser.get_visible_paths().size() == 8, "breadcrumb button retains root-scoped resources")
	browser.focus_search()
	await process_frame
	check(browser._search.has_focus() and browser.has_browser_focus(), "search takes focus for host shortcut isolation")
	browser._search.text = "other"
	browser._search.text_changed.emit("other")
	check(browser.get_visible_paths().is_empty(), "LineEdit signal remains texture-root scoped")
	check(not browser.select_path("res://art/other.tres"), "outside-root resource cannot be selected")
	browser.configure(fs, "res://", previewer, true)
	await settle(browser)
	check(browser.get_mapping("res://textures/native.tres").token == "textures/native.tres", "project-root native path")
	check(browser.get_mapping("res://textures/binary.res").resolved, "direct native lookup capability supports binary Material")
	check(browser.get_selected_path().is_empty() and selections.is_empty(), "root change does not assign a resource")
	check(browser.get_shader_mappings()["art/other.tres"] == "res://art/other.tres", "metadata preview lookup table")
	browser.set_texture_root("")
	check(not browser.get_mapping("res://textures/brick.png").resolved, "unbound root unresolved")
	browser.set_texture_root("res://")
	await settle(browser)
	browser.set_search("")
	browser.set_folder("res://many")
	await process_frame
	await process_frame
	previewer.complete()
	browser._request_visible_previews()
	check(previewer.requests.size() > 0 and previewer.requests.size() <= Browser.PREVIEW_LIMIT, "visible thumbnail requests bounded")
	var initial_paths: Array = previewer.requests.map(func(request: Array): return request[0])
	previewer.complete()
	browser._list.get_v_scroll_bar().value = browser._list.get_v_scroll_bar().max_value
	await process_frame
	browser._request_visible_previews()
	check(not previewer.requests.is_empty() and previewer.requests[0][0] not in initial_paths, "scroll requests new visible thumbnails lazily")
	var stale: Array = previewer.requests.duplicate()
	fs.filesystem_changed.emit()
	await settle(browser)
	for request in stale:
		browser._preview_ready(request[0], null, null, request[3])
	check(browser._pending_previews.is_empty(), "stale preview callbacks ignored after refresh")
	browser.hide()
	previewer.requests.clear()
	browser._request_visible_previews()
	check(previewer.requests.is_empty(), "hidden browser does not request thumbnails")
	outside.files.clear()
	fs.directory.children.erase(huge)
	textures.files.append(["added.png", "CompressedTexture2D"])
	fs.filesystem_changed.emit()
	await settle(browser)
	check(browser.get_selected_path().is_empty(), "deleted selected resource clears selection")
	check(browser.get_visible_paths().has("res://textures/added.png"), "deleted folder falls back to root and added resource appears")
	check(selections.is_empty(), "index changes never emit resource assignment")
	browser.rescan_project()
	await settle(browser)
	check(fs.disk_scans == 1, "manual refresh requests one disk scan without notification loop")
	var fs2 := Filesystem.new()
	fs2.directory = Directory.new("res://")
	browser.configure(fs2, "res://", previewer)
	check(not fs.is_connected("filesystem_changed", browser.request_refresh), "reconfigure disconnects old filesystem")
	await settle(browser)
	check(browser.get_index_entries().is_empty(), "empty project publishes empty index")
	root.remove_child(browser)
	check(not fs2.is_connected("filesystem_changed", browser.request_refresh), "teardown disconnects filesystem")
	root.add_child(browser)
	await settle(browser)
	check(fs2.is_connected("filesystem_changed", browser.request_refresh), "re-enter reconnects without rebuilding controls")
	check(browser.get_child_count() == 1, "re-enter does not duplicate browser layout")
	root.remove_child(browser)
	browser.free()
	if "--fail-probe" in OS.get_cmdline_user_args():
		check(false, "deliberate harness failure probe")
	if failures == 0:
		print("MATERIAL_BROWSER_PASS checks=%d" % checks)
	quit(0 if failures == 0 else 1)
