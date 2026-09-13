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
	test_operations()
	await test_checked_bake()
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
	for generated in loader.find_children("*", "", true, false):
		checks.check(generated.owner == loader, "root loader owns generated output")
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

func test_checked_bake() -> void:
	var scene = Node3D.new()
	scene.name = "BakeScene"
	root.add_child(scene)
	var loader = ClassDB.instantiate("TBLoader")
	scene.add_child(loader)
	loader.owner = scene
	loader.map_resource = "res://fixtures/classic_cube.map"
	var result = loader.build_meshes_checked()
	if not expect_ok(result, "checked initial bake"):
		scene.free()
		return
	checks.check(result.changed and result.value == {"path": loader.map_resource, "child_count": 1}, "checked bake success value")
	var old_children = loader.get_children()
	var old_mesh = loader.find_children("*", "MeshInstance3D", true, false)[0]
	var old_resource = old_mesh.mesh
	var old_collision = loader.find_children("*", "CollisionShape3D", true, false)[0]
	var cube: String = FileAccess.get_file_as_string(loader.map_resource)
	var failures = [
		["user://missing-bake.map", "IO_NOT_FOUND", ""],
		["user://invalid-bake.map", "PARSE_ERROR", "{\n"],
		["user://invalid-solid.map", "INVALID_GEOMETRY", cube.replace("0 0 0 1 1", "0 0 0 0 1")],
		["user://invalid-resource.map", "RESOURCE_LOAD_FAILED", cube.replace("baseline/checker", '"res://missing-material.res"')],
		["user://failed-generation.map", "GENERATION_FAILED", cube + '{"classname" "native_missing_entity"}\n'],
		["user://failed-audio.map", "GENERATION_FAILED", cube + '{"classname" "target_speaker" "sound" "res://missing-audio.ogg"}\n'],
	]
	for failure in failures:
		if not failure[2].is_empty():
			write_text(failure[0], failure[2])
		loader.map_resource = failure[0]
		result = loader.build_meshes_checked()
		checks.check(result.size() == 4 and not result.ok and not result.changed and result.value == null, "failed bake Result schema")
		checks.check(result.error.has_all(["code", "message", "operation", "path", "line", "column", "entity_id", "brush_id", "face"]), "bake complete error diagnostic")
		checks.check(result.error.code == StringName(failure[1]) and result.error.operation == &"build_meshes_checked" and result.error.path == failure[0], "bake error identifies bake rather than save: " + str(result.error))
		if failure[1] == "PARSE_ERROR":
			checks.check(result.error.line > 0 and result.error.column > 0, "bake reports parser location")
		await process_frame
		checks.check(loader.get_children() == old_children and is_instance_valid(old_mesh) and old_mesh.mesh == old_resource and is_instance_valid(old_collision), "failure retains exact successful baked nodes and resources")
	loader.map_inverse_scale = 0
	checks.check(loader.build_meshes_checked().error.code == &"INVALID_ARGUMENT" and loader.get_children() == old_children, "invalid bake settings retain output")
	loader.map_inverse_scale = 38
	loader.map_resource = "res://fixtures/classic_cube.map"
	expect_ok(loader.build_meshes_checked(), "successful replacement after failed generation")
	await process_frame
	checks.check(not is_instance_valid(old_mesh), "successful replacement retires prior bake")
	for generated in loader.find_children("*", "", true, false):
		checks.check(generated.owner == scene, "generated mesh and collider owned by scene parent")
	var packed = PackedScene.new()
	checks.check(packed.pack(scene) == OK, "pack baked scene")
	var restored = packed.instantiate()
	checks.check(restored.find_children("*", "MeshInstance3D", true, false).size() == 1 and restored.find_children("*", "CollisionShape3D", true, false).size() == 1, "packed scene preserves mesh and collision")
	restored.free()
	# Instantiated scene-local ownership survives the staging-parent transfer.
	var entity_root = Node3D.new()
	entity_root.name = "EntityRoot"
	var internal = Node3D.new()
	internal.name = "Internal"
	entity_root.add_child(internal)
	internal.owner = entity_root
	var entity_scene = PackedScene.new()
	checks.check(entity_scene.pack(entity_root) == OK, "pack native entity fixture")
	checks.check(ResourceSaver.save(entity_scene, "res://native_entity.tscn") == OK, "save native entity fixture")
	entity_root.free()
	loader.entity_path = "res://"
	write_text("user://entity-bake.map", '{"classname" "worldspawn"}\n' + cube.replace('"classname" "worldspawn"', '"classname" "native_entity"'))
	loader.map_resource = "user://entity-bake.map"
	expect_ok(loader.build_meshes_checked(), "bake custom PackedScene entity")
	var instances = loader.find_children("Internal", "Node3D", true, false)
	checks.check(instances.size() == 1 and instances[0].owner == instances[0].get_parent() and instances[0].get_parent().owner == scene, "scene-internal owner stays on entity instance")
	var entity_meshes = loader.find_children("*", "MeshInstance3D", true, false)
	checks.check(entity_meshes.size() == 1 and entity_meshes[0].owner == scene and entity_meshes[0].get_parent() == instances[0].get_parent(), "generated brush mesh within entity keeps outer scene ownership")
	var saved_doc = ClassDB.instantiate("TBMapDocument")
	expect_ok(saved_doc.import_text(cube + '{"classname" "native_missing_entity"}\n'), "prepare save versus bake failure")
	expect_ok(saved_doc.save_map("user://saved-unbakeable.map"), "saving valid map with unresolved entity succeeds")
	loader.map_resource = saved_doc.get_path()
	var saved_bytes: String = FileAccess.get_file_as_string(saved_doc.get_path())
	checks.check(not loader.build_meshes_checked().ok and not saved_doc.is_dirty() and FileAccess.get_file_as_string(saved_doc.get_path()) == saved_bytes, "failed bake leaves successfully saved file and baseline intact")

	# Save fixtures in this runner's disposable project, outside the texture root.
	checks.check(DirAccess.make_dir_recursive_absolute("res://native-bake-assets") == OK, "create native resource fixtures")
	var checker = load("res://textures/baseline/checker.png") as Texture2D
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.4, 0.8)
	material.albedo_texture = checker
	for extension in ["tres", "res"]:
		checks.check(ResourceSaver.save(material, "res://native-bake-assets/standalone." + extension) == OK, "save standalone Material " + extension)
	checks.check(ResourceSaver.save(material, "res://native-bake-assets/standalone 日本語 space.tres") == OK, "save Unicode spaced Material path")
	var gradient = GradientTexture2D.new()
	gradient.gradient = Gradient.new()
	gradient.width = 64
	gradient.height = 32
	checks.check(ResourceSaver.save(gradient, "res://native-bake-assets/texture.tres") == OK, "save native Texture2D resource")
	checks.check(ResourceSaver.save(material, "res://textures/baseline/legacy.tres") == OK, "save legacy material override")
	var priority = StandardMaterial3D.new()
	priority.albedo_color = Color.RED
	checks.check(ResourceSaver.save(priority, "res://textures/baseline/legacy.material") == OK, "save legacy .material priority")
	checks.check(loader.resolve_material("baseline/legacy").material == load("res://textures/baseline/legacy.material"), "legacy .material precedes .tres")
	checks.check(loader.resolve_material("baseline/checker").texture == checker, "legacy extensionless texture lookup")
	checks.check(ResourceSaver.save(priority, "res://textures/baseline/checker.tres") == OK, "save shadowing legacy companion material")
	checks.check(loader.resolve_material("baseline/checker").material == load("res://textures/baseline/checker.tres"), "legacy companion Material overrides generated texture material")
	checks.check(loader.resolve_material("res://textures/baseline/checker.png").texture == checker, "explicit texture bypasses legacy root")
	checks.check(loader.resolve_material("res://textures/baseline/checker.png").material != load("res://textures/baseline/checker.tres"), "explicit texture bypasses shadowing companion Material")
	loader.texture_path = "res://native-bake-assets"
	var tokens = ["res://textures/baseline/checker.png", "res://native-bake-assets/standalone.tres", "res://native-bake-assets/standalone.res", "res://native-bake-assets/standalone 日本語 space.tres", "standalone 日本語 space.tres", "standalone.tres", "standalone.res", "standalone", "res://native-bake-assets/texture.tres"]
	for token in tokens:
		var resolution: Dictionary = loader.resolve_material(token)
		checks.check(resolution.resolved and resolution.material is Material and resolution.texture_size == Vector2i(64, 32), "native preview resolves resource and dimensions: " + token)
		var doc = ClassDB.instantiate("TBMapDocument")
		var created = doc.create_cuboid(Vector3(-16, -32, -8), Vector3(48, 32, 24), token)
		expect_ok(created, "create explicit token cuboid")
		expect_ok(doc.save_map("user://material-bake.map"), "save explicit token map")
		var reopened = ClassDB.instantiate("TBMapDocument")
		expect_ok(reopened.load_map(doc.get_path()), "reload explicit token map")
		checks.check(reopened.get_texture_names().has(token), "serialized token survives document reload")
		expect_ok(reopened.set_texture_sizes({token: resolution.texture_size}), "use native resolver for preview dimensions")
		loader.map_resource = reopened.get_path()
		expect_ok(loader.build_meshes_checked(), "bake selected project resource: " + token)
		checks.check(not doc.is_dirty(), "bake does not affect saved document baseline")
		var meshes = loader.find_children("*", "MeshInstance3D", true, false)
		if not checks.check(meshes.size() == 1, "resource bake produces mesh"):
			continue
		var mesh: ArrayMesh = meshes[0].mesh
		var actual: Material = mesh.surface_get_material(0)
		if "standalone" in token:
			checks.check(actual == resolution.material, "bake uses identical standalone Material resource")
		else:
			checks.check(actual is StandardMaterial3D and actual.albedo_texture == resolution.texture, "bake uses identical project Texture2D resource")
		var baked_uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		var preview_uvs: PackedVector2Array = reopened.get_preview_data()[0].uvs
		checks.check(baked_uvs.size() == preview_uvs.size(), "preview and bake UV cardinality")
		for i in mini(baked_uvs.size(), preview_uvs.size()):
			checks.check(baked_uvs[i].is_equal_approx(preview_uvs[i]), "native preview/bake texture dimensions and UV parity")
		var shapes = loader.find_children("*", "CollisionShape3D", true, false)
		checks.check(shapes.size() == 1 and shapes[0].shape is ConcavePolygonShape3D and shapes[0].shape.get_faces().size() == 36, "resource bake retains twelve-triangle collision")
	var shader_material = ShaderMaterial.new()
	checks.check(ResourceSaver.save(shader_material, "res://native-bake-assets/shader.res") == OK, "save standalone ShaderMaterial")
	var shader_resolution = loader.resolve_material("res://native-bake-assets/shader.res")
	checks.check(shader_resolution.resolved and shader_resolution.material == load("res://native-bake-assets/shader.res") and shader_resolution.texture_size == Vector2i.ONE, "arbitrary Material preserves resource with fallback dimensions")
	checks.check(ResourceSaver.save(Resource.new(), "res://native-bake-assets/not-material.tres") == OK, "save wrong resource type fixture")
	checks.check(not loader.resolve_material("res://native-bake-assets/not-material.tres").resolved, "direct lookup rejects non-Material non-Texture2D resource")

	# Template resolution is shared, and the template itself must stay unchanged.
	loader.texture_material_template = priority
	var templated = loader.resolve_material("res://textures/baseline/checker.png")
	checks.check(templated.material != priority and templated.material.albedo_color == priority.albedo_color and templated.material.albedo_texture == checker and priority.albedo_texture == null, "shared resolver duplicates material template")
	loader.map_resource = "res://fixtures/empty.map"
	result = loader.build_meshes_checked()
	checks.check(result.ok and result.changed and result.value.child_count == 0 and loader.get_child_count() == 0, "empty map commits empty bake")
	result = loader.build_meshes_checked()
	checks.check(result.ok and not result.changed, "empty to empty bake reports no output change")
	scene.free()
	await process_frame

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

