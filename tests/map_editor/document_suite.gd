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
	test_native_lookup_and_draw_schema()
	test_spatial_queries()
	test_face_summary()
	test_preview_chunks()
	test_tohunga_fixture()
	test_operations()
	test_phase2_local_transactions()
	test_phase3_document_changes()
	test_brush_topology_tokens()
	test_apply_face_edits()
	test_rotation()
	test_candidate_geometry_previews()
	test_merge_brushes()
	test_phase5()
	test_vertex_hull_sequences()
	test_vertex_hull_metadata_and_degeneracy()
	test_shallow_vertex_intersections()
	await test_checked_bake()
	# Preserve the real bake regression gate alongside native document assertions.
	var loader = ClassDB.instantiate("TBLoader")
	checks.check(loader is Node3D, "TBLoader inherits Node3D")
	checks.check(loader.map_inverse_scale == 38, "default inverse scale")
	checks.check(loader.has_method("build_meshes"), "native bake method bound")
	var checker = load("res://textures/baseline/checker.png") as Texture2D
	checks.check(checker != null and checker.get_size() == Vector2(64, 32), "asymmetric checker imported")
	root.add_child(loader)
	var map_changes: Array[String] = []
	loader.map_resource_changed.connect(func(path: String): map_changes.append(path))
	loader.map_resource = "res://fixtures/classic_cube.map"
	checks.check(loader.get_map() == loader.map_resource, "map property round trip")
	loader.map_resource = loader.map_resource
	checks.check(map_changes == ["res://fixtures/classic_cube.map"], "map property emits one precise change signal")
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
	return {"snapshot": doc.snapshot().value, "path": doc.get_path(), "dirty": doc.is_dirty(), "revision": doc.get_revision(), "topology": doc.get_topology_revision(), "epoch": doc.get_epoch(), "entities": doc.get_entities()}

func test_native_lookup_and_draw_schema() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	if not expect_ok(doc.load_map("res://fixtures/interleaved.map"), "load interleaved native-index fixture"):
		return
	var entity: Dictionary = doc.get_entities()[0]
	checks.check(entity.primitives.map(func(p): return p.kind) == [StringName("brush"), StringName("patch"), StringName("brush")], "source order interleaves brush and patch indices")
	var first: int = entity.primitives[0].id
	var patch: int = entity.primitives[1].id
	var second: int = entity.primitives[2].id
	var draw: Array = doc.get_draw_data()
	checks.check(draw.map(func(b): return b.id) == [first, second], "draw order follows native brush order across interleaved primitives")
	for brush in draw:
		checks.check(brush.size() == 9 and brush.has_all(["id", "entity_id", "topology_revision", "aabb_min", "aabb_max", "vertices", "edges", "edge_vertex_indices", "faces"]), "draw brush schema parity")
		checks.check(brush.faces.all(func(face): return face.size() == 6 and face.has_all(["index", "winding", "vertex_indices", "center", "normal", "texture"])), "draw face schema parity")
		var ordered_edges := PackedInt32Array()
		for face in brush.faces:
			for i in face.vertex_indices.size():
				var a: int = face.vertex_indices[i]
				var b: int = face.vertex_indices[(i + 1) % face.vertex_indices.size()]
				if a > b:
					var swap := a; a = b; b = swap
				var found := false
				for edge in range(0, ordered_edges.size(), 2):
					if ordered_edges[edge] == a and ordered_edges[edge + 1] == b: found = true
				if not found: ordered_edges.append_array(PackedInt32Array([a, b]))
		checks.check(brush.edge_vertex_indices == ordered_edges, "draw edge order remains first face-winding occurrence")
	var before := state(doc)
	expect_failure(doc, doc.make_prism(entity.id, 6, 2), before, "INVALID_ID", "make_prism")
	expect_failure(doc, doc.make_prism(patch, 6, 2), before, "INVALID_ID", "make_prism")
	var saved: Dictionary = doc.snapshot().value
	var history = doc.capture_history_state()
	expect_ok(doc.rebuild(), "rebuild interleaved lookup index")
	var rebuilt_second: Dictionary = brush_data(doc, second)
	expect_ok(doc.get_face_uv(second, 0, rebuilt_second.topology_revision), "face lookup after rebuild")
	expect_ok(doc.make_prism(second, 5, 2), "edit second brush by primitive/native split index")
	expect_ok(doc.restore_snapshot(saved), "restore interleaved snapshot lookup index")
	var restored_first: Dictionary = brush_data(doc, first)
	expect_ok(doc.translate_face(first, 0, Vector3(-1, 0, 0), restored_first.topology_revision), "brush lookup after snapshot restore")
	expect_ok(doc.restore_history_state(history), "restore interleaved native history lookup index")
	var history_second: Dictionary = brush_data(doc, second)
	expect_ok(doc.get_face_uv(second, 0, history_second.topology_revision), "face lookup after native history restore")

func test_spatial_queries() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "first/texture").value
	var second: int = doc.create_cuboid(Vector3.ONE * 20, Vector3.ONE * 30, "second/texture").value
	var third: int = doc.create_cuboid(Vector3.ONE * 40, Vector3.ONE * 50, "third/texture").value
	for hidden_axis in 3:
		var mins := Vector3.ONE * 19
		var maxs := Vector3.ONE * 31
		mins[hidden_axis] = -1000000
		maxs[hidden_axis] = 1000000
		checks.check(doc.query_brushes_2d(hidden_axis, mins, maxs) == PackedInt64Array([second]), "2D BVH projection on hidden axis %d" % hidden_axis)
		mins = Vector3.ONE * 10
		maxs = Vector3.ONE * 20
		checks.check(doc.query_brushes_2d(hidden_axis, mins, maxs) == PackedInt64Array([first, second]), "2D BVH includes touching boundaries on axis %d" % hidden_axis)
	checks.check(doc.query_brushes_2d(2, Vector3(-100, -100, -100), Vector3(100, 100, 100)) == PackedInt64Array([first, second, third]), "2D broad phase returns source order")
	checks.check(doc.query_brushes_2d(-1, Vector3.ZERO, Vector3.ONE).is_empty(), "2D query rejects negative hidden axis")
	checks.check(doc.query_brushes_2d(3, Vector3.ZERO, Vector3.ONE).is_empty(), "2D query rejects out-of-range hidden axis")
	checks.check(doc.query_brushes_2d(2, Vector3(2, 0, 0), Vector3(1, 1, 1)).is_empty(), "2D query rejects reversed visible bounds")
	checks.check(doc.query_brushes_2d(2, Vector3(NAN, 0, 0), Vector3.ONE).is_empty(), "2D query rejects non-finite bounds")

	var exact_doc = ClassDB.instantiate("TBMapDocument")
	var exact_first: int = exact_doc.create_cuboid(Vector3(-10, -10, -10), Vector3(10, 10, 10), "stone").value
	var exact_second: int = exact_doc.create_cuboid(Vector3(-10, -10, -10), Vector3(10, 10, 10), "stone").value
	var no_ids := PackedInt64Array()
	var exact_hit: Dictionary = exact_doc.query_brush_2d_hit(2, Vector3.ZERO, 0.0, no_ids, 0, no_ids, false)
	checks.check(exact_hit.get("brush_id", 0) == exact_second, "exact 2D hit preserves reverse source draw order")
	exact_hit = exact_doc.query_brush_2d_hit(2, Vector3.ZERO, 0.0, no_ids, 0, PackedInt64Array([exact_first]), true)
	checks.check(exact_hit.get("brush_id", 0) == exact_first, "exact 2D hit gives selected overlap priority")
	exact_hit = exact_doc.query_brush_2d_hit(2, Vector3.ZERO, 0.0, PackedInt64Array([exact_second]), 0, no_ids, false)
	checks.check(exact_hit.get("brush_id", 0) == exact_first, "exact 2D hit passes through explicitly hidden brushes")
	checks.check(exact_doc.query_brush_2d_hit(2, Vector3(15, 0, 0), 6.0, no_ids, 0, no_ids, false).get("brush_id", 0) == exact_second
		and exact_doc.query_brush_2d_hit(2, Vector3(17, 0, 0), 6.0, no_ids, 0, no_ids, false).is_empty(),
		"exact 2D edge tolerance includes near misses and rejects farther points")
	expect_ok(exact_doc.rotate_brushes(PackedInt64Array([exact_second]), Vector3.ZERO, 2, PI / 4.0), "rotate exact 2D narrow-phase fixture")
	exact_hit = exact_doc.query_brush_2d_hit(2, Vector3(13.5, 13.5, 0), 0.0, PackedInt64Array([exact_first]), 0, no_ids, false)
	checks.check(exact_doc.query_brushes_2d(2, Vector3(13.5, 13.5, 0), Vector3(13.5, 13.5, 0)).has(exact_second) and exact_hit.is_empty(),
		"exact 2D narrow phase rejects an AABB-only rotated-brush corner")
	var filtered_doc = ClassDB.instantiate("TBMapDocument")
	var filtered: int = filtered_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "common/caulk").value
	checks.check(filtered_doc.query_brush_2d_hit(2, Vector3(5, 5, 0), 0.0, no_ids, 2, no_ids, false).is_empty(),
		"exact 2D hit excludes brushes whose every face is material-filtered")
	var filtered_brush: Dictionary = brush_data(filtered_doc, filtered)
	expect_ok(filtered_doc.set_face_texture(filtered, 0, "stone", filtered_brush.topology_revision), "make mixed exact-hit fixture")
	checks.check(filtered_doc.query_brush_2d_hit(2, Vector3(5, 5, 0), 0.0, no_ids, 2, no_ids, false).get("brush_id", 0) == filtered,
		"exact 2D hit preserves mixed-brush visibility")

	var ray_doc = ClassDB.instantiate("TBMapDocument")
	var ray_first: int = ray_doc.create_cuboid(Vector3.ZERO, Vector3(10, 10, 10), "first/texture").value
	var ray_second: int = ray_doc.create_cuboid(Vector3(20, 0, 0), Vector3(30, 10, 10), "second/texture").value
	var ray_third: int = ray_doc.create_cuboid(Vector3(40, 0, 0), Vector3(50, 10, 10), "third/texture").value
	var rays: Array = ray_doc.query_ray(Vector3(-10, 5, 5), Vector3(2, 0, 0))
	checks.check(rays.size() == 6, "ray deduplicates each quad's two triangles into one face hit")
	if rays.size() == 6:
		checks.check(rays.map(func(hit): return hit.brush_id) == [ray_first, ray_first, ray_second, ray_second, ray_third, ray_third], "ray hits are nearest-first with stable source ties")
		checks.check(rays.map(func(hit): return hit.distance) == [10.0, 20.0, 30.0, 40.0, 50.0, 60.0], "ray direction is normalized and distances are map-space")
		checks.check(rays[0].position == Vector3(0, 5, 5) and rays[0].normal == Vector3(-1, 0, 0), "ray reports exact map-space position and outward normal")
		checks.check(rays[0].entity_id == ray_doc.get_entities()[0].id and rays[0].texture == "first/texture" and rays[0].face_index >= 0, "ray reports entity face and texture provenance")
		var provenance := {}
		for hit in rays:
			provenance[Vector2i(hit.brush_id, hit.face_index)] = true
		checks.check(provenance.size() == rays.size(), "ray emits no duplicate brush-face provenance")
	checks.check(ray_doc.query_ray(Vector3(-10, 5, 5), Vector3.RIGHT, 10).size() == 1, "ray max distance includes its boundary")
	checks.check(ray_doc.query_ray(Vector3(-10, 5, 5), Vector3.RIGHT, 9.999).is_empty(), "ray max distance excludes farther hits")
	checks.check(ray_doc.query_ray(Vector3(-10, 5, 5), Vector3.ZERO).is_empty(), "ray rejects zero direction")
	checks.check(ray_doc.query_ray(Vector3(INF, 0, 0), Vector3.RIGHT).is_empty(), "ray rejects non-finite origin")
	checks.check(ray_doc.query_ray(Vector3.ZERO, Vector3(NAN, 0, 0)).is_empty(), "ray rejects non-finite direction")
	checks.check(ray_doc.query_ray(Vector3.ZERO, Vector3.RIGHT, -1).is_empty(), "ray rejects negative max distance")
	checks.check(ray_doc.query_ray(Vector3.ZERO, Vector3.RIGHT, INF).is_empty(), "ray rejects non-finite max distance")
	var nearest: Dictionary = ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 0)
	checks.check(nearest.get("brush_id", 0) == ray_first and nearest.get("distance", -1.0) == 10.0,
		"nearest ray returns only the closest visible face")
	nearest = ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array([ray_first]), 0)
	checks.check(nearest.get("brush_id", 0) == ray_second and nearest.get("distance", -1.0) == 30.0,
		"nearest ray skips hidden front brushes")
	checks.check(ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		9.999, PackedInt64Array(), 0).is_empty(), "nearest ray respects max distance")

	var filtered_ray_doc = ClassDB.instantiate("TBMapDocument")
	var caulk: int = filtered_ray_doc.create_cuboid(Vector3.ZERO, Vector3(10, 10, 10), "common/caulk").value
	var clip: int = filtered_ray_doc.create_cuboid(Vector3(20, 0, 0), Vector3(30, 10, 10), "common/playerclip").value
	var solid: int = filtered_ray_doc.create_cuboid(Vector3(40, 0, 0), Vector3(50, 10, 10), "stone").value
	nearest = filtered_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 2)
	checks.check(nearest.get("brush_id", 0) == clip, "nearest ray passes through filtered caulk")
	nearest = filtered_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 6)
	checks.check(nearest.get("brush_id", 0) == solid, "nearest ray passes through filtered caulk and clip")
	checks.check(not filtered_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array([caulk, clip, solid]), 0).has("brush_id"), "nearest ray returns empty when all brushes are hidden")

	nearest = ray_doc.query_ray_nearest_visible(Vector3(5, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 0)
	checks.check(nearest.get("brush_id", 0) == ray_first and nearest.get("distance", -1.0) == 5.0,
		"nearest ray exits a brush containing its origin")
	var tied_ray_doc = ClassDB.instantiate("TBMapDocument")
	var tied_first: int = tied_ray_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "first").value
	tied_ray_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "second")
	nearest = tied_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 0)
	checks.check(nearest.get("brush_id", 0) == tied_first, "nearest ray resolves exact ties by source order")

	var hint_ray_doc = ClassDB.instantiate("TBMapDocument")
	hint_ray_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "common/hint_skip")
	var behind_hint: int = hint_ray_doc.create_cuboid(Vector3(20, 0, 0), Vector3(30, 10, 10), "stone").value
	nearest = hint_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 8)
	checks.check(nearest.get("brush_id", 0) == behind_hint, "nearest ray passes through filtered hint/skip")

	var entity_ray_doc = ClassDB.instantiate("TBMapDocument")
	var entity_front: int = entity_ray_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 10, "entity").value
	var world_behind: int = entity_ray_doc.create_cuboid(Vector3(20, 0, 0), Vector3(30, 10, 10), "world").value
	expect_ok(entity_ray_doc.group_brushes(PackedInt64Array([entity_front]), "func_detail"), "group nearest-ray entity fixture")
	nearest = entity_ray_doc.query_ray_nearest_visible(Vector3(-10, 5, 5), Vector3.RIGHT,
		1e30, PackedInt64Array(), 1)
	checks.check(nearest.get("brush_id", 0) == world_behind, "nearest ray passes through filtered entity brushes")

	# Warm the lazy index, then exercise every geometry-cache replacement path.
	var original = doc.capture_history_state()
	expect_ok(doc.translate_brushes(PackedInt64Array([first]), Vector3(100, 0, 0)), "spatial invalidation after edit")
	checks.check(not doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10).has(first), "edited BVH does not retain stale bounds")
	var moved = doc.capture_history_state()
	expect_ok(doc.restore_history_state(original), "spatial cache undo source")
	checks.check(doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10).has(first), "spatial undo query reads retained original source")
	expect_ok(doc.restore_history_state(moved), "spatial cache redo source")
	checks.check(not doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10).has(first), "spatial redo query reads retained translated source")
	expect_ok(doc.delete_brushes(PackedInt64Array([second])), "spatial invalidation after delete")
	checks.check(not doc.query_brushes_2d(2, Vector3.ONE * 20, Vector3.ONE * 30).has(second), "deleted BVH does not retain stale index")
	expect_ok(doc.restore_history_state(original), "spatial invalidation after history restore")
	checks.check(doc.query_brushes_2d(2, Vector3.ONE * 20, Vector3.ONE * 30).has(second), "history restore rebuilds spatial index lazily")
	expect_ok(doc.rebuild(), "spatial invalidation after explicit rebuild")
	checks.check(doc.query_ray(Vector3(-10, 5, 5), Vector3.RIGHT, 10).size() == 1, "ray remains valid after rebuild")
	expect_ok(doc.set_texture_sizes({"first/texture": Vector2i(64, 32)}), "preview-only invalidation after texture-size regeneration")
	checks.check(doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10) == PackedInt64Array([first]), "warm BVH remains valid after texture-size-only regeneration")
	var warm: PackedInt64Array = doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10)
	checks.check(not doc.translate_brushes(PackedInt64Array([first]), Vector3.ZERO).changed and doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10) == warm, "no-op action preserves warm spatial results")
	checks.check(not doc.translate_brushes(PackedInt64Array([999999]), Vector3.ONE).ok and doc.query_brushes_2d(2, Vector3.ZERO, Vector3.ONE * 10) == warm, "failed action preserves warm spatial results")
	var old_epoch_state = doc.capture_history_state()
	doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	checks.check(doc.get_cache_root_counters().preview_active == 1 and doc.get_cache_root_counters().spatial_active == 1, "epoch replacement fixture warms preview and spatial roots")
	expect_ok(doc.import_text("{\n\"classname\" \"worldspawn\"\n}\n"), "replace warmed document epoch")
	checks.check(doc.get_cache_root_counters() == {"preview_active": 0, "preview_history": 0, "spatial_active": 0, "spatial_history": 0,
		"spatial_entries": 0, "spatial_nodes": 0, "spatial_stale_context_refs": 0},
		"whole-document epoch replacement releases active and historical cache roots")
	checks.check(not doc.restore_history_state(old_epoch_state).ok and doc.query_brushes_2d(2, Vector3(-16, -16, -16), Vector3(16, 16, 16)).is_empty(),
		"old epoch cache sources cannot be restored and replacement queries are correct")

	var interleaved = ClassDB.instantiate("TBMapDocument")
	expect_ok(interleaved.load_map("res://fixtures/interleaved.map"), "load spatial patch omission fixture")
	var primitive_ids: Array = interleaved.get_entities()[0].primitives
	checks.check(interleaved.query_brushes_2d(2, Vector3(-100, -100, 0), Vector3(100, 100, 0)) == PackedInt64Array([primitive_ids[0].id, primitive_ids[2].id]), "BVH omits patches and preserves interleaved source order")

