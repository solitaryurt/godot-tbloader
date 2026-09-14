extends SceneTree

func measured(operation: Callable) -> Dictionary:
	var started := Time.get_ticks_usec()
	var value = operation.call()
	return {"us": Time.get_ticks_usec() - started, "value": value}

func _initialize() -> void:
	var path = OS.get_environment("TB_REAL_MAP")
	if path.is_empty():
		push_error("TB_REAL_MAP is required")
		quit(2)
		return
	var extension_status := GDExtensionManager.load_extension("res://addons/tbloader/tbloader.gdextension")
	if extension_status != GDExtensionManager.LOAD_STATUS_OK:
		push_error("Extension failed to load: %s" % extension_status)
		quit(3)
		return
	var document = ClassDB.instantiate("TBMapDocument")
	var timings := {}
	var started := Time.get_ticks_usec()
	var loaded: Dictionary = document.load_map(path)
	timings.load = Time.get_ticks_usec() - started
	if not loaded.ok:
		push_error("Real map failed to load: %s" % loaded.error)
		quit(4)
		return
	var before_measure := measured(func(): return document.snapshot())
	var before: Dictionary = before_measure.value
	timings.snapshot_before = before_measure.us
	var history_before_measure := measured(func(): return document.capture_history_state())
	var history_before = history_before_measure.value
	timings.history_capture_before = history_before_measure.us
	var create_measure := measured(func(): return document.create_cuboid(Vector3(-64, -64, -64), Vector3(64, 64, 64), "common/caulk"))
	var result: Dictionary = create_measure.value
	timings.create = create_measure.us
	if not result.ok:
		push_error("Real map edit failed: %s" % result.error)
		quit(5)
		return
	var after_measure := measured(func(): return document.snapshot())
	var after: Dictionary = after_measure.value
	timings.snapshot_after = after_measure.us
	var history_after_measure := measured(func(): return document.capture_history_state())
	var history_after = history_after_measure.value
	timings.history_capture_after = history_after_measure.us
	var encode_measure := measured(func(): return var_to_bytes(before.value).size() + var_to_bytes(after.value).size())
	timings.snapshot_encode = encode_measure.us
	timings.snapshot_bytes = encode_measure.value
	var draw_measure := measured(func(): return document.get_draw_data())
	timings.draw = draw_measure.us
	var preview_measure := measured(func(): return document.get_preview_data())
	# Explicit compatibility API measurement; production camera uses native chunks.
	timings.preview = preview_measure.us
	var undo_measure := measured(func(): return document.restore_history_state(history_before))
	timings.undo = undo_measure.us
	if not undo_measure.value.ok or document.export_text().value != before.value.text or document.snapshot().value.identities != before.value.identities:
		push_error("Real map undo was not exact")
		quit(6)
		return
	var redo_measure := measured(func(): return document.restore_history_state(history_after))
	timings.redo = redo_measure.us
	if not redo_measure.value.ok or document.export_text().value != after.value.text or document.snapshot().value.identities != after.value.identities:
		push_error("Real map redo was not exact")
		quit(7)
		return
	var cut_before = document.capture_history_state()
	var cut_measure := measured(func(): return document.clip_brushes(PackedInt64Array([result.value]), Vector3(0, -128, -128), Vector3(0, 128, -128), Vector3(0, -128, 128), false))
	timings.cut = cut_measure.us
	if not cut_measure.value.ok or not cut_measure.value.changed:
		push_error("Real map cut failed: %s" % cut_measure.value)
		quit(8)
		return
	var cut_after = document.capture_history_state()
	var cut_text: String = document.export_text().value
	var cut_undo_measure := measured(func(): return document.restore_history_state(cut_before))
	timings.cut_undo = cut_undo_measure.us
	var cut_redo_measure := measured(func(): return document.restore_history_state(cut_after))
	timings.cut_redo = cut_redo_measure.us
	if not cut_undo_measure.value.ok or not cut_redo_measure.value.ok or document.export_text().value != cut_text:
		push_error("Real map cut undo/redo was not exact")
		quit(9)
		return
	print("TB_REAL_MAP_TIMINGS:" + JSON.stringify(timings))
	print("TB_REAL_MAP_PASS:%s" % path)
	quit(0)