func brush_data(doc, id: int) -> Dictionary:
	for brush in doc.get_draw_data():
		if brush.id == id:
			return brush
	return {}

func assert_solid(doc, id: int, expected_volume: float = -1.0) -> void:
	var b = brush_data(doc, id)
	if not checks.check(not b.is_empty(), "solid has stable draw handle"):
		return
	# A clipped triangular prism's AABB center can lie on its diagonal face.
	var center = Vector3.ZERO
	for vertex in b.vertices:
		center += vertex
	center /= b.vertices.size()
	var volume = 0.0
	var edge_counts = {}
	checks.check(b.vertices.size() - b.edge_vertex_indices.size() / 2 + b.faces.size() == 2, "convex hull Euler characteristic")
	for f in b.faces:
		checks.check(f.normal.is_normalized() and f.normal.dot(f.center - center) > 0, "outward unit face normal")
		for i in f.winding.size():
			checks.check(f.winding[i].is_equal_approx(b.vertices[f.vertex_indices[i]]), "face component refers to copied unique vertex")
			var a: int = f.vertex_indices[i]
			var c: int = f.vertex_indices[(i + 1) % f.vertex_indices.size()]
			var key = Vector2i(mini(a, c), maxi(a, c))
			edge_counts[key] = edge_counts.get(key, 0) + 1
		for i in range(1, f.winding.size() - 1):
			var a: Vector3 = f.winding[0] - center
			var c: Vector3 = f.winding[i] - center
			var d: Vector3 = f.winding[i + 1] - center
			checks.check((c - a).cross(d - a).dot(f.normal) < 0, "clockwise outward face winding")
			volume -= a.dot(c.cross(d)) / 6.0
	for count in edge_counts.values():
		checks.check(count == 2, "closed manifold paired edge")
	checks.check(volume > 0 and is_finite(volume), "positive finite signed volume")
	if expected_volume >= 0:
		checks.check(is_equal_approx(volume, expected_volume), "expected solid volume: " + str(volume))
	for surface in doc.get_preview_data():
		checks.check(surface.indices.size() == surface.triangle_brush_ids.size() * 3 and surface.triangle_face_indices.size() == surface.triangle_brush_ids.size(), "preview triangle ownership cardinality")
		for t in surface.triangle_brush_ids.size():
			if surface.triangle_brush_ids[t] != id:
				continue
			var i: int = surface.indices[t * 3]
			var j: int = surface.indices[t * 3 + 1]
			var k: int = surface.indices[t * 3 + 2]
			var normal: Vector3 = surface.normals[i]
			checks.check((surface.vertices[j] - surface.vertices[i]).cross(surface.vertices[k] - surface.vertices[i]).dot(normal) < 0, "Godot clockwise preview triangles")
			checks.check(normal.is_equal_approx(b.faces[surface.triangle_face_indices[t]].normal), "preview outward normal and owning face")