func test_face_summary() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var id: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "stone/a").value
	var brush: Dictionary = brush_data(doc, id)
	expect_ok(doc.set_face_uv(id, 0, Vector2(3, 4), 15.0, Vector2(2, 2), brush.topology_revision), "set aggregate face UV fixture")
	expect_ok(doc.set_face_texture(id, 1, "stone/b", brush.topology_revision), "set aggregate face material fixture")
	var targets := [
		{"brush_id": id, "index": 0, "topology_revision": brush.topology_revision, "kind": "face"},
		{"brush_id": id, "index": 1, "topology_revision": brush.topology_revision, "kind": "face"},
	]
	var result: Dictionary = doc.summarize_faces(targets)
	checks.check(result.ok and result.value.targets == targets and result.value.textures == PackedStringArray(["stone/a", "stone/b"]),
		"bulk face summary preserves target order and returns aligned materials")
	checks.check(result.value.unique_textures == PackedStringArray(["stone/a", "stone/b"]) and result.value.mixed and not result.value.valve
		and result.value.texture == "stone/a" and result.value.first.shift == Vector2(3, 4)
		and result.value.first.rotation == 15.0 and result.value.first.scale == Vector2(2, 2),
		"bulk face summary aggregates material and UV state in one result")
	expect_ok(doc.translate_face(id, 0, brush.faces[0].normal, brush.topology_revision), "invalidate aggregate face token")
	result = doc.summarize_faces(targets)
	checks.check(not result.ok and result.error.code == &"STALE_COMPONENT" and result.error.operation == &"summarize_faces",
		"bulk face summary safely rejects stale topology tokens")
	result = doc.summarize_faces([{"brush_id": id, "index": "bad", "topology_revision": 0}])
	checks.check(not result.ok and result.error.code == &"INVALID_ARGUMENT", "bulk face summary rejects malformed targets")

func test_preview_chunks() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	if not expect_ok(doc.load_map("res://fixtures/classic_cube.map"), "load preview chunk transform fixture"):
		return
	var manifest: Dictionary = doc.prepare_preview_chunks(38.0, PackedInt64Array(), 0)
	checks.check(manifest.schema == 1 and manifest.triangle_count == 12 and manifest.chunks.size() == 1, "preview manifest schema and cube counts")
	var repeated: Dictionary = doc.prepare_preview_chunks(38.0, PackedInt64Array(), 0)
	checks.check(repeated == manifest, "preview manifest IDs, ordering and hashes are deterministic")
	var cache_bytes: Dictionary = doc.get_preview_cache_counters()
	checks.check(cache_bytes.legacy_triangle_size == 160 and cache_bytes.descriptor_size <= 40, "preview cache replaces 160-byte triangles with bounded descriptors")
	checks.check(cache_bytes.descriptor_count == 12 and cache_bytes.group_reference_count == 12 and cache_bytes.chunk_reference_count == 12, "preview cache stores each triangle once with compact group and chunk references")
	checks.check(cache_bytes.logical_bytes == 12 * (32 + 4 + 4) and cache_bytes.retained_bytes <= 12 * 80, "preview descriptor and reference retention remains bounded")
	var entry: Dictionary = manifest.chunks[0]
	var chunk: Dictionary = doc.get_preview_chunk(entry.chunk_id)
	checks.check(chunk.schema == 1 and chunk.texture == entry.texture and chunk.triangle_count == 12 and chunk.geometry_hash == entry.geometry_hash and chunk.geometry_version == 1, "materialized chunk matches manifest metadata")
	checks.check(chunk.vertices.size() == 36 and chunk.normals.size() == 36 and chunk.uvs.size() == 36, "materialized chunk packs three corners per triangle")
	var source: Dictionary = doc.get_preview_data()[0]
	var draw_brush: Dictionary = doc.get_draw_data()[0]
	var face_target := [{"brush_id": draw_brush.id, "index": 0, "topology_revision": draw_brush.topology_revision}]
	var face_preview: PackedVector2Array = doc.get_face_preview_uvs(face_target, draw_brush.faces[0].texture)
	var wrapped := face_preview.size() == 6
	for uv in face_preview:
		wrapped = wrapped and uv.x >= 0.0 and uv.x < 1.0 and uv.y >= 0.0 and uv.y < 1.0
	checks.check(wrapped, "selected-face UV preview returns wrapped face triangles only")
	checks.check(doc.get_face_preview_uvs(face_target, "missing/texture").is_empty(), "selected-face UV preview filters other materials")
	var packed_index := 0
	for triangle in source.triangle_brush_ids.size():
		for corner in 3:
			var index: int = source.indices[triangle * 3 + corner]
			var point: Vector3 = source.vertices[index]
			var normal: Vector3 = source.normals[index]
			checks.check(chunk.vertices[packed_index].is_equal_approx(Vector3(point.y, point.z, point.x) / 38.0), "preview chunk map-to-Godot vertex transform")
			checks.check(chunk.normals[packed_index].is_equal_approx(Vector3(normal.y, normal.z, normal.x)), "preview chunk normal transform")
			checks.check(chunk.uvs[packed_index].is_equal_approx(source.uvs[index]), "preview chunk preserves UV")
			packed_index += 1

	var brush_id: int = doc.get_draw_data()[0].id
	checks.check(doc.prepare_preview_chunks(38.0, PackedInt64Array([brush_id]), 0).triangle_count == 0, "preview explicitly hides brush IDs")
	var mixed = ClassDB.instantiate("TBMapDocument")
	var mixed_id: int = mixed.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "visible/stone").value
	var mixed_brush: Dictionary = brush_data(mixed, mixed_id)
	expect_ok(mixed.set_face_texture(mixed_id, 0, "TOOLS/CAULK.TGA", mixed_brush.topology_revision), "set mixed caulk face")
	mixed_brush = brush_data(mixed, mixed_id)
	expect_ok(mixed.set_face_texture(mixed_id, 1, "common/player_clip", mixed_brush.topology_revision), "set mixed clip face")
	mixed_brush = brush_data(mixed, mixed_id)
	expect_ok(mixed.set_face_texture(mixed_id, 2, "common/hint_skip", mixed_brush.topology_revision), "set mixed hint_skip face")
	var mixed_source: String = mixed.export_text().value
	var mixed_manifest: Dictionary = mixed.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	var mixed_categories: Dictionary = {}
	for mixed_chunk in mixed_manifest.chunks:
		mixed_categories[mixed_chunk.render_category] = mixed_categories.get(mixed_chunk.render_category, 0) + mixed_chunk.triangle_count
	checks.check(mixed_categories == {"opaque": 6, "caulk": 2, "clip": 2, "hint_skip": 2}, "mixed-material preview classifies special faces")
	checks.check(mixed.export_text().value == mixed_source, "preview transparency classification does not modify source map data")
	checks.check(mixed.prepare_preview_chunks(1.0, PackedInt64Array(), 2).triangle_count == 10, "caulk basename filter removes only matching mixed-material face")
	checks.check(mixed.prepare_preview_chunks(1.0, PackedInt64Array(), 4).triangle_count == 10, "clip suffix basename filter removes only matching mixed-material face")
	checks.check(mixed.prepare_preview_chunks(1.0, PackedInt64Array(), 6).triangle_count == 8, "combined material filters retain visible mixed-material faces")
	checks.check(mixed.prepare_preview_chunks(1.0, PackedInt64Array(), 8).triangle_count == 10, "hint_skip filter removes only matching faces")

	var owned = ClassDB.instantiate("TBMapDocument")
	var owned_id: int = owned.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "visible/stone").value
	expect_ok(owned.group_brushes(PackedInt64Array([owned_id]), "func_detail"), "create entity-owned preview brush")
	var owned_manifest: Dictionary = owned.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	checks.check(owned_manifest.chunks.size() == 1 and owned_manifest.chunks[0].render_category == "entity", "entity-owned preview geometry is translucent regardless of material")
	checks.check(owned.prepare_preview_chunks(1.0, PackedInt64Array(), 0).triangle_count == 12 and owned.prepare_preview_chunks(1.0, PackedInt64Array(), 1).triangle_count == 0, "entity filter uses brush ownership")

	var chunked = ClassDB.instantiate("TBMapDocument")
	chunked.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "shared/material")
	chunked.create_cuboid(Vector3(256, 0, 0), Vector3(264, 8, 8), "shared/material")
	checks.check(chunked.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 24, 64.0).chunks.size() == 1, "texture group at threshold remains one chunk")
	var spatial: Dictionary = chunked.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 23, 64.0)
	checks.check(spatial.triangle_count == 24 and spatial.chunks.size() > 1, "texture group above threshold uses centroid spatial chunks")
	var spatial_sum := 0
	for spatial_chunk in spatial.chunks:
		spatial_sum += spatial_chunk.triangle_count
	checks.check(spatial_sum == 24, "spatial chunk manifest preserves triangle counts")
	var dense = ClassDB.instantiate("TBMapDocument")
	for offset in [0, 16, 32]:
		dense.create_cuboid(Vector3(offset, 0, 0), Vector3(offset + 8, 8, 8), "dense/material")
	var dense_manifest: Dictionary = dense.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 10, 100000.0)
	var dense_sizes: Array = dense_manifest.chunks.map(func(value: Dictionary): return value.triangle_count)
	checks.check(dense_manifest.triangle_count == 36 and dense_sizes == [10, 10, 10, 6], "dense spatial cell is deterministically subdivided at the triangle maximum")
	checks.check(dense_manifest.chunks[0].chunk_id == "dense/material|0,0,0|0" and dense_manifest.chunks[3].chunk_id == "dense/material|0,0,0|3", "dense spatial subdivisions have stable ordered IDs")
	checks.check(dense.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 10, 100000.0) == dense_manifest, "dense spatial subdivision IDs, order, and hashes are deterministic")
	for dense_chunk in dense_manifest.chunks:
		checks.check(dense_chunk.triangle_count <= 10, "every dense spatial subdivision respects chunk_triangles")

	var positive_zero = ClassDB.instantiate("TBMapDocument")
	positive_zero.create_cuboid(Vector3(0.0, 0.0, 0.0), Vector3(8, 8, 8), "zero/material")
	var negative_zero = ClassDB.instantiate("TBMapDocument")
	negative_zero.create_cuboid(Vector3(-0.0, -0.0, -0.0), Vector3(8, 8, 8), "zero/material")
	checks.check(positive_zero.prepare_preview_chunks(1.0, PackedInt64Array(), 0).chunks[0].geometry_hash == negative_zero.prepare_preview_chunks(1.0, PackedInt64Array(), 0).chunks[0].geometry_hash, "preview geometry hash normalizes signed zero")

	var change = ClassDB.instantiate("TBMapDocument")
	var change_id: int = change.create_cuboid(Vector3(10, 10, 10), Vector3(20, 20, 20), "change/material").value
	var before: Dictionary = change.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	var stable_id: String = before.chunks[0].chunk_id
	var stable_hash: String = before.chunks[0].geometry_hash
	var stable_vertices: PackedVector3Array = change.get_preview_chunk(stable_id).vertices
	expect_ok(change.rebuild(), "rebuild preview hash fixture")
	var rebuilt: Dictionary = change.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	checks.check(rebuilt.chunks[0].chunk_id == stable_id and rebuilt.chunks[0].geometry_hash == stable_hash, "equivalent rebuild preserves chunk ID and geometry hash")
	var history_before = change.capture_history_state()
	expect_ok(change.translate_brushes(PackedInt64Array([change_id]), Vector3.ONE), "change preview geometry")
	checks.check(change.get_preview_chunk(stable_id).is_empty(), "map edit invalidates prepared chunk access")
	var changed: Dictionary = change.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	checks.check(changed.chunks[0].chunk_id == stable_id and changed.chunks[0].geometry_hash != stable_hash, "changed geometry keeps stable chunk ID and changes hash")
	var changed_hash: String = changed.chunks[0].geometry_hash
	var changed_vertices: PackedVector3Array = change.get_preview_chunk(stable_id).vertices
	var history_after = change.capture_history_state()
	var changed_cache_bytes: Dictionary = change.get_preview_cache_counters()
	checks.check(changed_cache_bytes.descriptor_count == changed.triangle_count and changed_cache_bytes.logical_bytes <= changed.triangle_count * (40 + 4 + 4) and changed_cache_bytes.retained_bytes <= changed.triangle_count * 80, "translated preview cache remains compact without geometry copies")
	checks.check(changed_cache_bytes.history_byte_budget == 64 * 1024 * 1024
		and changed_cache_bytes.history_retained_bytes <= changed_cache_bytes.history_byte_budget
		and changed_cache_bytes.history_state_limit == 2 and changed_cache_bytes.history_state_count == 1
		and changed_cache_bytes.history_evictions == 0,
		"preview predecessor history has a strict byte budget and retains normal one-step undo")
	checks.check(change.get_last_operation_counters().deep_clones == 0, "incremental preview preparation does not deep-clone or materialize the map")
	expect_ok(change.restore_history_state(history_before), "restore cached preview history state")
	checks.check(change.get_preview_chunk(stable_id).geometry_hash == stable_hash and change.get_preview_chunk(stable_id).vertices == stable_vertices and change.is_history_state_current(history_before), "history undo reads its retained preview source")
	expect_ok(change.restore_history_state(history_after), "redo cached preview history state")
	checks.check(change.get_preview_chunk(stable_id).geometry_hash == changed_hash and change.get_preview_chunk(stable_id).vertices == changed_vertices and changed_vertices != stable_vertices and change.is_history_state_current(history_after), "history redo reads its retained preview source")
	expect_ok(change.set_texture_sizes({"change/material": Vector2i(64, 32)}), "change preview texture dimensions")
	checks.check(change.get_preview_chunk(stable_id).is_empty(), "texture-size regeneration invalidates prepared chunk access")
	checks.check(change.prepare_preview_chunks(1.0, PackedInt64Array(), 0).chunks[0].geometry_hash != changed_hash, "texture-size UV change updates geometry hash")
	var current_id: String = change.prepare_preview_chunks(1.0, PackedInt64Array(), 0).chunks[0].chunk_id
	expect_ok(change.import_text("{\n\"classname\" \"worldspawn\"\n}\n"), "replace preview map")
	checks.check(change.get_preview_chunk(current_id).is_empty(), "map replacement invalidates prepared chunk access")

	var bounded = ClassDB.instantiate("TBMapDocument")
	var bounded_id: int = bounded.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "bounded/material").value
	var oldest_state = bounded.capture_history_state()
	var bounded_chunk: String = bounded.prepare_preview_chunks(1.0, PackedInt64Array(), 0).chunks[0].chunk_id
	expect_ok(bounded.translate_brushes(PackedInt64Array([bounded_id]), Vector3.RIGHT), "advance bounded preview generation one")
	bounded.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	expect_ok(bounded.translate_brushes(PackedInt64Array([bounded_id]), Vector3.RIGHT), "advance bounded preview generation two")
	bounded.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	var newest_retained_state = bounded.capture_history_state()
	expect_ok(bounded.translate_brushes(PackedInt64Array([bounded_id]), Vector3.RIGHT), "advance bounded preview generation three")
	var bounded_history: Dictionary = bounded.get_preview_cache_counters()
	checks.check(bounded_history.history_state_count == bounded_history.history_state_limit
		and bounded_history.history_evictions == 1 and bounded_history.history_retained_bytes <= bounded_history.history_byte_budget,
		"preview history deterministically evicts its oldest state at the retention limit")
	expect_ok(bounded.restore_history_state(oldest_state), "restore oldest document state after preview eviction")
	checks.check(bounded.get_preview_chunk(bounded_chunk).is_empty(), "oldest evicted preview state is not retained")
	expect_ok(bounded.restore_history_state(newest_retained_state), "restore newest retained preview state")
	checks.check(not bounded.get_preview_chunk(bounded_chunk).is_empty(), "newest in-budget preview state remains available for one-step undo")

	checks.check(doc.get_preview_chunk("missing").is_empty(), "invalid preview chunk ID is safe")
	for invalid in [doc.prepare_preview_chunks(0.0, PackedInt64Array(), 0), doc.prepare_preview_chunks(NAN, PackedInt64Array(), 0), doc.prepare_preview_chunks(INF, PackedInt64Array(), 0), doc.prepare_preview_chunks(1.0, PackedInt64Array(), 16), doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 0), doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 1, 0.0), doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 1, INF)]:
		checks.check(invalid.is_empty(), "invalid preview preparation option is rejected safely")
	checks.check(doc.get_preview_chunk(entry.chunk_id).is_empty(), "invalid preparation clears the previous prepared cache")
	var patches = ClassDB.instantiate("TBMapDocument")
	expect_ok(patches.load_map("res://fixtures/patches.map"), "load preview patch omission fixture")
	checks.check(patches.prepare_preview_chunks(1.0, PackedInt64Array(), 0).triangle_count == 0, "preview chunks omit patches")

