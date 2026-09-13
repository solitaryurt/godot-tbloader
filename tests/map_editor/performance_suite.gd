extends SceneTree
## Native API wall time, not editor input-to-presentation latency.

const MARKER = "TB_PERF_COMPLETE:PASS"
var failed = false

func _initialize() -> void:
	call_deferred("run")

func require(condition: bool, message: String) -> bool:
	if not condition:
		failed = true
		push_error("TB_PERF_FAIL: " + message)
	return condition

func checked(result: Dictionary, operation: String) -> bool:
	if result.has_all(["ok", "changed", "value", "error"]) and result.ok and result.error.is_empty():
		return true
	return require(false, operation + ": " + str(result))

func memory() -> Dictionary:
	# Godot counters exclude some native malloc allocations; Linux RSS includes them.
	var result = {"godot_static_bytes": OS.get_static_memory_usage(), "godot_static_peak_bytes": OS.get_static_memory_peak_usage()}
	# procfs advertises length zero; read lines rather than get_file_as_string().
	var status = FileAccess.open("/proc/self/status", FileAccess.READ)
	if not require(status != null, "Linux status file opens"):
		return result
	while not status.eof_reached():
		var line = status.get_line()
		for key in ["VmRSS", "VmHWM"]:
			if line.begins_with(key + ":"):
				result[key + "_bytes"] = int(line.split(":")[1].strip_edges().split(" ", false)[0]) * 1024
	status.close()
	require(result.has_all(["VmRSS_bytes", "VmHWM_bytes"]), "Linux process memory counters available")
	return result

func measure(operation: Callable, warmups: int, samples: int, is_result: bool = true) -> Array:
	var durations: Array = []
	for i in range(warmups + samples):
		# Retain returned value through the end timestamp. Validation, destruction,
		# logging, sample storage and fixture generation are outside the interval.
		var started = Time.get_ticks_usec()
		var value = operation.call()
		var elapsed = Time.get_ticks_usec() - started
		if is_result and not checked(value, "measured operation"):
			return []
		if i >= warmups:
			durations.append(elapsed)
		# Explicit release avoids charging a previous return's destruction to the
		# next sample if the VM reuses this local's stack slot across iterations.
		value = null
	return durations

func translated(doc, ids: PackedInt64Array, direction: Dictionary) -> Dictionary:
	var result: Dictionary = doc.translate_brushes(ids, Vector3(16 * direction.sign, 0, 0))
	direction.sign = -direction.sign
	return result

