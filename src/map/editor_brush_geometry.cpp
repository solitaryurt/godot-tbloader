#include "editor_brush_geometry.h"

#include "brush_geometry_math.h"
#include "face.h"
#include "libmap_math.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <mutex>
#include <utility>

namespace {
std::atomic<uint64_t> build_count{0};
std::atomic<uint64_t> cache_hit_count{0};
std::atomic<size_t> cache_retained_bytes{0};

struct BuildCorner {
	vec3 position{};
	LMVertexUV uv{};
	uint32_t topology_position = 0;
	double sort_angle = 0;
};

constexpr int MAX_EDITOR_BRUSH_FACES = 64;
constexpr size_t MAX_EDITOR_BRUSH_CORNERS = 4096;

bool finite(vec3 value) {
	return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z);
}

// Thread-local F^3 scratch reused across builds with clear-not-free. Capacity
// is retained between brushes; each build clears without shrinking so the
// 256-brush blockout workload avoids repeated allocation.
thread_local std::vector<std::vector<BuildCorner>> t_windings;
thread_local std::vector<vec3> t_unique_positions;
thread_local std::vector<std::pair<uint32_t, uint32_t>> t_unique_edges;
}

struct LMEditorBrushCorners::Store {
	struct Patch {
		uint32_t index = 0;
		LMEditorBrushCorner corner{};
	};
	std::shared_ptr<const std::vector<LMEditorBrushCorner>> root;
	std::shared_ptr<const Store> parent;
	std::vector<Patch> patches;
	size_t count = 0;
	mutable std::once_flag materialize_once;
	mutable std::vector<LMEditorBrushCorner> materialized;

	const LMEditorBrushCorner &at(size_t index) const {
		auto found = std::lower_bound(patches.begin(), patches.end(), index,
				[](const Patch &patch, size_t candidate) { return patch.index < candidate; });
		if (found != patches.end() && found->index == index) return found->corner;
		return parent ? parent->at(index) : (*root)[index];
	}
	const LMEditorBrushCorner *data() const {
		if (root && patches.empty()) return root->data();
		std::call_once(materialize_once, [this]() {
			materialized.reserve(count);
			for (size_t i = 0; i < count; ++i) materialized.push_back(at(i));
		});
		return materialized.data();
	}
};

LMEditorBrushCorners::LMEditorBrushCorners() : writable(std::make_shared<std::vector<LMEditorBrushCorner>>()) {}
LMEditorBrushCorners::~LMEditorBrushCorners() = default;
size_t LMEditorBrushCorners::size() const { return writable ? writable->size() : store->count; }
size_t LMEditorBrushCorners::capacity() const { return writable ? writable->capacity() : store->count; }
void LMEditorBrushCorners::ensure_writable() {
	if (writable) {
		if (!writable.unique()) writable = std::make_shared<std::vector<LMEditorBrushCorner>>(*writable);
		return;
	}
	auto materialized = std::make_shared<std::vector<LMEditorBrushCorner>>();
	materialized->reserve(store->count);
	for (size_t i = 0; i < store->count; ++i) materialized->push_back(store->at(i));
	writable = std::move(materialized);
	store.reset();
}
void LMEditorBrushCorners::reserve(size_t count) { ensure_writable(); writable->reserve(count); }
void LMEditorBrushCorners::push_back(const LMEditorBrushCorner &corner) { ensure_writable(); writable->push_back(corner); }
void LMEditorBrushCorners::push_back(LMEditorBrushCorner &&corner) { ensure_writable(); writable->push_back(std::move(corner)); }
const LMEditorBrushCorner &LMEditorBrushCorners::operator[](size_t index) const { return writable ? (*writable)[index] : store->at(index); }
LMEditorBrushCorner &LMEditorBrushCorners::operator[](size_t index) { ensure_writable(); return (*writable)[index]; }
const LMEditorBrushCorner *LMEditorBrushCorners::data() const { return writable ? writable->data() : store->data(); }
LMEditorBrushCorner *LMEditorBrushCorners::data() { ensure_writable(); return writable->data(); }