func test_operations() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var events = {"map": 0, "preview": 0, "dirty": 0}
	doc.map_changed.connect(func(_r): events.map += 1)
	doc.preview_changed.connect(func(): events.preview += 1)
	doc.dirty_changed.connect(func(_d): events.dirty += 1)
	var created = doc.create_cuboid(Vector3(-16, -32, -8), Vector3(48, 32, 24), "baseline/checker")
	if not expect_ok(created, "native cuboid creation"):
		return
	var id: int = created.value
	checks.check(events.map == 1 and doc.get_draw_data().size() == 1, "create emits one consistent content commit")
	assert_solid(doc, id, 64 * 64 * 32)
	var b = brush_data(doc, id)
	checks.check(b.aabb_min == Vector3(-16, -32, -8) and b.aabb_max == Vector3(48, 32, 24), "created exact map bounds")
	checks.check(b.vertices.size() == 8 and b.edges.size() == 24 and b.faces.size() == 6, "cuboid unique vertices edges and faces")
	var snapshot = doc.snapshot().value
	var state_before = state(doc)
	var preview_before = doc.get_preview_data()
	var events_before = events.duplicate()
	for result in [doc.delete_brushes(PackedInt64Array()), doc.translate_brushes(PackedInt64Array([id, id]), Vector3.ZERO), doc.set_brush_texture(PackedInt64Array([id]), "baseline/checker"), doc.translate_face(id, 0, Vector3(0, 10, 0), b.topology_revision)]:
		expect_ok(result, "empty or unchanged operation")
		checks.check(not result.changed, "no-op reports unchanged")
	checks.check(state(doc) == state_before and events == events_before, "no-op operations emit nothing")
	expect_failure(doc, doc.create_cuboid(Vector3.ZERO, Vector3(0, 1, 1), "x"), state_before, "INVALID_ARGUMENT", "create_cuboid")
	expect_failure(doc, doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 0.000001, "x"), state_before, "INVALID_GEOMETRY", "create_cuboid")
	expect_failure(doc, doc.translate_brushes(PackedInt64Array([id, 999999]), Vector3.ONE), state_before, "INVALID_ID", "translate_brushes")
	expect_failure(doc, doc.translate_brushes(PackedInt64Array([id]), Vector3(INF, 0, 0)), state_before, "INVALID_ARGUMENT", "translate_brushes")
	expect_failure(doc, doc.translate_face(id, 0, Vector3(65, 0, 0), b.topology_revision), state_before, "INVALID_GEOMETRY", "translate_face")
	expect_failure(doc, doc.translate_face(id, 0, Vector3(64, 0, 0), b.topology_revision), state_before, "INVALID_GEOMETRY", "translate_face")
	expect_failure(doc, doc.set_face_uv(id, 0, Vector2.ZERO, 0, Vector2(0, 1), b.topology_revision), state_before, "INVALID_ARGUMENT", "set_face_uv")
	checks.check(doc.get_preview_data() == preview_before and events == events_before, "invalid candidates retain cache and signals")
	expect_ok(doc.set_texture_sizes({"baseline/checker": Vector2i(64, 32)}), "resolve asymmetric preview texture dimensions")
	checks.check(state(doc) == state_before and events.preview == events_before.preview + 1 and events.map == events_before.map, "texture cache does not dirty or revise document")
	checks.check(brush_data(doc, id).topology_revision == b.topology_revision, "texture sizes preserve component handles")
	var preview = doc.get_preview_data()[0]
	checks.check(preview.texture_size == Vector2i(64, 32), "actual texture dimensions in preview")
	for i in preview.uvs.size():
		checks.check(preview.uvs[i].is_equal_approx(preview_before[0].uvs[i] / Vector2(64, 32)), "UV normalized by independent width and height")
	preview.vertices[0] = Vector3(999, 999, 999)
	b.faces[0].winding[0] = Vector3(999, 999, 999)
	checks.check(doc.get_preview_data()[0].vertices[0] != preview.vertices[0] and brush_data(doc, id).faces[0].winding[0] != b.faces[0].winding[0], "draw and preview are independent copies")
	expect_failure(doc, doc.set_texture_sizes({"baseline/checker": Vector2i(0, 32)}), state_before, "INVALID_ARGUMENT", "set_texture_sizes")
	expect_ok(doc.set_face_uv(id, 0, Vector2(8, -4), 90, Vector2(0.5, 2), b.topology_revision), "classic UV assignment")
	b = brush_data(doc, id)
	var uv = doc.get_face_uv(id, 0, b.topology_revision).value
	checks.check(uv.projection == "classic" and uv.shift == Vector2(8, -4) and uv.rotation == 90 and uv.scale == Vector2(0.5, 2), "UV query reflects assignment")
	preview = doc.get_preview_data()[0]
	for i in 4:
		var p: Vector3 = preview.vertices[i]
		checks.check(preview.uvs[i].is_equal_approx(Vector2((p.z / 0.5 + 8) / 64, (p.y / 2 - 4) / 32)), "classic rotated shifted scaled analytic UV")
	var stale: int = b.topology_revision
	expect_ok(doc.translate_face(id, 0, Vector3(-16, 0, 0), stale), "face outward resize")
	assert_solid(doc, id, 80 * 64 * 32)
	checks.check(brush_data(doc, id).aabb_min.x == -32, "resized face moves bounds")
	expect_failure(doc, doc.set_face_texture(id, 0, "other", stale), state(doc), "STALE_COMPONENT", "set_face_texture")
	expect_ok(doc.translate_brushes(PackedInt64Array([id, id]), Vector3(16, 8, 4)), "deduplicated translation")
	checks.check(brush_data(doc, id).aabb_min == Vector3(-16, -24, -4), "deduplicated batch moves once")
	var copies = doc.duplicate_brushes(PackedInt64Array([id, id]))
	expect_ok(copies, "duplicate preserves owner and allocates stable ID")
	var clone: int = copies.value[0]
	checks.check(copies.value.size() == 1 and clone == id + 1 and brush_data(doc, clone).aabb_min == brush_data(doc, id).aabb_min, "duplicate is in place; rejected candidates did not consume IDs")
	expect_ok(doc.delete_brushes(PackedInt64Array([id])), "delete original")
	checks.check(brush_data(doc, id).is_empty() and not brush_data(doc, clone).is_empty(), "deletion cannot retarget surviving handle")
	expect_ok(doc.restore_snapshot(snapshot), "undo native operations")
	checks.check(brush_data(doc, clone).is_empty() and not brush_data(doc, id).is_empty(), "undo restores primitive identities")
	var branch = doc.duplicate_brushes(PackedInt64Array([id]))
	checks.check(branch.ok and branch.value[0] > clone, "abandoned redo IDs are not reused")
	expect_ok(doc.save_map("user://operations.map"), "save native mutations")
	var saved = doc.snapshot().value
	expect_ok(doc.set_brush_texture(PackedInt64Array([id]), "other/name"), "brush texture assignment")
	expect_ok(doc.restore_snapshot(saved), "undo texture to saved baseline")
	checks.check(not doc.is_dirty() and doc.get_path() == "user://operations.map", "operation undo preserves latest save baseline")
	var reopened = ClassDB.instantiate("TBMapDocument")
	expect_ok(reopened.load_map("user://operations.map"), "reopen operation output")
	checks.check(reopened.export_text().value == doc.export_text().value, "native operations persist semantically")
	b = brush_data(doc, id)
	expect_ok(doc.set_face_texture(id, 0, "unknown/texture", b.topology_revision), "individual face texture assignment")
	var unknown = {}
	for surface in doc.get_preview_data():
		if surface.texture == "unknown/texture":
			unknown = surface
	checks.check(not unknown.is_empty() and unknown.texture_size == Vector2i.ONE and unknown.triangle_brush_ids == PackedInt64Array([id, id]) and unknown.triangle_face_indices == PackedInt32Array([0, 0]), "preview groups exact texture with fallback dimensions and face ownership")
	checks.check(doc.get_texture_names().has("unknown/texture"), "texture names include assigned face shader")
	for axis in 3:
		expect_ok(doc.restore_snapshot(snapshot), "reset for prism")
		expect_ok(doc.make_prism(id, 5, axis), "five sided prism axis " + str(axis))
		assert_solid(doc, id)
		checks.check(brush_data(doc, id).faces.size() == 7, "prism caps and sides")
	expect_failure(doc, doc.make_prism(id, 2, 2), state(doc), "INVALID_ARGUMENT", "make_prism")
	expect_ok(doc.restore_snapshot(snapshot), "reset for vertex edits")
	b = brush_data(doc, id)
	expect_failure(doc, doc.translate_vertices(id, PackedInt32Array([0]), Vector3(1, 2, 3), b.topology_revision), state(doc), "INVALID_GEOMETRY", "translate_vertices")
	expect_failure(doc, doc.translate_vertices(id, PackedInt32Array([0, 99]), Vector3.ONE, b.topology_revision), state(doc), "INVALID_ARGUMENT", "translate_vertices")
	var face_vertices: PackedInt32Array = b.faces[0].vertex_indices
	face_vertices.append(face_vertices[0])
	expect_ok(doc.translate_vertices(id, face_vertices, Vector3(-16, 0, 0), b.topology_revision), "coplanar face vertex batch resize")
	assert_solid(doc, id, 80 * 64 * 32)
	expect_failure(doc, doc.translate_vertices(id, face_vertices, Vector3.ONE, b.topology_revision), state(doc), "STALE_COMPONENT", "translate_vertices")
	test_clipping(doc, snapshot, id)
	expect_ok(doc.load_map("res://fixtures/valve_cube.map"), "Valve preview fixture")
	id = doc.get_draw_data()[0].id
	b = brush_data(doc, id)
	uv = doc.get_face_uv(id, 0, b.topology_revision).value
	checks.check(uv.projection == "valve" and uv.u_axis == Vector3(0, 1, 0) and uv.v_axis == Vector3(0, 0, -1), "Valve axes copied exactly")
	expect_failure(doc, doc.set_face_uv(id, 0, Vector2.ZERO, 0, Vector2.ONE, b.topology_revision), state(doc), "UNSUPPORTED_PROJECTION", "set_face_uv")
	expect_ok(doc.set_texture_sizes({"baseline/checker": Vector2i(128, 64)}), "Valve dimensions")
	preview = doc.get_preview_data()[0]
	for i in preview.vertices.size():
		var face_index: int = i / 4
		var face_uv = doc.get_face_uv(id, face_index, b.topology_revision).value
		var p: Vector3 = preview.vertices[i]
		var expected = Vector2(p.dot(face_uv.u_axis) / face_uv.scale.x + face_uv.shift.x, p.dot(face_uv.v_axis) / face_uv.scale.y + face_uv.shift.y) / Vector2(128, 64)
		checks.check(preview.uvs[i].is_equal_approx(expected), "Valve analytic UV normalization")
	test_entities_and_clipboard(doc)