func test_tohunga_fixture() -> void:
	const PATH = "res://fixtures/tohunga.map"
	checks.check(FileAccess.get_sha256(PATH) == "1e9d250d26267ebda5ff52978ebacca23e37a686865fe47f950b0109e7ca8811", "Tohunga fixture has expected content")
	var doc = ClassDB.instantiate("TBMapDocument")
	if not expect_ok(doc.load_map(PATH), "load Tohunga regression map"):
		return
	var initial_brushes: int = doc.get_draw_data().size()
	checks.check(initial_brushes > 100 and doc.get_entities().size() > 1, "Tohunga loads substantial brush and entity topology")
	var history_before = doc.capture_history_state()
	var generation_before: int = doc.get_state_generation()
	var original_text: String = doc.export_text().value
	var original_ids: Dictionary = doc.snapshot().value.identities
	checks.check(doc.is_history_state_current(history_before) and history_before.get_retained_bytes() > original_text.to_utf8_buffer().size(), "Tohunga native history accounts for canonical, source and compact state")
	checks.check(history_before.get_additional_retained_bytes(history_before) < history_before.get_retained_bytes(), "shared native history payload is not counted twice")
	var translated_id: int = doc.get_draw_data()[0].id
	expect_ok(doc.translate_brushes(PackedInt64Array([translated_id]), Vector3(16, 0, 0)), "translate one Tohunga brush locally")
	var draw_delta: Dictionary = doc.get_draw_changes()
	checks.check(not draw_delta.reset and draw_delta.before_generation == generation_before and draw_delta.generation == doc.get_state_generation()
		and draw_delta.brush_ids == PackedInt64Array([translated_id]) and draw_delta.brushes.size() == 1
		and draw_delta.brushes[0].id == translated_id and draw_delta.added_ids.is_empty() and draw_delta.removed_ids.is_empty()
		and draw_delta.topology_revision == doc.get_topology_revision(), "one changed brush crosses the native draw delta boundary")
	var local_counters: Dictionary = doc.get_last_operation_counters()
	checks.check(local_counters.brush_builds == 1 and local_counters.brush_source_copies == 1 and local_counters.parser_calls == 0 and local_counters.writer_calls == 0 and local_counters.lm_geo_generator_calls == 0 and local_counters.materializations == 0 and local_counters.deep_clones == 0 and local_counters.operation == &"translate_brushes" and local_counters.positions_dirty == 1 and local_counters.spatial_dirty == 1, "local translation commit touches one source and compact build only")
	var translated_history = doc.capture_history_state()
	checks.check(translated_history.get_additional_retained_bytes(history_before) < original_text.to_utf8_buffer().size(), "one-brush history shares untouched Tohunga source and geometry")
	doc.get_draw_data()
	local_counters = doc.get_last_operation_counters()
	checks.check(local_counters.materializations == 0 and local_counters.deep_clones == 0 and local_counters.writer_calls == 0, "draw refresh reads compact geometry without whole-map materialization")
	var translated_text: String = doc.export_text().value
	local_counters = doc.get_last_operation_counters()
	checks.check(local_counters.materializations == 0 and local_counters.deep_clones == 0 and local_counters.writer_calls == 0, "explicit export cannot mutate frozen local operation counters")
	var parity = ClassDB.instantiate("TBMapDocument")
	checks.check(parity.import_text(translated_text).ok and parity.export_text().value == translated_text, "explicit local-translation export has exact canonical parity")
	expect_ok(doc.restore_history_state(history_before), "undo local Tohunga translation")
	draw_delta = doc.get_draw_changes()
	checks.check(not draw_delta.reset and draw_delta.brush_ids == PackedInt64Array([translated_id]) and draw_delta.brushes.size() == 1,
		"history restore exposes one changed draw brush without a full fallback")
	checks.check(doc.export_text().value == original_text, "local Tohunga translation undo restores exact canonical text")
	expect_ok(doc.restore_history_state(translated_history), "redo local Tohunga translation")
	checks.check(doc.export_text().value == translated_text, "local Tohunga translation redo restores exact canonical text")
	expect_ok(doc.restore_history_state(history_before), "return to Tohunga baseline after local translation checks")
	var structural_before_generation: int = doc.get_state_generation()
	var created: Dictionary = doc.create_cuboid(Vector3(-64, -64, -64), Vector3(64, 64, 64), "common/caulk")
	expect_ok(created, "create Tohunga native-history brush")
	draw_delta = doc.get_draw_changes()
	checks.check(draw_delta.reset and draw_delta.before_generation == structural_before_generation
		and draw_delta.generation == doc.get_state_generation() and draw_delta.generation != draw_delta.before_generation
		and draw_delta.brushes.is_empty() and draw_delta.added_ids == PackedInt64Array([created.value]),
		"structural draw change requests a full fallback and reports its added ID")
	var history_after = doc.capture_history_state()
	var generation_after: int = doc.get_state_generation()
	var edited_text: String = doc.export_text().value
	var edited_ids: Dictionary = doc.snapshot().value.identities
	checks.check(generation_after != generation_before and not doc.is_history_state_current(history_before) and doc.is_history_state_current(history_after), "committed edit changes native history state")
	expect_ok(doc.restore_history_state(history_before), "restore Tohunga native history undo")
	checks.check(doc.get_state_generation() == generation_before and doc.export_text().value == original_text and doc.snapshot().value.identities == original_ids, "native history undo restores exact Tohunga map, identities and stable generation")
	expect_ok(doc.restore_history_state(history_after), "restore Tohunga native history redo")
	checks.check(doc.get_state_generation() == generation_after and doc.export_text().value == edited_text and doc.snapshot().value.identities == edited_ids, "native history redo restores exact Tohunga map, identities and stable generation")
	var foreign = ClassDB.instantiate("TBMapDocument")
	expect_failure(doc, doc.restore_history_state(foreign.capture_history_state()), state(doc), "SNAPSHOT_MISMATCH", "restore_history_state")
	for repeat in 3:
		var before: Dictionary = doc.snapshot()
		expect_ok(before, "capture Tohunga snapshot %d" % repeat)
		expect_ok(doc.create_cuboid(Vector3(-64, -64, -64), Vector3(64, 64, 64), "common/caulk"), "edit Tohunga map %d" % repeat)
		var after: Dictionary = doc.snapshot()
		expect_ok(after, "capture edited Tohunga snapshot %d" % repeat)
		checks.check(not var_to_bytes(before.value).is_empty() and not var_to_bytes(after.value).is_empty(), "serialize Tohunga undo snapshots %d" % repeat)
	checks.check(doc.get_draw_data().size() == initial_brushes + 4, "Tohunga edits retain original topology")

