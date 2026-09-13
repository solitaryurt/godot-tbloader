@tool
extends RefCounted

# The manager retains this lightweight token, never an active-editor callback.
var session: RefCounted
var before: Dictionary
var after: Dictionary
var epoch: int
var bytes: int
var reporter: Callable

func restore(use_after: bool) -> void:
	if session == null or session.document.get_epoch() != epoch:
		retire()
		if reporter.is_valid():
			reporter.call("Map history expired; the originating session is no longer retained.")
		return
	session.restore(after if use_after else before)

func retire() -> void:
	session = null
	before.clear()
	after.clear()
	bytes = 0
