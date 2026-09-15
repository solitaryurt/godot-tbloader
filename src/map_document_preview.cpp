#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <unordered_set>

using namespace godot;

namespace {
constexpr int FILTER_ENTITIES = 1;
constexpr int FILTER_CAULK = 2;
constexpr int FILTER_CLIPS = 4;
constexpr int FILTER_HINT_SKIP = 8;

// History retains only accounted native preview-index storage. The live cache is
// independent of this 64 MiB oldest-first history budget and is never evicted.
constexpr size_t PREVIEW_HISTORY_BYTE_BUDGET = size_t(64) * 1024 * 1024;
constexpr size_t PREVIEW_HISTORY_STATE_LIMIT = 2;

enum RenderCategory { RENDER_OPAQUE, RENDER_CAULK, RENDER_CLIP, RENDER_HINT_SKIP, RENDER_ENTITY, RENDER_CATEGORY_COUNT };

struct GroupKey {
	std::string texture;
	int category = 0;
	bool operator<(const GroupKey &other) const { return texture != other.texture ? texture < other.texture : category < other.category; }
	bool operator==(const GroupKey &other) const { return texture == other.texture && category == other.category; }
};

struct ChunkKey {
	int64_t x = 0, y = 0, z = 0;
	bool operator<(const ChunkKey &other) const { return x != other.x ? x < other.x : y != other.y ? y < other.y : z < other.z; }
};

bool entity_owned(const LMEntity &entity) {
	for (int i = 0; i < entity.property_count; ++i) if (!std::strcmp(entity.properties[i].key, "classname")) return std::strcmp(entity.properties[i].value, "worldspawn") != 0;
	return true;
}

std::string texture_basename(const char *name) {
	std::string normalized(name ? name : "");
	std::replace(normalized.begin(), normalized.end(), '\\', '/');
	const size_t slash = normalized.find_last_of('/');
	if (slash != std::string::npos) normalized.erase(0, slash + 1);
	const size_t dot = normalized.find_last_of('.');
	if (dot != std::string::npos) normalized.erase(dot);
	std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	return normalized;
}

RenderCategory material_category(const char *texture) {
	const std::string name = texture_basename(texture);
	if (name == "caulk") return RENDER_CAULK;
	if (name == "clip" || name.rfind("clip", 0) == 0 || (name.size() >= 4 && name.compare(name.size() - 4, 4, "clip") == 0)) return RENDER_CLIP;
	if (name == "hint_skip") return RENDER_HINT_SKIP;
	return RENDER_OPAQUE;
}

bool category_filtered(RenderCategory category, int mask) {
	return (category == RENDER_CAULK && (mask & FILTER_CAULK)) || (category == RENDER_CLIP && (mask & FILTER_CLIPS)) ||
			(category == RENDER_HINT_SKIP && (mask & FILTER_HINT_SKIP));
}

const char *category_name(RenderCategory category) {
	switch (category) {
		case RENDER_CAULK: return "caulk";
		case RENDER_CLIP: return "clip";
		case RENDER_HINT_SKIP: return "hint_skip";
		case RENDER_ENTITY: return "entity";
		default: return "opaque";
	}
}

Vector3 transformed(vec3 point, double scale) { return Vector3(point.y / scale, point.z / scale, point.x / scale); }
Vector3 transformed_normal(vec3 normal) { return Vector3(normal.y, normal.z, normal.x); }

void hash_scalar(uint64_t &hash, double value) {
	static_assert(sizeof(double) == sizeof(uint64_t) && std::numeric_limits<double>::is_iec559, "preview hashes require IEEE-754 binary64");
	uint64_t bits = 0;
	if (value == 0.0) bits = 0;
	else if (std::isnan(value)) bits = UINT64_C(0x7ff8000000000000);
	else std::memcpy(&bits, &value, sizeof(bits));
	for (int shift = 56; shift >= 0; shift -= 8) { hash ^= static_cast<uint8_t>(bits >> shift); hash *= UINT64_C(1099511628211); }
}
}