func test_phase3_document_changes() -> void:
	checks.check(ClassDB.class_exists("TBMapDocumentChange"), "object-level document change is bound")
	var doc = ClassDB.instantiate("TBMapDocument")
	if not expect_ok(doc.load_map("res://fixtures/tohunga.map"), "load Phase 3 Tohunga fixture"):
		return
	var base_state = doc.capture_history_state()
	var base_bytes: int = base_state.get_retained_bytes()
	var ids: Array = doc.get_draw_data().slice(0, 4).map(func(item): return item.id)
	var structural = ClassDB.instantiate("TBMapDocument")
	checks.check(structural.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "phase3/structural").changed
		and structural.get_last_document_change() == null, "structural operation deliberately exposes snapshot fallback only")
	var changes: Array[RefCounted] = []
	var retained_bytes := 0
	for index in 128:
		var changed_ids := PackedInt64Array([ids[index % ids.size()]])
		checks.check(doc.translate_brushes(changed_ids, Vector3(1, 0, 0)).changed, "Phase 3 synthetic local edit %d changes" % index)
		var change: RefCounted = doc.get_last_document_change()
		checks.check(change != null and change.get_changed_brush_count() == 1, "Phase 3 action %d owns exactly one brush memento" % index)
		changes.append(change)
		retained_bytes += change.get_retained_bytes()
	checks.check(changes[4].get_additional_retained_bytes(changes[0]) < changes[4].get_retained_bytes(),
		"adjacent changes do not recount their shared BrushRecord and compact geometry")
	checks.check(retained_bytes > 0 and retained_bytes < base_bytes,
		"sum of 128 conservative per-action Tohunga charges stays bounded without a base-map charge")
	var final_generation: int = doc.get_state_generation()
	checks.check(not doc.apply_document_change(changes[0], false).ok and doc.get_state_generation() == final_generation,
		"out-of-order document change callback fails without mutation")
	for index in range(changes.size() - 1, -1, -1):
		checks.check(doc.apply_document_change(changes[index], false).ok, "Phase 3 reverse action %d" % index)
	checks.check(doc.get_state_generation() == base_state.get_state_generation(), "128 object mementos restore the starting generation")
	for index in changes.size():
		checks.check(doc.apply_document_change(changes[index], true).ok, "Phase 3 replay action %d" % index)
	var restore_counters: Dictionary = doc.get_last_operation_counters()
	checks.check(doc.get_state_generation() == final_generation and restore_counters.restore_touched_brushes == 1
		and restore_counters.restore_full_resets == 0, "object memento restore reports one touched brush and no full reset")
	checks.check(not doc.translate_brushes(PackedInt64Array([ids[0]]), Vector3.ZERO).changed
		and doc.get_last_document_change() == null, "local no-op publishes no document change")
	checks.check(not doc.translate_brushes(PackedInt64Array([9223372036854775807]), Vector3.ONE).ok
		and doc.get_last_document_change() == null, "failed local edit publishes no document change")

	var saved = ClassDB.instantiate("TBMapDocument")
	var saved_id: int = saved.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "phase3/save").value
	expect_ok(saved.save_map("user://phase3-change-save.map"), "establish Phase 3 save baseline")
	var original_text: String = saved.export_text().value
	expect_ok(saved.translate_brushes(PackedInt64Array([saved_id]), Vector3.RIGHT), "edit before Phase 3 consolidation")
	var saved_change: RefCounted = saved.get_last_document_change()
	expect_ok(saved.save_map("user://phase3-change-save.map"), "consolidate Phase 3 local edit")
	var consolidated_text: String = saved.export_text().value
	expect_ok(saved.set_texture_sizes({"phase3/save": Vector2i(64, 32)}), "change derived texture context after retaining memento")
	expect_ok(saved.apply_document_change(saved_change, false), "undo retained source record after save consolidation")
	checks.check(saved.is_dirty() and saved.export_text().value == original_text, "post-save memento undo restores pre-save source and dirty state")
	expect_ok(saved.apply_document_change(saved_change, true), "redo retained source record after save consolidation")
	checks.check(not saved.is_dirty() and saved.export_text().value == consolidated_text, "post-save memento redo removes base-equivalent override and restores clean state")

	var multi = ClassDB.instantiate("TBMapDocument")
	var multi_text: String = FileAccess.get_file_as_string("res://fixtures/classic_cube.map")
	for face in 6:
		var texture_offset := multi_text.find("baseline/checker")
		multi_text = multi_text.substr(0, texture_offset) + "phase3/face%d" % face + multi_text.substr(texture_offset + len("baseline/checker"))
	expect_ok(multi.import_text(multi_text), "load multi-texture memento fixture")
	expect_ok(multi.save_map("user://phase3-multi-texture.map"), "save multi-texture baseline")
	var multi_id: int = multi.get_draw_data()[0].id
	var multi_original: String = multi.export_text().value
	expect_ok(multi.translate_brushes(PackedInt64Array([multi_id]), Vector3(3, 5, 7)), "translate multi-texture brush")
	var multi_change: RefCounted = multi.get_last_document_change()
	expect_ok(multi.save_map("user://phase3-multi-texture.map"), "consolidate multi-texture override")
	var dimensions := {}
	for face in 6:
		dimensions["phase3/face%d" % face] = Vector2i(16 + face * 7, 32 + face * 11)
	expect_ok(multi.set_texture_sizes(dimensions), "change every multi-texture face context")
	expect_ok(multi.apply_document_change(multi_change, false), "undo normalized multi-texture base record")
	checks.check(multi.export_text().value == multi_original, "multi-texture undo restores exact pre-save source")
	expect_ok(multi.apply_document_change(multi_change, true), "redo normalized multi-texture record")
	var multi_parity = ClassDB.instantiate("TBMapDocument")
	expect_ok(multi_parity.import_text(multi.export_text().value), "reparse multi-texture redo parity")
	expect_ok(multi_parity.set_texture_sizes(dimensions), "apply parity texture context")
	var multi_draw: Dictionary = multi.get_draw_data()[0]
	var parity_draw: Dictionary = multi_parity.get_draw_data()[0]
	for face in 6:
		var actual: PackedVector2Array = multi.get_face_preview_uvs([{"brush_id": multi_id, "index": face, "topology_revision": multi_draw.topology_revision}], multi_draw.faces[face].texture)
		var expected: PackedVector2Array = multi_parity.get_face_preview_uvs([{"brush_id": parity_draw.id, "index": face, "topology_revision": parity_draw.topology_revision}], parity_draw.faces[face].texture)
		checks.check(actual == expected and not actual.is_empty(), "multi-texture restored compact UV parity face %d" % face)

	var identity = ClassDB.instantiate("TBMapDocument")
	var identity_a: int = identity.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "phase3/id").value
	var identity_state = identity.capture_history_state()
	var identity_snapshot: Dictionary = identity.snapshot().value
	var identity_text: String = identity.export_text().value
	expect_ok(identity.translate_brushes(PackedInt64Array([identity_a]), Vector3.RIGHT), "create same-document stale memento fixture")
	var identity_change: RefCounted = identity.get_last_document_change()
	expect_ok(identity.apply_document_change(identity_change, false), "return stale memento fixture to source")
	var identity_b: int = identity.duplicate_brushes(PackedInt64Array([identity_a])).value[0]
	expect_ok(identity.delete_brushes(PackedInt64Array([identity_a])), "replace brush by identical source with a different ID")
	var different_id_generation: int = identity.get_state_generation()
	checks.check(identity.export_text().value == identity_text and identity.get_draw_data()[0].id == identity_b,
		"same canonical text can identify a distinct structural state")
	expect_ok(identity.restore_snapshot(identity_snapshot), "restore same-text snapshot with original ID")
	checks.check(identity.get_state_generation() > different_id_generation and identity.get_draw_data()[0].id == identity_a,
		"same-text different-ID snapshot restore receives a fresh monotonic generation")
	var stale_base_change_result: Dictionary = identity.apply_document_change(identity_change, true)
	checks.check(not stale_base_change_result.ok, "same-document stale memento is rejected after same-text structural replacement")
	checks.check(not identity.is_history_state_current(identity_state), "snapshot restore never aliases the old state identity")

	var spatial = ClassDB.instantiate("TBMapDocument")
	var spatial_id: int = spatial.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "phase3/base").value
	spatial.query_brushes_2d(2, Vector3(-1, -1, -1), Vector3(17, 17, 17))
	expect_ok(spatial.set_brush_texture(PackedInt64Array([spatial_id]), "phase3/override"), "populate material memento over active BVH")
	var spatial_change: RefCounted = spatial.get_last_document_change()
	expect_ok(spatial.apply_document_change(spatial_change, false), "undo material memento to null editor context")
	checks.check(spatial.get_cache_root_counters().spatial_stale_context_refs == 0
		and spatial.query_brushes_2d(2, Vector3(-1, -1, -1), Vector3(17, 17, 17)).has(spatial_id),
		"undo-to-base rebinds BVH to normalized null overlay")

	var prepared = ClassDB.instantiate("TBMapDocument")
	var prepared_id: int = prepared.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "phase3/prepared").value
	expect_ok(prepared.translate_brushes(PackedInt64Array([prepared_id]), Vector3.RIGHT), "prepare overlay save failure")
	var prepared_state: Dictionary = state(prepared)
	expect_failure(prepared, prepared.save_map("user://missing-phase3-parent/prepared.map"), prepared_state, "IO_WRITE", "save_map")
	checks.check(prepared.get_last_document_change() == null and not FileAccess.file_exists("user://missing-phase3-parent/prepared.map"),
		"prepared consolidation disk failure publishes no document state")

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
	# Production maps can contain redundant planes which do not contribute a polygon.
	var redundant = cube.replace("( 48 -32 -8 ) ( -16 32 -8 ) ( -16 -32 -8 ) baseline/checker 0 0 0 1 1\n", "( 48 -32 -8 ) ( -16 32 -8 ) ( -16 -32 -8 ) baseline/checker 0 0 0 1 1\n( 48 -32 -8 ) ( -16 32 -8 ) ( -16 -32 -8 ) baseline/checker 0 0 0 1 1\n( 64 -32 -8 ) ( 64 32 24 ) ( 64 32 -8 ) baseline/checker 0 0 0 1 1\n")
	expect_ok(doc.import_text(redundant), "solid with duplicate and non-contributing source planes")
	checks.check(doc.export_text().value.contains("( 64 -32 -8 ) ( 64 32 24 ) ( 64 32 -8 )"), "non-contributing source plane is preserved")
	var redundant_draw: Dictionary = doc.get_draw_data()[0]
	checks.check(redundant_draw.faces.size() == 8 and redundant_draw.faces[6].winding.is_empty()
		and redundant_draw.faces[7].winding.is_empty() and redundant_draw.vertices.size() == 8
		and redundant_draw.edge_vertex_indices.size() == 24,
		"redundant planes have empty windings and exactly the cube topology")
	var redundant_id: int = redundant_draw.id
	var redundant_token: int = redundant_draw.topology_revision
	expect_ok(doc.set_face_texture(redundant_id, 0, "redundant/material", redundant_token), "material edit on redundant brush")
	redundant_token = brush_data(doc, redundant_id).topology_revision
	expect_ok(doc.set_face_uv(redundant_id, 0, Vector2(3, 5), 17, Vector2(2, 4), redundant_token), "UV edit on redundant brush")
	expect_ok(doc.translate_brushes(PackedInt64Array([redundant_id]), Vector3(2, 3, 4)), "position edit on redundant brush")
	redundant_token = brush_data(doc, redundant_id).topology_revision
	expect_ok(doc.translate_face(redundant_id, 0, Vector3(1, 0, 0), redundant_token), "topology edit on redundant brush")
	expect_ok(doc.import_text(redundant), "restore redundant structural fixture")
	redundant_id = doc.get_draw_data()[0].id
	var redundant_duplicate: Dictionary = doc.duplicate_brushes(PackedInt64Array([redundant_id]))
	expect_ok(redundant_duplicate, "duplicate redundant brush structurally")
	checks.check(doc.get_last_operation_counters().brush_builds == 2,
		"structural preparation builds compact geometry exactly once per stable brush ID")
	expect_ok(doc.import_text(redundant), "restore redundant prism fixture")
	redundant_id = doc.get_draw_data()[0].id
	expect_ok(doc.make_prism(redundant_id, 8, 2), "replace redundant brush with prism")
	expect_ok(doc.import_text(redundant), "restore redundant validation fixture")
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
	var pathological_text := "{\n\"classname\" \"worldspawn\"\n{\n" \
		+ "( 0 0 1 ) ( 0 1 0 ) ( 0 1 1 ) pathological 0 0 0 1 1\n" \
		+ "( 0 0 1 ) ( 1 0 0 ) ( 0 0 0 ) pathological 0 0 0 1 1\n" \
		+ "( 0 0 1 ) ( 1 1 1 ) ( 1 0 1 ) pathological 0 0 0 1 1\n" \
		+ "( 1 0 0 ) ( 0 1 0 ) ( 0 0 0 ) pathological 0 0 0 1 1\n" \
		+ "( 1 0 0 ) ( 0.999999999999 1 1 ) ( 0.999999999999 1 0 ) pathological 0 0 0 1 1\n}\n}\n"
	write_text("user://pathological.map", pathological_text)
	var pathological_result: Dictionary = doc.load_map("user://pathological.map")
	expect_failure(doc, pathological_result, before, "INVALID_GEOMETRY", "load_map")
	checks.check(pathological_result.error.path == "user://pathological.map", "incoming compact geometry diagnostics retain the requested path")
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
	checks.check(doc.is_dirty(), "generation-based snapshot inverse remains intentionally dirty even at saved text")
	before = state(doc)
	events_before = events.duplicate()
	var noop = doc.restore_snapshot(saved)
	expect_ok(noop, "identical snapshot restore")
	checks.check(noop.changed and doc.get_revision() == before.revision + 1 and events.map == events_before.map + 1 and doc.is_dirty(),
		"identical snapshot restore is a distinct structural state generation")
	checks.check(doc.save_map("user://document.map").changed and not doc.save_map("user://document.map").changed,
		"saving the fresh inverse generation establishes baseline, then unchanged save is a no-op")
	before = state(doc)
	var overlay_save = ClassDB.instantiate("TBMapDocument")
	expect_ok(overlay_save.import_text(cube), "prepare translated save consolidation fixture")
	expect_ok(overlay_save.save_map("user://translated-save.map"), "establish translated save baseline")
	var overlay_id: int = overlay_save.get_draw_data()[0].id
	overlay_save.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	overlay_save.query_brushes_2d(2, Vector3(-256, -256, -256), Vector3(256, 256, 256))
	expect_ok(overlay_save.translate_brushes(PackedInt64Array([overlay_id]), Vector3(24, -8, 4)), "translate before consolidated save")
	overlay_save.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	overlay_save.query_brushes_2d(2, Vector3(-256, -256, -256), Vector3(256, 256, 256))
	var roots_before_save: Dictionary = overlay_save.get_cache_root_counters()
	checks.check(roots_before_save.preview_active == 1 and roots_before_save.spatial_active == 1
		and roots_before_save.preview_history > 0 and roots_before_save.spatial_history > 0, "translated overlay retains incremental predecessor cache roots before save")
	var translated_generation: int = overlay_save.get_state_generation()
	var translated_state = overlay_save.capture_history_state()
	expect_ok(overlay_save.save_map("user://translated-save.map"), "save translated overlay")
	checks.check(overlay_save.get_cache_root_counters() == {"preview_active": 0, "preview_history": 0, "spatial_active": 0, "spatial_history": 0,
		"spatial_entries": 0, "spatial_nodes": 0, "spatial_stale_context_refs": 0},
		"save consolidation releases active and historical base-overlay roots")
	checks.check(overlay_save.prepare_preview_chunks(1.0, PackedInt64Array(), 0).triangle_count == 12
		and overlay_save.query_brushes_2d(2, Vector3(-64, -128, -128), Vector3(128, 128, 128)).has(overlay_id),
		"queries rebuild correctly after save consolidation")
	checks.check(not overlay_save.is_dirty() and overlay_save.get_state_generation() == translated_generation and overlay_save.is_history_state_current(translated_state), "successful translated save consolidates without semantic history change")
	var consolidated_counters: Dictionary = overlay_save.get_last_operation_counters().duplicate(true)
	checks.check(consolidated_counters.get("completed", false), "translated save completes translation measurement")
	checks.check(not overlay_save.save_map("user://translated-save.map").changed and not overlay_save.is_dirty(), "repeated translated save is unchanged and clean")
	checks.check(overlay_save.get_last_operation_counters() == consolidated_counters, "work after save consolidation cannot mutate completed translation counters")
	expect_ok(overlay_save.translate_brushes(PackedInt64Array([overlay_id]), Vector3.RIGHT), "edit after saving overlay generation")
	checks.check(overlay_save.is_dirty(), "generation after saved overlay is dirty")
	expect_ok(overlay_save.restore_history_state(translated_state), "undo to saved pre-consolidation overlay state")
	checks.check(not overlay_save.is_dirty() and overlay_save.export_text().value == FileAccess.get_file_as_string("user://translated-save.map"), "saved generation is clean independent of overlay/base representation")
	var overlay_reopen = ClassDB.instantiate("TBMapDocument")
	expect_ok(overlay_reopen.load_map("user://translated-save.map"), "reopen consolidated translated save")
	checks.check(overlay_reopen.export_text().value == overlay_save.export_text().value, "consolidated translated save preserves exact canonical bytes")
	var collapsed = ClassDB.instantiate("TBMapDocument")
	expect_ok(collapsed.import_text(cube), "prepare zero-sum translation fixture")
	expect_ok(collapsed.save_map("user://zero-sum-translation.map"), "establish zero-sum translation baseline")
	var collapsed_id: int = collapsed.get_draw_data()[0].id
	var collapsed_min: Vector3 = brush_data(collapsed, collapsed_id).aabb_min
	var collapsed_base = collapsed.capture_history_state()
	expect_ok(collapsed.translate_brushes(PackedInt64Array([collapsed_id]), Vector3(24, -8, 4)), "apply first half of zero-sum translation")
	var collapsed_moved = collapsed.capture_history_state()
	checks.check(collapsed.is_dirty() and brush_data(collapsed, collapsed_id).aabb_min == collapsed_min + Vector3(24, -8, 4), "positive translation installs compact override")
	expect_ok(collapsed.translate_brushes(PackedInt64Array([collapsed_id]), Vector3(-24, 8, -4)), "return translation exactly to base")
	var collapsed_state = collapsed.capture_history_state()
	checks.check(collapsed.is_dirty() and brush_data(collapsed, collapsed_id).aabb_min == collapsed_min, "zero cumulative translation removes override but remains a new semantic generation")
	checks.check(collapsed_state.get_additional_retained_bytes(collapsed_base) == collapsed_base.get_additional_retained_bytes(collapsed_base), "collapsed translation retains no overlay allocation")
	var completed_counters: Dictionary = collapsed.get_last_operation_counters().duplicate(true)
	checks.check(completed_counters.get("completed", false) and completed_counters.brush_builds == 1 and completed_counters.brush_source_copies == 1, "zero-sum collapse completes translation measurement")
	expect_ok(collapsed.rebuild(), "run unrelated rebuild after completed translation measurement")
	checks.check(collapsed.get_last_operation_counters() == completed_counters, "unrelated parser and geometry work cannot mutate completed translation counters")
	expect_ok(collapsed.restore_history_state(collapsed_moved), "undo zero-sum collapse")
	checks.check(collapsed.is_dirty() and brush_data(collapsed, collapsed_id).aabb_min == collapsed_min + Vector3(24, -8, 4), "zero-sum history undo restores compact override")
	expect_ok(collapsed.restore_history_state(collapsed_state), "redo zero-sum collapse")
	checks.check(collapsed.is_dirty() and brush_data(collapsed, collapsed_id).aabb_min == collapsed_min, "zero-sum history redo restores overlay-free edited generation")
	var sharing = ClassDB.instantiate("TBMapDocument")
	var sharing_first: int = sharing.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "shared/material").value
	var sharing_second: int = sharing.create_cuboid(Vector3(16, 0, 0), Vector3(24, 8, 8), "shared/material").value
	var sharing_base = sharing.capture_history_state()
	expect_ok(sharing.translate_brushes(PackedInt64Array([sharing_first]), Vector3.UP), "prepare first shared brush record")
	var sharing_one = sharing.capture_history_state()
	var one_record_bytes: int = sharing_one.get_additional_retained_bytes(sharing_base)
	expect_ok(sharing.translate_brushes(PackedInt64Array([sharing_second]), Vector3.UP), "prepare second shared brush record")
	var sharing_two = sharing.capture_history_state()
	checks.check(sharing_two.get_additional_retained_bytes(sharing_one) < one_record_bytes * 3 / 2, "additional history bytes do not recount shared BrushRecord pointers")
	var spatial_context = ClassDB.instantiate("TBMapDocument")
	var spatial_context_id: int = spatial_context.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "base/material").value
	var spatial_query_box := func(): return spatial_context.query_brushes_2d(2, Vector3(-1, -1, -1), Vector3(17, 17, 17))
	var spatial_query_ray := func(): return spatial_context.query_ray(Vector3(-8, 8, 8), Vector3.RIGHT, 64)
	spatial_query_box.call()
	expect_ok(spatial_context.set_brush_texture(PackedInt64Array([spatial_context_id]), "overlay/only"), "prepare overlay-only spatial material context")
	var spatial_box_before: PackedInt64Array = spatial_query_box.call()
	var spatial_ray_before: Array = spatial_query_ray.call()
	var spatial_roots_before: Dictionary = spatial_context.get_cache_root_counters()
	checks.check(spatial_roots_before.spatial_history > 0 and spatial_roots_before.spatial_stale_context_refs == 0,
		"overlay-only material transition retains a valid predecessor spatial root")
	expect_ok(spatial_context.set_texture_sizes({"overlay/only": Vector2i(64, 32)}), "rebind overlay-only spatial texture context")
	var spatial_roots_after: Dictionary = spatial_context.get_cache_root_counters()
	checks.check(spatial_query_box.call() == spatial_box_before and spatial_query_ray.call() == spatial_ray_before,
		"UV-only spatial context rebind preserves 2D and ray query behavior")
	checks.check(spatial_roots_after.spatial_active == 1 and spatial_roots_after.spatial_history == 0
		and spatial_roots_after.spatial_entries == spatial_roots_before.spatial_entries
		and spatial_roots_after.spatial_nodes == spatial_roots_before.spatial_nodes
		and spatial_roots_after.spatial_stale_context_refs == 0,
		"UV-only spatial context keeps BVH topology and releases all obsolete compact roots")
	var spatial_texture_counters: Dictionary = spatial_context.get_last_operation_counters()
	checks.check(spatial_texture_counters.compact_uv_updates == 1 and spatial_texture_counters.compact_shared_brushes == 1
		and spatial_texture_counters.compact_full_builds == 0,
		"overlay-only UV update rebinds one current payload and exactly shares the unaffected base payload")

	var dimension_restore = ClassDB.instantiate("TBMapDocument")
	expect_ok(dimension_restore.import_text(cube), "prepare texture-dimension overlay history fixture")
	expect_ok(dimension_restore.create_cuboid(Vector3(96, -32, -8), Vector3(160, 32, 24), "baseline/checker"), "add historical base brush sharing resolved texture")
	expect_ok(dimension_restore.create_cuboid(Vector3(192, -32, -8), Vector3(256, 32, 24), "dimension/missing"), "add historical base brush with missing texture entry")
	expect_ok(dimension_restore.set_texture_sizes({"baseline/checker": Vector2i(64, 32)}), "set initial overlay history texture dimensions")
	var dimension_id: int = dimension_restore.get_draw_data()[0].id
	expect_ok(dimension_restore.translate_brushes(PackedInt64Array([dimension_id]), Vector3(32, 0, 0)), "translate texture-dimension history state")
	var dimension_state = dimension_restore.capture_history_state()
	var dimension_generation: int = dimension_restore.get_state_generation()
	var dimension_dirty: bool = dimension_restore.is_dirty()
	var first_translation_min: Vector3 = brush_data(dimension_restore, dimension_id).aabb_min
	expect_ok(dimension_restore.translate_brushes(PackedInt64Array([dimension_id]), Vector3(64, 0, 0)), "move beyond texture-dimension history state")
	var texture_context_before = dimension_restore.capture_history_state()
	expect_ok(dimension_restore.set_texture_sizes({"baseline/checker": Vector2i(128, 64)}), "change dimensions after overlay history capture")
	var texture_context_after = dimension_restore.capture_history_state()
	var counters_before_restore: Dictionary = dimension_restore.get_last_operation_counters().duplicate()
	checks.check(counters_before_restore.operation == &"set_texture_sizes" and counters_before_restore.source_clones == 0
		and counters_before_restore.materializations == 0 and counters_before_restore.deep_clones == 0
		and counters_before_restore.parser_calls == 0 and counters_before_restore.writer_calls == 0
		and counters_before_restore.lm_geo_generator_calls == 0 and counters_before_restore.brush_builds == 0
		and counters_before_restore.compact_full_builds == 0 and counters_before_restore.compact_uv_updates == 3
		and counters_before_restore.compact_shared_brushes == 1 and counters_before_restore.compact_uv_copy_bytes > 0,
		"texture dimensions update affected UV payloads and exactly share unaffected compact geometry")
	checks.check(texture_context_after.get_additional_retained_bytes(texture_context_before) < texture_context_after.get_retained_bytes(),
		"mixed-texture rebuild shares compact geometry for the untouched missing-texture brush")
	expect_ok(dimension_restore.restore_history_state(dimension_state), "restore overlay history under changed texture dimensions")
	var counters_after_restore: Dictionary = dimension_restore.get_last_operation_counters()
	checks.check(brush_data(dimension_restore, dimension_id).aabb_min == first_translation_min, "dimension-mismatch history restore preserves translated brush position")
	checks.check(counters_after_restore.operation == &"restore_history_state" and counters_after_restore.source_clones == 0
		and counters_after_restore.materializations == 0 and counters_after_restore.deep_clones == 0
		and counters_after_restore.parser_calls == 0 and counters_after_restore.writer_calls == 0
		and counters_after_restore.lm_geo_generator_calls == 0 and counters_after_restore.brush_builds == 0
		and counters_after_restore.compact_full_builds == 0 and counters_after_restore.compact_uv_updates == 3
		and counters_after_restore.compact_shared_brushes == 1,
		"dimension-mismatch restore updates historical UV payloads without compact topology builds")
	checks.check(dimension_restore.get_state_generation() == dimension_generation and dimension_restore.is_dirty() == dimension_dirty, "history restore keeps generation-based dirty semantics")
	checks.check(dimension_restore.is_history_state_current(dimension_state), "restored semantic history state is current under the active texture context")
	var repeated_dimension_restore: Dictionary = dimension_restore.restore_history_state(dimension_state)
	checks.check(repeated_dimension_restore.ok and not repeated_dimension_restore.changed and dimension_restore.get_last_operation_counters() == counters_after_restore, "repeated history restore does not rebuild derived texture context")
	var dimension_text: String = dimension_restore.export_text().value
	var dimension_parity = ClassDB.instantiate("TBMapDocument")
	expect_ok(dimension_parity.import_text(dimension_text), "reparse dimension-mismatch restored overlay")
	expect_ok(dimension_parity.set_texture_sizes({"baseline/checker": Vector2i(128, 64)}), "apply current dimensions to restored-overlay parity map")
	var restored_preview: Array = dimension_restore.get_preview_data()
	var parity_preview: Array = dimension_parity.get_preview_data()
	checks.check(restored_preview.size() == 2 and parity_preview.size() == 2, "dimension-mismatch multi-brush previews preserve resolved and missing texture groups")
	for restored_surface in restored_preview:
		var parity_surface: Dictionary = parity_preview.filter(func(surface): return surface.texture == restored_surface.texture)[0]
		checks.check(restored_surface.uvs == parity_surface.uvs, "dimension-mismatch base and overridden UVs match reparsed parity for " + restored_surface.texture)
		checks.check(restored_surface.texture_size == (Vector2i(128, 64) if restored_surface.texture == "baseline/checker" else Vector2i.ONE), "dimension-mismatch restore applies current dimensions and exact 1x1 fallback")
	var restored_draw: Dictionary = brush_data(dimension_restore, dimension_id)
	var parity_draw: Dictionary = dimension_parity.get_draw_data()[0]
	var restored_uvs: PackedVector2Array = dimension_restore.get_face_preview_uvs([{"brush_id": dimension_id, "index": 0, "topology_revision": restored_draw.topology_revision}], restored_draw.faces[0].texture)
	var parity_uvs: PackedVector2Array = dimension_parity.get_face_preview_uvs([{"brush_id": parity_draw.id, "index": 0, "topology_revision": parity_draw.topology_revision}], parity_draw.faces[0].texture)
	checks.check(restored_uvs == parity_uvs and not restored_uvs.is_empty(), "dimension-mismatch restore rebuilds compact selected-face UVs with current dimensions")
	var restored_roots: Dictionary = dimension_restore.get_cache_root_counters()
	checks.check(restored_roots.spatial_history == 0 and restored_roots.spatial_stale_context_refs == 0,
		"dimension-context history restore retains no obsolete spatial compact roots")
	var restored_generation: int = dimension_restore.get_state_generation()
	expect_ok(dimension_restore.set_face_texture(dimension_id, 0, "dimension/further", restored_draw.topology_revision), "edit restored dimension-mismatch overlay")
	checks.check(dimension_restore.get_state_generation() != restored_generation and brush_data(dimension_restore, dimension_id).faces[0].texture == "dimension/further", "further edit targets restored overlay rather than a consolidated duplicate")
	var further_text: String = dimension_restore.export_text().value
	var further_parity = ClassDB.instantiate("TBMapDocument")
	var further_loaded: bool = further_parity.import_text(further_text).ok
	var further_draw: Dictionary = dimension_restore.get_draw_data()[0]
	var further_parity_draw: Dictionary = further_parity.get_draw_data()[0]
	checks.check(further_loaded and further_parity.export_text().value == further_text and further_draw.aabb_min.is_equal_approx(further_parity_draw.aabb_min) and further_draw.aabb_max.is_equal_approx(further_parity_draw.aabb_max) and further_draw.faces[0].texture == further_parity_draw.faces[0].texture, "dimension restore further edit/export/draw parity")
	var further_loader = ClassDB.instantiate("TBLoader")
	var further_target = Node3D.new()
	root.add_child(further_loader); root.add_child(further_target)
	checks.check(further_loader.build_visual_preview_checked(dimension_restore, further_target).ok and further_target.get_child_count() > 0, "dimension restore further edit materializes through Builder preparation")
	further_loader.queue_free(); further_target.queue_free()
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

