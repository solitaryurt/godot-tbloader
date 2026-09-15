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
	std::shared_ptr<LMMapData> source;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> base_geometry;
	std::shared_ptr<const EditorState> overlay;
	int64_t state_generation = 0;
	struct Bounds { vec3 mins{}, maxs{}; };
	struct Entry {
		Bounds bounds;
		int64_t brush_id = 0;
		int64_t entity_id = 0;
		const LMBrush *brush = nullptr;
		std::shared_ptr<const LMEditorBrushGeometry> geometry;
		std::shared_ptr<const EditorState::BrushRecord> compact;
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

	explicit SpatialIndex(const std::shared_ptr<LMMapData> &source_map, const std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &base_store, const std::shared_ptr<const EditorState> &source_overlay, int64_t generation) : source(source_map), base_geometry(base_store), overlay(source_overlay), state_generation(generation) {
		const LMMapData &map = *source_map;
		int source_order = 0;
		for (int e = 0; e < map.entity_count; ++e) {
			const auto &entity = map.entities[e];
			for (int p = 0; p < entity.primitive_count; ++p) {
				const auto &primitive = entity.primitives[p];
				if (primitive.is_patch) continue;
				const auto &base_brush = entity.brushes[primitive.index];
				const LMBrush *brush = &base_brush;
				std::shared_ptr<const LMEditorBrushGeometry> geometry;
				auto base_found = base_store->brushes.find(base_brush.id); if (base_found != base_store->brushes.end()) geometry = base_found->second;
				std::shared_ptr<const EditorState::BrushRecord> compact;
				if (overlay) {
					auto found = overlay->brushes.find(base_brush.id);
					if (found != overlay->brushes.end()) { compact = found->second; brush = &compact->brush; geometry = compact->geometry; }
				}
				Bounds bounds{}; bool first = true;
				auto include = [&](vec3 point) {
					if (first) { bounds.mins = bounds.maxs = point; first = false; }
					else {
						bounds.mins = {std::min(bounds.mins.x, point.x), std::min(bounds.mins.y, point.y), std::min(bounds.mins.z, point.z)};
						bounds.maxs = {std::max(bounds.maxs.x, point.x), std::max(bounds.maxs.y, point.y), std::max(bounds.maxs.z, point.z)};
					}
				};
				if (geometry) for (const vec3 point : geometry->positions) include(point);
				if (!first) {
					const int filter_begin = face_filters.size();
					for (int f = 0; f < brush->face_count; ++f) face_filters.push_back(material_filter(compact ? compact->materials[f].c_str() : map.textures[brush->faces[f].texture_idx].name));
					entries.push_back({bounds, brush->id, entity.id, brush, geometry, compact, source_order++, filter_begin, entity_owned(entity)});
				}
			}
		}
		order.resize(entries.size());
		std::iota(order.begin(), order.end(), 0);
		if (!entries.empty()) build_node(0, entries.size());
	}
};

void TBMapDocument::rebind_spatial_indexes(const std::shared_ptr<LMMapData> &previous) {
	auto rebind = [&](std::shared_ptr<SpatialIndex> &index) {
		if (!index || index->source != previous) return;
		index->source = map;
		for (auto &entry : index->entries) {
			const auto *location = live_location(entry.brush_id, 'b');
			if (!location) { index.reset(); return; }
			const auto &base = map->entities[location->entity].brushes[location->index];
			entry.entity_id = map->entities[location->entity].id;
			entry.brush = &base;
			auto base_found = index->base_geometry->brushes.find(entry.brush_id); entry.geometry = base_found == index->base_geometry->brushes.end() ? nullptr : base_found->second;
			entry.compact.reset();
			if (index->overlay) {
				auto found = index->overlay->brushes.find(entry.brush_id);
				if (found != index->overlay->brushes.end()) { entry.compact = found->second; entry.brush = &entry.compact->brush; entry.geometry = entry.compact->geometry; }
			}
		}
	};
	rebind(spatial_index);
	for (auto &index : spatial_history) rebind(index);
}