size_t LMEditorBrushCorners::with_uv_updates(const std::vector<std::pair<uint32_t, LMVertexUV>> &updates) {
	if (updates.empty()) return 0;
	const size_t count = size();
	if (updates.size() == count) {
		auto replacement = std::make_shared<std::vector<LMEditorBrushCorner>>();
		replacement->reserve(count);
		for (size_t i = 0; i < count; ++i) {
			LMEditorBrushCorner corner = static_cast<const LMEditorBrushCorners &>(*this)[i];
			corner.uv = updates[i].second;
			replacement->push_back(corner);
		}
		writable = std::move(replacement);
		store.reset();
		return updates.size() * sizeof(LMEditorBrushCorner);
	}
	std::shared_ptr<const Store> parent = store;
	if (!parent) {
		auto root = std::make_shared<Store>();
		root->root = writable;
		root->count = writable->size();
		parent = std::move(root);
	}
	auto next = std::make_shared<Store>();
	next->count = parent->count;
	next->parent = std::move(parent);
	next->patches.reserve(updates.size());
	for (const auto &update : updates) {
		LMEditorBrushCorner corner = next->parent->at(update.first);
		corner.uv = update.second;
		next->patches.push_back({update.first, corner});
	}
	writable.reset();
	store = std::move(next);
	return updates.size() * sizeof(LMEditorBrushCorner);
}

namespace {
bool valid_face(const LMFace &face) {
	return finite(face.plane_points.v0) && finite(face.plane_points.v1) && finite(face.plane_points.v2) &&
			finite(face.plane_normal) && std::isfinite(face.plane_dist) &&
			std::isfinite(face.uv_standard.u) && std::isfinite(face.uv_standard.v) &&
			finite(face.uv_valve.u.axis) && finite(face.uv_valve.v.axis) &&
			std::isfinite(face.uv_valve.u.offset) && std::isfinite(face.uv_valve.v.offset) &&
			std::isfinite(face.uv_extra.rot) && std::isfinite(face.uv_extra.scale_x) &&
			std::isfinite(face.uv_extra.scale_y) && face.uv_extra.scale_x != 0 && face.uv_extra.scale_y != 0;
}

LMVertexUV face_uv(vec3 vertex, const LMFace &face, LMEditorTextureSize texture) {
	return face.is_valve_uv ? lm_valve_brush_uv(vertex, &face, texture.width, texture.height) :
			lm_standard_brush_uv(vertex, &face, texture.width, texture.height);
}

LMEditorBrushBuildResult failure(LMEditorBrushBuildStatus status) {
	LMEditorBrushBuildResult result;
	result.status = status;
	return result;
}
}

uint32_t LMEditorBrushGeometry::face_index(uint32_t face_index, uint32_t index) const {
	const auto &face = faces[face_index];
	const uint32_t triangle_corner = index % 3;
	const uint32_t triangle = index / 3;
	return face.corner_begin + (triangle_corner == 0 ? 0 : triangle + triangle_corner);
}

size_t LMEditorBrushGeometry::retained_bytes() const {
	return sizeof(*this) + positions.capacity() * sizeof(vec3) + corners.capacity() * sizeof(LMEditorBrushCorner) +
			faces.capacity() * sizeof(LMEditorBrushFace) + edges.capacity() * sizeof(LMEditorBrushEdge);
}