func check_local_counters(doc, operation: StringName, brushes: int, spatial: int, message: String) -> void:
	var counters: Dictionary = doc.get_last_operation_counters()
	var change: RefCounted = doc.get_last_document_change()
	checks.check(counters.operation == operation and counters.brush_source_copies == brushes and counters.brush_builds <= brushes and counters.parser_calls == 0 and counters.writer_calls == 0 and counters.lm_geo_generator_calls == 0 and counters.materializations == 0 and counters.deep_clones == 0 and counters.spatial_dirty == spatial
		and change != null and change.get_changed_brush_count() == brushes, message)

func built_mesh_data(target: Node) -> Array:
	var result: Array = []
	for instance in target.find_children("*", "MeshInstance3D", true, false):
		for surface in instance.mesh.get_surface_count():
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			result.append({"vertices": arrays[Mesh.ARRAY_VERTEX], "normals": arrays[Mesh.ARRAY_NORMAL], "indices": arrays[Mesh.ARRAY_INDEX]})
	return result

func test_phase2_local_transactions() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "local/base").value
	var second: int = doc.create_cuboid(Vector3(96, 0, 0), Vector3(160, 64, 64), "local/base").value
	var signals := {"count": 0}
	doc.map_changed.connect(func(_revision): signals.count += 1)
	var brush := brush_data(doc, first)
	expect_ok(doc.rotate_brushes(PackedInt64Array([first]), Vector3(32, 32, 32), 2, PI / 2), "local rotate transaction")
	check_local_counters(doc, &"rotate_brushes", 1, 1, "rotate uses one local source/build without compatibility work")
	brush = brush_data(doc, first)
	expect_ok(doc.translate_face(first, 0, brush.faces[0].normal * 8, brush.topology_revision), "local one-face translation")
	check_local_counters(doc, &"translate_face", 1, 1, "face translation uses one local source/build")
	brush = brush_data(doc, first)
	var stable_component_token: int = brush.topology_revision
	doc.query_ray(Vector3(-128, 32, 32), Vector3.RIGHT)
	var material_manifest: Dictionary = doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 4, 32.0)
	expect_ok(doc.set_face_texture(first, 0, "common/caulk", brush.topology_revision), "local one-face texture")
	check_local_counters(doc, &"set_face_texture", 1, 0, "material edit refreshes filters without spatial BVH dirtiness")
	var frozen_material_counters: Dictionary = doc.get_last_operation_counters().duplicate(true)
	brush = brush_data(doc, first)
	checks.check(brush.topology_revision == stable_component_token, "material-only edit preserves component topology token")
	var face_center: Vector3 = brush.faces[0].center
	var face_normal: Vector3 = brush.faces[0].normal
	checks.check(doc.query_ray(face_center + face_normal * 128, -face_normal).any(func(hit): return hit.brush_id == first and hit.face_index == 0 and hit.texture == "common/caulk"), "spatial result observes local material override")
	var changed_manifest: Dictionary = doc.prepare_preview_chunks(1.0, PackedInt64Array(), 0, 4, 32.0)
	checks.check(changed_manifest.chunks.any(func(chunk): return chunk.texture == "common/caulk" and chunk.render_category == "caulk") and doc.get_preview_cache_counters().buckets_changed > 0 and material_manifest != changed_manifest, "incremental preview invalidates old/new material categories and cells")
	checks.check(doc.get_last_operation_counters() == frozen_material_counters, "preview preparation cannot mutate frozen operation counters")
	brush = brush_data(doc, first)
	expect_ok(doc.set_face_uv(first, 0, Vector2(7, -3), 45, Vector2(0.5, 2), stable_component_token), "local UV transaction")
	check_local_counters(doc, &"set_face_uv", 1, 0, "UV edit preserves spatial BVH")
	brush = brush_data(doc, first)
	checks.check(brush.topology_revision == stable_component_token and doc.get_face_uv(first, 1, stable_component_token).ok, "UV-only edit preserves existing component handles")
	var second_brush := brush_data(doc, second)
	var batch = [{"brush_id": first, "face": 1, "topology_revision": brush.topology_revision, "texture": "batch/one"}, {"brush_id": second, "face": 0, "topology_revision": second_brush.topology_revision, "texture": "batch/two"}]
	var before_batch_signals: int = signals.count
	expect_ok(doc.apply_face_edits(batch), "atomic two-brush face batch")
	check_local_counters(doc, &"apply_face_edits", 2, 0, "atomic face batch copies/builds each touched source once")
	checks.check(signals.count == before_batch_signals + 1, "atomic face batch publishes one map change")
	brush = brush_data(doc, first)
	var component = {"brush_id": first, "kind": "vertex", "index": 0, "topology_revision": brush.topology_revision}
	expect_ok(doc.translate_components([component], Vector3(2, 3, 4)), "local component move")
	check_local_counters(doc, &"translate_components", 1, 1, "component move uses one local source/build")
	checks.check(not doc.get_face_uv(first, 0, stable_component_token).ok, "hull-changing component edit invalidates old handles")
	var generation: int = doc.get_state_generation()
	var revision: int = doc.get_revision()
	second_brush = brush_data(doc, second)
	checks.check(not doc.set_face_texture(second, 0, "batch/two", second_brush.topology_revision).changed and doc.get_state_generation() == generation and doc.get_revision() == revision, "local no-op consumes no generation or revision")
	var exported: String = doc.export_text().value
	var parity = ClassDB.instantiate("TBMapDocument")
	checks.check(parity.import_text(exported).ok and parity.export_text().value == exported, "mixed local overrides materialize with exact export parity")
	var phong = ClassDB.instantiate("TBMapDocument")
	var phong_text: String = FileAccess.get_file_as_string("res://fixtures/classic_cube.map").replace("\"classname\" \"worldspawn\"", "\"classname\" \"worldspawn\"\n\"_phong\" \"1\"\n\"_phong_angle\" \"80\"")
	expect_ok(phong.import_text(phong_text), "load phong materialization fixture")
	var phong_brush: Dictionary = phong.get_draw_data()[0]
	expect_ok(phong.translate_vertices(phong_brush.id, PackedInt32Array([0]), Vector3(1, 2, 3), phong_brush.topology_revision), "create non-simple phong override")
	var phong_oracle = ClassDB.instantiate("TBMapDocument")
	expect_ok(phong_oracle.import_text(phong.export_text().value), "reparse non-simple phong override")
	var loader = ClassDB.instantiate("TBLoader")
	var overlay_target = Node3D.new(); var oracle_target = Node3D.new()
	root.add_child(loader); root.add_child(overlay_target); root.add_child(oracle_target)
	checks.check(loader.build_visual_preview_checked(phong, overlay_target).ok and loader.build_visual_preview_checked(phong_oracle, oracle_target).ok and built_mesh_data(overlay_target) == built_mesh_data(oracle_target), "clone_map_for_build and Builder regeneration preserve non-simple phong geometry attributes")
	loader.queue_free(); overlay_target.queue_free(); oracle_target.queue_free()

func face_edit_target(brush: Dictionary, face: int) -> Dictionary:
	return {"brush_id": brush.id, "face": face, "topology_revision": brush.topology_revision}

func face_uv_data(doc, brush: Dictionary) -> Array:
	var result: Array = []
	for face in brush.faces:
		result.append(doc.get_face_uv(brush.id, face.index, brush.topology_revision).value)
	return result

func check_unchanged_brush_geometry(before: Dictionary, after: Dictionary, message: String) -> void:
	for key in ["id", "entity_id", "aabb_min", "aabb_max", "vertices", "edges", "edge_vertex_indices"]:
		checks.check(after[key] == before[key], message + " " + key)
	checks.check(after.faces.size() == before.faces.size(), message + " face count")
	for index in mini(after.faces.size(), before.faces.size()):
		for key in ["index", "winding", "vertex_indices", "center", "normal"]:
			checks.check(after.faces[index][key] == before.faces[index][key], message + " face %d %s" % [index, key])

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
		for vertex in b.vertices:
			checks.check(f.normal.dot(vertex - f.center) <= 0.001, "every vertex inside supporting half-space")
		for i in f.winding.size():
			checks.check(absf(f.normal.dot(f.winding[i] - f.center)) < 0.001, "face winding is planar")
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
	doc.query_brushes_2d(2, Vector3(-100, -100, -100), Vector3(100, 100, 100))
	var spatial_before_sizes: Dictionary = doc.get_cache_root_counters()
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
	var failed_local_counters: Dictionary = doc.get_last_operation_counters()
	checks.check(not failed_local_counters.success and not failed_local_counters.committed and not failed_local_counters.get("completed", false)
		and failed_local_counters.brush_source_copies == 1, "failed local operation counters are unsuccessful and uncommitted")
	expect_failure(doc, doc.set_face_uv(id, 0, Vector2.ZERO, 0, Vector2(0, 1), b.topology_revision), state_before, "INVALID_ARGUMENT", "set_face_uv")
	checks.check(doc.get_preview_data() == preview_before and events == events_before, "invalid candidates retain cache and signals")
	expect_ok(doc.set_texture_sizes({"baseline/checker": Vector2i(64, 32)}), "resolve asymmetric preview texture dimensions")
	checks.check(state(doc) == state_before and events.preview == events_before.preview + 1 and events.map == events_before.map
		and doc.get_last_preview_change_reason() == &"texture_uv", "texture cache reports UV-only preview change without dirtying or revising document")
	var spatial_after_sizes: Dictionary = doc.get_cache_root_counters()
	checks.check(spatial_before_sizes.spatial_active == 1 and spatial_after_sizes.spatial_active == 1
		and spatial_after_sizes.spatial_entries == spatial_before_sizes.spatial_entries
		and spatial_after_sizes.spatial_nodes == spatial_before_sizes.spatial_nodes
		and spatial_after_sizes.spatial_history == 0 and spatial_after_sizes.spatial_stale_context_refs == 0,
		"texture dimensions retain BVH entries/nodes while rebinding only the current compact context")
	var texture_counters: Dictionary = doc.get_last_operation_counters()
	checks.check(texture_counters.operation == &"set_texture_sizes" and texture_counters.source_clones == 0
		and texture_counters.materializations == 0 and texture_counters.deep_clones == 0
		and texture_counters.parser_calls == 0 and texture_counters.writer_calls == 0
		and texture_counters.lm_geo_generator_calls == 0 and texture_counters.brush_builds == 0
		and texture_counters.compact_full_builds == 0 and texture_counters.compact_uv_updates > 0
		and texture_counters.compact_uv_copy_bytes > 0,
		"texture dimensions update compact UV data without topology builds, parser/writer, or geogen")
	checks.check(brush_data(doc, id).topology_revision == b.topology_revision, "texture sizes preserve component handles")
	var preview = doc.get_preview_data()[0]
	checks.check(preview.texture_size == Vector2i(64, 32), "actual texture dimensions in preview")
	for i in preview.uvs.size():
		checks.check(preview.uvs[i].is_equal_approx(preview_before[0].uvs[i] / Vector2(64, 32)), "UV normalized by independent width and height")
	expect_ok(doc.set_texture_sizes({}), "remove texture dimensions back to exact fallback")
	checks.check(doc.get_last_operation_counters().brush_builds == 0 and doc.get_last_operation_counters().compact_uv_updates > 0
		and doc.get_last_operation_counters().lm_geo_generator_calls == 0,
		"removed texture entry updates only its base and override UV payloads")
	b = brush_data(doc, id)
	expect_ok(doc.set_face_uv(id, 0, Vector2(7, 11), 23, Vector2(2, 3), b.topology_revision), "local UV edit after texture-size removal")
	var fallback_text: String = doc.export_text().value
	var fallback_reference = ClassDB.instantiate("TBMapDocument")
	expect_ok(fallback_reference.import_text(fallback_text), "reopen fallback UV reference")
	checks.check(doc.get_preview_data()[0].uvs == fallback_reference.get_preview_data()[0].uvs,
		"removed texture dimensions and subsequent local edits use exact 1x1 UV fallback")
	expect_ok(doc.set_texture_sizes({"baseline/checker": Vector2i(64, 32)}), "restore asymmetric dimensions after fallback parity")
	preview.vertices[0] = Vector3(999, 999, 999)
	b.faces[0].winding[0] = Vector3(999, 999, 999)
	checks.check(doc.get_preview_data()[0].vertices[0] != preview.vertices[0] and brush_data(doc, id).faces[0].winding[0] != b.faces[0].winding[0], "draw and preview are independent copies")
	state_before = state(doc)
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
	checks.check(doc.is_dirty() and doc.get_path() == "user://operations.map", "snapshot inverse preserves path but receives a distinct dirty generation")
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
		for sides in range(3, 10):
			expect_ok(doc.restore_snapshot(snapshot), "reset for prism")
			expect_ok(doc.make_prism(id, sides, axis), "%d sided prism axis %d" % [sides, axis])
			assert_solid(doc, id, sides * sin(TAU / sides) / 8.0 * 64 * 64 * 32)
			var prism = brush_data(doc, id)
			checks.check(prism.faces.size() == sides + 2 and prism.vertices.size() == sides * 2, "prism caps sides and vertices")
			checks.check(prism.aabb_min[axis] == Vector3(-16, -32, -8)[axis] and prism.aabb_max[axis] == Vector3(48, 32, 24)[axis], "prism extrusion axis/depth")
			checks.check(absf(prism.faces[0].normal[axis]) == 1 and prism.faces[0].normal == -prism.faces[1].normal, "prism cap orientation")
			var roundtrip = ClassDB.instantiate("TBMapDocument")
			expect_ok(roundtrip.import_text(doc.export_text().value), "prism round-trip")
			checks.check(roundtrip.export_text().value == doc.export_text().value, "prism canonical round-trip")
	expect_failure(doc, doc.make_prism(id, 2, 2), state(doc), "INVALID_ARGUMENT", "make_prism")
	expect_ok(doc.restore_snapshot(snapshot), "reset for vertex edits")
	b = brush_data(doc, id)
	var moved_vertex: Vector3 = b.vertices[0] + Vector3(1, 2, 3)
	expect_ok(doc.translate_vertices(id, PackedInt32Array([0]), Vector3(1, 2, 3), b.topology_revision), "single vertex rebuilds convex hull")
	b = brush_data(doc, id)
	checks.check(b.vertices.has(moved_vertex) and b.faces.size() > 6, "nonplanar cuboid sides split into convex hull planes")
	assert_solid(doc, id)
	expect_ok(doc.restore_snapshot(snapshot), "reset after vertex hull edit")
	b = brush_data(doc, id)
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

