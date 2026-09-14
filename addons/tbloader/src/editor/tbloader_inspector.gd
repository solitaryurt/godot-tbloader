@tool
extends EditorInspectorPlugin

var plugin_ref: WeakRef

func _init(plugin: EditorPlugin) -> void:
	plugin_ref = weakref(plugin)

func _can_handle(object: Object) -> bool:
	return object is TBLoader

func _parse_begin(object: Object) -> void:
	var loader_ref := weakref(object)
	var open_button := Button.new()
	open_button.name = "OpenRadiantEditor"
	open_button.text = "Open Radiant Editor"
	open_button.tooltip_text = "Open this TBLoader in the Radiant map editor"
	open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_button.pressed.connect(func():
		var plugin = plugin_ref.get_ref()
		var loader = loader_ref.get_ref()
		if is_instance_valid(plugin) and is_instance_valid(loader):
			plugin.open_in_map_editor(loader))
	add_custom_control(open_button)
