extends SceneTree
## One displayed renderer measurement process. The Python runner enforces the
## engine pin and stages an isolated project before this script is loaded.

var failed := false
var report := {}

func require(condition: bool, message: String) -> bool:
	if not condition:
		failed = true
		push_error("TB_WORLDSPAWN_RENDER_BENCH_FAIL: " + message)
	return condition

func vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))

func memory() -> Dictionary:
	var result := {"godot_static_bytes": OS.get_static_memory_usage(), "godot_static_peak_bytes": OS.get_static_memory_peak_usage()}
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if status != null:
		while not status.eof_reached():
			var line := status.get_line()
			for key in ["VmRSS", "VmHWM"]:
				if line.begins_with(key + ":"):
					result[key + "_bytes"] = int(line.split(":")[1].strip_edges().split(" ", false)[0]) * 1024
		status.close()
	return result

func count_scene(node: Node) -> Dictionary:
	var result := {"nodes": 1, "mesh_instances": int(node is MeshInstance3D), "material_surfaces": 0}
	if node is MeshInstance3D and node.mesh != null:
		result.material_surfaces = node.mesh.get_surface_count()
	for child in node.get_children():
		var child_count := count_scene(child)
		for key in result:
			result[key] += child_count[key]
	return result

func add_occluder(scene: Node3D, specification: Dictionary) -> OccluderInstance3D:
	var instance := OccluderInstance3D.new()
	var resource := BoxOccluder3D.new()
	resource.size = vector(specification.size)
	instance.occluder = resource
	instance.position = vector(specification.position)
	scene.add_child(instance)
	return instance

