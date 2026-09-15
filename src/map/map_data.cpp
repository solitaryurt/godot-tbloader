#include "map_data.h"

#include "brush.h"
#include "face.h"
#include "patch.h"
#include "platform.h"

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <memory>
#include <utility>

namespace {
uint64_t texture_hash(const char *value) {
	uint64_t hash = 1469598103934665603ull;
	for (const unsigned char *p = reinterpret_cast<const unsigned char *>(value); *p; ++p) hash = (hash ^ *p) * 1099511628211ull;
	return hash;
}
char *clone_string(const char *source) {
	if (!source) return nullptr;
	const size_t bytes = strlen(source) + 1;
	auto *result = static_cast<char *>(malloc(bytes));
	memcpy(result, source, bytes);
	return result;
}
template <typename T>
T *clone_array(const T *source, int count) {
	if (!source || count <= 0) return nullptr;
	auto *result = static_cast<T *>(malloc(size_t(count) * sizeof(T)));
	memcpy(result, source, size_t(count) * sizeof(T));
	return result;
}
}

size_t LMMapData::retained_bytes() const {
	size_t bytes = sizeof(LMMapData);
	bytes += size_t(entity_count) * sizeof(LMEntity);
	for (int e = 0; e < entity_count; ++e) {
		const auto &entity = entities[e];
		bytes += size_t(entity.primitive_count) * sizeof(LMPrimitive);
		bytes += size_t(entity.property_count) * sizeof(LMProperty);
		for (int p = 0; p < entity.property_count; ++p) {
			bytes += entity.properties[p].key ? strlen(entity.properties[p].key) + 1 : 0;
			bytes += entity.properties[p].value ? strlen(entity.properties[p].value) + 1 : 0;
		}
		bytes += size_t(entity.brush_count) * sizeof(LMBrush);
		for (int b = 0; b < entity.brush_count; ++b) bytes += size_t(entity.brushes[b].face_count) * sizeof(LMFace);
		bytes += size_t(entity.patch_count) * sizeof(LMPatch);
		for (int p = 0; p < entity.patch_count; ++p) bytes += size_t(entity.patches[p].width) * size_t(entity.patches[p].height) * sizeof(LMPatchControlPoint);
	}
	bytes += size_t(texture_count) * sizeof(LMTextureData);
	for (int t = 0; t < texture_count; ++t) bytes += textures[t].name ? strlen(textures[t].name) + 1 : 0;
	bytes += size_t(texture_index_capacity) * sizeof(int);
	bytes += size_t(worldspawn_layer_count) * sizeof(LMWorldspawnLayer);
	bytes += size_t(geometry_entity_count) * sizeof(LMEntityGeometry);
	for (int e = 0; e < geometry_entity_count; ++e) {
		const auto &geometry = entity_geo[e];
		bytes += size_t(geometry.brush_count) * sizeof(LMBrushGeometry);
		for (int b = 0; b < geometry.brush_count; ++b) {
			const auto &brush = geometry.brushes[b];
			bytes += size_t(brush.face_count) * sizeof(LMFaceGeometry);
			for (int f = 0; f < brush.face_count; ++f) {
				bytes += size_t(brush.faces[f].vertex_count) * sizeof(LMFaceVertex);
				bytes += size_t(brush.faces[f].index_count) * sizeof(int);
			}
		}
		bytes += size_t(geometry.patch_count) * sizeof(LMPatchGeometry);
		for (int p = 0; p < geometry.patch_count; ++p) {
			bytes += size_t(geometry.patches[p].vertex_count) * sizeof(LMFaceVertex);
			bytes += size_t(geometry.patches[p].index_count) * sizeof(int);
		}
	}
	return bytes;
}