func test_clipping(doc, snapshot: Dictionary, id: int) -> void:
	expect_ok(doc.restore_snapshot(snapshot), "reset for clipping")
	var before = state(doc)
	var p0 = Vector3(0, 0, 0)
	var p1 = Vector3(0, 0, 1)
	var p2 = Vector3(0, 1, 0)
	expect_failure(doc, doc.clip_brushes(PackedInt64Array([id]), p0, p1, p1, false), before, "INVALID_ARGUMENT", "clip_brushes")
	expect_failure(doc, doc.clip_brushes(PackedInt64Array([id, 999999]), p0, p1, p2, true), before, "INVALID_ID", "clip_brushes")
	var noop = doc.clip_brushes(PackedInt64Array([id]), Vector3(48, 0, 0), Vector3(48, 0, 1), Vector3(48, 1, 0), true)
	expect_ok(noop, "tangent split no-op")
	checks.check(not noop.changed and noop.value == PackedInt64Array([id]) and state(doc) == before, "tangent split preserves IDs and revision")
	var clipped = doc.clip_brushes(PackedInt64Array([id, id]), p0, p1, p2, false)
	expect_ok(clipped, "one-sided clip retains negative half-space")
	checks.check(clipped.value == PackedInt64Array([id]) and brush_data(doc, id).aabb_max.x == 0, "clip keeps stable original ID and correct side")
	assert_solid(doc, id, 16 * 64 * 32)
	checks.check(brush_data(doc, id).faces.size() == 6, "clip prunes old empty supporting face")
	expect_ok(doc.restore_snapshot(snapshot), "undo one-sided clip")
	var split = doc.clip_brushes(PackedInt64Array([id]), p0, p1, p2, true)
	expect_ok(split, "split intersected brush")
	checks.check(split.value.size() == 2 and split.value[0] != id and split.value[1] != id and split.value[0] != split.value[1] and brush_data(doc, id).is_empty(), "split replaces original with two fresh IDs")
	assert_solid(doc, split.value[0], 16 * 64 * 32)
	assert_solid(doc, split.value[1], 48 * 64 * 32)
	var split_snapshot = doc.snapshot().value
	expect_ok(doc.restore_snapshot(snapshot), "undo split")
	expect_ok(doc.restore_snapshot(split_snapshot), "redo split with same issued identities")
	checks.check(not brush_data(doc, split.value[0]).is_empty() and not brush_data(doc, split.value[1]).is_empty(), "split redo stable handles")
	expect_ok(doc.restore_snapshot(snapshot), "reset for diagonal cut")
	var diagonal = doc.clip_brushes(PackedInt64Array([id]), Vector3(16, 0, 0), Vector3(16, 0, 1), Vector3(15, 1, 0), true)
	expect_ok(diagonal, "diagonal split through hull edges")
	if diagonal.ok:
		for result_id in diagonal.value:
			assert_solid(doc, result_id, 64 * 64 * 32 / 2)
	expect_ok(doc.restore_snapshot(snapshot), "reset for discarded clip")
	var removed = doc.clip_brushes(PackedInt64Array([id]), Vector3(-32, 0, 0), Vector3(-32, 0, 1), Vector3(-32, 1, 0), false)
	expect_ok(removed, "clip entirely discarded brush")
	checks.check(removed.value.is_empty() and doc.get_draw_data().is_empty() and doc.get_preview_data().is_empty(), "discard clip leaves safe empty-world caches")