struct TBMapDocument::PreviewCache {
	struct Triangle {
		int64_t brush_id = 0;
		uint64_t source_order = 0;
		uint32_t entity = 0;
		uint32_t brush = 0;
		uint32_t face = 0;
		uint32_t first_index = 0;
	};
	static_assert(sizeof(Triangle) <= 40, "preview triangle descriptors must remain compact");

	struct ResolvedTriangle {
		vec3 normal{};
		vec3 points[3]{};
		LMVertexUV uvs[3]{};
	};
	struct Chunk {
		String id;
		GroupKey group;
		ChunkKey cell;
		uint32_t reference_begin = 0;
		uint32_t reference_count = 0;
		bool unchunked = false;
		String hash;
	};

	std::shared_ptr<LMMapData> source;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> base_geometry;
	std::shared_ptr<const EditorState> editor;
	int64_t state_generation = 0;
	double scale = 1.0;
	double chunk_size = 0.0;
	int filter_mask = 0;
	int chunk_triangles = 0;
	std::vector<int64_t> hidden_ids;
	std::vector<Triangle> triangles;
	std::vector<ChunkKey> triangle_cells;
	std::vector<uint32_t> triangle_groups;
	std::vector<uint32_t> free_triangles;
	std::vector<GroupKey> group_keys;
	std::map<GroupKey, uint32_t> group_ids;
	std::unordered_map<int64_t, std::vector<uint32_t>> brushes;
	std::map<GroupKey, std::vector<uint32_t>> groups;
	std::map<GroupKey, std::map<ChunkKey, std::vector<uint32_t>>> cells;
	std::vector<uint32_t> chunk_references;
	std::vector<Chunk> chunks;
	std::map<String, size_t> lookup;
	Dictionary manifest;
	int64_t buckets_changed = 0;
	int64_t buckets_unchanged = 0;
	int64_t descriptors_rebuilt = 0;
	int64_t descriptors_reused = 0;
	int64_t chunks_rehashed = 0;
	int64_t chunks_reused = 0;

	bool resolve(const Triangle &triangle, ResolvedTriangle &out) const {
		if (!source || triangle.entity >= static_cast<uint32_t>(source->entity_count)) return false;
		const auto &entity_source = source->entities[triangle.entity];
		if (triangle.brush >= static_cast<uint32_t>(entity_source.brush_count)) return false;
		const LMBrush &base_brush = entity_source.brushes[triangle.brush];
		if (base_brush.id != triangle.brush_id) return false;
		const LMBrush *brush_source = &base_brush;
		const LMEditorBrushGeometry *compact_geometry = nullptr;
		if (editor) {
			auto found = editor->brushes.find(triangle.brush_id);
			if (found != editor->brushes.end()) {
				brush_source = &found->second->brush;
				compact_geometry = found->second->geometry.get();
			}
		}
		if (!compact_geometry && base_geometry) { auto found = base_geometry->brushes.find(triangle.brush_id); if (found != base_geometry->brushes.end()) compact_geometry = found->second.get(); }
		if (triangle.face >= static_cast<uint32_t>(brush_source->face_count)) return false;
		out.normal = brush_source->faces[triangle.face].plane_normal;
		if (compact_geometry) {
			if (triangle.face >= compact_geometry->faces.size() || triangle.first_index + 2 >= compact_geometry->faces[triangle.face].index_count) return false;
			for (uint32_t corner = 0; corner < 3; ++corner) {
				const auto &item = compact_geometry->corners[compact_geometry->face_index(triangle.face, triangle.first_index + corner)];
				if (item.position >= compact_geometry->positions.size()) return false;
				out.points[corner] = compact_geometry->positions[item.position]; out.uvs[corner] = item.uv;
			}
		} else return false;
		return true;
	}

	size_t group_reference_count() const { size_t count = 0; for (const auto &group : groups) count += group.second.size(); return count; }
	size_t retained_bytes() const {
		size_t bytes = triangles.capacity() * sizeof(Triangle) + triangle_cells.capacity() * sizeof(ChunkKey) + triangle_groups.capacity() * sizeof(uint32_t) +
				free_triangles.capacity() * sizeof(uint32_t) + chunk_references.capacity() * sizeof(uint32_t);
		for (const auto &group : groups) bytes += group.second.capacity() * sizeof(uint32_t);
		for (const auto &brush : brushes) bytes += brush.second.capacity() * sizeof(uint32_t);
		for (const auto &group : cells) for (const auto &cell : group.second) bytes += cell.second.capacity() * sizeof(uint32_t);
		return bytes;
	}
};

