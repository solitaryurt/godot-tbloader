@tool
extends RefCounted

# Scene history owns packed generated-child snapshots. Native bake replaces all
# children, so the UI must capture them before invoking the checked operation.
var loader: WeakRef
var scene: WeakRef
var session: WeakRef
var before: PackedScene
var after: PackedScene
var before_text = ""
var after_text = ""
var reporter: Callable

static func capture(target: Node) -> PackedScene:
	var holder = Node3D.new()
	holder.name = "BakeSnapshot"
	for child in target.get_children():
		var copy = child.duplicate()
		if copy == null:
			holder.free()
			return null
		holder.add_child(copy)
		pack_owners(copy, holder)
	var packed = PackedScene.new()
	var result = packed.pack(holder)
	holder.free()
	return packed if result == OK else null

static func pack_owners(node: Node, root: Node) -> void:
	# Preserve owners within instantiated subscenes, assign external/missing owners
	# to the snapshot root so every child replaced by native bake is retained.
	if node.owner == null or not root.is_ancestor_of(node.owner):
		node.owner = root
	for child in node.get_children():
		pack_owners(child, root)

static func restore_owners(node: Node, holder: Node, root: Node) -> void:
	if node.owner == holder or node.owner == null:
		node.owner = root
	for child in node.get_children():
		restore_owners(child, holder, root)

static func clear_snapshot_owners(node: Node, holder: Node) -> void:
	if node.owner == holder:
		node.owner = null
	for child in node.get_children():
		clear_snapshot_owners(child, holder)

func restore(use_after: bool) -> void:
	var target = loader.get_ref()
	var root = scene.get_ref()
	if not is_instance_valid(target) or root == null or root != EditorInterface.get_edited_scene_root() or (target != root and not root.is_ancestor_of(target)):
		if reporter.is_valid():
			reporter.call("Bake history target is no longer in the current scene.")
		return
	var packed = after if use_after else before
	var holder = packed.instantiate()
	for child in target.get_children():
		target.remove_child(child)
		child.queue_free()
	for child in holder.get_children():
		clear_snapshot_owners(child, holder)
		holder.remove_child(child)
		target.add_child(child)
		restore_owners(child, holder, root)
	holder.free()
	var origin = session.get_ref()
	if origin != null:
		origin.baked_text = after_text if use_after else before_text
		origin.changed.emit()
	EditorInterface.mark_scene_as_unsaved()
