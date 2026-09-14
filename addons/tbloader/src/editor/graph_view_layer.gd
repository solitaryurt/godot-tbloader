@tool
extends Control

var graph: Control
var layer_kind := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	if is_instance_valid(graph):
		graph.draw_layer(self, layer_kind)
