#include "map_document.h"
#include "map/brush.h"
#include "map/entity_geometry.h"
#include "map/face.h"
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <unordered_set>

using namespace godot;

struct TBMapDocument::PreviewCache {
	struct Triangle {
		int entity;
		int brush;
		int face;
		int indices[3];
	};
	struct Chunk {
		String id;
		int texture;
		int render_category;
		std::vector<Triangle> triangles;
		String hash;
	};
	std::shared_ptr<LMMapData> source;
	double scale = 1.0;
	std::vector<Chunk> chunks;
	std::map<String, size_t> lookup;
};

namespace {
constexpr int FILTER_ENTITIES = 1;
constexpr int FILTER_CAULK = 2;
constexpr int FILTER_CLIPS = 4;
constexpr int FILTER_HINT_SKIP = 8;

enum RenderCategory {
	RENDER_OPAQUE,
	RENDER_CAULK,
	RENDER_CLIP,
	RENDER_HINT_SKIP,
	RENDER_ENTITY,
	RENDER_CATEGORY_COUNT,
};

struct ChunkKey {
	int64_t x = 0, y = 0, z = 0;
	bool operator<(const ChunkKey &other) const {
		if (x != other.x) return x < other.x;
		if (y != other.y) return y < other.y;
		return z < other.z;
	}
};

bool entity_owned(const LMEntity &entity) {
	for (int i = 0; i < entity.property_count; ++i) {
		if (!std::strcmp(entity.properties[i].key, "classname")) return std::strcmp(entity.properties[i].value, "worldspawn") != 0;
	}
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
	if (value == 0.0) {
		bits = 0;
	} else if (std::isnan(value)) {
		bits = UINT64_C(0x7ff8000000000000);
	} else {
		std::memcpy(&bits, &value, sizeof(bits));
	}
	for (int shift = 56; shift >= 0; shift -= 8) {
		hash ^= static_cast<uint8_t>(bits >> shift);
		hash *= UINT64_C(1099511628211);
	}
}

template <typename Chunk>
String chunk_hash(const Chunk &chunk, const LMMapData &map, double scale) {
	uint64_t hash = UINT64_C(1469598103934665603);
	for (const auto &triangle : chunk.triangles) {
		const auto &brush = map.entities[triangle.entity].brushes[triangle.brush];
		const auto &face = map.entity_geo[triangle.entity].brushes[triangle.brush].faces[triangle.face];
		for (int corner = 0; corner < 3; ++corner) {
			const auto &vertex = face.vertices[triangle.indices[corner]];
			const Vector3 point = transformed(vertex.vertex, scale);
			const Vector3 normal = transformed_normal(brush.faces[triangle.face].plane_normal);
			for (int axis = 0; axis < 3; ++axis) hash_scalar(hash, static_cast<double>(point[axis]));
			for (int axis = 0; axis < 3; ++axis) hash_scalar(hash, static_cast<double>(normal[axis]));
			hash_scalar(hash, static_cast<double>(vertex.uv.u));
			hash_scalar(hash, static_cast<double>(vertex.uv.v));
		}
	}
	char text[17];
	std::snprintf(text, sizeof(text), "%016llx", static_cast<unsigned long long>(hash));
	return String(text);
}
}