namespace {
template <typename Cache, typename Chunk>
String chunk_hash(const Cache &cache, const Chunk &chunk) {
	uint64_t hash = UINT64_C(1469598103934665603);
	for (uint32_t i = 0; i < chunk.reference_count; ++i) {
		const uint32_t descriptor_index = cache.chunk_references[chunk.reference_begin + i];
		if (descriptor_index >= cache.triangles.size()) return String();
		typename Cache::ResolvedTriangle triangle;
		if (!cache.resolve(cache.triangles[descriptor_index], triangle)) return String();
		const Vector3 normal = transformed_normal(triangle.normal);
		for (uint32_t corner = 0; corner < 3; ++corner) {
			const Vector3 point = transformed(triangle.points[corner], cache.scale);
			for (int axis = 0; axis < 3; ++axis) hash_scalar(hash, static_cast<double>(point[axis]));
			for (int axis = 0; axis < 3; ++axis) hash_scalar(hash, static_cast<double>(normal[axis]));
			hash_scalar(hash, triangle.uvs[corner].u); hash_scalar(hash, triangle.uvs[corner].v);
		}
	}
	char text[17]; std::snprintf(text, sizeof(text), "%016llx", static_cast<unsigned long long>(hash)); return String(text);
}

template <typename Cache>
bool same_config(const Cache &cache, double scale, double chunk_size, int chunk_triangles, int filter_mask, const std::vector<int64_t> &hidden) {
	return cache.scale == scale && cache.chunk_size == chunk_size && cache.chunk_triangles == chunk_triangles && cache.filter_mask == filter_mask && cache.hidden_ids == hidden;
}
}

