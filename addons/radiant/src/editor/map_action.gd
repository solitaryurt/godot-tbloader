@tool
extends RefCounted

# MapSession retains this lightweight event metadata; native/UI states live once
# in the session timeline. The legacy snapshot fields support direct callers only.
var session: RefCounted
var before: Dictionary
var after: Dictionary
var before_ui: Dictionary
var after_ui: Dictionary
var change: RefCounted
var epoch: int
var before_generation: int
var after_generation: int
var bytes: int
var reporter: Callable
var label := ""
var sequence := 0
var before_state_id := 0
var after_state_id := 0

func restore(use_after: bool) -> void:
	if before.is_empty() and after.is_empty() and change == null:
		if session != null:
			session.history_navigate_state(after_state_id if use_after else before_state_id)
		return
	var expected_generation := before_generation if use_after else after_generation
	if session == null or session.document.get_epoch() != epoch or session.document.get_state_generation() != expected_generation:
		var report_callback := reporter
		retire()
		if report_callback.is_valid():
			report_callback.call("Map history expired or is out of order; the originating state is no longer current.")
		return
	if change != null:
		session.restore_document_change(change, use_after, after_ui if use_after else before_ui)
	else:
		session.restore(after if use_after else before)

func retire() -> void:
	# EditorUndoRedoManager cannot remove one expired global entry. Its cursor may
	# still visit this payload-free token, which deliberately remains a safe no-op.
	session = null
	before.clear()
	after.clear()
	before_ui.clear()
	after_ui.clear()
	change = null
	bytes = 0
