#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <numeric>
#include <queue>
#include <string>
#include <unordered_set>

using namespace godot;

namespace {
bool entity_owned(const LMEntity &entity);
int material_filter(const char *texture);
}

struct TBMapDocument::SpatialIndex {
	std::weak_ptr<LMMapData> source;
	struct Bounds { vec3 mins{}, maxs{}; };
	struct Entry {
		Bounds bounds;
		int entity = 0;
		int brush = 0;
		int source_order = 0;
		int face_filter_begin = 0;
		bool owned = false;
	};
	struct Node {
		Bounds bounds;
		int left = -1;
		int right = -1;
		int begin = 0;
		int count = 0;
	};

	std::vector<Entry> entries;
	std::vector<unsigned char> face_filters;
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

	explicit SpatialIndex(const std::shared_ptr<LMMapData> &source_map) : source(source_map) {
		const LMMapData &map = *source_map;
		int source_order = 0;
		for (int e = 0; e < map.entity_count; ++e) {
			const auto &entity = map.entities[e];
			for (int p = 0; p < entity.primitive_count; ++p) {
				const auto &primitive = entity.primitives[p];
				if (primitive.is_patch) continue;
				const auto &brush = entity.brushes[primitive.index];
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
				if (!first) {
					const int filter_begin = face_filters.size();
					for (int f = 0; f < brush.face_count; ++f) face_filters.push_back(material_filter(map.textures[brush.faces[f].texture_idx].name));
					entries.push_back({bounds, e, primitive.index, source_order++, filter_begin, entity_owned(entity)});
				}
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

template <typename Bounds>
bool ray_bounds_near(const Bounds &bounds, vec3 origin, vec3 direction, double max_distance, double &near) {
	near = 0;
	double far = max_distance;
	for (int axis = 0; axis < 3; ++axis) {
		const double d = component(direction, axis), o = component(origin, axis);
		if (std::abs(d) < 1e-15) {
			if (o < component(bounds.mins, axis) || o > component(bounds.maxs, axis)) return false;
			continue;
		}
		double a = (component(bounds.mins, axis) - o) / d;
		double b = (component(bounds.maxs, axis) - o) / d;
		if (a > b) std::swap(a, b);
		near = std::max(near, a);
		far = std::min(far, b);
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

bool entity_owned(const LMEntity &entity) {
	for (int i = 0; i < entity.property_count; ++i) {
		if (!std::strcmp(entity.properties[i].key, "classname")) return std::strcmp(entity.properties[i].value, "worldspawn") != 0;
	}
	return true;
}

int material_filter(const char *texture) {
	std::string name(texture ? texture : "");
	std::replace(name.begin(), name.end(), '\\', '/');
	const size_t slash = name.find_last_of('/');
	if (slash != std::string::npos) name.erase(0, slash + 1);
	const size_t dot = name.find_last_of('.');
	if (dot != std::string::npos) name.erase(dot);
	std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	if (name == "caulk") return 2;
	if (name == "clip" || name.rfind("clip", 0) == 0 || (name.size() >= 4 && name.compare(name.size() - 4, 4, "clip") == 0)) return 4;
	if (name == "hint_skip") return 8;
	return 0;
}
}

void TBMapDocument::invalidate_spatial_index() { spatial_index.reset(); }

void TBMapDocument::retain_spatial_index() {
	if (!spatial_index) return;
	spatial_history.erase(std::remove_if(spatial_history.begin(), spatial_history.end(), [&](const auto &cached) {
		return cached->source.expired() || cached->source.lock() == spatial_index->source.lock();
	}), spatial_history.end());
	spatial_history.push_back(spatial_index);
	if (spatial_history.size() > 2) spatial_history.erase(spatial_history.begin());
}

void TBMapDocument::restore_spatial_index() {
	spatial_index.reset();
	for (auto it = spatial_history.rbegin(); it != spatial_history.rend(); ++it) {
		if ((*it)->source.lock() == map) {
			spatial_index = *it;
			break;
		}
	}
}

void TBMapDocument::invalidate_preview_cache() { preview_cache.reset(); }

const TBMapDocument::SpatialIndex &TBMapDocument::get_spatial_index() const {
	if (!spatial_index) spatial_index = std::make_shared<SpatialIndex>(map);
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

Dictionary TBMapDocument::query_ray_nearest_visible(Vector3 origin, Vector3 direction, double max_distance, const PackedInt64Array &hidden_ids, int filter_mask) const {
	Dictionary result;
	if (!origin.is_finite() || !direction.is_finite() || !std::isfinite(max_distance) || max_distance < 0 ||
			direction.length_squared() <= 1e-24 || filter_mask < 0 || (filter_mask & ~15)) return result;
	direction = direction.normalized();
	const vec3 ray_origin = native(origin), ray_direction = native(direction);
	const auto &index = get_spatial_index();
	if (index.nodes.empty()) return result;

	std::unordered_set<int64_t> hidden_lookup;
	if (hidden_ids.size() > 8) {
		hidden_lookup.reserve(hidden_ids.size());
		for (int i = 0; i < hidden_ids.size(); ++i) hidden_lookup.insert(hidden_ids[i]);
	}
	auto hidden = [&](int64_t id) {
		if (!hidden_lookup.empty()) return hidden_lookup.count(id) != 0;
		for (int i = 0; i < hidden_ids.size(); ++i) if (hidden_ids[i] == id) return true;
		return false;
	};
	struct PendingNode {
		double near;
		int node;
	};
	struct FartherFirst {
		bool operator()(const PendingNode &a, const PendingNode &b) const {
			return a.near != b.near ? a.near > b.near : a.node > b.node;
		}
	};
	std::vector<PendingNode> pending_storage;
	pending_storage.reserve(64);
	std::priority_queue<PendingNode, std::vector<PendingNode>, FartherFirst> pending(FartherFirst{}, std::move(pending_storage));
	double root_near;
	if (!ray_bounds_near(index.nodes[0].bounds, ray_origin, ray_direction, max_distance, root_near)) return result;
	pending.push({root_near, 0});

	double nearest = max_distance;
	int best_entry = -1, best_face = -1;
	auto better = [&](double distance, int entry, int face) {
		if (best_entry < 0 || distance < nearest) return true;
		if (distance != nearest) return false;
		const int order = index.entries[entry].source_order;
		const int best_order = index.entries[best_entry].source_order;
		return order < best_order || (order == best_order && face < best_face);
	};

	while (!pending.empty()) {
		const PendingNode current = pending.top();
		pending.pop();
		if (current.near > nearest) break;
		const auto &node = index.nodes[current.node];
		if (!node.count) {
			for (int child : {node.left, node.right}) {
				double child_near;
				if (ray_bounds_near(index.nodes[child].bounds, ray_origin, ray_direction, nearest, child_near)) pending.push({child_near, child});
			}
			continue;
		}
		for (int i = node.begin; i < node.begin + node.count; ++i) {
			const int candidate = index.order[i];
			const auto &entry = index.entries[candidate];
			double entry_near;
			if (!ray_bounds_near(entry.bounds, ray_origin, ray_direction, nearest, entry_near)) continue;
			const auto &entity = map->entities[entry.entity];
			const auto &brush = entity.brushes[entry.brush];
			if (hidden(brush.id) || ((filter_mask & 1) && entry.owned)) continue;
			const auto &geometry = map->entity_geo[entry.entity].brushes[entry.brush];
			for (int f = 0; f < geometry.face_count; ++f) {
				if (filter_mask & index.face_filters[entry.face_filter_begin + f]) continue;
				const auto &face = geometry.faces[f];
				for (int triangle = 0; triangle + 2 < face.index_count; triangle += 3) {
					double distance;
					if (ray_triangle(ray_origin, ray_direction, face.vertices[face.indices[triangle]].vertex,
							face.vertices[face.indices[triangle + 1]].vertex, face.vertices[face.indices[triangle + 2]].vertex,
							nearest, distance) && distance <= nearest && better(distance, candidate, f)) {
						nearest = distance;
						best_entry = candidate;
						best_face = f;
					}
				}
			}
		}
	}
	if (best_entry < 0) return result;
	const auto &entry = index.entries[best_entry];
	const auto &entity = map->entities[entry.entity];
	const auto &brush = entity.brushes[entry.brush];
	const auto &face = brush.faces[best_face];
	result["brush_id"] = brush.id; result["entity_id"] = entity.id; result["face_index"] = best_face; result["distance"] = nearest;
	result["position"] = origin + direction * nearest; result["normal"] = vector(face.plane_normal);
	result["texture"] = String::utf8(map->textures[face.texture_idx].name);
	return result;
}