Dictionary TBMapDocument::prepare_preview_chunks(double scale, const PackedInt64Array &hidden_ids, int filter_mask, int chunk_triangles, double chunk_size) {
	if (!std::isfinite(scale) || scale <= 0 || !std::isfinite(chunk_size) || chunk_size <= 0 || chunk_triangles <= 0 || filter_mask < 0 || (filter_mask & ~(FILTER_ENTITIES | FILTER_CAULK | FILTER_CLIPS | FILTER_HINT_SKIP))) {
		preview_cache.reset(); preview_history_restored = false; return Dictionary();
	}
	std::vector<int64_t> hidden_key; hidden_key.reserve(hidden_ids.size());
	for (int i = 0; i < hidden_ids.size(); ++i) hidden_key.push_back(hidden_ids[i]);
	std::sort(hidden_key.begin(), hidden_key.end()); hidden_key.erase(std::unique(hidden_key.begin(), hidden_key.end()), hidden_key.end());
	if (preview_cache && preview_cache->state_generation == state_generation && same_config(*preview_cache, scale, chunk_size, chunk_triangles, filter_mask, hidden_key)) return preview_cache->manifest;

	std::shared_ptr<PreviewCache> previous;
	if (transition.compatible) for (auto it = preview_history.rbegin(); it != preview_history.rend(); ++it) {
		if ((*it)->state_generation == transition.from_generation && (*it)->source == map &&
				same_config(**it, scale, chunk_size, chunk_triangles, filter_mask, hidden_key) &&
				(*it)->group_keys.size() <= (*it)->groups.size() * 2 + 64) { previous = *it; break; }
	}
	std::unordered_set<int64_t> hidden(hidden_key.begin(), hidden_key.end());
	auto make_cache = [&]() {
		auto cache = std::make_shared<PreviewCache>();
		cache->source = map; cache->base_geometry = base_geometry; cache->editor = editor; cache->state_generation = state_generation; cache->scale = scale; cache->chunk_size = chunk_size;
		cache->chunk_triangles = chunk_triangles; cache->filter_mask = filter_mask; cache->hidden_ids = hidden_key; return cache;
	};
	auto prepared = make_cache();
	std::set<GroupKey> touched;
	std::map<GroupKey, std::set<ChunkKey>> touched_cells;
	auto triangle_cell = [&](const PreviewCache &cache, const PreviewCache::Triangle &triangle, ChunkKey &cell) {
		PreviewCache::ResolvedTriangle resolved; if (!cache.resolve(triangle, resolved)) return false;
		vec3 center{}; for (const vec3 point : resolved.points) center = vec3_add(center, point);
		const Vector3 point = transformed(vec3_div_double(center, 3.0), scale);
		double values[3] = {std::floor(point.x / chunk_size), std::floor(point.y / chunk_size), std::floor(point.z / chunk_size)};
		for (double value : values) if (!std::isfinite(value) || value < static_cast<double>(std::numeric_limits<int64_t>::min()) || value > static_cast<double>(std::numeric_limits<int64_t>::max())) return false;
		cell = {static_cast<int64_t>(values[0]), static_cast<int64_t>(values[1]), static_cast<int64_t>(values[2])}; return true;
	};
	auto group_id = [&](const GroupKey &key) {
		auto found = prepared->group_ids.find(key); if (found != prepared->group_ids.end()) return found->second;
		const uint32_t id = static_cast<uint32_t>(prepared->group_keys.size()); prepared->group_keys.push_back(key); prepared->group_ids[key] = id; return id;
	};
	auto descriptor_less = [&](uint32_t left, uint32_t right) {
		const auto &a = prepared->triangles[left]; const auto &b = prepared->triangles[right];
		if (a.entity != b.entity) return a.entity < b.entity; if (a.brush != b.brush) return a.brush < b.brush;
		if (a.face != b.face) return a.face < b.face; return a.first_index < b.first_index;
	};
	auto append_brush = [&](int e, int b, uint64_t &source_order, bool incremental) {
		const auto view = current_brush_geometry(e, b); if (!view.brush) return false;
		const auto &brush = *view.brush; const bool owned = entity_owned(map->entities[e]);
		for (int f = 0; f < brush.face_count; ++f) {
			const std::string texture = current_face_texture(e, b, f); const RenderCategory face_category = material_category(texture.c_str());
			const RenderCategory category = owned ? RENDER_ENTITY : face_category;
			const bool visible = !hidden.count(brush.id) && !((filter_mask & FILTER_ENTITIES) && owned) && !category_filtered(face_category, filter_mask);
			const uint32_t count = view.compact ? view.compact->faces[f].index_count : 0;
			for (uint32_t i = 0; i + 2 < count; i += 3, ++source_order) {
				if (!visible) continue;
				const GroupKey key{texture, category}; const uint32_t key_id = group_id(key);
				PreviewCache::Triangle triangle{brush.id, source_order, static_cast<uint32_t>(e), static_cast<uint32_t>(b), static_cast<uint32_t>(f), i};
				PreviewCache::ResolvedTriangle resolved; if (!prepared->resolve(triangle, resolved)) return false;
				for (const vec3 point : resolved.points) if (!transformed(point, scale).is_finite()) return false;
				ChunkKey cell; if (!triangle_cell(*prepared, triangle, cell)) return false;
				uint32_t index;
				if (incremental && !prepared->free_triangles.empty()) {
					index = prepared->free_triangles.back(); prepared->free_triangles.pop_back(); prepared->triangles[index] = triangle; prepared->triangle_cells[index] = cell; prepared->triangle_groups[index] = key_id;
				} else {
					if (prepared->triangles.size() >= UINT32_MAX) return false;
					index = static_cast<uint32_t>(prepared->triangles.size()); prepared->triangles.push_back(triangle); prepared->triangle_cells.push_back(cell); prepared->triangle_groups.push_back(key_id);
				}
				prepared->groups[key].push_back(index); prepared->brushes[brush.id].push_back(index);
				++prepared->descriptors_rebuilt;
				touched.insert(key); touched_cells[key].insert(cell);
			}
		}
		return true;
	};

	bool incremental = previous != nullptr;
	if (incremental) {
		prepared->triangles = previous->triangles; prepared->triangle_cells = previous->triangle_cells; prepared->triangle_groups = previous->triangle_groups; prepared->free_triangles = previous->free_triangles;
		prepared->group_keys = previous->group_keys; prepared->group_ids = previous->group_ids; prepared->brushes = previous->brushes;
		prepared->groups = previous->groups; prepared->cells = previous->cells;
		std::unordered_set<uint32_t> removed;
		for (int64_t id : transition.brush_ids) {
			const LiveLocation *location = live_location(id, 'b'); if (!location) { incremental = false; break; }
			auto found = prepared->brushes.find(id);
			if (found != prepared->brushes.end()) for (uint32_t index : found->second) {
				if (index >= prepared->triangles.size() || index >= prepared->triangle_cells.size() || index >= prepared->triangle_groups.size() || prepared->triangle_groups[index] >= prepared->group_keys.size()) { incremental = false; break; }
				const GroupKey &key = prepared->group_keys[prepared->triangle_groups[index]]; touched.insert(key); touched_cells[key].insert(prepared->triangle_cells[index]); removed.insert(index);
			}
			if (!incremental) break;
		}
		if (incremental) {
			for (const GroupKey &key : touched) {
				auto &descriptors = prepared->groups[key]; descriptors.erase(std::remove_if(descriptors.begin(), descriptors.end(), [&](uint32_t index) { return removed.count(index); }), descriptors.end());
				auto cell_group = prepared->cells.find(key);
				if (cell_group != prepared->cells.end()) for (const ChunkKey &cell : touched_cells[key]) {
					auto found = cell_group->second.find(cell); if (found == cell_group->second.end()) continue;
					found->second.erase(std::remove_if(found->second.begin(), found->second.end(), [&](uint32_t index) { return removed.count(index); }), found->second.end());
					if (found->second.empty()) cell_group->second.erase(found);
				}
			}
			for (int64_t id : transition.brush_ids) prepared->brushes.erase(id);
			prepared->free_triangles.insert(prepared->free_triangles.end(), removed.begin(), removed.end());
			uint64_t ignored_order = 0;
			for (int64_t id : transition.brush_ids) {
				const LiveLocation *location = live_location(id, 'b');
				if (!append_brush(location->entity, location->index, ignored_order, true)) { incremental = false; break; }
			}
		}
	}
	if (!incremental) {
		previous.reset(); prepared = make_cache(); touched.clear(); touched_cells.clear();
		uint64_t source_order = 0;
		for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) if (!append_brush(e, b, source_order, false)) return Dictionary();
		for (const auto &group : prepared->groups) {
			touched.insert(group.first);
			if (group.second.size() > static_cast<size_t>(chunk_triangles)) for (uint32_t index : group.second) prepared->cells[group.first][prepared->triangle_cells[index]].push_back(index);
		}
	} else {
		for (const GroupKey &key : touched) {
			auto group = prepared->groups.find(key); const auto old = previous->groups.find(key);
			const bool old_chunked = old != previous->groups.end() && old->second.size() > static_cast<size_t>(chunk_triangles);
			if (group == prepared->groups.end() || group->second.empty()) { prepared->groups.erase(key); prepared->cells.erase(key); continue; }
			std::sort(group->second.begin(), group->second.end(), descriptor_less);
			const bool new_chunked = group->second.size() > static_cast<size_t>(chunk_triangles);
			if (!new_chunked) { prepared->cells.erase(key); continue; }
			if (!old_chunked) {
				auto &cells = prepared->cells[key]; cells.clear();
				for (uint32_t index : group->second) { cells[prepared->triangle_cells[index]].push_back(index); touched_cells[key].insert(prepared->triangle_cells[index]); }
			} else {
				auto &cells = prepared->cells[key];
				for (uint32_t index : group->second) if (touched_cells[key].count(prepared->triangle_cells[index])) cells[prepared->triangle_cells[index]].push_back(index);
				for (const ChunkKey &cell : touched_cells[key]) {
					auto found = cells.find(cell); if (found == cells.end()) continue;
					std::sort(found->second.begin(), found->second.end(), descriptor_less);
					found->second.erase(std::unique(found->second.begin(), found->second.end()), found->second.end());
				}
			}
		}
	}

	auto append_chunk = [&](const GroupKey &group, const ChunkKey &cell, const std::vector<uint32_t> &indices, size_t begin, size_t end, bool unchunked, bool unchanged, int64_t subdivision = -1) {
		if (prepared->chunk_references.size() + end - begin > UINT32_MAX) return false;
		PreviewCache::Chunk chunk; chunk.group = group; chunk.cell = cell; chunk.unchunked = unchunked;
		chunk.reference_begin = static_cast<uint32_t>(prepared->chunk_references.size()); chunk.reference_count = static_cast<uint32_t>(end - begin);
		prepared->chunk_references.insert(prepared->chunk_references.end(), indices.begin() + begin, indices.begin() + end);
		const String texture = String::utf8(group.texture.c_str());
		chunk.id = unchunked ? texture + String("|all") : texture + String("|") + String::num_int64(cell.x) + String(",") + String::num_int64(cell.y) + String(",") + String::num_int64(cell.z);
		if (subdivision >= 0) chunk.id += String("|") + String::num_int64(subdivision);
		if (group.category != RENDER_OPAQUE) chunk.id += String("|") + String(category_name(static_cast<RenderCategory>(group.category)));
		if (unchanged && previous) { const auto old = previous->lookup.find(chunk.id); if (old != previous->lookup.end()) { chunk.hash = previous->chunks[old->second].hash; ++prepared->chunks_reused; } }
		if (chunk.hash.is_empty()) { chunk.hash = chunk_hash(*prepared, chunk); ++prepared->chunks_rehashed; } if (chunk.hash.is_empty()) return false;
		prepared->chunks.push_back(std::move(chunk)); return true;
	};
	prepared->chunk_references.reserve(prepared->group_reference_count());
	int64_t changed_buckets = 0, unchanged_buckets = 0;
	for (const auto &group : prepared->groups) {
		const auto &descriptors = group.second; const bool unchunked = descriptors.size() <= static_cast<size_t>(chunk_triangles);
		auto old_group = previous ? previous->groups.find(group.first) : decltype(previous->groups.find(group.first)){};
		const bool old_exists = previous && old_group != previous->groups.end();
		const bool old_unchunked = old_exists && old_group->second.size() <= static_cast<size_t>(chunk_triangles);
		if (unchunked) {
			const bool unchanged = previous && old_unchunked && !touched.count(group.first);
			if (!append_chunk(group.first, {}, descriptors, 0, descriptors.size(), true, unchanged)) return Dictionary();
			if (unchanged) ++unchanged_buckets; else ++changed_buckets;
			continue;
		}
		const auto &cells = prepared->cells[group.first];
		for (const auto &cell : cells) {
			const bool unchanged = old_exists && !old_unchunked && !touched_cells[group.first].count(cell.first);
			if (unchanged) ++unchanged_buckets; else ++changed_buckets;
			for (size_t begin = 0, subdivision = 0; begin < cell.second.size(); begin += chunk_triangles, ++subdivision) {
				const size_t end = std::min(begin + static_cast<size_t>(chunk_triangles), cell.second.size());
				if (!append_chunk(group.first, cell.first, cell.second, begin, end, false, unchanged, cell.second.size() > static_cast<size_t>(chunk_triangles) ? static_cast<int64_t>(subdivision) : -1)) return Dictionary();
			}
		}
		if (old_exists && !old_unchunked) for (const auto &cell : touched_cells[group.first]) if (!cells.count(cell)) ++changed_buckets;
	}
	if (previous) for (const auto &group : previous->groups) if (!prepared->groups.count(group.first) && touched.count(group.first)) {
		if (group.second.size() <= static_cast<size_t>(chunk_triangles)) ++changed_buckets; else changed_buckets += touched_cells[group.first].size();
	}
	if (!incremental) { prepared->triangles.shrink_to_fit(); prepared->triangle_cells.shrink_to_fit(); prepared->triangle_groups.shrink_to_fit(); }
	prepared->chunk_references.shrink_to_fit(); for (auto &group : prepared->groups) group.second.shrink_to_fit();

	Array manifest_chunks; manifest_chunks.resize(prepared->chunks.size()); int64_t total_triangles = 0;
	for (size_t i = 0; i < prepared->chunks.size(); ++i) {
		const auto &chunk = prepared->chunks[i]; Dictionary item;
		item["chunk_id"] = chunk.id; item["texture"] = String::utf8(chunk.group.texture.c_str());
		item["render_category"] = String(category_name(static_cast<RenderCategory>(chunk.group.category)));
		item["triangle_count"] = static_cast<int64_t>(chunk.reference_count); item["geometry_hash"] = chunk.hash; item["geometry_version"] = 1;
		prepared->lookup[chunk.id] = i; manifest_chunks[i] = item; total_triangles += chunk.reference_count;
	}
	Dictionary manifest; manifest["schema"] = 1; manifest["triangle_count"] = total_triangles; manifest["chunks"] = manifest_chunks; prepared->manifest = manifest;
	prepared->descriptors_reused = incremental ? static_cast<int64_t>(prepared->group_reference_count()) - prepared->descriptors_rebuilt : 0;
	prepared->buckets_changed = changed_buckets; prepared->buckets_unchanged = unchanged_buckets;
	preview_cache = std::move(prepared); preview_history_restored = false; return manifest;
}

