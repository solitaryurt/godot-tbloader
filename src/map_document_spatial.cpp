#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include <algorithm>
#include <cmath>
#include <numeric>

using namespace godot;

struct TBMapDocument::SpatialIndex {
	struct Bounds { vec3 mins{}, maxs{}; };
	struct Entry {
		Bounds bounds;
		int entity = 0;
		int brush = 0;
		int source_order = 0;
	};
	struct Node {
		Bounds bounds;
		int left = -1;
		int right = -1;
		int begin = 0;
		int count = 0;
	};

	std::vector<Entry> entries;
	std::vector<int> order;
	std::vector<Node> nodes;

	static Bounds merge(const Bounds &a, const Bounds &b) {
		return {{std::min(a.mins.x, b.mins.x), std::min(a.mins.y, b.mins.y), std::min(a.mins.z, b.mins.z)},
			{std::max(a.maxs.x, b.maxs.x), std::max(a.maxs.y, b.maxs.y), std::max(a.maxs.z, b.maxs.z)}};
	}
	static double component(vec3 value, int axis) { return axis == 0 ? value.x : axis == 1 ? value.y : value.z; }

	int build_node(int begin, int end) {
		Bounds bounds = entries[order[begin]].bounds;
		for (int i = begin + 1; i < end; ++i) bounds = merge(bounds, entries[order[i]].bounds);
		const int node_index = nodes.size();
		nodes.push_back({bounds, -1, -1, begin, end - begin});
		if (end - begin <= 4) return node_index;
		vec3 extent = vec3_sub(bounds.maxs, bounds.mins);
		int axis = extent.y > extent.x ? 1 : 0;
		if (component(extent, 2) > component(extent, axis)) axis = 2;
		const int middle = begin + (end - begin) / 2;
		std::nth_element(order.begin() + begin, order.begin() + middle, order.begin() + end, [&](int a, int b) {
			const auto &aa = entries[a].bounds; const auto &bb = entries[b].bounds;
			return component(vec3_add(aa.mins, aa.maxs), axis) < component(vec3_add(bb.mins, bb.maxs), axis);
		});
		nodes[node_index].left = build_node(begin, middle);
		nodes[node_index].right = build_node(middle, end);
		nodes[node_index].count = 0;
		return node_index;
	}

	explicit SpatialIndex(const LMMapData &map) {
		int source_order = 0;
		for (int e = 0; e < map.entity_count; ++e) {
			const auto &entity = map.entities[e];
			for (int p = 0; p < entity.primitive_count; ++p) {
				const auto &primitive = entity.primitives[p];
				if (primitive.is_patch) continue;
				const auto &geometry = map.entity_geo[e].brushes[primitive.index];
				Bounds bounds{}; bool first = true;
				for (int f = 0; f < geometry.face_count; ++f) for (int v = 0; v < geometry.faces[f].vertex_count; ++v) {
					const vec3 point = geometry.faces[f].vertices[v].vertex;
					if (first) { bounds.mins = bounds.maxs = point; first = false; }
					else {
						bounds.mins = {std::min(bounds.mins.x, point.x), std::min(bounds.mins.y, point.y), std::min(bounds.mins.z, point.z)};
						bounds.maxs = {std::max(bounds.maxs.x, point.x), std::max(bounds.maxs.y, point.y), std::max(bounds.maxs.z, point.z)};
					}
				}
				if (!first) entries.push_back({bounds, e, primitive.index, source_order++});
			}
		}
		order.resize(entries.size());
		std::iota(order.begin(), order.end(), 0);
		if (!entries.empty()) build_node(0, entries.size());
	}
};

namespace {
double component(vec3 value, int axis) { return axis == 0 ? value.x : axis == 1 ? value.y : value.z; }
vec3 native(Vector3 value) { return {value.x, value.y, value.z}; }
Vector3 vector(vec3 value) { return Vector3(value.x, value.y, value.z); }

template <typename Bounds>
bool overlap_2d(const Bounds &bounds, vec3 mins, vec3 maxs, int hidden_axis) {
	for (int axis = 0; axis < 3; ++axis) if (axis != hidden_axis &&
		(component(bounds.maxs, axis) < component(mins, axis) || component(bounds.mins, axis) > component(maxs, axis))) return false;
	return true;
}

template <typename Bounds>
bool ray_bounds(const Bounds &bounds, vec3 origin, vec3 direction, double max_distance) {
	double near = 0, far = max_distance;
	for (int axis = 0; axis < 3; ++axis) {
		const double d = component(direction, axis), o = component(origin, axis);
		if (std::abs(d) < 1e-15) {
			if (o < component(bounds.mins, axis) || o > component(bounds.maxs, axis)) return false;
			continue;
		}
		double a = (component(bounds.mins, axis) - o) / d;
		double b = (component(bounds.maxs, axis) - o) / d;
		if (a > b) std::swap(a, b);
		near = std::max(near, a); far = std::min(far, b);
		if (near > far) return false;
	}
	return true;
}

bool ray_triangle(vec3 origin, vec3 direction, vec3 a, vec3 b, vec3 c, double max_distance, double &distance) {
	const vec3 edge_a = vec3_sub(b, a), edge_b = vec3_sub(c, a);
	const vec3 p = vec3_cross(direction, edge_b);
	const double determinant = vec3_dot(edge_a, p);
	if (std::abs(determinant) < 1e-12) return false;
	const double inverse = 1.0 / determinant;
	const vec3 offset = vec3_sub(origin, a);
	const double u = vec3_dot(offset, p) * inverse;
	if (u < -1e-9 || u > 1.0 + 1e-9) return false;
	const double v = vec3_dot(direction, vec3_cross(offset, edge_a)) * inverse;
	if (v < -1e-9 || u + v > 1.0 + 1e-9) return false;
	distance = vec3_dot(edge_b, vec3_cross(offset, edge_a)) * inverse;
	if (distance < -1e-9 || distance > max_distance + 1e-9) return false;
	distance = std::max(0.0, distance);
	return true;
}
}

