extends SceneTree

const Checks = preload("res://checks.gd")
var checks = Checks.new()

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if not checks.check(ClassDB.class_exists("TBLoader"), "real native TBLoader is registered"):
		checks.finish(self, "document")
		return
	# This is the pre-document baseline, not a substitute TBMapDocument.
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