void TBMapDocument::retain_preview_cache() {
	if (!preview_cache) return;
	preview_history.erase(std::remove_if(preview_history.begin(), preview_history.end(), [&](const auto &cached) { return cached->state_generation == preview_cache->state_generation; }), preview_history.end());
	preview_history.push_back(preview_cache);
	size_t retained = 0;
	for (const auto &cached : preview_history) {
		const size_t bytes = cached->retained_bytes();
		retained = bytes > std::numeric_limits<size_t>::max() - retained ? std::numeric_limits<size_t>::max() : retained + bytes;
	}
	while (!preview_history.empty() && (preview_history.size() > PREVIEW_HISTORY_STATE_LIMIT || retained > PREVIEW_HISTORY_BYTE_BUDGET)) {
		const size_t bytes = preview_history.front()->retained_bytes();
		retained = bytes > retained ? 0 : retained - bytes;
		preview_history.erase(preview_history.begin());
		++preview_history_evictions;
	}
}

void TBMapDocument::clear_preview_caches() { preview_cache.reset(); preview_history.clear(); preview_history_evictions = 0; preview_history_restored = false; }

void TBMapDocument::restore_preview_cache() {
	preview_cache.reset(); preview_history_restored = true;
	for (auto it = preview_history.rbegin(); it != preview_history.rend(); ++it) if ((*it)->state_generation == state_generation) { preview_cache = *it; break; }
}