std::shared_ptr<LMMapData> LMMapData::source_clone() const {
	auto result = std::make_shared<LMMapData>();
	result->entity_count = entity_count;
	result->entities = static_cast<LMEntity *>(calloc(entity_count, sizeof(LMEntity)));
	for (int e = 0; e < entity_count; ++e) {
		const auto &source = entities[e];
		auto &target = result->entities[e];
		target = source;
		target.primitives = clone_array(source.primitives, source.primitive_count);
		target.properties = static_cast<LMProperty *>(calloc(source.property_count, sizeof(LMProperty)));
		for (int p = 0; p < source.property_count; ++p) {
			target.properties[p].key = clone_string(source.properties[p].key);
			target.properties[p].value = clone_string(source.properties[p].value);
		}
		target.brushes = static_cast<LMBrush *>(calloc(source.brush_count, sizeof(LMBrush)));
		for (int b = 0; b < source.brush_count; ++b) {
			target.brushes[b] = source.brushes[b];
			target.brushes[b].faces = clone_array(source.brushes[b].faces, source.brushes[b].face_count);
		}
		target.patches = static_cast<LMPatch *>(calloc(source.patch_count, sizeof(LMPatch)));
		for (int p = 0; p < source.patch_count; ++p) {
			target.patches[p] = source.patches[p];
			target.patches[p].control_points = clone_array(source.patches[p].control_points, source.patches[p].width * source.patches[p].height);
		}
	}
	result->texture_count = texture_count;
	result->textures = static_cast<LMTextureData *>(calloc(texture_count, sizeof(LMTextureData)));
	for (int t = 0; t < texture_count; ++t) {
		result->textures[t] = textures[t];
		result->textures[t].name = clone_string(textures[t].name);
	}
	if (texture_count) result->rebuild_texture_index();
	result->worldspawn_layer_count = worldspawn_layer_count;
	result->worldspawn_layers = clone_array(worldspawn_layers, worldspawn_layer_count);
	return result;
}

std::shared_ptr<LMMapData> LMMapData::deep_clone() const {
	auto result = source_clone();
	result->geometry_entity_count = geometry_entity_count;
	result->entity_geo = static_cast<LMEntityGeometry *>(calloc(geometry_entity_count, sizeof(LMEntityGeometry)));
	for (int e = 0; e < geometry_entity_count; ++e) {
		const auto &source = entity_geo[e];
		auto &target = result->entity_geo[e];
		target.brush_count = source.brush_count;
		target.patch_count = source.patch_count;
		target.brushes = static_cast<LMBrushGeometry *>(calloc(source.brush_count, sizeof(LMBrushGeometry)));
		for (int b = 0; b < source.brush_count; ++b) {
			target.brushes[b].face_count = source.brushes[b].face_count;
			target.brushes[b].faces = static_cast<LMFaceGeometry *>(calloc(source.brushes[b].face_count, sizeof(LMFaceGeometry)));
			for (int f = 0; f < source.brushes[b].face_count; ++f) {
				const auto &source_face = source.brushes[b].faces[f];
				auto &target_face = target.brushes[b].faces[f];
				target_face.vertex_count = source_face.vertex_count;
				target_face.index_count = source_face.index_count;
				target_face.vertices = clone_array(source_face.vertices, source_face.vertex_count);
				target_face.indices = clone_array(source_face.indices, source_face.index_count);
			}
		}
		target.patches = static_cast<LMPatchGeometry *>(calloc(source.patch_count, sizeof(LMPatchGeometry)));
		for (int p = 0; p < source.patch_count; ++p) {
			target.patches[p].vertex_count = source.patches[p].vertex_count;
			target.patches[p].index_count = source.patches[p].index_count;
			target.patches[p].vertices = clone_array(source.patches[p].vertices, source.patches[p].vertex_count);
			target.patches[p].indices = clone_array(source.patches[p].indices, source.patches[p].index_count);
		}
	}
	return result;
}

void LMMapData::map_data_free_geometry() {
	// Allocation counts belong to the cache, never to subsequently edited topology.
	if (entity_geo) {
		for (int e = 0; e < geometry_entity_count; ++e) {
			auto &geo = entity_geo[e];
			if (geo.brushes) for (int b = 0; b < geo.brush_count; ++b) {
				auto &brush = geo.brushes[b];
				if (brush.faces) for (int f = 0; f < brush.face_count; ++f) {
					free(brush.faces[f].vertices);
					free(brush.faces[f].indices);
				}
				free(brush.faces);
			}
			if (geo.patches) for (int p = 0; p < geo.patch_count; ++p) {
				free(geo.patches[p].vertices);
				free(geo.patches[p].indices);
			}
			free(geo.brushes);
			free(geo.patches);
		}
	}
	free(entity_geo);
	entity_geo = nullptr;
	geometry_entity_count = 0;
}