func test_apply_face_edits() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "first/original").value
	var second: int = doc.create_cuboid(Vector3(32, 0, 0), Vector3(48, 16, 16), "second/original").value
	var events := {"map": 0, "preview": 0, "dirty": 0}
	doc.map_changed.connect(func(_revision): events.map += 1)
	doc.preview_changed.connect(func(): events.preview += 1)
	doc.dirty_changed.connect(func(_dirty): events.dirty += 1)

	var first_before := brush_data(doc, first)
	var second_before := brush_data(doc, second)
	var first_uvs := face_uv_data(doc, first_before)
	var second_uvs := face_uv_data(doc, second_before)
	var revision_before: int = doc.get_revision()
	var texture_edits := [face_edit_target(first_before, 0), face_edit_target(second_before, 1)]
	texture_edits[0].texture = "batch/first"
	texture_edits[1].texture = "batch/second"
	var result: Dictionary = doc.apply_face_edits(texture_edits)
	expect_ok(result, "multi-face texture batch")
	checks.check(result.changed and doc.get_revision() == revision_before + 1 and events == {"map": 1, "preview": 0, "dirty": 0}, "texture batch commits one revision and signal")
	var first_after := brush_data(doc, first)
	var second_after := brush_data(doc, second)
	checks.check(first_after.faces[0].texture == "batch/first" and second_after.faces[1].texture == "batch/second", "texture batch updates every target")
	checks.check(first_after.faces[1].texture == "first/original" and second_after.faces[0].texture == "second/original", "texture batch leaves untargeted textures unchanged")
	check_unchanged_brush_geometry(first_before, first_after, "texture batch preserves first geometry")
	check_unchanged_brush_geometry(second_before, second_after, "texture batch preserves second geometry")
	checks.check(face_uv_data(doc, first_after) == first_uvs and face_uv_data(doc, second_after) == second_uvs, "texture batch preserves all UV data")

	first_before = first_after
	second_before = second_after
	var textures_before := [first_before.faces.map(func(face): return face.texture), second_before.faces.map(func(face): return face.texture)]
	var uv_edits := [face_edit_target(first_before, 2), face_edit_target(second_before, 3)]
	uv_edits[0].uv = {"shift": Vector2(4, -8), "rotation": 15.0, "scale": Vector2(0.5, 2)}
	uv_edits[1].uv = {"shift": Vector2(-3, 9), "rotation": -30.0, "scale": Vector2(4, 0.25)}
	revision_before = doc.get_revision()
	result = doc.apply_face_edits(uv_edits)
	expect_ok(result, "multi-face UV batch")
	checks.check(result.changed and doc.get_revision() == revision_before + 1 and events == {"map": 2, "preview": 0, "dirty": 0}, "UV batch commits one revision and signal")
	first_after = brush_data(doc, first)
	second_after = brush_data(doc, second)
	var first_after_uvs := face_uv_data(doc, first_after)
	var second_after_uvs := face_uv_data(doc, second_after)
	checks.check(first_after_uvs[2].shift == Vector2(4, -8) and first_after_uvs[2].rotation == 15.0 and first_after_uvs[2].scale == Vector2(0.5, 2), "first batched UV is exact")
	checks.check(second_after_uvs[3].shift == Vector2(-3, 9) and second_after_uvs[3].rotation == -30.0 and second_after_uvs[3].scale == Vector2(4, 0.25), "second batched UV is exact")
	checks.check(first_after_uvs[0] == first_uvs[0] and second_after_uvs[0] == second_uvs[0], "UV batch leaves untargeted UV data unchanged")
	checks.check([first_after.faces.map(func(face): return face.texture), second_after.faces.map(func(face): return face.texture)] == textures_before, "UV batch preserves all textures")
	check_unchanged_brush_geometry(first_before, first_after, "UV batch preserves first geometry")
	check_unchanged_brush_geometry(second_before, second_after, "UV batch preserves second geometry")

	first_before = first_after
	var stale_revision: int = first_before.topology_revision
	var combined := face_edit_target(first_before, 4)
	combined.texture = "combined/material"
	combined.uv = {"shift": Vector2(12, 6), "rotation": 45, "scale": Vector2(2, 3)}
	revision_before = doc.get_revision()
	result = doc.apply_face_edits([combined])
	expect_ok(result, "combined texture and UV face edit")
	first_after = brush_data(doc, first)
	var combined_uv: Dictionary = doc.get_face_uv(first, 4, first_after.topology_revision).value
	checks.check(result.changed and doc.get_revision() == revision_before + 1 and events == {"map": 3, "preview": 0, "dirty": 0}, "combined edit commits one revision and signal")
	checks.check(first_after.faces[4].texture == "combined/material" and combined_uv.shift == Vector2(12, 6) and combined_uv.rotation == 45 and combined_uv.scale == Vector2(2, 3), "combined edit applies both fields")
	check_unchanged_brush_geometry(first_before, first_after, "combined edit preserves geometry")

	var unchanged := state(doc)
	var events_before := events.duplicate()
	result = doc.apply_face_edits([])
	expect_ok(result, "empty face edit batch")
	checks.check(not result.changed, "empty face edit batch is unchanged")
	var current_uv: Dictionary = doc.get_face_uv(first, 4, first_after.topology_revision).value
	var no_op := face_edit_target(first_after, 4)
	no_op.texture = first_after.faces[4].texture
	no_op.uv = {"shift": current_uv.shift, "rotation": current_uv.rotation, "scale": current_uv.scale}
	result = doc.apply_face_edits([no_op])
	expect_ok(result, "no-op face edit batch")
	checks.check(not result.changed and state(doc) == unchanged and events == events_before, "empty and no-op batches preserve revision state and signals")

	var duplicate_a := face_edit_target(first_after, 0)
	duplicate_a.texture = "duplicate/a"
	var duplicate_b := face_edit_target(first_after, 0)
	duplicate_b.texture = "duplicate/b"
	expect_failure(doc, doc.apply_face_edits([duplicate_a, duplicate_b]), unchanged, "INVALID_ARGUMENT", "apply_face_edits")
	checks.check(events == events_before, "duplicate rejection emits no signals")

	var valid_before_stale := face_edit_target(first_after, 5)
	valid_before_stale.texture = "must/not/commit"
	var stale := {"brush_id": second, "face": 4, "topology_revision": stale_revision - 1, "texture": "stale/not/commit"}
	expect_failure(doc, doc.apply_face_edits([valid_before_stale, stale]), unchanged, "STALE_COMPONENT", "apply_face_edits")
	checks.check(state(doc) == unchanged and events == events_before, "stale target atomically rejects preceding valid edit")
	var invalid := face_edit_target(first_after, 5)
	invalid.brush_id = 999999
	expect_failure(doc, doc.apply_face_edits([valid_before_stale, invalid]), unchanged, "INVALID_ID", "apply_face_edits")
	checks.check(state(doc) == unchanged and events == events_before, "invalid target atomically rejects preceding valid edit")

	var valve = ClassDB.instantiate("TBMapDocument")
	if not expect_ok(valve.load_map("res://fixtures/valve_cube.map"), "load Valve face batch fixture"):
		return
	var valve_brush: Dictionary = valve.get_draw_data()[0]
	var valve_before := state(valve)
	var valve_events := {"map": 0, "preview": 0, "dirty": 0}
	valve.map_changed.connect(func(_revision): valve_events.map += 1)
	valve.preview_changed.connect(func(): valve_events.preview += 1)
	valve.dirty_changed.connect(func(_dirty): valve_events.dirty += 1)
	var valve_texture := face_edit_target(valve_brush, 0)
	valve_texture.texture = "must/not/commit"
	var valve_uv := face_edit_target(valve_brush, 1)
	valve_uv.uv = {"shift": Vector2.ONE, "rotation": 0, "scale": Vector2.ONE}
	expect_failure(valve, valve.apply_face_edits([valve_texture, valve_uv]), valve_before, "UNSUPPORTED_PROJECTION", "apply_face_edits")
	checks.check(valve.get_draw_data()[0].faces[0].texture == valve_brush.faces[0].texture and valve_events == {"map": 0, "preview": 0, "dirty": 0}, "Valve UV rejection is atomic and emits no signals")

func test_brush_topology_tokens() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "token/first").value
	var second: int = doc.create_cuboid(Vector3(32, 0, 0), Vector3(48, 16, 16), "token/second").value
	var before: RefCounted = doc.capture_history_state()
	var first_before: Dictionary = brush_data(doc, first)
	var second_before: Dictionary = brush_data(doc, second)
	checks.check(first_before.topology_revision == second_before.topology_revision, "structural load gives both brushes current topology tokens")
	var old_token: int = first_before.topology_revision
	expect_ok(doc.translate_face(first, 0, first_before.faces[0].normal, old_token), "topology edit changes one brush token")
	var first_changed: Dictionary = brush_data(doc, first)
	var second_unchanged: Dictionary = brush_data(doc, second)
	var changed_state: RefCounted = doc.capture_history_state()
	checks.check(first_changed.topology_revision != old_token and second_unchanged.topology_revision == old_token,
		"topology edit replaces only the changed brush token")
	expect_failure(doc, doc.get_face_uv(first, 0, old_token), state(doc), "STALE_COMPONENT", "get_face_uv")
	expect_ok(doc.get_face_uv(second, 0, old_token), "independent brush token remains valid")

	var first_token: int = first_changed.topology_revision
	expect_ok(doc.set_face_texture(first, 0, "token/material", first_token), "material edit preserves topology token")
	checks.check(brush_data(doc, first).topology_revision == first_token, "material edit keeps stable indices and token")
	expect_ok(doc.set_face_uv(first, 0, Vector2.ONE, 0, Vector2.ONE, first_token), "UV edit preserves topology token")
	checks.check(brush_data(doc, first).topology_revision == first_token, "UV edit keeps stable indices and token")
	expect_ok(doc.translate_brushes(PackedInt64Array([first]), Vector3.RIGHT), "rigid translation preserves topology token")
	checks.check(brush_data(doc, first).topology_revision == first_token, "rigid transform keeps stable indices and token")

	expect_ok(doc.restore_history_state(before), "topology-token undo state")
	checks.check(brush_data(doc, first).topology_revision == old_token and doc.get_face_uv(second, 0, old_token).ok,
		"undo restores per-brush tokens without invalidating the independent brush")
	expect_ok(doc.restore_history_state(changed_state), "topology-token redo state")
	checks.check(brush_data(doc, first).topology_revision == first_token and brush_data(doc, second).topology_revision == old_token,
		"redo restores changed and unchanged brush tokens independently")
	expect_failure(doc, doc.get_face_uv(first, 0, old_token), state(doc), "STALE_COMPONENT", "get_face_uv")

func component(b: Dictionary, kind: String, index: int) -> Dictionary:
	return {"brush_id": b.id, "kind": kind, "index": index, "topology_revision": b.topology_revision}

func test_rotation() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3(16, 16, 16), "first/material").value
	var second: int = doc.create_cuboid(Vector3(32, 0, 0), Vector3(48, 16, 16), "second/material").value
	var first_brush = brush_data(doc, first)
	expect_ok(doc.set_face_uv(first, 0, Vector2(7, -3), 22.5, Vector2(0.5, 2), first_brush.topology_revision), "prepare rotation material data")
	first_brush = brush_data(doc, first)
	var before_text: String = doc.export_text().value
	var before_state = doc.capture_history_state()
	var before_uv: Dictionary = doc.get_face_uv(first, 0, first_brush.topology_revision).value
	var ids = PackedInt64Array([first, second, first])
	expect_ok(doc.rotate_brushes(ids, Vector3(24, 8, 8), 2, PI / 2), "rotate deduplicated brush selection")
	var a = brush_data(doc, first)
	var b = brush_data(doc, second)
	checks.check(a.aabb_min.is_equal_approx(Vector3(16, -16, 0)) and a.aabb_max.is_equal_approx(Vector3(32, 0, 16)), "first brush rotates around shared selection center")
	checks.check(b.aabb_min.is_equal_approx(Vector3(16, 16, 0)) and b.aabb_max.is_equal_approx(Vector3(32, 32, 16)), "second brush rotates around shared selection center")
	checks.check(a.faces.all(func(face): return face.texture == "first/material") and b.faces.all(func(face): return face.texture == "second/material"), "rotation preserves per-brush face materials")
	var after_uv: Dictionary = doc.get_face_uv(first, 0, a.topology_revision).value
	checks.check(after_uv.projection == before_uv.projection and after_uv.shift == before_uv.shift and after_uv.rotation == before_uv.rotation and after_uv.scale == before_uv.scale, "rotation preserves face UV metadata")
	var rotated_text: String = doc.export_text().value
	var rotated_state = doc.capture_history_state()
	expect_ok(doc.restore_history_state(before_state), "native rotation undo state")
	checks.check(doc.export_text().value == before_text, "native rotation undo restores exact canonical text")
	expect_ok(doc.restore_history_state(rotated_state), "native rotation redo state")
	checks.check(doc.export_text().value == rotated_text, "native rotation redo restores exact canonical text")
	var unchanged = state(doc)
	checks.check(not doc.rotate_brushes(ids, Vector3.ZERO, 0, TAU).changed and state(doc) == unchanged, "full-turn rotation is an exact no-op")
	expect_failure(doc, doc.rotate_brushes(ids, Vector3(INF, 0, 0), 2, PI), unchanged, "INVALID_ARGUMENT", "rotate_brushes")
	expect_failure(doc, doc.rotate_brushes(PackedInt64Array([999999]), Vector3.ZERO, 2, PI), unchanged, "INVALID_ID", "rotate_brushes")

func expect_preview(result: Dictionary, message: String) -> Array:
	if not expect_ok(result, message):
		return []
	checks.check(not result.changed and result.value is Array, message + " is read-only and returns candidate brushes")
	for brush in result.value:
		checks.check(brush.size() == 9 and brush.has_all(["id", "source_id", "entity_id", "aabb_min", "aabb_max", "vertices", "edges", "edge_vertex_indices", "faces"]), message + " candidate brush schema")
		checks.check(brush.faces.all(func(face): return face.size() == 6 and face.has_all(["index", "winding", "vertex_indices", "center", "normal", "texture"])), message + " candidate face schema")
	return result.value

func preview_matches_document(candidates: Array, doc, message: String) -> void:
	for candidate in candidates:
		var committed := brush_data(doc, candidate.id)
		checks.check(not committed.is_empty(), message + " committed candidate ID exists")
		for key in ["entity_id", "aabb_min", "aabb_max", "vertices", "edges", "edge_vertex_indices", "faces"]:
			checks.check(candidate[key] == committed[key], message + " exact " + key)