Dictionary TBMapDocument::get_preview_chunk(const String &chunk_id) const {
	auto cache = preview_cache;
	if (preview_history_restored && (!cache || cache->state_generation != state_generation)) for (auto it = preview_history.rbegin(); it != preview_history.rend(); ++it) if ((*it)->state_generation == state_generation) { cache = *it; break; }
	if (!cache || cache->state_generation != state_generation) return Dictionary();
	const auto found = cache->lookup.find(chunk_id); if (found == cache->lookup.end()) return Dictionary();
	const auto &chunk = cache->chunks[found->second];
	PackedVector3Array vertices, normals; PackedVector2Array uvs;
	vertices.resize(chunk.reference_count * 3); normals.resize(chunk.reference_count * 3); uvs.resize(chunk.reference_count * 3);
	uint32_t output = 0;
	for (uint32_t i = 0; i < chunk.reference_count; ++i) {
		const uint32_t descriptor_index = cache->chunk_references[chunk.reference_begin + i]; if (descriptor_index >= cache->triangles.size()) return Dictionary();
		PreviewCache::ResolvedTriangle triangle; if (!cache->resolve(cache->triangles[descriptor_index], triangle)) return Dictionary();
		for (uint32_t corner = 0; corner < 3; ++corner, ++output) {
			vertices.set(output, transformed(triangle.points[corner], cache->scale)); normals.set(output, transformed_normal(triangle.normal)); uvs.set(output, Vector2(triangle.uvs[corner].u, triangle.uvs[corner].v));
		}
	}
	Dictionary result; result["schema"] = 1; result["chunk_id"] = chunk.id; result["texture"] = String::utf8(chunk.group.texture.c_str());
	result["render_category"] = String(category_name(static_cast<RenderCategory>(chunk.group.category))); result["triangle_count"] = static_cast<int64_t>(chunk.reference_count);
	result["geometry_hash"] = chunk.hash; result["geometry_version"] = 1; result["vertices"] = vertices; result["normals"] = normals; result["uvs"] = uvs; return result;
}