void TBMapDocument::rebind_spatial_context() {
	spatial_history.clear();
	if (!spatial_index) return;
	if (spatial_index->state_generation != state_generation) { spatial_index.reset(); return; }
	spatial_index->source = map;
	spatial_index->base_geometry = base_geometry;
	spatial_index->overlay = editor;
	for (auto &entry : spatial_index->entries) {
		const auto *location = live_location(entry.brush_id, 'b');
		if (!location) { spatial_index.reset(); return; }
		const auto &base = map->entities[location->entity].brushes[location->index];
		entry.entity_id = map->entities[location->entity].id;
		entry.brush = &base;
		entry.compact.reset();
		auto base_found = base_geometry->brushes.find(entry.brush_id);
		entry.geometry = base_found == base_geometry->brushes.end() ? nullptr : base_found->second;
		if (editor) {
			auto found = editor->brushes.find(entry.brush_id);
			if (found != editor->brushes.end()) { entry.compact = found->second; entry.brush = &entry.compact->brush; entry.geometry = entry.compact->geometry; }
		}
		for (int f = 0; f < entry.brush->face_count; ++f) spatial_index->face_filters[entry.face_filter_begin + f] =
				material_filter(entry.compact ? entry.compact->materials[f].c_str() : map->textures[entry.brush->faces[f].texture_idx].name);
	}
}

void TBMapDocument::append_spatial_cache_counters(Dictionary &out) const {
	int64_t stale = 0;
	out["spatial_entries"] = spatial_index ? static_cast<int64_t>(spatial_index->entries.size()) : 0;
	out["spatial_nodes"] = spatial_index ? static_cast<int64_t>(spatial_index->nodes.size()) : 0;
	if (spatial_index) {
		stale += spatial_index->source != map || spatial_index->base_geometry != base_geometry || spatial_index->overlay != editor;
		for (const auto &entry : spatial_index->entries) {
			const auto *location = live_location(entry.brush_id, 'b');
			if (!location) { ++stale; continue; }
			const auto &base = map->entities[location->entity].brushes[location->index];
			const LMBrush *brush = &base;
			std::shared_ptr<const LMEditorBrushGeometry> geometry;
			auto base_found = base_geometry->brushes.find(entry.brush_id);
			if (base_found != base_geometry->brushes.end()) geometry = base_found->second;
			std::shared_ptr<const EditorState::BrushRecord> compact;
			if (editor) {
				auto found = editor->brushes.find(entry.brush_id);
				if (found != editor->brushes.end()) { compact = found->second; brush = &compact->brush; geometry = compact->geometry; }
			}
			if (entry.brush != brush || entry.geometry != geometry || entry.compact != compact) ++stale;
			for (int f = 0; f < brush->face_count; ++f) if (spatial_index->face_filters[entry.face_filter_begin + f] !=
					material_filter(compact ? compact->materials[f].c_str() : map->textures[brush->faces[f].texture_idx].name)) ++stale;
		}
	}
	out["spatial_stale_context_refs"] = stale;
}

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

double projected_segment_distance_squared(vec3 point, vec3 a, vec3 b, int hidden_axis) {
	const int u = hidden_axis == 0 ? 1 : 0, v = hidden_axis == 2 ? 1 : 2;
	const double ab_u = component(b, u) - component(a, u), ab_v = component(b, v) - component(a, v);
	const double ap_u = component(point, u) - component(a, u), ap_v = component(point, v) - component(a, v);
	const double length_squared = ab_u * ab_u + ab_v * ab_v;
	const double t = length_squared > 0 ? std::clamp((ap_u * ab_u + ap_v * ab_v) / length_squared, 0.0, 1.0) : 0.0;
	const double du = ap_u - ab_u * t, dv = ap_v - ab_v * t;
	return du * du + dv * dv;
}

