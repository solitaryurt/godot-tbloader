@tool
extends RefCounted

# Scene history owns the subtree which is not currently live. Undo/redo swaps it
# with the loader children, retaining one detached tree and no packed duplicates.
var loader: WeakRef
var scene: WeakRef
var session: WeakRef
var detached: Node
var live_is_after := true
var before_text = ""
var after_text = ""
var reporter: Callable

static func detach_children(target: Node) -> Node:
	var holder = Node3D.new()
	holder.name = "BakeHistory"
	for child in target.get_children():
		target.remove_child(child)
		holder.add_child(child)
	return holder

static func restore_owners(node: Node, holder: Node, root: Node) -> void:
	if node.owner == holder or node.owner == null:
		node.owner = root
	for child in node.get_children():
		restore_owners(child, holder, root)

static func attach_children(target: Node, holder: Node, root: Node) -> void:
	for child in holder.get_children():
		holder.remove_child(child)
		target.add_child(child)
		restore_owners(child, holder, root)

func get_retention_counters() -> Dictionary:
	return {
		"packed_snapshot_count": 0,
		"detached_root_count": detached.get_child_count() if is_instance_valid(detached) else 0,
		"live_is_after": live_is_after,
	}

func restore(use_after: bool) -> void:
	var target = loader.get_ref()
	var root = scene.get_ref()
	if not is_instance_valid(target) or root == null or root != EditorInterface.get_edited_scene_root() or (target != root and not root.is_ancestor_of(target)):
		if reporter.is_valid():
			reporter.call("Bake history target is no longer in the current scene.")
		return
	if use_after == live_is_after:
		return
	var outgoing := detach_children(target)
	attach_children(target, detached, root)
	detached.free()
	detached = outgoing
	live_is_after = use_after
	var origin = session.get_ref()
	if origin != null:
		origin.baked_text = after_text if use_after else before_text
		origin.changed.emit()
	EditorInterface.mark_scene_as_unsaved()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(detached):
		detached.free()
		detached = null