func test_candidate_geometry_previews() -> void:
	var translated = ClassDB.instantiate("TBMapDocument")
	var first: int = translated.create_cuboid(Vector3.ZERO, Vector3(16, 24, 32), "first/material").value
	var second: int = translated.create_cuboid(Vector3(40, 0, 0), Vector3(56, 24, 32), "second/material").value
	var first_token: int = brush_data(translated, first).topology_revision
	expect_ok(translated.set_face_texture(first, 0, "first/overlay", first_token), "prepare preview editor material overlay")
	var ids := PackedInt64Array([second, first, second])
	var events := {"map": 0, "preview": 0, "dirty": 0}
	translated.map_changed.connect(func(_r): events.map += 1)
	translated.preview_changed.connect(func(): events.preview += 1)
	translated.dirty_changed.connect(func(_d): events.dirty += 1)
	var manifest: Dictionary = translated.prepare_preview_chunks(1.0, PackedInt64Array(), 0)
	var chunk_id: String = manifest.chunks[0].chunk_id
	var before := state(translated)
	var history = translated.capture_history_state()
	var translation := expect_preview(translated.preview_translate_brushes(ids, Vector3(8, -4, 2)), "preview multi-brush translation")
	checks.check(translation.map(func(b): return b.id) == [first, second] and translation.all(func(b): return b.source_id == b.id), "translation preview deduplicates in source order rather than selection order")
	checks.check(state(translated) == before and events == {"map": 0, "preview": 0, "dirty": 0} and translated.is_history_state_current(history), "translation preview preserves text dirty revisions IDs and history")
	checks.check(not translated.get_preview_chunk(chunk_id).is_empty(), "translation preview preserves prepared native caches")
	expect_ok(translated.translate_brushes(ids, Vector3(8, -4, 2)), "commit previewed translation")
	preview_matches_document(translation, translated, "translation preview")

	var rotated = ClassDB.instantiate("TBMapDocument")
	first = rotated.create_cuboid(Vector3.ZERO, Vector3(16, 24, 32), "first/material").value
	second = rotated.create_cuboid(Vector3(40, 0, 0), Vector3(56, 24, 32), "second/material").value
	ids = PackedInt64Array([first, second])
	before = state(rotated)
	var rotation := expect_preview(rotated.preview_rotate_brushes(ids, Vector3(28, 12, 16), 2, PI / 2), "preview world-axis multi-brush rotation")
	checks.check(state(rotated) == before, "rotation preview preserves complete document state")
	expect_ok(rotated.rotate_brushes(ids, Vector3(28, 12, 16), 2, PI / 2), "commit previewed rotation")
	preview_matches_document(rotation, rotated, "rotation preview")

	for kind in ["face", "edge", "vertex"]:
		var components_doc = ClassDB.instantiate("TBMapDocument")
		var id: int = components_doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "component/material").value
		var brush := brush_data(components_doc, id)
		var movement: Vector3 = brush.faces[0].normal * 8 if kind == "face" else Vector3(8, 4, 2)
		var selected := [component(brush, kind, 0)]
		before = state(components_doc)
		var component_preview := expect_preview(components_doc.preview_translate_components(selected, movement), "preview " + kind + " translation")
		checks.check(state(components_doc) == before and component_preview.size() == 1 and component_preview[0].source_id == id, kind + " preview is atomic and identifies its source")
		expect_ok(components_doc.translate_components(selected, movement), "commit previewed " + kind + " translation")
		preview_matches_document(component_preview, components_doc, kind + " preview")
		var stale_before := state(components_doc)
		expect_failure(components_doc, components_doc.preview_translate_components(selected, movement), stale_before, "STALE_COMPONENT", "preview_translate_components")

	var invalid = ClassDB.instantiate("TBMapDocument")
	var invalid_id: int = invalid.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "invalid/material").value
	var invalid_brush := brush_data(invalid, invalid_id)
	before = state(invalid)
	expect_failure(invalid, invalid.preview_translate_brushes(PackedInt64Array([invalid_id, 999999]), Vector3.ONE), before, "INVALID_ID", "preview_translate_brushes")
	expect_failure(invalid, invalid.preview_rotate_brushes(PackedInt64Array([invalid_id]), Vector3.ZERO, 3, PI), before, "INVALID_ARGUMENT", "preview_rotate_brushes")
	expect_failure(invalid, invalid.preview_translate_components([component(invalid_brush, "face", 0)], Vector3(64, 0, 0)), before, "INVALID_GEOMETRY", "preview_translate_components")
	expect_failure(invalid, invalid.preview_clip_brushes(PackedInt64Array([invalid_id]), Vector3.ZERO, Vector3.UP, Vector3.UP, true), before, "INVALID_ARGUMENT", "preview_clip_brushes")

	var clipped = ClassDB.instantiate("TBMapDocument")
	first = clipped.create_cuboid(Vector3(-16, 0, 0), Vector3(16, 32, 32), "first/material").value
	second = clipped.create_cuboid(Vector3(-16, 48, 0), Vector3(16, 80, 32), "second/material").value
	ids = PackedInt64Array([first, second, first])
	var p0 := Vector3.ZERO
	var p1 := Vector3(0, 0, 1)
	var p2 := Vector3(0, 1, 0)
	before = state(clipped)
	var split_preview := expect_preview(clipped.preview_clip_brushes(ids, p0, p1, p2, true), "preview multi-brush split")
	checks.check(split_preview.size() == 4 and split_preview.filter(func(b): return b.source_id == first).size() == 2 and split_preview.filter(func(b): return b.source_id == second).size() == 2, "split preview reports both pieces and source provenance")
	checks.check(state(clipped) == before, "split preview does not consume predicted IDs")
	var split: Dictionary = clipped.clip_brushes(ids, p0, p1, p2, true)
	expect_ok(split, "commit previewed multi-brush split")
	checks.check(split.value == PackedInt64Array(split_preview.map(func(b): return b.id)), "split preview IDs equal immediate commit IDs")
	preview_matches_document(split_preview, clipped, "split preview")

	var flipped = ClassDB.instantiate("TBMapDocument")
	var flipped_id: int = flipped.create_cuboid(Vector3(-16, -16, -16), Vector3.ONE * 16, "flip/material").value
	var flip_preview := expect_preview(flipped.preview_clip_brushes(PackedInt64Array([flipped_id]), p0, p1, p2, false, true), "preview flipped clip")
	expect_ok(flipped.clip_brushes(PackedInt64Array([flipped_id]), p0, p2, p1, false), "commit flipped preview with reversed points")
	preview_matches_document(flip_preview, flipped, "flipped clip preview")

	var ids_doc = ClassDB.instantiate("TBMapDocument")
	var source_id: int = ids_doc.create_cuboid(Vector3(-16, -16, -16), Vector3.ONE * 16, "ids/material").value
	var predicted := expect_preview(ids_doc.preview_clip_brushes(PackedInt64Array([source_id]), p0, p1, p2, true), "preview predicted split IDs")
	var created: Dictionary = ids_doc.create_cuboid(Vector3(64, 0, 0), Vector3(80, 16, 16), "after/preview")
	expect_ok(created, "create after split preview")
	checks.check(predicted.size() == 2 and created.value == predicted[0].id, "preview does not consume its first predicted brush ID")

func test_merge_brushes() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "first/material").value
	var second: int = doc.create_cuboid(Vector3(16, 0, 0), Vector3(32, 16, 16), "second/material").value
	var first_brush := brush_data(doc, first)
	var metadata_face := -1
	for face in first_brush.faces:
		if face.normal == Vector3(0, -1, 0): metadata_face = face.index
	expect_ok(doc.set_face_texture(first, metadata_face, "first/metadata", first_brush.topology_revision), "prepare merge texture metadata")
	first_brush = brush_data(doc, first)
	expect_ok(doc.set_face_uv(first, metadata_face, Vector2(7, -3), 22.5, Vector2(0.5, 2), first_brush.topology_revision), "prepare merge UV metadata")
	var before_text: String = doc.export_text().value
	var before_history = doc.capture_history_state()
	var merged: Dictionary = doc.merge_brushes(PackedInt64Array([first, second, first]))
	if not expect_ok(merged, "merge two full-face boxes"):
		return
	var merged_id: int = merged.value
	checks.check(merged.changed and merged_id > second and brush_data(doc, first).is_empty() and brush_data(doc, second).is_empty(), "merge replaces sources with one fresh-ID brush")
	var result := brush_data(doc, merged_id)
	checks.check(doc.get_draw_data().size() == 1 and result.aabb_min == Vector3.ZERO and result.aabb_max == Vector3(32, 16, 16) and result.faces.size() == 6, "two-box merge is the exact convex union")
	assert_solid(doc, merged_id, 32 * 16 * 16)
	var retained_face := -1
	for face in result.faces:
		if face.normal == Vector3(0, -1, 0):
			retained_face = face.index
			checks.check(face.texture == "first/metadata", "coplanar outward plane keeps first retained source texture")
	var uv: Dictionary = doc.get_face_uv(merged_id, retained_face, result.topology_revision).value
	checks.check(uv.shift == Vector2(7, -3) and uv.rotation == 22.5 and uv.scale == Vector2(0.5, 2), "coplanar outward plane keeps first retained source UV metadata")
	var after_text: String = doc.export_text().value
	var after_history = doc.capture_history_state()
	expect_ok(doc.restore_history_state(before_history), "undo merge native history state")
	checks.check(doc.export_text().value == before_text and not brush_data(doc, first).is_empty() and not brush_data(doc, second).is_empty() and brush_data(doc, merged_id).is_empty(), "merge undo restores exact sources and identities")
	expect_ok(doc.restore_history_state(after_history), "redo merge native history state")
	checks.check(doc.export_text().value == after_text and not brush_data(doc, merged_id).is_empty(), "merge redo restores exact result identity")

	var chain = ClassDB.instantiate("TBMapDocument")
	var chain_ids := PackedInt64Array()
	for x in 4:
		chain_ids.append(chain.create_cuboid(Vector3(x * 8, 0, 0), Vector3((x + 1) * 8, 8, 8), "chain/%d" % x).value)
	var chain_result: Dictionary = chain.merge_brushes(chain_ids)
	expect_ok(chain_result, "merge connected N-brush chain")
	checks.check(chain.get_draw_data().size() == 1 and brush_data(chain, chain_result.value).aabb_max == Vector3(32, 8, 8), "N-brush chain removes every interior pair")
	assert_solid(chain, chain_result.value, 32 * 8 * 8)

	var invalid = ClassDB.instantiate("TBMapDocument")
	var base: int = invalid.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "base").value
	var partial: int = invalid.create_cuboid(Vector3(16, 0, 0), Vector3(32, 8, 16), "partial").value
	var disconnected: int = invalid.create_cuboid(Vector3(64, 0, 0), Vector3(80, 16, 16), "disconnected").value
	var before := state(invalid)
	expect_failure(invalid, invalid.merge_brushes(PackedInt64Array([base, partial])), before, "INVALID_GEOMETRY", "merge_brushes")
	expect_failure(invalid, invalid.merge_brushes(PackedInt64Array([base, disconnected])), before, "INVALID_GEOMETRY", "merge_brushes")
	expect_failure(invalid, invalid.merge_brushes(PackedInt64Array([base, base])), before, "INVALID_ARGUMENT", "merge_brushes")
	expect_failure(invalid, invalid.merge_brushes(PackedInt64Array([base, 999999])), before, "INVALID_ID", "merge_brushes")
	var next_after_failures: Dictionary = invalid.create_cuboid(Vector3(96, 0, 0), Vector3(112, 16, 16), "fresh")
	expect_ok(next_after_failures, "create after atomic merge failures")
	checks.check(next_after_failures.value == disconnected + 1, "failed merges consume no brush ID")

	var l_shape = ClassDB.instantiate("TBMapDocument")
	var corner: int = l_shape.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "corner").value
	var right: int = l_shape.create_cuboid(Vector3(16, 0, 0), Vector3(32, 16, 16), "right").value
	var upper: int = l_shape.create_cuboid(Vector3(0, 16, 0), Vector3(16, 32, 16), "upper").value
	expect_failure(l_shape, l_shape.merge_brushes(PackedInt64Array([corner, right, upper])), state(l_shape), "INVALID_GEOMETRY", "merge_brushes")

	var owners = ClassDB.instantiate("TBMapDocument")
	var owned_a: int = owners.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "a").value
	var owned_b: int = owners.create_cuboid(Vector3(16, 0, 0), Vector3(32, 16, 16), "b").value
	expect_ok(owners.group_brushes(PackedInt64Array([owned_b]), "func_detail"), "prepare mixed-owner merge")
	expect_failure(owners, owners.merge_brushes(PackedInt64Array([owned_a, owned_b])), state(owners), "INVALID_ARGUMENT", "merge_brushes")

	var limited = ClassDB.instantiate("TBMapDocument")
	var many_faces := "{\n\"classname\" \"worldspawn\"\n" + pyramid_brush_text(63, 64.0, "upper") + pyramid_brush_text(63, -64.0, "lower") + "}\n"
	if expect_ok(limited.import_text(many_faces), "import 126-face convex merge candidate"):
		var limited_ids: PackedInt64Array = limited.get_draw_data().map(func(brush): return brush.id)
		expect_failure(limited, limited.merge_brushes(limited_ids), state(limited), "LIMIT_EXCEEDED", "merge_brushes")
		var after_limit: Dictionary = limited.create_cuboid(Vector3(256, 0, 0), Vector3(272, 16, 16), "after-limit")
		expect_ok(after_limit, "create after over-limit merge failure")
		checks.check(after_limit.value == limited_ids[-1] + 1, "over-limit merge consumes no brush ID")

func pyramid_brush_text(sides: int, apex_z: float, texture: String) -> String:
	var ring: Array[Vector3] = []
	for i in sides:
		var angle := TAU * i / sides
		ring.append(Vector3(128 * cos(angle), 128 * sin(angle), 0))
	var points := [ring[0], ring[1], ring[2]]
	if apex_z < 0:
		var swap: Vector3 = points[1]; points[1] = points[2]; points[2] = swap
	var out := "{\n" + map_face_text(points[0], points[1], points[2], texture)
	var apex := Vector3(0, 0, apex_z)
	for i in sides:
		out += map_face_text(ring[i], apex if apex_z > 0 else ring[(i + 1) % sides], ring[(i + 1) % sides] if apex_z > 0 else apex, texture)
	return out + "}\n"

func map_face_text(a: Vector3, b: Vector3, c: Vector3, texture: String) -> String:
	return "( %s %s %s ) ( %s %s %s ) ( %s %s %s ) %s 0 0 0 1 1\n" % [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, texture]

func test_vertex_hull_sequences() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 73019
	for origin in [Vector3.ZERO, Vector3(4096, -2048, 1024)]:
		var doc = ClassDB.instantiate("TBMapDocument")
		var id: int = doc.create_cuboid(origin, origin + Vector3.ONE * 256, "baseline/checker").value
		for step in 24:
			var b := brush_data(doc, id)
			var index := random.randi_range(0, b.vertices.size() - 1)
			var delta := Vector3(random.randi_range(-2, 2), random.randi_range(-2, 2), random.randi_range(-2, 2)) * 8
			var expected: PackedVector3Array = b.vertices.duplicate()
			expected[index] += delta
			if not expect_ok(doc.translate_vertices(id, PackedInt32Array([index]), delta, b.topology_revision), "sequential different corners origin %s step %d index %d delta %s" % [origin, step, index, delta]):
				break
			assert_vertex_hull(doc, id, expected)
	for extent in [1.0, 64.0, 256.0, 1024.0]:
		for origin in [Vector3.ZERO, Vector3(4096, -2048, 1024)]:
			var doc = ClassDB.instantiate("TBMapDocument")
			var id: int = doc.create_cuboid(origin, origin + Vector3.ONE * extent, "baseline/checker").value
			var snapshot: Dictionary = doc.snapshot().value
			for corner in 8:
				for delta in [Vector3(8, 16, 0), Vector3(16, 16, 0), Vector3(1, 2, 3), Vector3(-8, -16, -8)]:
					doc.restore_snapshot(snapshot)
					var b := brush_data(doc, id)
					var expected: PackedVector3Array = b.vertices.duplicate()
					expected[corner] += delta
					if expect_ok(doc.translate_vertices(id, PackedInt32Array([corner]), delta, b.topology_revision), "corner %d delta %s extent %s origin %s" % [corner, delta, extent, origin]):
						assert_vertex_hull(doc, id, expected)
	# Re-select by position after each committed drag: face/vertex ordering changes
	# when nonplanar sides split, and the next drag starts from regenerated planes.
	for extent in [64.0, 256.0, 1024.0]:
		for origin in [Vector3.ZERO, Vector3(4096, -2048, 1024)]:
			var doc = ClassDB.instantiate("TBMapDocument")
			var created: Dictionary = doc.create_cuboid(origin, origin + Vector3.ONE * extent, "baseline/checker")
			if not expect_ok(created, "create sequential vertex fixture"):
				continue
			var id: int = created.value
			var position: Vector3 = origin + Vector3.ONE * extent
			var movements := [Vector3(16, 8, 0), Vector3(0, 8, 16), Vector3(-8, -16, -8), Vector3(-8, 0, -8), Vector3(-8, -8, -8), Vector3(8, 8, 8)]
			for step in movements.size():
				var b := brush_data(doc, id)
				var index := -1
				for i in b.vertices.size():
					if b.vertices[i].distance_to(position) < 0.001:
						index = i
				if not checks.check(index >= 0, "sequential moved corner remains selectable"):
					break
				var movement: Vector3 = movements[step] * (extent / 64.0)
				if not expect_ok(doc.translate_vertices(id, PackedInt32Array([index]), movement, b.topology_revision), "vertex drag extent %s origin %s step %d" % [extent, origin, step]):
					break
				position += movement
				assert_solid(doc, id)
				b = brush_data(doc, id)
				checks.check(Array(b.vertices).any(func(v): return v.distance_to(position) < 0.001), "drag reaches requested corner extent %s origin %s step %d: %s in %s" % [extent, origin, step, position, b.vertices])
				if step == 3 or step == 5:
					checks.check(b.faces.size() == 6 and b.vertices.size() == 8, "returning corner merges coplanar faces into cuboid")
				expect_ok(doc.rebuild(), "deformed hull survives native regeneration")