func run() -> void:
	# No texture assets are needed. Load the staged real extension explicitly,
	# avoiding an editor/import process and its unrelated lifecycle behavior.
	var extension_status = GDExtensionManager.load_extension("res://addons/tbloader/tbloader.gdextension")
	if not require(extension_status == GDExtensionManager.LOAD_STATUS_OK, "real staged extension loads"):
		quit(1)
		return
	var probe = OS.get_environment("TB_PERF_PROBE")
	if probe == "timeout":
		return
	if probe == "missing-marker":
		quit(0)
		return
	if probe == "engine-error":
		push_error("TB_PERF_FAIL: deliberate engine error with success marker")
		print(MARKER)
		quit(0)
		return
	if not require(ClassDB.class_exists("TBMapDocument"), "real native document is registered"):
		quit(1)
		return
	var count = int(OS.get_environment("TB_PERF_BRUSHES"))
	var samples = int(OS.get_environment("TB_PERF_SAMPLES"))
	var warmups = int(OS.get_environment("TB_PERF_WARMUPS"))
	var text = FileAccess.get_file_as_string("res://blockout-%d.map" % count)
	var expected = JSON.parse_string(FileAccess.get_file_as_string("res://blockout-%d.json" % count))
	if not require(count > 0 and samples > 0 and warmups >= 0 and not text.is_empty() and expected is Dictionary, "valid benchmark configuration"):
		quit(1)
		return
	var mem = {"before_document": memory()}
	var doc = ClassDB.instantiate("TBMapDocument")
	var started = Time.get_ticks_usec()
	var imported: Dictionary = doc.import_text(text)
	var first_import_us = Time.get_ticks_usec() - started
	if not checked(imported, "first bulk import"):
		quit(1)
		return
	mem.after_import = memory()
	var draw: Array = doc.get_draw_data()
	var ids = PackedInt64Array()
	var face_count = 0
	require(draw.size() == count and doc.get_entities().size() == 1, "one worldspawn and expected brush count")
	for i in draw.size():
		var brush: Dictionary = draw[i]
		ids.append(brush.id)
		face_count += brush.faces.size()
		require(brush.faces.size() == 6 and brush.vertices.size() == 8, "cuboid topology")
		var bounds: Array = expected.bounds[i]
		require(brush.aabb_min == Vector3(bounds[0], bounds[1], bounds[2]) and brush.aabb_max == Vector3(bounds[3], bounds[4], bounds[5]), "deterministic brush bounds")
	var triangles = 0
	for surface in doc.get_preview_data():
		triangles += surface.indices.size() / 3
	require(face_count == count * 6 and triangles == count * 12, "face and triangle counts")
	var original: String = doc.export_text().value
	draw.clear()
	var operations = {}
	operations.rebuild = measure(func(): return doc.rebuild(), warmups, samples)
	operations.snapshot = measure(func(): return doc.snapshot(), warmups, samples)
	operations.export_text = measure(func(): return doc.export_text(), warmups, samples)
	operations.get_draw_data = measure(func(): return doc.get_draw_data(), warmups, samples, false)
	operations.get_preview_data = measure(func(): return doc.get_preview_data(), warmups, samples, false)
	for selection in ["one", "all"]:
		var selected = PackedInt64Array([ids[0]]) if selection == "one" else ids
		var direction = {"sign": 1}
		var revision: int = doc.get_revision()
		operations["translate_" + selection] = measure(func(): return translated(doc, selected, direction), warmups, samples)
		require(doc.get_revision() == revision + warmups + samples, "every measured translation commits a non-noop change")
		if direction.sign == -1:
			checked(translated(doc, selected, direction), "untimed inverse translation")
		require(doc.export_text().value == original, "inverse translation restores exact canonical map")
	mem.after_operations = memory()
	# Separate document keeps the measured translation IDs stable. Repeated import
	# includes replacement costs and runs only after the main document measurements.
	var import_doc = ClassDB.instantiate("TBMapDocument")
	operations.import_text = measure(func(): return import_doc.import_text(text), warmups, samples)
	require(import_doc.export_text().value == original, "bulk import canonical agreement")
	import_doc = null
	# Estimate retained undo payload separately; this is Godot Variant encoding,
	# not heap size or an editor history-limit measurement.
	var saved: Dictionary = doc.snapshot().value
	var snapshot_bytes = var_to_bytes(saved).size()
	var canonical_bytes = original.to_utf8_buffer().size()
	saved.clear()
	doc = null
	mem.after_document_release = memory()
	var report = {
		"schema": 1, "scope": "native_document_headless", "brushes": count,
		"faces": face_count, "triangles": triangles, "entities": 1,
		"samples": samples, "warmups": warmups, "clock": "Time.get_ticks_usec (monotonic)",
		"first_import_us": first_import_us, "operations_us": operations,
		"map_sha256": text.sha256_text(), "canonical_sha256": original.sha256_text(),
		"map_bytes": text.to_utf8_buffer().size(), "canonical_bytes": canonical_bytes,
		"snapshot_variant_bytes": snapshot_bytes, "memory": mem,
		"engine": Engine.get_version_info(), "processor": OS.get_processor_name(),
		"logical_processors": OS.get_processor_count(), "debug_build": OS.is_debug_build(),
		"display_driver": DisplayServer.get_name(),
	}
	var file = FileAccess.open("res://performance-result.json", FileAccess.WRITE)
	if require(file != null, "result output opens"):
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	if not failed:
		print("TB_PERF_COUNTS:%d:%d:%d" % [count, face_count, triangles])
		print(MARKER)
	quit(1 if failed else 0)
