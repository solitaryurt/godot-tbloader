extends SceneTree

const Checks = preload("res://checks.gd")
var checks = Checks.new()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if not checks.check(ClassDB.class_exists("TBLoader"), "real native TBLoader is registered"):
		checks.finish(self, "document")
		return
	test_document()
	# Preserve the real bake regression gate alongside native document assertions.
	var loader = ClassDB.instantiate("TBLoader")
	checks.check(loader is Node3D, "TBLoader inherits Node3D")
	checks.check(loader.map_inverse_scale == 38, "default inverse scale")
	checks.check(loader.has_method("build_meshes"), "native bake method bound")
	var checker = load("res://textures/baseline/checker.png") as Texture2D
	checks.check(checker != null and checker.get_size() == Vector2(64, 32), "asymmetric checker imported")
	root.add_child(loader)
	loader.map_resource = "res://fixtures/classic_cube.map"
	checks.check(loader.get_map() == loader.map_resource, "map property round trip")
	loader.build_meshes()
	await process_frame
	var meshes = loader.find_children("*", "MeshInstance3D", true, false)
	checks.check(meshes.size() == 1, "cube produces one material mesh")
	var triangles: int = 0
	var points: Array[Vector3] = []
	for instance in meshes:
		for surface in instance.mesh.get_surface_count():
			var arrays = instance.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangles += (indices.size() if not indices.is_empty() else vertices.size()) / 3
			checks.check(normals.size() == vertices.size(), "normal per vertex")
			checks.check(uvs.size() == vertices.size(), "UV per vertex")
			for vertex in vertices:
				checks.check(vertex.is_finite(), "finite baked vertex")
				points.append(instance.global_transform * vertex)
			for normal in normals:
				checks.check(normal.is_finite(), "finite baked normal")
			for uv in uvs:
				checks.check(uv.is_finite(), "finite texture UV")
	checks.check(triangles == 12, "six cube faces produce twelve triangles")
	if checks.check(not points.is_empty(), "cube has vertices"):
		var bounds = AABB(points[0], Vector3.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		checks.check(bounds.position.is_equal_approx(Vector3(-32, -8, -16) / 38.0), "map to Godot minimum (y,z,x)/38")
		checks.check(bounds.end.is_equal_approx(Vector3(32, 24, 48) / 38.0), "map to Godot maximum (y,z,x)/38")
	checks.check(loader.find_children("*", "CollisionShape3D", true, false).size() == 1, "cube collision generated")
	loader.free()
	await process_frame
	var empty_loader = ClassDB.instantiate("TBLoader")
	root.add_child(empty_loader)
	empty_loader.map_resource = "res://fixtures/empty.map"
	empty_loader.build_meshes()
	await process_frame
	checks.check(empty_loader.get_child_count() == 0, "empty worldspawn bake is safe")
	empty_loader.free()
	for fixture in ["classic_cube", "valve_cube", "patches", "ownership"]:
		var roundtrip_loader = ClassDB.instantiate("TBLoader")
		root.add_child(roundtrip_loader)
		roundtrip_loader.map_resource = "user://roundtrip-" + fixture + ".map"
		roundtrip_loader.build_meshes()
		await process_frame
		var baked = roundtrip_loader.find_children("*", "MeshInstance3D", true, false)
		checks.check(baked.size() == 1, "saved " + fixture + " bakes one material mesh")
		var triangle_count: int = 0
		for instance in baked:
			for surface in instance.mesh.get_surface_count():
				var arrays = instance.mesh.surface_get_arrays(surface)
				triangle_count += arrays[Mesh.ARRAY_INDEX].size() / 3
		checks.check(triangle_count == (80 if fixture == "patches" else 12), "saved " + fixture + " bakes expected triangles/subdivisions")
		roundtrip_loader.free()
		await process_frame
	if OS.get_environment("TB_TEST_PROBE") == "assertion":
		checks.check(false, "deliberate harness failure")
	elif OS.get_environment("TB_TEST_PROBE") == "engine-error":
		push_error("deliberate engine error with successful completion")
	elif OS.get_environment("TB_TEST_PROBE") == "missing-marker":
		quit(0)
		return
	elif OS.get_environment("TB_TEST_PROBE") == "timeout":
		return
	checks.finish(self, "document")

func state(doc) -> Dictionary:
	return {"snapshot": doc.snapshot().value, "path": doc.get_path(), "dirty": doc.is_dirty(), "revision": doc.get_revision(), "epoch": doc.get_epoch(), "entities": doc.get_entities()}

func expect_ok(result: Dictionary, message: String) -> bool:
	checks.check(result.size() == 4 and result.has_all(["ok", "changed", "value", "error"]), message + " Result schema")
	return checks.check(result.ok and result.error.is_empty(), message + " succeeded: " + str(result.error))

func expect_failure(doc, result: Dictionary, before: Dictionary, code: String, operation: String) -> void:
	checks.check(result.size() == 4 and not result.ok and not result.changed and result.value == null, operation + " failed Result schema")
	checks.check(result.error.has_all(["code", "message", "operation", "path", "line", "column", "entity_id", "brush_id", "face"]), "complete error diagnostic")
	checks.check(result.error.code == StringName(code) and result.error.operation == StringName(operation), "expected error " + code + ": " + str(result.error))
	checks.check(state(doc) == before, operation + " failure preserves all document state")

func write_text(path: String, text: String) -> void:
	var file = FileAccess.open(path, FileAccess.WRITE)
	checks.check(file != null, "test output file opens")
	if file:
		file.store_string(text)
		file.close()

func test_document() -> void:
	if not checks.check(ClassDB.class_exists("TBMapDocument"), "TBMapDocument is registered"):
		return
	var doc = ClassDB.instantiate("TBMapDocument")
	checks.check(doc is RefCounted and doc.is_dirty() and doc.get_path().is_empty(), "new document is untitled and unsaved")
	checks.check(doc.get_entities()[0].epairs == [{"key": "classname", "value": "worldspawn"}], "new worldspawn properties")
	var events = {"map": 0, "dirty": 0, "preview": 0}
	doc.map_changed.connect(func(_revision): events.map += 1)
	doc.dirty_changed.connect(func(_dirty): events.dirty += 1)
	doc.preview_changed.connect(func(): events.preview += 1)
	for fixture in ["empty", "classic_cube", "valve_cube", "patches", "ownership"]:
		expect_ok(doc.load_map("res://fixtures/" + fixture + ".map"), "load " + fixture)
		checks.check(not doc.is_dirty(), "loaded document is clean")
		expect_ok(doc.save_map("user://roundtrip-" + fixture + ".map"), "save roundtrip " + fixture)
		var exported = doc.export_text()
		expect_ok(exported, "export " + fixture)
		checks.check(not exported.changed, "export is a query")
		var text: String = exported.value
		var original = state(doc)
		var other = ClassDB.instantiate("TBMapDocument")
		expect_ok(other.import_text(text), "roundtrip import " + fixture)
		checks.check(other.is_dirty() and other.get_path().is_empty(), "import unsaved and untitled")
		checks.check(other.export_text().value == text, "canonical serialization fixed point " + fixture)
		checks.check(state(doc) == original, "roundtrip query did not mutate original")
		if fixture == "classic_cube":
			checks.check(text.contains('"baseline/checker" 0 0 0 1 1\n'), "absent flags stay absent")
			checks.check(text.contains('"baseline/checker" 0 0 0 1 1 0 0 0\n'), "explicit zero flags preserved")
			checks.check(text.contains('4 -2 90 0.5 2\n'), "classic projection preserved")
		elif fixture == "valve_cube":
			checks.check(text.contains('[ 0 1 0 2.5 ] [ 0 0 -1 -0.5 ]'), "Valve axes and offsets preserved")
			checks.check(text.count("[ ") == 12, "all Valve faces remain Valve")
		elif fixture == "patches":
			checks.check(text.contains("patchDef2\n") and text.contains("( 3 3 1 2 3 )"), "def2 complete header")
			checks.check(text.contains("patchDef3\n") and text.contains("( 3 3 4 6 7 8 9 )"), "def3 discriminator, subdivisions and header flags")
			checks.check(text.contains("( -16.5 0 8 0 0.5 )") and text.contains("( 0 0 48 0.5 0.5 )"), "patch positions and control UVs")
			checks.check(doc.get_entities()[0].primitives.size() == 2 and doc.get_entities()[1].primitives.is_empty(), "patch and point entity ownership")
		elif fixture == "ownership":
			var entities = doc.get_entities()
			checks.check(entities.size() == 3 and entities[0].primitives.is_empty() and entities[1].primitives.size() == 1 and entities[2].primitives.is_empty(), "brush belongs to second entity")
			checks.check(entities[0].epairs[1].value == "first" and entities[0].epairs[2].value == "second", "duplicate epair order preserved")
			checks.check(entities[1].epairs[2].value == "日本語 café", "UTF-8 properties preserved")
			checks.check(text.contains("-0.5 2 1 134217728 -7\n"), "nonzero flags and negative fractional projection")
			entities[0].epairs.clear()
			checks.check(doc.get_entities()[0].epairs.size() == 5, "entity query returns independent data")
		var ids = doc.snapshot().value.identities
		var revision: int = doc.get_revision()
		var dirty: bool = doc.is_dirty()
		var map_events: int = events.map
		expect_ok(doc.rebuild(), "rebuild " + fixture)
		checks.check(doc.snapshot().value.identities == ids and doc.get_revision() == revision and doc.is_dirty() == dirty and events.map == map_events, "cache rebuild preserves identity, content revision and baseline")

	# Mixed primitive ordering is independent of separate native brush/patch arrays.
	var cube: String = FileAccess.get_file_as_string("res://fixtures/classic_cube.map")
	var patch_text: String = FileAccess.get_file_as_string("res://fixtures/patches.map")
	var brush = cube.substr(cube.find("{\n("), cube.rfind("}") - cube.find("{\n("))
	var mixed = patch_text.replace("{\npatchDef3", brush + "{\npatchDef3")
	expect_ok(doc.import_text(mixed), "mixed brush patch ordering")
	var primitives = doc.get_entities()[0].primitives
	checks.check(primitives.size() == 3 and primitives[0].kind == &"patch" and primitives[1].kind == &"brush" and primitives[2].kind == &"patch", "source primitive order retained")
	var canonical: String = doc.export_text().value
	checks.check(canonical.find("patchDef2") < canonical.find("( 48 -32 -8 )") and canonical.find("( 48 -32 -8 )") < canonical.find("patchDef3"), "writer emits source primitive order")
	var before = state(doc)
	var events_before = events.duplicate()
	for invalid in ["", "// only comment", "{", '{"key"}', '{"key" "unterminated}', cube.left(cube.length() - 3), cube.replace("48 -32 -8", "NaN -32 -8"), cube.replace("0 0 0 1 1 0 0 0", "0 0 0 1 1 0 0"), patch_text.replace("( 3 3 1 2 3 )", "( 4 3 1 2 3 )"), patch_text.replace("( -16.5 0 8 0 0.5 )", "( -16.5 0 8 0 )"), cube + "garbage", "/* unterminated"]:
		expect_failure(doc, doc.import_text(invalid), before, "PARSE_ERROR", "import_text")
		checks.check(doc.import_text(invalid).error.line > 0 and doc.import_text(invalid).error.column > 0, "parse location is 1-based")
	expect_failure(doc, doc.import_text('{"classname" "worldspawn" { brushDef3 { } } }'), before, "UNSUPPORTED_SYNTAX", "import_text")
	expect_failure(doc, doc.import_text(cube.replace("0 0 0 1 1", "0 0 0 0 1")), before, "INVALID_GEOMETRY", "import_text")
	expect_failure(doc, doc.import_text(patch_text.replace("( 3 3 1 2 3 )", "( 999999 3 1 2 3 )")), before, "LIMIT_EXCEEDED", "import_text")
	expect_failure(doc, doc.import_text('{"long" "' + "x".repeat(65537) + '"}'), before, "LIMIT_EXCEEDED", "import_text")
	expect_failure(doc, doc.load_map("user://missing.map"), before, "IO_NOT_FOUND", "load_map")
	write_text("user://malformed.map", "{\n")
	expect_failure(doc, doc.load_map("user://malformed.map"), before, "PARSE_ERROR", "load_map")
	for bytes in [PackedByteArray([123, 34, 255, 34, 32, 34, 120, 34, 125]), PackedByteArray([123, 0, 125]), PackedByteArray([123, 34, 237, 160, 128, 34, 125])]:
		var binary = FileAccess.open("user://invalid-encoding.map", FileAccess.WRITE)
		binary.store_buffer(bytes)
		binary.close()
		expect_failure(doc, doc.load_map("user://invalid-encoding.map"), before, "PARSE_ERROR", "load_map")
	checks.check(events == events_before, "failed operations emit no signals")
	# Long tokens formerly overflowed a 255-byte stack buffer. Empty quotes and escapes work.
	expect_ok(doc.import_text('{"classname" "worldspawn" "long" "' + "x".repeat(4096) + '"}'), "dynamic quoted tokenizer")
	checks.check(doc.get_entities()[0].epairs[1].value.length() == 4096, "long epair retained")
	expect_ok(doc.import_text(cube), "prepare snapshot fixture")
	var bom = FileAccess.open("user://bom.map", FileAccess.WRITE)
	bom.store_buffer(PackedByteArray([239, 187, 191]))
	bom.store_string(cube)
	bom.close()
	expect_ok(doc.load_map("user://bom.map"), "UTF-8 BOM load")
	checks.check(doc.export_text().value.begins_with("{\n"), "BOM normalized without semantic changes")
	var first = doc.snapshot().value
	var modified: Dictionary = first.duplicate(true)
	modified.text = modified.text.replace("Phase 0 classic cube", "Edited properties")
	var old_revision: int = doc.get_revision()
	var old_events: int = events.map
	expect_ok(doc.restore_snapshot(modified), "restore edited same-epoch snapshot")
	checks.check(doc.get_revision() > old_revision and events.map == old_events + 1, "one content signal and monotonic revision on restore")
	checks.check(doc.snapshot().value.identities == first.identities, "restore preserves stable IDs")
	expect_ok(doc.save_map("user://document.map"), "atomic save new file")
	checks.check(not doc.is_dirty() and doc.get_path() == "user://document.map", "save baseline and path")
	var saved_text: String = doc.export_text().value
	checks.check(FileAccess.get_file_as_string("user://document.map") == saved_text, "saved canonical bytes")
	var saved = doc.snapshot().value
	expect_ok(doc.restore_snapshot(first), "undo across saved baseline")
	checks.check(doc.is_dirty() and doc.get_path() == "user://document.map", "undo retains path and latest baseline")
	var dirty_state = state(doc)
	expect_failure(doc, doc.save_map("user://missing-parent/dirty.map"), dirty_state, "IO_WRITE", "save_map")
	checks.check(FileAccess.get_file_as_string("user://document.map") == saved_text, "failed dirty save retains last saved file")
	expect_ok(doc.restore_snapshot(saved), "redo to saved baseline")
	checks.check(not doc.is_dirty(), "redo to saved semantic content clears dirty")
	before = state(doc)
	events_before = events.duplicate()
	var noop = doc.restore_snapshot(saved)
	expect_ok(noop, "identical restore")
	checks.check(not noop.changed and state(doc) == before and events == events_before, "no-op restore creates no revision or signals")
	checks.check(not doc.save_map("user://document.map").changed, "saving unchanged file is not content change")
	for broken in [{}, {"schema": "1"}, {"epoch": -1}, {"text": 12}, {"identities": []}]:
		var bad = saved.duplicate(true)
		if broken.is_empty():
			bad.clear()
		else:
			bad.merge(broken, true)
		expect_failure(doc, doc.restore_snapshot(bad), before, "SNAPSHOT_MISMATCH", "restore_snapshot")
	for bad_id in [0, -1, 999999, saved.identities.entities[0].id]:
		var bad = saved.duplicate(true)
		bad.identities.entities[0].primitives[0].id = bad_id
		expect_failure(doc, doc.restore_snapshot(bad), before, "SNAPSHOT_MISMATCH", "restore_snapshot")
	var bad_shape = saved.duplicate(true)
	bad_shape.identities.entities[0].primitives.clear()
	expect_failure(doc, doc.restore_snapshot(bad_shape), before, "SNAPSHOT_MISMATCH", "restore_snapshot")
	var foreign = ClassDB.instantiate("TBMapDocument")
	expect_ok(foreign.import_text(saved.text), "foreign document with identical content")
	expect_failure(doc, doc.restore_snapshot(foreign.snapshot().value), before, "SNAPSHOT_MISMATCH", "restore_snapshot")
	expect_failure(doc, doc.save_map("user://missing-parent/fail.map"), before, "IO_WRITE", "save_map")
	checks.check(FileAccess.get_file_as_string("user://document.map") == saved_text, "failed Save As retains original file")
	# Force rename failure after a complete sibling-temp write, retaining destination.
	var blocked = "user://destination-directory"
	checks.check(DirAccess.make_dir_absolute(blocked) == OK, "create blocked destination")
	write_text(blocked + "/sentinel", "keep")
	expect_failure(doc, doc.save_map(blocked), before, "IO_WRITE", "save_map")
	checks.check(FileAccess.get_file_as_string(blocked + "/sentinel") == "keep", "rename failure preserves destination")
	var entries = DirAccess.get_files_at("user://")
	for entry in entries:
		checks.check(not entry.contains(".tbmap-"), "failed save cleans temporary file")
	write_text("user://document.map", "external editor bytes")
	expect_failure(doc, doc.save_map("user://document.map"), before, "EXTERNAL_CHANGE", "save_map")
	checks.check(FileAccess.get_file_as_string("user://document.map") == "external editor bytes", "external edit is never overwritten")
	checks.check(DirAccess.remove_absolute("user://document.map") == OK, "delete externally")
	expect_failure(doc, doc.save_map("user://document.map"), before, "EXTERNAL_CHANGE", "save_map")
	expect_ok(doc.save_map("user://save-as.map"), "save as after external removal")
	checks.check(not doc.is_dirty() and doc.get_path() == "user://save-as.map", "Save As establishes new baseline")
	expect_ok(foreign.load_map("user://save-as.map"), "reopen saved map")
	checks.check(foreign.export_text().value == saved_text, "reopen semantic content")
	var target_absolute = ProjectSettings.globalize_path("user://save-as.map")
	var link_absolute = ProjectSettings.globalize_path("user://linked.map")
	checks.check(OS.execute("ln", ["-s", target_absolute, link_absolute]) == 0, "create path alias fixture")
	expect_ok(foreign.load_map("user://linked.map"), "load via symlink")
	var foreign_before = state(foreign)
	write_text("user://save-as.map", "external alias change")
	expect_failure(foreign, foreign.save_map(target_absolute), foreign_before, "EXTERNAL_CHANGE", "save_map")
	write_text("user://save-as.map", saved_text)
	expect_ok(foreign.save_map("user://linked.map"), "save through link")
	var link_output: Array = []
	checks.check(OS.execute("readlink", [link_absolute], link_output) == 0 and str(link_output[0]).strip_edges() == target_absolute, "atomic save preserves symlink")
	var prior_epoch: int = doc.get_epoch()
	var prior_id: int = doc.get_entities()[0].id
	expect_ok(doc.new_map(), "reset document")
	checks.check(doc.get_epoch() != prior_epoch and doc.get_entities()[0].id > prior_id, "replacement changes epoch without reusing IDs")
	before = state(doc)
	expect_failure(doc, doc.restore_snapshot(saved), before, "SNAPSHOT_MISMATCH", "restore_snapshot")
	for i in 30:
		expect_ok(doc.load_map("res://fixtures/patches.map" if i % 2 else "res://fixtures/ownership.map"), "repeated lifecycle load")
		expect_ok(doc.rebuild(), "repeated lifecycle rebuild")
		expect_ok(doc.new_map(), "repeated lifecycle reset")
	checks.check(events.preview >= 35, "cache-only preview signals delivered")
