@tool
extends Control

var graph: Control
var layer_kind := ""
var buffer_index := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	if is_instance_valid(graph):
		if layer_kind == "DenseEdges":
			graph.draw_dense_edge_buffer(self, buffer_index)
		else:
			graph.draw_layer(self, layer_kind)