void LMMapData::map_data_reset() {
	map_data_free_geometry();
	for (int e = 0; e < entity_count; ++e) {
		auto &ent = entities[e];
		for (int b = 0; b < ent.brush_count; ++b) free(ent.brushes[b].faces);
		for (int p = 0; p < ent.patch_count; ++p) free(ent.patches[p].control_points);
		for (int p = 0; p < ent.property_count; ++p) {
			free(ent.properties[p].key);
			free(ent.properties[p].value);
		}
		free(ent.brushes);
		free(ent.patches);
		free(ent.properties);
		free(ent.primitives);
	}
	free(entities);
	entities = nullptr;
	entity_count = 0;
	for (int t = 0; t < texture_count; ++t) free(textures[t].name);
	free(textures);
	textures = nullptr;
	texture_count = 0;
	free(texture_index);
	texture_index = nullptr;
	texture_index_capacity = 0;
	free(worldspawn_layers);
	worldspawn_layers = nullptr;
	worldspawn_layer_count = 0;
}

LMMapData::~LMMapData() { map_data_reset(); }

void LMMapData::swap(LMMapData &other) {
	using std::swap;
	swap(entities, other.entities);
	swap(entity_count, other.entity_count);
	swap(entity_geo, other.entity_geo);
	swap(geometry_entity_count, other.geometry_entity_count);
	swap(textures, other.textures);
	swap(texture_count, other.texture_count);
	swap(texture_index, other.texture_index);
	swap(texture_index_capacity, other.texture_index_capacity);
	swap(worldspawn_layers, other.worldspawn_layers);
	swap(worldspawn_layer_count, other.worldspawn_layer_count);
}

void LMMapData::map_data_register_worldspawn_layer(const char *name, bool build_visuals) {
	worldspawn_layers = (LMWorldspawnLayer *)realloc(worldspawn_layers, (worldspawn_layer_count + 1) * sizeof(LMWorldspawnLayer));
	LMWorldspawnLayer *layer = &worldspawn_layers[worldspawn_layer_count];
	*layer = { 0 };
	layer->texture_idx = map_data_find_texture(name);
	layer->build_visuals = build_visuals;
	worldspawn_layer_count++;
}

int LMMapData::map_data_find_worldspawn_layer(int texture_idx) {
	for (int l = 0; l < worldspawn_layer_count; ++l) {
		LMWorldspawnLayer *layer = &worldspawn_layers[l];
		if (layer->texture_idx == texture_idx) {
			return l;
		}
	}

	return -1;
}

int LMMapData::map_data_get_worldspawn_layer_count() {
	return worldspawn_layer_count;
}

LMWorldspawnLayer *LMMapData::map_data_get_worldspawn_layers() {
	return worldspawn_layers;
}

int LMMapData::map_data_register_texture(const char *name) {
	int found = map_data_find_texture(name);
	if (found >= 0) return found;
	if (texture_count == INT32_MAX) return -1;
	if (texture_count + 1 > texture_index_capacity / 2) {
		if (texture_index_capacity > INT32_MAX / 2) return -1;
		if (!rebuild_texture_index(texture_index_capacity ? texture_index_capacity * 2 : 16)) return -1;
	}

	auto *grown = (LMTextureData *)realloc(textures, (texture_count + 1) * sizeof(LMTextureData));
	if (!grown) return -1;
	textures = grown;
	LMTextureData *texture = &textures[texture_count];
	*texture = { 0 };
	texture->name = STRDUP(name);
	if (!texture->name) return -1;
	texture->width = texture->height = 1;
	const int index = texture_count++;
	int slot = int(texture_hash(texture->name) & uint64_t(texture_index_capacity - 1));
	while (texture_index[slot]) slot = (slot + 1) & (texture_index_capacity - 1);
	texture_index[slot] = index + 1;
	return index;
}

void LMMapData::map_data_set_texture_size(const char *name, int width, int height) {
	for (int t = 0; t < texture_count; ++t) {
		LMTextureData *texture = &textures[t];
		if (strcmp(texture->name, name) == 0) {
			texture->width = width;
			texture->height = height;
			return;
		}
	}
}

int LMMapData::map_data_get_texture_count() {
	return texture_count;
}

LMTextureData *LMMapData::map_data_get_textures() {
	return textures;
}

LMTextureData *LMMapData::map_data_get_texture(int texture_idx) {
	if (texture_idx >= 0 && texture_idx < texture_count) {
		return &textures[texture_idx];
	}

	return NULL;
}

