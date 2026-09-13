extends RefCounted

var failures: int = 0
var assertions: int = 0

func check(condition: bool, message: String) -> bool:
	assertions += 1
	if not condition:
		failures += 1
		printerr("TB_TEST_ASSERTION_FAILED: " + message)
	return condition

func finish(tree: SceneTree, suite: String) -> void:
	print("TB_TEST_COUNTS:%s:%d:%d" % [suite, assertions, failures])
	print("TB_TEST_COMPLETE:%s:%s" % [suite, "PASS" if failures == 0 else "FAIL"])
	tree.quit(0 if failures == 0 else 1)