static LMEditorBrushBuildResult build_editor_brush_geometry(const LMBrush &brush, const LMEditorBrushBuildContext &context) {
	if (brush.face_count < 0 || (brush.face_count > 0 && !brush.faces)) return failure(LMEditorBrushBuildStatus::INVALID_FACE_STORAGE);
	if (brush.face_count > MAX_EDITOR_BRUSH_FACES) return failure(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);
	if (static_cast<uint64_t>(brush.face_count) > std::numeric_limits<uint32_t>::max()) return failure(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);

	for (auto &winding : t_windings) winding.clear();
	t_windings.resize(static_cast<size_t>(brush.face_count));
	t_unique_positions.clear();
	t_unique_edges.clear();
	auto &windings = t_windings;
	auto &unique_positions = t_unique_positions;
	auto &unique_edges = t_unique_edges;
	size_t generated_corner_count = 0;
	for (int f = 0; f < brush.face_count; ++f) {
		const LMFace &face = brush.faces[f];
		if (!valid_face(face)) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
		if (face.texture_idx < 0 || static_cast<size_t>(face.texture_idx) >= context.texture_count || !context.textures ||
				context.textures[face.texture_idx].width <= 0 || context.textures[face.texture_idx].height <= 0) {
			return failure(LMEditorBrushBuildStatus::INVALID_TEXTURE_CONTEXT);
		}
		bool duplicate_plane = false;
		for (int previous = 0; previous < f; ++previous) {
			const LMFace &candidate = brush.faces[previous];
			if (vec3_dot(face.plane_normal, candidate.plane_normal) > 1.0 - 1e-10 &&
					std::abs(face.plane_dist - candidate.plane_dist) < 1e-10) {
				duplicate_plane = true;
				break;
			}
		}
		if (duplicate_plane) continue;
		for (int f1 = 0; f1 < brush.face_count; ++f1) for (int f2 = 0; f2 < brush.face_count; ++f2) {
			vec3 vertex{};
			if (!lm_intersect_brush_faces(face, brush.faces[f1], brush.faces[f2], &vertex) ||
					!lm_brush_vertex_in_hull(brush.faces, brush.face_count, vertex)) continue;
			auto &winding = windings[f];
			const auto duplicate = std::find_if(winding.begin(), winding.end(), [vertex](const BuildCorner &corner) {
				return vec3_length(vec3_sub(vertex, corner.position)) < CMP_EPSILON;
			});
			if (duplicate == winding.end()) {
				if (!finite(vertex)) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
				if (generated_corner_count == MAX_EDITOR_BRUSH_CORNERS) return failure(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);
				winding.push_back({vertex, face_uv(vertex, face, context.textures[face.texture_idx]), 0, 0});
				++generated_corner_count;
			}
		}
		auto &winding = windings[f];
		if (winding.size() >= 3) {
			vec3 center{};
			for (const auto &corner : winding) {
				center = vec3_add(center, corner.position);
				if (!finite(center)) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
			}
			center = vec3_div_double(center, winding.size());
			const vec3 basis = vec3_sub(winding[1].position, winding[0].position);
			if (!finite(center) || !finite(basis) || vec3_dot(basis, basis) == 0) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
			const vec3 u = vec3_normalize(basis);
			const vec3 cross = vec3_cross(u, face.plane_normal);
			if (!finite(u) || !finite(cross) || vec3_dot(cross, cross) == 0) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
			const vec3 v = vec3_normalize(cross);
			if (!finite(v)) return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
			for (auto &corner : winding) {
				const vec3 local = vec3_sub(corner.position, center);
				const double projected_u = vec3_dot(local, u), projected_v = vec3_dot(local, v);
				corner.sort_angle = std::atan2(projected_v, projected_u);
				if (!finite(local) || !std::isfinite(projected_u) || !std::isfinite(projected_v) || !std::isfinite(corner.sort_angle)) {
					return failure(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
				}
			}
			std::sort(winding.begin(), winding.end(), [](const BuildCorner &a, const BuildCorner &b) { return a.sort_angle < b.sort_angle; });
		}
	}

	size_t corner_count = 0;
	for (const auto &winding : windings) {
		if (winding.size() > MAX_EDITOR_BRUSH_CORNERS - corner_count ||
				winding.size() > (std::numeric_limits<uint32_t>::max() / 3u) + 2u) {
			return failure(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);
		}
		corner_count += winding.size();
	}
	if (corner_count > std::numeric_limits<uint32_t>::max()) return failure(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);
	unique_positions.reserve(corner_count);
	for (auto &winding : windings) for (auto &corner : winding) {
		uint32_t index = 0;
		for (; index < unique_positions.size(); ++index) {
			const vec3 delta = vec3_sub(unique_positions[index], corner.position);
			if (vec3_dot(delta, delta) < 1e-10) break;
		}
		if (index == unique_positions.size()) unique_positions.push_back(corner.position);
		corner.topology_position = index;
	}

	unique_edges.reserve(corner_count);
	for (const auto &winding : windings) for (size_t i = 0; i < winding.size(); ++i) {
		uint32_t a = winding[i].topology_position, b = winding[(i + 1) % winding.size()].topology_position;
		if (a > b) std::swap(a, b);
		if (std::find(unique_edges.begin(), unique_edges.end(), std::make_pair(a, b)) == unique_edges.end()) unique_edges.emplace_back(a, b);
	}

	LMEditorBrushBuildResult result;
	auto &out = result.geometry;
	out.brush_id = brush.id;
	out.positions.reserve(unique_positions.size());
	for (const vec3 position : unique_positions) out.positions.push_back(position);
	out.corners.reserve(corner_count);
	out.faces.reserve(static_cast<size_t>(brush.face_count));
	out.edges.reserve(unique_edges.size());
	for (int f = 0; f < brush.face_count; ++f) {
		const auto &winding = windings[f];
		LMEditorBrushFace face;
		face.corner_begin = static_cast<uint32_t>(out.corners.size());
		face.corner_count = static_cast<uint32_t>(winding.size());
		face.index_count = winding.size() >= 3 ? static_cast<uint32_t>((winding.size() - 2) * 3) : 0;
		face.plane_normal = brush.faces[f].plane_normal;
		face.texture_idx = brush.faces[f].texture_idx;
		for (const auto &corner : winding) {
			face.center = vec3_add(face.center, corner.position);
			out.corners.push_back({corner.topology_position, corner.uv});
		}
		if (!winding.empty()) face.center = vec3_div_double(face.center, winding.size());
		out.faces.push_back(face);
	}
	if (!out.positions.empty()) {
		out.has_bounds = true;
		out.mins = out.maxs = out.positions[0];
		for (const vec3 point : out.positions) {
			out.mins = {std::min(out.mins.x, point.x), std::min(out.mins.y, point.y), std::min(out.mins.z, point.z)};
			out.maxs = {std::max(out.maxs.x, point.x), std::max(out.maxs.y, point.y), std::max(out.maxs.z, point.z)};
		}
	}
	for (const auto edge_pair : unique_edges) {
		LMEditorBrushEdge edge{edge_pair.first, edge_pair.second};
		for (uint32_t f = 0; f < windings.size(); ++f) for (size_t i = 0; i < windings[f].size(); ++i) {
			uint32_t a = windings[f][i].topology_position, b = windings[f][(i + 1) % windings[f].size()].topology_position;
			if (a > b) std::swap(a, b);
			if (a == edge.a && b == edge.b) {
				if (edge.use_count == 0) edge.first_face = f;
				else if (edge.use_count == 1) edge.second_face = f;
				++edge.use_count;
			}
		}
		out.edges.push_back(edge);
	}
	return result;
}

LMEditorBrushBuildResult lm_build_editor_brush_geometry(const LMBrush &brush, const LMEditorBrushBuildContext &context) {
	build_count.fetch_add(1, std::memory_order_relaxed);
	return build_editor_brush_geometry(brush, context);
}

LMEditorBrushTranslateResult lm_translate_editor_brush_geometry(const LMBrush &brush,
		const LMEditorBrushGeometry &source, vec3 delta, const LMEditorBrushBuildContext &context) {
	LMEditorBrushTranslateResult out;
	auto fail = [&](LMEditorBrushBuildStatus status) {
		out.status = status;
		return out;
	};
	if (brush.face_count <= 0 || !brush.faces) return fail(LMEditorBrushBuildStatus::INVALID_FACE_STORAGE);
	if (brush.face_count > MAX_EDITOR_BRUSH_FACES) return fail(LMEditorBrushBuildStatus::LIMIT_EXCEEDED);
	if (static_cast<size_t>(brush.face_count) != source.faces.size()) return fail(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
	if (source.positions.empty() || !source.has_bounds) return fail(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
	if (!finite(delta) || !finite(source.mins) || !finite(source.maxs)) return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
	// Shallow copy shares faces/corners-topology/edges storage via copy-on-write.
	// Positions/faces/corners detach on first write; edges stay shared.
	LMEditorBrushGeometry moved = source;
	moved.brush_id = brush.id;
	for (size_t i = 0; i < moved.positions.size(); ++i) {
		const vec3 next = vec3_add(source.positions[i], delta);
		if (!finite(next) || std::abs(next.x) > 1e9 || std::abs(next.y) > 1e9 || std::abs(next.z) > 1e9) {
			return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
		}
		moved.positions[i] = next;
	}
	const vec3 next_mins = vec3_add(source.mins, delta);
	const vec3 next_maxs = vec3_add(source.maxs, delta);
	if (!finite(next_mins) || !finite(next_maxs) || std::abs(next_mins.x) > 1e9 || std::abs(next_mins.y) > 1e9 ||
			std::abs(next_mins.z) > 1e9 || std::abs(next_maxs.x) > 1e9 || std::abs(next_maxs.y) > 1e9 ||
			std::abs(next_maxs.z) > 1e9) {
		return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
	}
	moved.mins = next_mins;
	moved.maxs = next_maxs;
	for (int f = 0; f < brush.face_count; ++f) {
		if (!valid_face(brush.faces[f])) return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
		const int texture = brush.faces[f].texture_idx;
		if (texture < 0 || static_cast<size_t>(texture) >= context.texture_count || !context.textures ||
				context.textures[texture].width <= 0 || context.textures[texture].height <= 0) {
			return fail(LMEditorBrushBuildStatus::INVALID_TEXTURE_CONTEXT);
		}
		const auto &source_face = source.faces[f];
		auto &face = moved.faces[f];
		if (source_face.corner_begin > source.corners.size() ||
				source_face.corner_count > source.corners.size() - source_face.corner_begin) {
			return fail(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
		}
		if (source_face.corner_count == 0) {
			// Redundant/non-contributing plane: full builds keep a zero center.
			face.center = {};
			face.plane_normal = brush.faces[f].plane_normal;
			face.texture_idx = brush.faces[f].texture_idx;
			continue;
		}
		const vec3 next_center = vec3_add(source_face.center, delta);
		if (!finite(next_center)) return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
		face.center = next_center;
		face.plane_normal = brush.faces[f].plane_normal;
		face.texture_idx = brush.faces[f].texture_idx;
	}
	for (int f = 0; f < brush.face_count; ++f) {
		const uint32_t begin = moved.faces[f].corner_begin;
		const uint32_t count = moved.faces[f].corner_count;
		if (count == 0) continue;
		if (begin > moved.corners.size() || count > moved.corners.size() - begin) {
			return fail(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
		}
		const int texture = brush.faces[f].texture_idx;
		for (uint32_t v = 0; v < count; ++v) {
			const uint32_t corner_index = begin + v;
			const uint32_t position = moved.corners[corner_index].position;
			if (position >= moved.positions.size()) return fail(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
			const LMVertexUV uv = face_uv(moved.positions[position], brush.faces[f], context.textures[texture]);
			if (!std::isfinite(uv.u) || !std::isfinite(uv.v) || std::abs(uv.u) > 1e9 || std::abs(uv.v) > 1e9) {
				return fail(LMEditorBrushBuildStatus::NONFINITE_SOURCE);
			}
			moved.corners[corner_index].uv = uv;
		}
	}
	out.geometry = std::move(moved);
	return out;
}

LMEditorBrushUVUpdateResult lm_update_editor_brush_uvs(const LMBrush &brush,
		const std::shared_ptr<const LMEditorBrushGeometry> &geometry,
		const LMEditorBrushBuildContext &old_context, const LMEditorBrushBuildContext &new_context,
		uint64_t source_generation) {
	LMEditorBrushUVUpdateResult result;
	if (brush.face_count < 0 || (brush.face_count > 0 && !brush.faces)) {
		result.status = LMEditorBrushBuildStatus::INVALID_FACE_STORAGE;
		return result;
	}
	if (!geometry || geometry->brush_id != brush.id || geometry->source_generation != source_generation ||
			geometry->faces.size() != static_cast<size_t>(brush.face_count)) {
		result.status = LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH;
		return result;
	}
	std::vector<uint8_t> changed(static_cast<size_t>(brush.face_count));
	for (int f = 0; f < brush.face_count; ++f) {
		const int texture = brush.faces[f].texture_idx;
		if (texture < 0 || !old_context.textures || !new_context.textures ||
				static_cast<size_t>(texture) >= old_context.texture_count || static_cast<size_t>(texture) >= new_context.texture_count ||
				old_context.textures[texture].width <= 0 || old_context.textures[texture].height <= 0 ||
				new_context.textures[texture].width <= 0 || new_context.textures[texture].height <= 0) {
			result.status = LMEditorBrushBuildStatus::INVALID_TEXTURE_CONTEXT;
			return result;
		}
		const auto &compact_face = geometry->faces[f];
		if (compact_face.texture_idx != texture || compact_face.corner_begin > geometry->corners.size() ||
				compact_face.corner_count > geometry->corners.size() - compact_face.corner_begin) {
			result.status = LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH;
			return result;
		}
		changed[f] = compact_face.corner_count > 0 &&
				(old_context.textures[texture].width != new_context.textures[texture].width ||
				old_context.textures[texture].height != new_context.textures[texture].height);
		result.updated_faces += changed[f];
	}
	if (!result.updated_faces) {
		result.geometry = geometry;
		return result;
	}
	auto updated = std::make_shared<LMEditorBrushGeometry>(*geometry);
	std::vector<std::pair<uint32_t, LMVertexUV>> uv_updates;
	size_t update_count = 0;
	for (int f = 0; f < brush.face_count; ++f) if (changed[f]) update_count += geometry->faces[f].corner_count;
	uv_updates.reserve(update_count);
	for (int f = 0; f < brush.face_count; ++f) {
		if (!changed[f]) continue;
		const auto &face = static_cast<const LMEditorBrushGeometry &>(*updated).faces[f];
		for (uint32_t v = 0; v < face.corner_count; ++v) {
			const uint32_t corner_index = face.corner_begin + v;
			const auto &corner = static_cast<const LMEditorBrushGeometry &>(*updated).corners[corner_index];
			if (corner.position >= updated->positions.size()) {
				result.status = LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH;
				return result;
			}
			const LMVertexUV uv = face_uv(static_cast<const LMEditorBrushGeometry &>(*updated).positions[corner.position],
					brush.faces[f], new_context.textures[brush.faces[f].texture_idx]);
			if (!std::isfinite(uv.u) || !std::isfinite(uv.v) || std::abs(uv.u) > 1e9 || std::abs(uv.v) > 1e9) {
				result.status = LMEditorBrushBuildStatus::NONFINITE_SOURCE;
				return result;
			}
			uv_updates.emplace_back(corner_index, uv);
		}
	}
	result.copied_bytes = updated->corners.with_uv_updates(uv_updates);
	result.geometry = std::move(updated);
	return result;
}

bool lm_validate_editor_brush_geometry(const LMBrush &brush, const LMEditorBrushGeometry &geometry) {
	if (brush.face_count < 4 || geometry.faces.size() != static_cast<size_t>(brush.face_count) || geometry.positions.empty()) return false;
	for (const vec3 point : geometry.positions) {
		if (!finite(point) || std::abs(point.x) > 1e9 || std::abs(point.y) > 1e9 || std::abs(point.z) > 1e9) return false;
	}
	vec3 center{};
	for (const vec3 point : geometry.positions) center = vec3_add(center, point);
	center = vec3_div_double(center, geometry.positions.size());
	int contributing_faces = 0;
	double volume = 0;
	for (int f = 0; f < brush.face_count; ++f) {
		const auto &face = geometry.faces[f];
		if (face.corner_begin > geometry.corners.size() || face.corner_count > geometry.corners.size() - face.corner_begin) return false;
		if (face.corner_count < 3) continue;
		++contributing_faces;
		for (uint32_t v = 0; v < face.corner_count; ++v) {
			const auto &corner = geometry.corners[face.corner_begin + v];
			const auto &next = geometry.corners[face.corner_begin + (v + 1) % face.corner_count];
			if (corner.position >= geometry.positions.size() || next.position >= geometry.positions.size() || corner.position == next.position ||
					!std::isfinite(corner.uv.u) || !std::isfinite(corner.uv.v) || std::abs(corner.uv.u) > 1e9 || std::abs(corner.uv.v) > 1e9) return false;
		}
		const vec3 a = vec3_sub(geometry.positions[geometry.corners[face.corner_begin].position], center);
		for (uint32_t v = 1; v + 1 < face.corner_count; ++v) {
			const vec3 b = vec3_sub(geometry.positions[geometry.corners[face.corner_begin + v].position], center);
			const vec3 c = vec3_sub(geometry.positions[geometry.corners[face.corner_begin + v + 1].position], center);
			const double orientation = vec3_dot(vec3_cross(vec3_sub(b, a), vec3_sub(c, a)), brush.faces[f].plane_normal);
			if (!std::isfinite(orientation) || orientation >= -1e-10) return false;
			volume += std::abs(vec3_dot(a, vec3_cross(b, c))) / 6.0;
		}
	}
	if (contributing_faces < 4 || !std::isfinite(volume) || volume <= 1e-9) return false;
	return std::all_of(geometry.edges.begin(), geometry.edges.end(), [](const LMEditorBrushEdge &edge) {
		return edge.a != edge.b && edge.use_count == 2;
	});
}

LMEditorBrushDirtyDomain lm_editor_brush_dirty_dependencies(LMEditorBrushDirtyDomain domains) {
	if ((domains & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) return LMEditorBrushDirtyDomain::ALL;
	if ((domains & LMEditorBrushDirtyDomain::POSITIONS) != LMEditorBrushDirtyDomain::NONE) {
		domains = domains | LMEditorBrushDirtyDomain::UVS | LMEditorBrushDirtyDomain::BOUNDS |
				LMEditorBrushDirtyDomain::SPATIAL | LMEditorBrushDirtyDomain::PREVIEW;
	}
	if ((domains & LMEditorBrushDirtyDomain::UVS) != LMEditorBrushDirtyDomain::NONE) domains = domains | LMEditorBrushDirtyDomain::PREVIEW;
	if ((domains & LMEditorBrushDirtyDomain::MATERIAL) != LMEditorBrushDirtyDomain::NONE) domains = domains | LMEditorBrushDirtyDomain::PREVIEW;
	return domains;
}

LMEditorBrushInstrumentation lm_editor_brush_instrumentation() {
	return {build_count.load(std::memory_order_relaxed), cache_hit_count.load(std::memory_order_relaxed), cache_retained_bytes.load(std::memory_order_relaxed)};
}

void lm_reset_editor_brush_instrumentation() {
	build_count.store(0, std::memory_order_relaxed);
	cache_hit_count.store(0, std::memory_order_relaxed);
}

LMEditorBrushCacheSlot::~LMEditorBrushCacheSlot() { clear(); }

LMEditorBrushCacheSlot::LMEditorBrushCacheSlot(LMEditorBrushCacheSlot &&other) noexcept :
		value(std::move(other.value)), token(other.token), dirty(other.dirty), retained(other.retained), populated(other.populated) {
	other.retained = 0; other.populated = false; other.dirty = LMEditorBrushDirtyDomain::ALL;
}

LMEditorBrushCacheSlot &LMEditorBrushCacheSlot::operator=(LMEditorBrushCacheSlot &&other) noexcept {
	if (this == &other) return *this;
	clear(); value = std::move(other.value); token = other.token; dirty = other.dirty; retained = other.retained; populated = other.populated;
	other.retained = 0; other.populated = false; other.dirty = LMEditorBrushDirtyDomain::ALL;
	return *this;
}

const LMEditorBrushBuildResult &LMEditorBrushCacheSlot::ensure_geometry(const LMBrush &brush, const LMEditorBrushBuildContext &context,
		LMEditorBrushSourceToken source_token, LMEditorBrushDirtyDomain required) {
	if (source_token.brush_id != brush.id) {
		if (retained) cache_retained_bytes.fetch_sub(retained, std::memory_order_relaxed);
		value = failure(LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH);
		retained = value.geometry.retained_bytes();
		cache_retained_bytes.fetch_add(retained, std::memory_order_relaxed);
		token = source_token; populated = false; dirty = LMEditorBrushDirtyDomain::ALL;
		return value;
	}
	if (populated && source_token == token && (dirty & required) == LMEditorBrushDirtyDomain::NONE) {
		cache_hit_count.fetch_add(1, std::memory_order_relaxed);
		return value;
	}
	if (retained) cache_retained_bytes.fetch_sub(retained, std::memory_order_relaxed);
	value = lm_build_editor_brush_geometry(brush, context);
	retained = value.geometry.retained_bytes();
	cache_retained_bytes.fetch_add(retained, std::memory_order_relaxed);
	token = source_token;
	populated = bool(value);
	dirty = populated ? LMEditorBrushDirtyDomain::NONE : LMEditorBrushDirtyDomain::ALL;
	return value;
}

void LMEditorBrushCacheSlot::invalidate(LMEditorBrushDirtyDomain domains) {
	dirty = dirty | lm_editor_brush_dirty_dependencies(domains);
}

void LMEditorBrushCacheSlot::clear() {
	if (retained) cache_retained_bytes.fetch_sub(retained, std::memory_order_relaxed);
	value = {}; token = {}; dirty = LMEditorBrushDirtyDomain::ALL; retained = 0; populated = false;
}