func test_shallow_vertex_intersections() -> void:
	var source := FileAccess.get_file_as_string("res://fixtures/vertex_prism.map")
	# Reverse the serialized faces and use Valve projection too: neither plane
	# traversal order nor UV syntax may decide whether an edited solid is closed.
	var planes: Array = Array(source.split("\n")).filter(func(line): return line.begins_with("("))
	planes.reverse()
	var valve := "{\n\"classname\" \"worldspawn\"\n{\n"
	for line in planes:
		valve += line.replace("baseline/checker 0 0 0 1 1", "baseline/checker [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1") + "\n"
	valve += "}\n}\n"
	for map_text in [source, valve]:
		var doc = ClassDB.instantiate("TBMapDocument")
		if not expect_ok(doc.import_text(map_text), "import shallow-plane vertex fixture"):
			continue
		var id: int = doc.get_draw_data()[0].id
		var snapshot: Dictionary = doc.snapshot().value
		for kind in ["vertex", "edge"]:
			doc.restore_snapshot(snapshot)
			var b := brush_data(doc, id)
			var a := Vector3(4144, -2043.7127685546875, 1024)
			var c := Vector3(4155.712890625, -2032, 1024)
			var index := -1
			var selected := PackedInt32Array()
			var movement := Vector3(16, 16, 0)
			if kind == "vertex":
				index = b.vertices.find(c)
				selected.append(index)
			else:
				selected = PackedInt32Array([b.vertices.find(a), b.vertices.find(c)])
				for edge in b.edge_vertex_indices.size() / 2:
					if selected.has(b.edge_vertex_indices[edge * 2]) and selected.has(b.edge_vertex_indices[edge * 2 + 1]):
						index = edge
				var reference := (a + c) * 0.5
				movement = (reference + movement).snapped(Vector3.ONE * 16) - reference
			if not checks.check(index >= 0 and not selected.has(-1), "select actual prism corner/edge by position"):
				continue
			var expected: PackedVector3Array = b.vertices.duplicate()
			for v in selected:
				expected[v] += movement
			var result: Dictionary = doc.translate_components([component(b, kind, index)], movement)
			if not expect_ok(result, "shallow supporting planes after %s grid edit" % kind):
				continue
			assert_vertex_hull(doc, id, expected)
			expect_ok(doc.rebuild(), "shallow-plane edit regenerates from serialized planes")
			assert_vertex_hull(doc, id, expected)
			var reopened = ClassDB.instantiate("TBMapDocument")
			expect_ok(reopened.import_text(doc.export_text().value), "shallow-plane edit round-trips")
			checks.check(reopened.export_text().value == doc.export_text().value, "shallow-plane round-trip retains exact source")

	# Merely lowering the determinant cutoff is insufficient: solving rounded
	# unit normals creates duplicate corners >1e-5 apart in this larger prism.
	var doc = ClassDB.instantiate("TBMapDocument")
	var id: int = doc.create_cuboid(Vector3(4096, -2048, 1024), Vector3(5120, -1024, 2048), "baseline/checker").value
	if expect_ok(doc.make_prism(id, 12, 2), "create precision-loss prism"):
		var b := brush_data(doc, id)
		var index: int = b.vertices.find(Vector3(4864, -1979.405029296875, 1024))
		if checks.check(index >= 0, "select precision-loss corner by position"):
			var expected: PackedVector3Array = b.vertices.duplicate()
			expected[index] += Vector3(-16, -16, 0)
			if expect_ok(doc.translate_vertices(id, PackedInt32Array([index]), Vector3(-16, -16, 0), b.topology_revision), "intersections preserve incidence at shallow angles"):
				assert_vertex_hull(doc, id, expected)

func assert_vertex_hull(doc, id: int, expected: PackedVector3Array) -> void:
	assert_solid(doc, id)
	var b := brush_data(doc, id)
	# Together these checks distinguish the requested convex hull from a merely
	# closed solid whose missing supporting planes expanded/moved other corners.
	for vertex in b.vertices:
		checks.check(Array(expected).any(func(v): return v.distance_to(vertex) < 0.001), "hull has only input extreme points")
	for point in expected:
		for face in b.faces:
			checks.check(face.normal.dot(point - face.center) <= 0.001, "hull contains every requested input point")

func test_vertex_hull_metadata_and_degeneracy() -> void:
	for fixture in ["classic_cube", "valve_cube"]:
		var doc = ClassDB.instantiate("TBMapDocument")
		if not expect_ok(doc.load_map("res://fixtures/" + fixture + ".map"), "load vertex metadata fixture"):
			continue
		var b: Dictionary = doc.get_draw_data()[0]
		var id: int = b.id
		for f in b.faces.size():
			b = brush_data(doc, id)
			expect_ok(doc.set_face_texture(id, f, "face/%d" % f, b.topology_revision), "label source face provenance")
		var snapshot: Dictionary = doc.snapshot().value
		var original_lines: PackedStringArray = doc.export_text().value.split("\n")
		for delta in [Vector3(8, 16, 8), Vector3(-8, -16, -8)]:
			doc.restore_snapshot(snapshot)
			b = brush_data(doc, id)
			var index: int = b.vertices.find(b.aabb_max)
			var expected: PackedVector3Array = b.vertices.duplicate()
			expected[index] += delta
			var uvs: Array = []
			for face in b.faces:
				uvs.append(doc.get_face_uv(id, face.index, b.topology_revision).value)
			if not expect_ok(doc.translate_vertices(id, PackedInt32Array([index]), delta, b.topology_revision), "textured inward/outward corner"):
				continue
			assert_vertex_hull(doc, id, expected)
			var after := brush_data(doc, id)
			for face in after.faces:
				var source: int = face.texture.trim_prefix("face/").to_int()
				checks.check(doc.get_face_uv(id, face.index, after.topology_revision).value == uvs[source], "split/merged face preserves complete classic or Valve UV metadata")
				# Every hull triangle in this fixture has a common source face.
				for v in face.vertex_indices:
					checks.check(Array(b.faces[source].vertex_indices).any(func(old): return expected[old].distance_to(after.vertices[v]) < 0.001), "new plane inherits its common incident face")
			var lines: PackedStringArray = doc.export_text().value.split("\n")
			for line in lines:
				if not line.begins_with("("):
					continue
				var suffix := line.substr(line.find('"face/'))
				checks.check(Array(original_lines).any(func(original): return original.ends_with(suffix)), "vertex hull retains projection and optional surface flags verbatim")
			for face in b.faces:
				if not face.vertex_indices.has(index):
					for original in original_lines:
						if original.contains('"%s"' % face.texture):
							checks.check(lines.has(original), "untouched source supporting plane is retained exactly")
			var reopened = ClassDB.instantiate("TBMapDocument")
			expect_ok(reopened.import_text(doc.export_text().value), "vertex hull round-trip validation")
			checks.check(reopened.export_text().value == doc.export_text().value, "deformed face metadata round-trips exactly")
	var doc = ClassDB.instantiate("TBMapDocument")
	var id: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	var snapshot: Dictionary = doc.snapshot().value
	# Coincident, collinear and interior input points cease being hull corners.
	for destination in [Vector3(0, 64, 64), Vector3(32, 32, 64), Vector3(32, 32, 32)]:
		doc.restore_snapshot(snapshot)
		var b := brush_data(doc, id)
		var index: int = b.vertices.find(Vector3.ONE * 64)
		var expected: PackedVector3Array = b.vertices.duplicate()
		expected[index] = destination
		if expect_ok(doc.translate_vertices(id, PackedInt32Array([index]), destination - Vector3.ONE * 64, b.topology_revision), "corner degeneracy retains valid solid"):
			assert_vertex_hull(doc, id, expected)
			assert_solid(doc, id, 64.0 * 64 * 64 * 5 / 6)
			checks.check(brush_data(doc, id).vertices.size() == 7 and brush_data(doc, id).faces.size() == 7, "redundant corner removed from hull")

func test_phase5() -> void:
	var doc = ClassDB.instantiate("TBMapDocument")
	var id: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	var snapshot: Dictionary = doc.snapshot().value
	var b = brush_data(doc, id)
	var faces = [component(b, "face", 0), component(b, "face", 1), component(b, "face", 0)]
	expect_failure(doc, doc.translate_components(Array(b.faces[0].vertex_indices).map(func(index): return component(b, "vertex", index)), Vector3(64, 0, 0)), state(doc), "INVALID_GEOMETRY", "translate_components")
	expect_ok(doc.translate_components(Array(b.faces[0].vertex_indices).map(func(index): return component(b, "vertex", index)), Vector3(80, 0, 0)), "vertex batch rebuilds changed hull")
	assert_solid(doc, id)
	expect_ok(doc.restore_snapshot(snapshot), "reset vertex hull batch")
	b = brush_data(doc, id)
	faces = [component(b, "face", 0), component(b, "face", 1), component(b, "face", 0)]
	for movement in [Vector3(64, 0, 0), Vector3(80, 0, 0)]:
		expect_failure(doc, doc.translate_components([component(b, "face", 0)], movement), state(doc), "INVALID_GEOMETRY", "translate_components")
	var events = {"map": 0}
	doc.map_changed.connect(func(_r): events.map += 1)
	expect_ok(doc.translate_components(faces, Vector3(128, 0, 0)), "opposite planes batch bypasses invalid intermediate hull")
	checks.check(events.map == 1 and brush_data(doc, id).aabb_min.x == 128 and brush_data(doc, id).aabb_max.x == 192, "batch deduplicates and commits once")
	assert_solid(doc, id, 64 * 64 * 64)
	expect_failure(doc, doc.translate_components(faces, Vector3.ONE), state(doc), "STALE_COMPONENT", "translate_components")
	expect_ok(doc.restore_snapshot(snapshot), "reset batch")
	b = brush_data(doc, id)
	var edge_index = -1
	for i in range(0, b.edge_vertex_indices.size(), 2):
		var p: Vector3 = b.vertices[b.edge_vertex_indices[i]]
		var q: Vector3 = b.vertices[b.edge_vertex_indices[i + 1]]
		if p.x == 64 and q.x == 64 and p.y == 64 and q.y == 64:
			edge_index = i / 2
	checks.check(edge_index >= 0, "find vertical edge by endpoints")
	expect_ok(doc.translate_components([component(b, "edge", edge_index)], Vector3(16, 0, 0)), "valid constrained edge moves both incident vertices")
	assert_solid(doc, id, 72 * 64 * 64)
	expect_ok(doc.restore_snapshot(snapshot), "reset atomic group")
	var second: int = doc.create_cuboid(Vector3(128, 0, 0), Vector3(192, 64, 64), "baseline/checker").value
	b = brush_data(doc, id)
	var second_brush: Dictionary = brush_data(doc, second)
	var collapse_face: Dictionary = second_brush.faces[0]
	var collapse_movement: Vector3 = -collapse_face.normal * 64
	var outward_face: Dictionary = b.faces.filter(func(face): return face.normal.dot(collapse_movement) > 0.5)[0]
	var group = [component(b, "face", outward_face.index)]
	group.append_array(Array(collapse_face.vertex_indices).map(func(index): return component(second_brush, "vertex", index)))
	var before = state(doc)
	var event_count: int = events.map
	expect_failure(doc, doc.translate_components(group, collapse_movement), before, "INVALID_GEOMETRY", "translate_components")
	checks.check(events.map == event_count, "invalid later brush emits no partial group commit")
	group = [component(b, "face", 1), component(brush_data(doc, second), "face", 1)]
	expect_ok(doc.translate_components(group, Vector3(16, 0, 0)), "valid multi-brush face batch")
	checks.check(events.map == event_count + 1 and brush_data(doc, id).aabb_max.x == 80 and brush_data(doc, second).aabb_max.x == 208, "every selected brush deformed in one commit")
	expect_ok(doc.restore_snapshot(snapshot), "reset tetrahedron")
	expect_ok(doc.clip_brushes(PackedInt64Array([id]), Vector3(64, 0, 0), Vector3(0, 0, 64), Vector3(0, 64, 0), false), "construct tetrahedron with clip")
	b = brush_data(doc, id)
	var corner: int = b.vertices.find(Vector3(64, 0, 0))
	checks.check(b.vertices.size() == 4 and corner >= 0, "tetrahedron corner")
	expect_ok(doc.translate_vertices(id, PackedInt32Array([corner]), Vector3(16, 0, 0), b.topology_revision), "valid constrained single vertex deformation")
	assert_solid(doc, id, 80 * 64 * 64 / 6.0)
	# Source face planes, projections, transforms and flags survive clipping.
	for fixture in ["classic_cube", "valve_cube"]:
		expect_ok(doc.load_map("res://fixtures/" + fixture + ".map"), "clip textured fixture")
		var original_lines: PackedStringArray = doc.export_text().value.split("\n")
		b = doc.get_draw_data()[0]
		var source_uvs: Array = []
		for face in b.faces:
			source_uvs.append(doc.get_face_uv(b.id, face.index, b.topology_revision).value)
		var split = doc.clip_brushes(PackedInt64Array([b.id]), Vector3(16, 0, 0), Vector3(16, 0, 1), Vector3(16, 1, 0), true)
		expect_ok(split, "midpoint textured split")
		for line in doc.export_text().value.split("\n"):
			if line.begins_with("("):
				if line.contains("common/caulk"):
					checks.check(line.ends_with('"common/caulk" 0 0 0 1 1'), "cap has no inherited surface flags or projection")
				else:
					checks.check(original_lines.has(line), "surviving source face preserves serialized planes texture UV and flags exactly")
		var normals: Array = []
		for piece_id in split.value:
			assert_solid(doc, piece_id, 32 * 64 * 32)
			var piece = brush_data(doc, piece_id)
			var cap_count = 0
			for face in piece.faces:
				var uv: Dictionary = doc.get_face_uv(piece_id, face.index, piece.topology_revision).value
				if absf(face.center.x - 16) < 0.001 and absf(face.normal.x) > 0.999:
					cap_count += 1
					normals.append(face.normal)
					checks.check(face.texture == "common/caulk" and uv.projection == "classic" and uv.shift == Vector2.ZERO and uv.rotation == 0 and uv.scale == Vector2.ONE, "new caulk cap identity UV even from Valve source")
				else:
					var matched = false
					for source in b.faces:
						if face.normal.is_equal_approx(source.normal) and absf(face.normal.dot(face.center - source.center)) < 0.001:
							matched = true
							checks.check(face.texture == source.texture and uv == source_uvs[source.index], "original plane retains texture and complete UV")
					checks.check(matched, "surviving face retains original plane orientation")
			checks.check(cap_count == 1, "one fresh cap per half")
		checks.check(normals.size() == 2 and normals[0] == -normals[1], "split caps have complementary normals")
	# Half-space boundary outcomes, including coplanar/tangent and near-degenerate.
	expect_ok(doc.restore_snapshot(doc.snapshot().value), "clip snapshot self restore")
	var boundary = ClassDB.instantiate("TBMapDocument")
	id = boundary.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	snapshot = boundary.snapshot().value
	for x in [-16.0, 0.0, 64.0, 80.0, 64.000001]:
		for split in [false, true]:
			for flipped in [false, true]:
				expect_ok(boundary.restore_snapshot(snapshot), "reset clip boundary")
				var p = Vector3(x, 0, 0)
				var q = p + Vector3(0, 0, 1)
				var r = p + Vector3(0, 1, 0)
				before = state(boundary)
				var result = boundary.clip_brushes(PackedInt64Array([id]), p, r if flipped else q, q if flipped else r, split)
				expect_ok(result, "clip boundary %s split %s flip %s" % [x, split, flipped])
				var kept: bool = split or (x <= 0 if flipped else x >= 64)
				checks.check(result.value.size() == int(kept), "boundary keeps/discards expected solid")
				if kept:
					checks.check(state(boundary) == before and not result.changed, "coplanar/tangent/entirely retained is exact no-op")
	expect_ok(boundary.restore_snapshot(snapshot), "reset near-degenerate plane")
	expect_failure(boundary, boundary.clip_brushes(PackedInt64Array([id]), Vector3.ZERO, Vector3(0, 0, 0.000001), Vector3(0, 0.000001, 0), true), state(boundary), "INVALID_ARGUMENT", "clip_brushes")
	var right: int = boundary.create_cuboid(Vector3(128, 0, 0), Vector3(192, 64, 64), "baseline/checker").value
	var left: int = boundary.create_cuboid(Vector3(-128, 0, 0), Vector3(-64, 64, 64), "baseline/checker").value
	snapshot = boundary.snapshot().value
	for split in [true, false]:
		expect_ok(boundary.restore_snapshot(snapshot), "reset multi-brush clip")
		var result = boundary.clip_brushes(PackedInt64Array([id, right, left, id]), Vector3(32, 0, 0), Vector3(32, 0, 1), Vector3(32, 1, 0), split)
		expect_ok(result, "multi-brush clipping crosses retains and discards")
		checks.check(result.value.size() == (4 if split else 2) and result.value.has(left) and result.value.has(right) == split, "multi-brush clip deduplicates and keeps expected owners")
		for piece_id in result.value:
			assert_solid(boundary, piece_id, 64 * 64 * 64 if piece_id in [left, right] else 32 * 64 * 64)

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
	checks.check(doc.is_dirty() and doc.snapshot().value.identities == saved.identities, "entity snapshot inverse keeps identities but receives a distinct dirty generation")
	expect_ok(doc.load_map("res://fixtures/patches.map"), "patch preservation fixture")
	var patch_state = doc.snapshot().value
	var cube = doc.create_cuboid(Vector3.ZERO, Vector3(16, 16, 16), "baseline/checker")
	expect_ok(cube, "create brush alongside patches")
	expect_ok(doc.translate_brushes(PackedInt64Array([cube.value]), Vector3.ONE), "edit brush alongside patches")
	expect_ok(doc.delete_brushes(PackedInt64Array([cube.value])), "delete brush alongside patches")
	checks.check(doc.export_text().value == patch_state.text and doc.snapshot().value.identities == patch_state.identities, "brush edits retain exact patch text order and handles")
	expect_failure(doc, doc.import_selection(patch_state.text), state(doc), "UNSUPPORTED_SYNTAX", "import_selection")
	expect_failure(doc, doc.delete_entities(PackedInt64Array([doc.get_entities()[0].id]), true), state(doc), "INVALID_ARGUMENT", "delete_entities")