int LMMapData::map_data_find_texture(const char *texture_name) {
	if (!texture_index_capacity) {
		for (int i = 0; i < texture_count; ++i) if (!strcmp(textures[i].name, texture_name)) return i;
		return -1;
	}
	int slot = int(texture_hash(texture_name) & uint64_t(texture_index_capacity - 1));
	while (texture_index[slot]) {
		int index = texture_index[slot] - 1;
		if (!strcmp(textures[index].name, texture_name)) return index;
		slot = (slot + 1) & (texture_index_capacity - 1);
	}
	return -1;
}

bool LMMapData::rebuild_texture_index(int minimum_capacity) {
	if (texture_count > INT32_MAX / 2) return false;
	int capacity = 16;
	while (capacity < minimum_capacity || capacity < texture_count * 2) {
		if (capacity > INT32_MAX / 2) return false;
		capacity *= 2;
	}
	auto *slots = static_cast<int *>(calloc(size_t(capacity), sizeof(int)));
	if (!slots) return false;
	for (int i = 0; i < texture_count; ++i) {
		int slot = int(texture_hash(textures[i].name) & uint64_t(capacity - 1));
		while (slots[slot]) slot = (slot + 1) & (capacity - 1);
		slots[slot] = i + 1;
	}
	free(texture_index);
	texture_index = slots;
	texture_index_capacity = capacity;
	return true;
}

void LMMapData::map_data_set_spawn_type_by_classname(const char *key, int spawn_type) {
	for (int e = 0; e < entity_count; ++e) {
		LMEntity *ent = &entities[e];
		if (ent->property_count == 0) {
			continue;
		}

		for (int p = 0; p < ent->property_count; ++p) {
			LMProperty *prop = &ent->properties[p];
			if (strcmp(prop->key, "classname") == 0 && strcmp(prop->value, key) == 0) {
				ent->spawn_type = (ENTITY_SPAWN_TYPE)spawn_type;
				break;
			}
		}
	}
}

int LMMapData::map_data_get_entity_count() {
	return entity_count;
}

const LMEntity *LMMapData::map_data_get_entities() {
	return entities;
}

const char *LMMapData::map_data_get_entity_property(int entity_idx, const char *key) {
	if (entity_idx < 0 || entity_idx >= entity_count) {
		return NULL;
	}

	const LMEntity *ent = &entities[entity_idx];

	for (int p = 0; p < ent->property_count; ++p) {
		LMProperty *prop = &ent->properties[p];
		if (strcmp(prop->key, key) == 0) {
			return prop->value;
		}
	}

	return NULL;
}

void LMMapData::map_data_print_entities() {
	for (int e = 0; e < entity_count; ++e) {
		LMEntity entity_inst = entities[e];
		printf("Entity %d\n", e);
		for (int b = 0; b < entity_inst.brush_count; ++b) {
			LMBrush entity_brush = entity_inst.brushes[b];
			printf("Brush %d\n", b);
			printf("Face Count: %d\n", entity_brush.face_count);

			for (int f = 0; f < entity_brush.face_count; ++f) {
				LMFace brush_face = entity_brush.faces[f];
				printf("Face %d\n", f);
				printf(
						"(%f %f %f) (%f %f %f) (%f %f %f)\n%s %f %f\n[%f %f %f %f] [%f %f %f %f]\n%f %f %f\n\n",
						brush_face.plane_points.v0.x, brush_face.plane_points.v0.y, brush_face.plane_points.v0.z,
						brush_face.plane_points.v1.x, brush_face.plane_points.v1.y, brush_face.plane_points.v1.z,
						brush_face.plane_points.v2.x, brush_face.plane_points.v2.y, brush_face.plane_points.v2.z,

						map_data_get_texture(brush_face.texture_idx)->name,

						brush_face.uv_standard.u,
						brush_face.uv_standard.v,

						brush_face.uv_valve.u.axis.x, brush_face.uv_valve.u.axis.y, brush_face.uv_valve.u.axis.z, brush_face.uv_valve.u.offset,
						brush_face.uv_valve.v.axis.x, brush_face.uv_valve.v.axis.y, brush_face.uv_valve.v.axis.z, brush_face.uv_valve.v.offset,

						brush_face.uv_extra.rot,
						brush_face.uv_extra.scale_x,
						brush_face.uv_extra.scale_y);
			}

			putchar('\n');
		}
	}
}

LMMapData::LMMapData() {}