void TBMapDocument::invalidate_spatial_index() { spatial_index.reset(); }

void TBMapDocument::invalidate_preview_cache() { preview_cache.reset(); }

const TBMapDocument::SpatialIndex &TBMapDocument::get_spatial_index() const {
	if (!spatial_index) spatial_index = std::make_shared<SpatialIndex>(*map);
	return *spatial_index;
}

PackedInt64Array TBMapDocument::query_brushes_2d(int hidden_axis, Vector3 mins, Vector3 maxs) const {
	PackedInt64Array result;
	if (hidden_axis < 0 || hidden_axis > 2 || !mins.is_finite() || !maxs.is_finite()) return result;
	for (int axis = 0; axis < 3; ++axis) if (axis != hidden_axis && mins[axis] > maxs[axis]) return result;
	const auto &index = get_spatial_index();
	if (index.nodes.empty()) return result;
	const vec3 query_mins = native(mins), query_maxs = native(maxs);
	std::vector<int> matches, stack{0};
	while (!stack.empty()) {
		const auto &node = index.nodes[stack.back()]; stack.pop_back();
		if (!overlap_2d(node.bounds, query_mins, query_maxs, hidden_axis)) continue;
		if (node.count) for (int i = node.begin; i < node.begin + node.count; ++i) {
			const int entry = index.order[i];
			if (overlap_2d(index.entries[entry].bounds, query_mins, query_maxs, hidden_axis)) matches.push_back(entry);
		} else { stack.push_back(node.left); stack.push_back(node.right); }
	}
	std::sort(matches.begin(), matches.end(), [&](int a, int b) { return index.entries[a].source_order < index.entries[b].source_order; });
	for (int match : matches) result.push_back(map->entities[index.entries[match].entity].brushes[index.entries[match].brush].id);
	return result;
}

Array TBMapDocument::query_ray(Vector3 origin, Vector3 direction, double max_distance) const {
	Array result;
	if (!origin.is_finite() || !direction.is_finite() || !std::isfinite(max_distance) || max_distance < 0 || direction.length_squared() <= 1e-24) return result;
	direction = direction.normalized();
	const vec3 ray_origin = native(origin), ray_direction = native(direction);
	const auto &index = get_spatial_index();
	if (index.nodes.empty()) return result;
	std::vector<int> candidates, stack{0};
	while (!stack.empty()) {
		const auto &node = index.nodes[stack.back()]; stack.pop_back();
		if (!ray_bounds(node.bounds, ray_origin, ray_direction, max_distance)) continue;
		if (node.count) for (int i = node.begin; i < node.begin + node.count; ++i) {
			const int entry = index.order[i];
			if (ray_bounds(index.entries[entry].bounds, ray_origin, ray_direction, max_distance)) candidates.push_back(entry);
		} else { stack.push_back(node.left); stack.push_back(node.right); }
	}
	struct Hit { double distance; int entry; int face; };
	std::vector<Hit> hits;
	for (int candidate : candidates) {
		const auto &entry = index.entries[candidate];
		const auto &brush = map->entities[entry.entity].brushes[entry.brush];
		const auto &geometry = map->entity_geo[entry.entity].brushes[entry.brush];
		for (int f = 0; f < geometry.face_count; ++f) {
			const auto &face = geometry.faces[f];
			double nearest = max_distance + 1; bool found = false;
			for (int i = 0; i + 2 < face.index_count; i += 3) {
				double distance;
				if (ray_triangle(ray_origin, ray_direction, face.vertices[face.indices[i]].vertex,
						face.vertices[face.indices[i + 1]].vertex, face.vertices[face.indices[i + 2]].vertex,
						max_distance, distance)) { nearest = std::min(nearest, distance); found = true; }
			}
			if (found) hits.push_back({nearest, candidate, f});
		}
	}
	std::sort(hits.begin(), hits.end(), [&](const Hit &a, const Hit &b) {
		if (a.distance != b.distance) return a.distance < b.distance;
		const int ao = index.entries[a.entry].source_order, bo = index.entries[b.entry].source_order;
		return ao != bo ? ao < bo : a.face < b.face;
	});
	for (const Hit &hit : hits) {
		const auto &entry = index.entries[hit.entry];
		const auto &entity = map->entities[entry.entity]; const auto &brush = entity.brushes[entry.brush]; const auto &face = brush.faces[hit.face];
		Dictionary item;
		item["brush_id"] = brush.id; item["entity_id"] = entity.id; item["face_index"] = hit.face; item["distance"] = hit.distance;
		item["position"] = origin + direction * hit.distance; item["normal"] = vector(face.plane_normal);
		item["texture"] = String::utf8(map->textures[face.texture_idx].name);
		result.push_back(item);
	}
	return result;
}