func sample_view(camera: Camera3D, specification: Dictionary, warmup: int, samples: int) -> Dictionary:
	camera.position = vector(specification.position)
	var direction := vector(specification.target) - camera.position
	var up := Vector3.FORWARD if abs(direction.normalized().dot(Vector3.UP)) > 0.999 else Vector3.UP
	camera.look_at(camera.position + direction, up)
	for _index in warmup:
		await process_frame
	var values := {"frame_ms": [], "process_cpu_ms": [], "render_cpu_ms": [], "render_gpu_ms": [],
		"draw_calls": [], "rendered_objects": [], "rendered_primitives": [], "video_memory_bytes": []}
	var viewport_rid := get_root().get_viewport_rid()
	var previous := Time.get_ticks_usec()
	for _index in samples:
		await process_frame
		var now := Time.get_ticks_usec()
		values.frame_ms.append((now - previous) / 1000.0)
		previous = now
		values.process_cpu_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		values.render_cpu_ms.append(RenderingServer.get_frame_setup_time_cpu() + RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid))
		values.render_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
		values.draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		values.rendered_objects.append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		values.rendered_primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		values.video_memory_bytes.append(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	return {"samples": values, "memory": memory()}

func verify_occluder_effect(camera: Camera3D, occluder: OccluderInstance3D, specification: Dictionary) -> Dictionary:
	camera.position = vector(specification.position)
	var direction := (vector(specification.target) - camera.position).normalized()
	camera.look_at(camera.position + direction, Vector3.UP)
	camera.cull_mask = 1
	var probe := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	probe.mesh = mesh
	probe.layers = 1
	probe.position = occluder.position + direction * 4.0
	current_scene.add_child(probe)
	var measurements := {}
	for state in ["hidden", "visible"]:
		occluder.visible = state == "visible"
		for _index in 20:
			await process_frame
		var objects: Array = []
		var primitives: Array = []
		for _index in 20:
			await process_frame
			objects.append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
			primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		objects.sort()
		primitives.sort()
		measurements[state] = {"rendered_objects_median": objects[objects.size() >> 1],
			"rendered_primitives_median": primitives[primitives.size() >> 1]}
	occluder.visible = true
	camera.cull_mask = 0xffffffff
	probe.queue_free()
	await process_frame
	measurements["effect_observed"] = measurements.hidden.rendered_objects_median > measurements.visible.rendered_objects_median \
		and measurements.hidden.rendered_primitives_median > measurements.visible.rendered_primitives_median
	return measurements

func finish(code: int) -> void:
	if not failed:
		var output := FileAccess.open("res://worldspawn-render-result.json", FileAccess.WRITE)
		if require(output != null, "result file opens"):
			output.store_string(JSON.stringify(report, "\t") + "\n")
			output.close()
	if not failed:
		print("TB_WORLDSPAWN_RENDER_BENCH_COMPLETE:PASS")
	quit(1 if failed else code)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var fixture_name := OS.get_environment("TB_BENCH_FIXTURE")
	var profile_name := OS.get_environment("TB_BENCH_PROFILE")
	var samples := int(OS.get_environment("TB_BENCH_SAMPLES"))
	var warmup := int(OS.get_environment("TB_BENCH_WARMUP"))
	var bake_samples := int(OS.get_environment("TB_BENCH_BAKE_SAMPLES"))
	if not require(DisplayServer.get_name().to_lower() != "headless", "a real displayed rendering context is required"):
		finish(1)
		return
	var adapter := RenderingServer.get_video_adapter_name()
	if not require(not adapter.is_empty(), "renderer video adapter identity is available"):
		finish(1)
		return
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://fixtures/manifest.json"))
	if not require(manifest.get("schema") == 1 and manifest.fixtures.has(fixture_name), "fixture manifest and selection are valid"):
		finish(1)
		return
	var fixture: Dictionary = manifest.fixtures[fixture_name]
	var profile: Dictionary = JSON.parse_string(OS.get_environment("TB_BENCH_PROFILE_JSON"))
	if not require(profile is Dictionary and samples > 0 and warmup >= 0 and bake_samples > 0, "profile and sample counts are valid"):
		finish(1)
		return

	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for _index in 3:
		await process_frame
	var controls := {
		"requested_max_fps": 0,
		"effective_max_fps": Engine.max_fps,
		"project_vsync_mode": int(ProjectSettings.get_setting("display/window/vsync/vsync_mode", -1)),
		"requested_vsync_mode": DisplayServer.VSYNC_DISABLED,
		"effective_vsync_mode": DisplayServer.window_get_vsync_mode(),
		"screen_refresh_hz": DisplayServer.screen_get_refresh_rate(),
		"project_occlusion_culling": bool(ProjectSettings.get_setting("rendering/occlusion_culling/use_occlusion_culling", false)),
	}
	if not require(controls.effective_max_fps == 0 and controls.project_vsync_mode == DisplayServer.VSYNC_DISABLED
			and controls.effective_vsync_mode == DisplayServer.VSYNC_DISABLED,
			"project and runtime VSync are disabled and max FPS is unlimited"):
		finish(1)
		return
	if not require(controls.project_occlusion_culling and get_root().use_occlusion_culling,
			"project occlusion culling enabled the root viewport at startup"):
		finish(1)
		return
	var scene := Node3D.new()
	scene.name = "WorldspawnBenchmark"
	get_root().add_child(scene)
	current_scene = scene
	var loader := TBLoader.new()
	loader.name = "TBLoader"
	loader.map_resource = "res://fixtures/" + fixture.map
	loader.map_inverse_scale = 1
	loader.option_collision = false
	loader.lighting_unwrap_uv2 = false
	loader.worldspawn_chunking_enabled = profile.enabled
	loader.worldspawn_chunk_size = profile.extent
	loader.worldspawn_chunk_triangles = profile.get("triangles", 1000000000)
	loader.worldspawn_max_chunks = profile.max_chunks
	scene.add_child(loader)
	loader.owner = scene
	var bake_ms: Array = []
	var partition_ms: Array = []
	var build_result := {}
	for index in bake_samples + 1:
		var started := Time.get_ticks_usec()
		build_result = loader.build_meshes_checked()
		var elapsed := (Time.get_ticks_usec() - started) / 1000.0
		if not require(build_result.get("ok", false), "worldspawn build succeeds"):
			finish(1)
			return
		if index > 0:
			bake_ms.append(elapsed)
			partition_ms.append(build_result.value.metrics.partition_duration_ms)
	var metrics: Dictionary = build_result.value.metrics
	if not require(metrics.visual_triangle_count == fixture.expected_triangles, "all fixture triangles are conserved"):
		finish(1)
		return

	var packed := PackedScene.new()
	if not require(packed.pack(scene) == OK, "generated scene packs"):
		finish(1)
		return
	var packed_path := "res://packed-%s-%s.scn" % [fixture_name, profile_name]
	if not require(ResourceSaver.save(packed, packed_path) == OK, "generated scene saves"):
		finish(1)
		return
	var generated_counts := count_scene(loader)
	var occluder := add_occluder(scene, fixture.cameras.occluder)
	var camera := Camera3D.new()
	camera.fov = 75.0
	camera.far = 1000.0
	scene.add_child(camera)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -25, 0)
	light.shadow_enabled = false
	scene.add_child(light)
	RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)
	for _index in 3:
		await process_frame
	controls["root_viewport_occlusion_culling"] = get_root().use_occlusion_culling
	controls["occluder_inside_tree"] = occluder.is_inside_tree()
	controls["occluder_visible"] = occluder.is_visible_in_tree()
	controls["occluder_resource_class"] = occluder.occluder.get_class() if occluder.occluder != null else ""
	controls["occluder_position"] = occluder.position
	controls["occluder_size"] = occluder.occluder.size if occluder.occluder is BoxOccluder3D else Vector3.ZERO
	controls["occluded_gate_context_valid"] = controls.project_occlusion_culling \
		and controls.root_viewport_occlusion_culling and controls.occluder_inside_tree \
		and controls.occluder_visible and controls.occluder_resource_class == "BoxOccluder3D" \
		and controls.occluder_size == vector(fixture.cameras.occluder.size)
	if not require(controls.occluded_gate_context_valid, "the fixed box occluder is active in the measured root viewport"):
		finish(1)
		return
	controls["occlusion_effect_probe"] = await verify_occluder_effect(camera, occluder, fixture.cameras.heavily_occluded)
	controls["occluded_gate_context_valid"] = controls.occluded_gate_context_valid \
		and controls.occlusion_effect_probe.effect_observed
	if not require(controls.occluded_gate_context_valid, "the fixed box occluder rejects an isolated object behind it"):
		finish(1)
		return
	report = {"schema": 1, "fixture": fixture_name, "fixture_sha256": fixture.sha256,
		"profile": profile_name, "profile_settings": profile, "engine": Engine.get_version_info(),
		"display_driver": DisplayServer.get_name(), "rendering_method": RenderingServer.get_current_rendering_method(),
		"renderer": {"adapter": adapter, "vendor": RenderingServer.get_video_adapter_vendor(),
			"api_version": RenderingServer.get_video_adapter_api_version(), "driver": OS.get_video_adapter_driver_info()},
		"controls": controls,
		"resolution": [get_root().size.x, get_root().size.y], "warmup_frames": warmup, "sample_frames": samples,
		"bake_samples": {"total_ms": bake_ms, "partition_ms": partition_ms}, "build_metrics": metrics,
		"generated_counts": generated_counts, "packed_scene_size_bytes": FileAccess.get_file_as_bytes(packed_path).size(),
		"views": {}, "timing_units": "milliseconds"}
	for view_name in ["fully_visible", "frustum_limited", "heavily_occluded"]:
		report.views[view_name] = await sample_view(camera, fixture.cameras[view_name], warmup, samples)
	finish(0)