func test_entities_and_clipboard(doc) -> void:
	expect_ok(doc.load_map("res://fixtures/ownership.map"), "entity ownership fixture")
	var entities = doc.get_entities()
	var world: int = entities[0].id
	var owner: int = entities[1].id
	var id: int = entities[1].primitives[0].id
	var original = doc.snapshot().value
	expect_ok(doc.set_entity_property(world, "duplicate", "edited"), "ordered entity property assignment")
	# Fixture keys are deliberately inspected rather than assumed by position.
	var key: String = entities[0].epairs[1].key
	expect_ok(doc.set_entity_property(world, key, "first edited"), "edit first duplicate epair")
	checks.check(doc.get_entities()[0].epairs[1].value == "first edited" and doc.get_entities()[0].epairs[2] == entities[0].epairs[2], "first duplicate changes in place; later duplicate preserved")
	expect_ok(doc.remove_entity_property(world, key), "remove all occurrences of property")
	for pair in doc.get_entities()[0].epairs:
		checks.check(pair.key != key, "removed duplicate property cannot reappear")
	expect_ok(doc.set_entity_property(owner, "unknown appended", "日本語 \\\" value"), "append unknown escaped UTF-8 epair")
	var selection = doc.export_selection(PackedInt64Array([id, id]))
	expect_ok(selection, "map-text clipboard export")
	checks.check(selection.value.contains("unknown appended") and not selection.value.contains('"classname" "worldspawn"'), "clipboard includes selected owner epairs only")
	var pasted = doc.import_selection(selection.value)
	expect_ok(pasted, "brush entity clipboard paste")
	var pasted_id: int = pasted.value[0]
	checks.check(pasted.value.size() == 1 and pasted_id != id and brush_data(doc, pasted_id).entity_id != owner, "paste allocates fresh primitive and owner IDs")
	checks.check(doc.get_entities()[-1].epairs == doc.get_entities()[1].epairs, "paste preserves exact ordered owner properties")
	var point = doc.create_point_entity("info_player_start", Vector3(1, 2, 3))
	expect_ok(point, "create point entity")
	var point_id: int = point.value
	expect_ok(doc.translate_point_entities(PackedInt64Array([point_id, point_id]), Vector3(3, 4, 5)), "move point entity once")
	checks.check(doc.get_entities()[-1].epairs[1] == {"key": "origin", "value": "4 6 8"}, "point origin updated in map space")
	var unchanged = state(doc)
	checks.check(not doc.set_entity_property(point_id, "origin", "4 6 8").changed and not doc.remove_entity_property(point_id, "absent").changed and not doc.translate_point_entities(PackedInt64Array([point_id]), Vector3.ZERO).changed and state(doc) == unchanged, "unchanged entity mutations create no revision")
	expect_failure(doc, doc.translate_point_entities(PackedInt64Array([point_id, owner]), Vector3.ONE), state(doc), "INVALID_ARGUMENT", "translate_point_entities")
	expect_failure(doc, doc.set_entity_property(point_id, "origin", "bad coordinates"), state(doc), "INVALID_ARGUMENT", "set_entity_property")
	expect_failure(doc, doc.set_entity_property(world, "classname", "light"), state(doc), "INVALID_ARGUMENT", "set_entity_property")
	expect_failure(doc, doc.delete_entities(PackedInt64Array([point_id, world]), true), state(doc), "INVALID_ARGUMENT", "delete_entities")
	var grouped = doc.group_brushes(PackedInt64Array([pasted_id, id]), "func_detail")
	expect_ok(grouped, "group selected brushes into stable brush entity")
	checks.check(brush_data(doc, id).entity_id == grouped.value and brush_data(doc, pasted_id).entity_id == grouped.value, "group reparent preserves brush handles")
	checks.check(doc.get_entities()[-1].primitives[0].id == pasted_id, "group follows deduplicated selection order")
	expect_ok(doc.return_brushes_to_worldspawn(PackedInt64Array([id])), "return brush to worldspawn")
	checks.check(brush_data(doc, id).entity_id == world, "return preserves world and brush IDs")
	var grouped_snapshot = doc.snapshot().value
	expect_ok(doc.delete_entities(PackedInt64Array([grouped.value]), false), "delete owner returning brushes")
	checks.check(brush_data(doc, pasted_id).entity_id == world, "explicit keep-brush deletion rehomes to world")
	expect_ok(doc.restore_snapshot(grouped_snapshot), "undo entity ownership deletion")
	expect_ok(doc.delete_entities(PackedInt64Array([grouped.value]), true), "delete owner and owned brushes")
	checks.check(brush_data(doc, pasted_id).is_empty() and not brush_data(doc, id).is_empty(), "owned-brush deletion is explicit and scoped")
	expect_ok(doc.delete_entities(PackedInt64Array([point_id]), false), "delete point entity")
	expect_failure(doc, doc.set_entity_property(point_id, "x", "y"), state(doc), "INVALID_ID", "set_entity_property")
	var world_paste = doc.import_selection(doc.export_selection(PackedInt64Array([id])).value)
	expect_ok(world_paste, "world selection clipboard merge")
	checks.check(brush_data(doc, world_paste.value[0]).entity_id == world, "world clipboard merges into existing world handle")
	expect_ok(doc.save_map("user://entities.map"), "save entity mutations")
	var saved = doc.snapshot().value
	expect_ok(doc.restore_snapshot(original), "undo entity session to original")
	expect_ok(doc.restore_snapshot(saved), "redo entity session to save")
	checks.check(not doc.is_dirty() and doc.snapshot().value.identities == saved.identities, "entity save undo redo stable identities and clean baseline")
	expect_ok(doc.load_map("res://fixtures/patches.map"), "patch preservation fixture")
	var patch_state = doc.snapshot().value
	var cube = doc.create_cuboid(Vector3.ZERO, Vector3(16, 16, 16), "baseline/checker")
	expect_ok(cube, "create brush alongside patches")
	expect_ok(doc.translate_brushes(PackedInt64Array([cube.value]), Vector3.ONE), "edit brush alongside patches")
	expect_ok(doc.delete_brushes(PackedInt64Array([cube.value])), "delete brush alongside patches")
	checks.check(doc.export_text().value == patch_state.text and doc.snapshot().value.identities == patch_state.identities, "brush edits retain exact patch text order and handles")
	expect_failure(doc, doc.import_selection(patch_state.text), state(doc), "UNSUPPORTED_SYNTAX", "import_selection")
	expect_failure(doc, doc.delete_entities(PackedInt64Array([doc.get_entities()[0].id]), true), state(doc), "INVALID_ARGUMENT", "delete_entities")