Dictionary TBMapDocument::prepare_preview_chunks(double scale, const PackedInt64Array &hidden_ids, int filter_mask, int chunk_triangles, double chunk_size) {
	preview_cache.reset();
	if (!std::isfinite(scale) || scale <= 0 || !std::isfinite(chunk_size) || chunk_size <= 0 || chunk_triangles <= 0 || filter_mask < 0 || (filter_mask & ~(FILTER_ENTITIES | FILTER_CAULK | FILTER_CLIPS | FILTER_HINT_SKIP))) return Dictionary();

	auto prepared = std::make_shared<PreviewCache>();
	prepared->source = map;
	prepared->scale = scale;
	std::unordered_set<int64_t> hidden;
	for (int i = 0; i < hidden_ids.size(); ++i) hidden.insert(hidden_ids[i]);

	std::vector<std::array<std::vector<PreviewCache::Triangle>, RENDER_CATEGORY_COUNT>> textures(map->texture_count);
	for (int e = 0; e < map->entity_count; ++e) {
		const auto &entity = map->entities[e];
		const bool owned = entity_owned(entity);
		if ((filter_mask & FILTER_ENTITIES) && owned) continue;
		for (int b = 0; b < entity.brush_count; ++b) {
			const auto &brush = entity.brushes[b];
			if (hidden.count(brush.id)) continue;
			const auto &geometry = map->entity_geo[e].brushes[b];
			for (int f = 0; f < brush.face_count; ++f) {
				const int texture = brush.faces[f].texture_idx;
				const RenderCategory face_category = material_category(map->textures[texture].name);
				if (category_filtered(face_category, filter_mask)) continue;
				const RenderCategory category = owned ? RENDER_ENTITY : face_category;
				const auto &face = geometry.faces[f];
				for (int i = 0; i + 2 < face.index_count; i += 3) {
					bool finite = true;
					for (int corner = 0; corner < 3; ++corner) finite = finite && transformed(face.vertices[face.indices[i + corner]].vertex, scale).is_finite();
					if (!finite) return Dictionary();
					textures[texture][category].push_back({e, b, f, {face.indices[i], face.indices[i + 1], face.indices[i + 2]}});
				}
			}
		}
	}

	Array manifest_chunks;
	int64_t total_triangles = 0;
	for (int texture = 0; texture < map->texture_count; ++texture) {
		for (int category_value = RENDER_OPAQUE; category_value < RENDER_CATEGORY_COUNT; ++category_value) {
			const RenderCategory category = static_cast<RenderCategory>(category_value);
			auto &triangles = textures[texture][category];
			if (triangles.empty()) continue;
			std::map<ChunkKey, std::vector<PreviewCache::Triangle>> groups;
			const bool unchunked = triangles.size() <= static_cast<size_t>(chunk_triangles);
			if (!unchunked) {
				for (const auto &triangle : triangles) {
					const auto &face = map->entity_geo[triangle.entity].brushes[triangle.brush].faces[triangle.face];
					vec3 center{};
					for (int corner = 0; corner < 3; ++corner) center = vec3_add(center, face.vertices[triangle.indices[corner]].vertex);
					const Vector3 point = transformed(vec3_div_double(center, 3.0), scale);
					if (!point.is_finite()) return Dictionary();
					double cells[3] = {std::floor(point.x / chunk_size), std::floor(point.y / chunk_size), std::floor(point.z / chunk_size)};
					for (double cell : cells) if (!std::isfinite(cell) || cell < static_cast<double>(std::numeric_limits<int64_t>::min()) || cell > static_cast<double>(std::numeric_limits<int64_t>::max())) return Dictionary();
					groups[{static_cast<int64_t>(cells[0]), static_cast<int64_t>(cells[1]), static_cast<int64_t>(cells[2])}].push_back(triangle);
				}
			}
			auto append_chunk = [&](const ChunkKey &key, std::vector<PreviewCache::Triangle> &&group_triangles, int64_t subdivision = -1) {
				PreviewCache::Chunk chunk;
				chunk.texture = texture;
				chunk.render_category = category;
				chunk.triangles = std::move(group_triangles);
				const String texture_name = String::utf8(map->textures[texture].name);
				chunk.id = unchunked ? texture_name + String("|all") : texture_name + String("|") + String::num_int64(key.x) + String(",") + String::num_int64(key.y) + String(",") + String::num_int64(key.z);
				if (subdivision >= 0) chunk.id += String("|") + String::num_int64(subdivision);
				if (category != RENDER_OPAQUE) chunk.id += String("|") + String(category_name(category));
				chunk.hash = chunk_hash(chunk, *map, scale);
				Dictionary item;
				item["chunk_id"] = chunk.id;
				item["texture"] = texture_name;
				item["render_category"] = String(category_name(category));
				item["triangle_count"] = static_cast<int64_t>(chunk.triangles.size());
				item["geometry_hash"] = chunk.hash;
				item["geometry_version"] = 1;
				prepared->lookup[chunk.id] = prepared->chunks.size();
				prepared->chunks.push_back(std::move(chunk));
				manifest_chunks.push_back(item);
				total_triangles += int64_t(item["triangle_count"]);
			};
			if (unchunked) {
				append_chunk({}, std::move(triangles));
			} else {
				for (auto &group : groups) {
					auto &cell_triangles = group.second;
					if (cell_triangles.size() <= static_cast<size_t>(chunk_triangles)) {
						append_chunk(group.first, std::move(cell_triangles));
						continue;
					}
					for (size_t begin = 0, subdivision = 0; begin < cell_triangles.size(); begin += chunk_triangles, ++subdivision) {
						const size_t end = std::min(begin + static_cast<size_t>(chunk_triangles), cell_triangles.size());
						std::vector<PreviewCache::Triangle> batch(cell_triangles.begin() + begin, cell_triangles.begin() + end);
						append_chunk(group.first, std::move(batch), static_cast<int64_t>(subdivision));
					}
				}
			}
		}
	}
	Dictionary manifest;
	manifest["schema"] = 1;
	manifest["triangle_count"] = total_triangles;
	manifest["chunks"] = manifest_chunks;
	preview_cache = std::move(prepared);
	return manifest;
}

Dictionary TBMapDocument::get_preview_chunk(const String &chunk_id) const {
	if (!preview_cache || preview_cache->source != map) return Dictionary();
	const auto found = preview_cache->lookup.find(chunk_id);
	if (found == preview_cache->lookup.end()) return Dictionary();
	const auto &chunk = preview_cache->chunks[found->second];
	PackedVector3Array vertices, normals;
	PackedVector2Array uvs;
	for (const auto &triangle : chunk.triangles) {
		const auto &brush = map->entities[triangle.entity].brushes[triangle.brush];
		const auto &face = map->entity_geo[triangle.entity].brushes[triangle.brush].faces[triangle.face];
		for (int corner = 0; corner < 3; ++corner) {
			const auto &vertex = face.vertices[triangle.indices[corner]];
			vertices.push_back(transformed(vertex.vertex, preview_cache->scale));
			normals.push_back(transformed_normal(brush.faces[triangle.face].plane_normal));
			uvs.push_back(Vector2(vertex.uv.u, vertex.uv.v));
		}
	}
	Dictionary result;
	result["schema"] = 1;
	result["chunk_id"] = chunk.id;
	result["texture"] = String::utf8(map->textures[chunk.texture].name);
	result["render_category"] = String(category_name(static_cast<RenderCategory>(chunk.render_category)));
	result["triangle_count"] = static_cast<int64_t>(chunk.triangles.size());
	result["geometry_hash"] = chunk.hash;
	result["geometry_version"] = 1;
	result["vertices"] = vertices;
	result["normals"] = normals;
	result["uvs"] = uvs;
	return result;
}