Dictionary TBMapDocument::get_preview_cache_counters() const {
	Dictionary out;
	size_t history_bytes = 0; for (const auto &cached : preview_history) history_bytes += cached->retained_bytes();
	out["history_byte_budget"] = static_cast<int64_t>(PREVIEW_HISTORY_BYTE_BUDGET);
	out["history_state_limit"] = static_cast<int64_t>(PREVIEW_HISTORY_STATE_LIMIT);
	out["history_state_count"] = static_cast<int64_t>(preview_history.size());
	out["history_evictions"] = preview_history_evictions;
	out["legacy_triangle_size"] = int64_t(160); out["descriptor_size"] = int64_t(sizeof(PreviewCache::Triangle));
	if (!preview_cache) {
		out["descriptor_count"] = int64_t(0); out["descriptor_bytes"] = int64_t(0);
		out["group_reference_count"] = int64_t(0); out["group_reference_bytes"] = int64_t(0);
		out["chunk_reference_count"] = int64_t(0); out["chunk_reference_bytes"] = int64_t(0);
		out["logical_bytes"] = int64_t(0); out["retained_bytes"] = int64_t(0); out["indexed_retained_bytes"] = int64_t(0); out["history_retained_bytes"] = static_cast<int64_t>(history_bytes);
		out["descriptors_rebuilt"] = int64_t(0); out["descriptors_reused"] = int64_t(0); out["chunks_rehashed"] = int64_t(0); out["chunks_reused"] = int64_t(0);
		out["buckets_changed"] = int64_t(0); out["buckets_unchanged"] = int64_t(0); return out;
	}
	size_t group_bytes = 0; for (const auto &group : preview_cache->groups) group_bytes += group.second.capacity() * sizeof(uint32_t);
	const size_t descriptor_bytes = preview_cache->triangles.capacity() * sizeof(PreviewCache::Triangle);
	const size_t chunk_bytes = preview_cache->chunk_references.capacity() * sizeof(uint32_t);
	out["descriptor_count"] = static_cast<int64_t>(preview_cache->group_reference_count());
	out["descriptor_bytes"] = static_cast<int64_t>(descriptor_bytes);
	out["group_reference_count"] = static_cast<int64_t>(preview_cache->group_reference_count()); out["group_reference_bytes"] = static_cast<int64_t>(group_bytes);
	out["chunk_reference_count"] = static_cast<int64_t>(preview_cache->chunk_references.size()); out["chunk_reference_bytes"] = static_cast<int64_t>(chunk_bytes);
	out["logical_bytes"] = static_cast<int64_t>(preview_cache->group_reference_count() * sizeof(PreviewCache::Triangle) +
			preview_cache->group_reference_count() * sizeof(uint32_t) + preview_cache->chunk_references.size() * sizeof(uint32_t));
	out["retained_bytes"] = static_cast<int64_t>(descriptor_bytes + group_bytes + chunk_bytes);
	out["indexed_retained_bytes"] = static_cast<int64_t>(preview_cache->retained_bytes());
	out["history_retained_bytes"] = static_cast<int64_t>(history_bytes);
	out["descriptors_rebuilt"] = preview_cache->descriptors_rebuilt; out["descriptors_reused"] = preview_cache->descriptors_reused;
	out["chunks_rehashed"] = preview_cache->chunks_rehashed; out["chunks_reused"] = preview_cache->chunks_reused;
	out["buckets_changed"] = preview_cache->buckets_changed; out["buckets_unchanged"] = preview_cache->buckets_unchanged; return out;
}
