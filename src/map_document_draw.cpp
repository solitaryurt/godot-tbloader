#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include "map/brush_topology.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <cmath>
#include <map>
#include <vector>

using namespace godot;
namespace {
Vector3 vector(vec3 v) { return Vector3(v.x, v.y, v.z); }
}

Array TBMapDocument::get_draw_data() const {
	Array out;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto view = current_brush_geometry(e, b); const auto &brush = *view.brush;
		Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices;
		vec3 mins{}, maxs{};
		if (view.compact) {
			const auto &geometry = *view.compact;
			for (const auto &point : geometry.positions) vertices.push_back(vector(point));
			for (const auto &edge : geometry.edges) {
				edge_indices.push_back(edge.a); edge_indices.push_back(edge.b);
				edges.push_back(vector(geometry.positions[edge.a])); edges.push_back(vector(geometry.positions[edge.b]));
			}
			for (int f = 0; f < brush.face_count; ++f) {
				const auto &face = geometry.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices;
				for (uint32_t v = 0; v < face.corner_count; ++v) {
					const auto &corner = geometry.corners[face.corner_begin + v]; winding.push_back(vector(geometry.positions[corner.position])); indices.push_back(corner.position);
				}
				data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices;
				data["center"] = vector(face.center); data["normal"] = vector(brush.faces[f].plane_normal);
				data["texture"] = String::utf8(current_face_texture(e, b, f).c_str()); faces.push_back(data);
			}
			mins = geometry.mins; maxs = geometry.maxs;
		}
		entry["id"] = brush.id; entry["entity_id"] = map->entities[e].id; entry["topology_revision"] = brush.topology_revision;
		entry["aabb_min"] = vector(mins); entry["aabb_max"] = vector(maxs); entry["vertices"] = vertices; entry["edges"] = edges;
		entry["edge_vertex_indices"] = edge_indices; entry["faces"] = faces; out.push_back(entry);
	}
	return out;
}

Dictionary TBMapDocument::get_draw_changes() const {
	Dictionary out = get_last_change();
	Array brushes;
	if (!last_change.reset) for (int64_t id : last_change.brush_ids) {
		const LiveLocation *location = live_location(id, 'b');
		if (!location) continue;
		const auto view = current_brush_geometry(location->entity, location->index); const auto &brush = *view.brush;
		Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices; vec3 mins{}, maxs{};
		if (view.compact) {
			const auto &geometry = *view.compact;
			for (const auto &point : geometry.positions) vertices.push_back(vector(point));
			for (const auto &edge : geometry.edges) { edge_indices.push_back(edge.a); edge_indices.push_back(edge.b); edges.push_back(vector(geometry.positions[edge.a])); edges.push_back(vector(geometry.positions[edge.b])); }
			for (int f = 0; f < brush.face_count; ++f) {
				const auto &face = geometry.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices;
				for (uint32_t v = 0; v < face.corner_count; ++v) { const auto &corner = geometry.corners[face.corner_begin + v]; winding.push_back(vector(geometry.positions[corner.position])); indices.push_back(corner.position); }
				data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices; data["center"] = vector(face.center); data["normal"] = vector(brush.faces[f].plane_normal); data["texture"] = String::utf8(current_face_texture(location->entity, location->index, f).c_str()); faces.push_back(data);
			}
			mins = geometry.mins; maxs = geometry.maxs;
		}
		entry["id"] = brush.id; entry["entity_id"] = map->entities[location->entity].id; entry["topology_revision"] = brush.topology_revision;
		entry["aabb_min"] = vector(mins); entry["aabb_max"] = vector(maxs); entry["vertices"] = vertices; entry["edges"] = edges; entry["edge_vertex_indices"] = edge_indices; entry["faces"] = faces; brushes.push_back(entry);
	}
	out["brushes"] = brushes;
	return out;
}

Array TBMapDocument::get_preview_data() const {
	struct Surface {
		PackedVector3Array vertices, normals;
		PackedVector2Array uvs;
		PackedInt32Array indices, faces;
		PackedInt64Array brushes;
	};
	std::map<std::string, Surface> surfaces;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto view = current_brush_geometry(e, b); const auto &brush = *view.brush;
		for (int f = 0; f < brush.face_count; ++f) {
			const std::string material = current_face_texture(e, b, f); auto &s = surfaces[material]; int base = s.vertices.size(); int index_count = 0;
			if (view.compact) {
				const auto &face = view.compact->faces[f]; index_count = face.index_count;
				for (uint32_t v = 0; v < face.corner_count; ++v) {
					const auto &corner = view.compact->corners[face.corner_begin + v];
					s.vertices.push_back(vector(view.compact->positions[corner.position])); s.normals.push_back(vector(brush.faces[f].plane_normal)); s.uvs.push_back(Vector2(corner.uv.u, corner.uv.v));
				}
				for (uint32_t i = 0; i < face.index_count; ++i) s.indices.push_back(base + view.compact->face_index(f, i) - face.corner_begin);
			}
			for (int i = 0; i < index_count / 3; ++i) { s.brushes.push_back(brush.id); s.faces.push_back(f); }
		}
	}
	Array out;
	for (const auto &item : surfaces) {
		const auto &s = item.second; if (s.indices.is_empty()) continue;
		Vector2i texture_size = texture_sizes.get(String::utf8(item.first.c_str()), Vector2i(1, 1));
		Dictionary data; data["texture"] = String::utf8(item.first.c_str()); data["texture_size"] = texture_size;
		data["vertices"] = s.vertices; data["normals"] = s.normals; data["uvs"] = s.uvs; data["indices"] = s.indices;
		data["triangle_brush_ids"] = s.brushes; data["triangle_face_indices"] = s.faces; out.push_back(data);
	}
	return out;
}

PackedVector2Array TBMapDocument::get_face_preview_uvs(const Array &targets, const String &texture) const {
	PackedVector2Array out;
	for (int i = 0; i < targets.size(); ++i) {
		if (targets[i].get_type() != Variant::DICTIONARY) continue;
		const Dictionary target = targets[i];
		if (!target.has("brush_id") || !target.has("index") || !target.has("topology_revision") ||
				target["brush_id"].get_type() != Variant::INT || target["index"].get_type() != Variant::INT ||
				target["topology_revision"].get_type() != Variant::INT) continue;
		const int64_t id = target["brush_id"];
		const int face_index = target["index"];
		const int64_t token = target["topology_revision"];
		const LiveLocation *location = live_location(id, 'b');
		if (!location) continue;
		const auto view = current_brush_geometry(location->entity, location->index); const auto &brush = *view.brush;
		if (brush.topology_revision != token || face_index < 0 || face_index >= brush.face_count ||
				String::utf8(current_face_texture(location->entity, location->index, face_index).c_str()) != texture) continue;
		if (view.compact) {
			const auto &face = view.compact->faces[face_index];
			for (uint32_t index = 0; index < face.index_count; ++index) { const auto &uv = view.compact->corners[view.compact->face_index(face_index, index)].uv; out.push_back(Vector2(uv.u - std::floor(uv.u), uv.v - std::floor(uv.v))); }
		}
	}
	return out;
}