bool projected_face_contains(const LMEditorBrushGeometry &geometry, const LMEditorBrushFace &face, vec3 point, int hidden_axis) {
	if (face.corner_count < 3) return false;
	const int u = hidden_axis == 0 ? 1 : 0, v = hidden_axis == 2 ? 1 : 2;
	bool inside = false;
	for (uint32_t i = 0, previous = face.corner_count - 1; i < face.corner_count; previous = i++) {
		const vec3 a = geometry.positions[geometry.corners[face.corner_begin + previous].position];
		const vec3 b = geometry.positions[geometry.corners[face.corner_begin + i].position];
		if (projected_segment_distance_squared(point, a, b, hidden_axis) <= 1e-18) return true;
		const double ay = component(a, v), by = component(b, v), py = component(point, v);
		if ((ay > py) != (by > py) && component(point, u) <
				(component(b, u) - component(a, u)) * (py - ay) / (by - ay) + component(a, u)) inside = !inside;
	}
	return inside;
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

void TBMapDocument::clear_spatial_caches() { spatial_index.reset(); spatial_history.clear(); }

void TBMapDocument::advance_spatial_index(const std::shared_ptr<const EditorState> &next, const std::vector<int64_t> &ids, LMEditorBrushDirtyDomain domains, int64_t generation) {
	if (!spatial_index) return;
	if ((domains & LMEditorBrushDirtyDomain::SPATIAL) != LMEditorBrushDirtyDomain::NONE || (domains & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) { spatial_index.reset(); return; }
	auto updated = std::make_shared<SpatialIndex>(*spatial_index); updated->overlay = next; updated->state_generation = generation;
	if ((domains & LMEditorBrushDirtyDomain::MATERIAL) != LMEditorBrushDirtyDomain::NONE) for (int64_t id : ids) for (auto &entry : updated->entries) if (entry.brush_id == id) {
		auto found = next ? next->brushes.find(id) : decltype(next->brushes.find(id)){};
		if (next && found != next->brushes.end()) { entry.compact = found->second; entry.brush = &entry.compact->brush; entry.geometry = entry.compact->geometry; }
		else { const auto *location = live_location(id, 'b'); entry.compact.reset(); entry.brush = &map->entities[location->entity].brushes[location->index]; auto base_found = updated->base_geometry->brushes.find(id); entry.geometry = base_found == updated->base_geometry->brushes.end() ? nullptr : base_found->second; }
		for (int f = 0; f < entry.brush->face_count; ++f) updated->face_filters[entry.face_filter_begin + f] = material_filter(entry.compact ? entry.compact->materials[f].c_str() : map->textures[entry.brush->faces[f].texture_idx].name);
	}
	spatial_index = std::move(updated);
}

void TBMapDocument::retain_spatial_index() {
	if (!spatial_index) return;
	spatial_history.erase(std::remove_if(spatial_history.begin(), spatial_history.end(), [&](const auto &cached) {
		return cached->state_generation == spatial_index->state_generation;
	}), spatial_history.end());
	spatial_history.push_back(spatial_index);
	if (spatial_history.size() > 2) spatial_history.erase(spatial_history.begin());
}

void TBMapDocument::restore_spatial_index() {
	spatial_index.reset();
	for (auto it = spatial_history.rbegin(); it != spatial_history.rend(); ++it) {
		if ((*it)->state_generation == state_generation) {
			spatial_index = *it;
			break;
		}
	}
}

void TBMapDocument::invalidate_preview_cache() { preview_cache.reset(); preview_history_restored = false; }

const TBMapDocument::SpatialIndex &TBMapDocument::get_spatial_index() const {
	if (!spatial_index || spatial_index->state_generation != state_generation) spatial_index = std::make_shared<SpatialIndex>(map, base_geometry, editor, state_generation);
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
	for (int match : matches) result.push_back(index.entries[match].brush_id);
	return result;
}

Dictionary TBMapDocument::query_brush_2d_hit(int hidden_axis, Vector3 point, double tolerance, const PackedInt64Array &hidden_ids,
		int filter_mask, const PackedInt64Array &selected_ids, bool prefer_selected) const {
	Dictionary result;
	if (hidden_axis < 0 || hidden_axis > 2 || !point.is_finite() || !std::isfinite(tolerance) || tolerance < 0 ||
			filter_mask < 0 || (filter_mask & ~15)) return result;
	const auto &index = get_spatial_index();
	if (index.nodes.empty()) return result;
	const vec3 query_point = native(point);
	vec3 query_mins = query_point, query_maxs = query_point;
	for (int axis = 0; axis < 3; ++axis) if (axis != hidden_axis) {
		if (axis == 0) { query_mins.x -= tolerance; query_maxs.x += tolerance; }
		else if (axis == 1) { query_mins.y -= tolerance; query_maxs.y += tolerance; }
		else { query_mins.z -= tolerance; query_maxs.z += tolerance; }
	}
	std::unordered_set<int64_t> hidden_lookup, selected_lookup;
	if (hidden_ids.size() > 8) { hidden_lookup.reserve(hidden_ids.size()); for (int64_t id : hidden_ids) hidden_lookup.insert(id); }
	if (prefer_selected && selected_ids.size() > 8) { selected_lookup.reserve(selected_ids.size()); for (int64_t id : selected_ids) selected_lookup.insert(id); }
	auto contains = [](const PackedInt64Array &ids, const std::unordered_set<int64_t> &lookup, int64_t id) {
		if (!lookup.empty()) return lookup.count(id) != 0;
		for (int i = 0; i < ids.size(); ++i) if (ids[i] == id) return true;
		return false;
	};
	const double tolerance_squared = tolerance * tolerance;
	int best = -1, best_selected = -1;
	std::vector<int> stack;
	stack.reserve(64);
	stack.push_back(0);
	while (!stack.empty()) {
		const auto &node = index.nodes[stack.back()]; stack.pop_back();
		if (!overlap_2d(node.bounds, query_mins, query_maxs, hidden_axis)) continue;
		if (!node.count) { stack.push_back(node.left); stack.push_back(node.right); continue; }
		for (int i = node.begin; i < node.begin + node.count; ++i) {
			const int candidate = index.order[i]; const auto &entry = index.entries[candidate];
			if (!overlap_2d(entry.bounds, query_mins, query_maxs, hidden_axis) || contains(hidden_ids, hidden_lookup, entry.brush_id) ||
					((filter_mask & 1) && entry.owned) || !entry.geometry) continue;
			bool all_faces_filtered = entry.brush->face_count > 0;
			for (int f = 0; f < entry.brush->face_count; ++f) if (!(filter_mask & index.face_filters[entry.face_filter_begin + f])) {
				all_faces_filtered = false; break;
			}
			if (all_faces_filtered) continue;
			bool hit = false;
			for (const auto &face : entry.geometry->faces) if (projected_face_contains(*entry.geometry, face, query_point, hidden_axis)) {
				hit = true; break;
			}
			if (!hit) for (const auto &edge : entry.geometry->edges) if (projected_segment_distance_squared(query_point,
					entry.geometry->positions[edge.a], entry.geometry->positions[edge.b], hidden_axis) < tolerance_squared) {
				hit = true; break;
			}
			if (!hit) continue;
			if (best < 0 || entry.source_order > index.entries[best].source_order) best = candidate;
			if (prefer_selected && contains(selected_ids, selected_lookup, entry.brush_id) &&
					(best_selected < 0 || entry.source_order > index.entries[best_selected].source_order)) best_selected = candidate;
		}
	}
	const int selected = best_selected >= 0 ? best_selected : best;
	if (selected >= 0) result["brush_id"] = index.entries[selected].brush_id;
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
		const auto &brush = *entry.brush;
		for (int f = 0; f < brush.face_count; ++f) {
			double nearest = max_distance + 1; bool found = false;
			if (entry.geometry) {
				const auto &face = entry.geometry->faces[f];
				for (uint32_t i = 0; i + 2 < face.index_count; i += 3) { double distance; const auto &g = *entry.geometry;
					if (ray_triangle(ray_origin, ray_direction, g.positions[g.corners[g.face_index(f, i)].position], g.positions[g.corners[g.face_index(f, i + 1)].position], g.positions[g.corners[g.face_index(f, i + 2)].position], max_distance, distance)) { nearest = std::min(nearest, distance); found = true; } }
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
		const auto &brush = *entry.brush; const auto &face = brush.faces[hit.face];
		Dictionary item;
		item["brush_id"] = entry.brush_id; item["entity_id"] = entry.entity_id; item["face_index"] = hit.face; item["distance"] = hit.distance;
		item["position"] = origin + direction * hit.distance; item["normal"] = vector(face.plane_normal);
		item["texture"] = String::utf8(entry.compact ? entry.compact->materials[hit.face].c_str() : index.source->textures[face.texture_idx].name);
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
			const auto &brush = *entry.brush;
			if (hidden(brush.id) || ((filter_mask & 1) && entry.owned)) continue;
			for (int f = 0; f < brush.face_count; ++f) {
				if (filter_mask & index.face_filters[entry.face_filter_begin + f]) continue;
				if (entry.geometry) {
					const auto &face = entry.geometry->faces[f]; const auto &g = *entry.geometry;
					for (uint32_t triangle = 0; triangle + 2 < face.index_count; triangle += 3) { double distance;
						if (ray_triangle(ray_origin, ray_direction, g.positions[g.corners[g.face_index(f, triangle)].position], g.positions[g.corners[g.face_index(f, triangle + 1)].position], g.positions[g.corners[g.face_index(f, triangle + 2)].position], nearest, distance) && distance <= nearest && better(distance, candidate, f)) { nearest = distance; best_entry = candidate; best_face = f; } }
				}
			}
		}
	}
	if (best_entry < 0) return result;
	const auto &entry = index.entries[best_entry];
	const auto &brush = *entry.brush;
	const auto &face = brush.faces[best_face];
	result["brush_id"] = brush.id; result["entity_id"] = entry.entity_id; result["face_index"] = best_face; result["distance"] = nearest;
	result["position"] = origin + direction * nearest; result["normal"] = vector(face.plane_normal);
	result["texture"] = String::utf8(entry.compact ? entry.compact->materials[best_face].c_str() : index.source->textures[face.texture_idx].name);
	return result;
}
