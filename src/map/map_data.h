#ifndef LIBMAP_MAP_DATA_H
#define LIBMAP_MAP_DATA_H

#include "entity.h"
#include "entity_geometry.h"
#include "libmap.h"
#include <stddef.h>
#include <stdlib.h>
#include <memory>

typedef struct LMTextureData {
	char *name;
	int width;
	int height;
} LMTextureData;

typedef struct LMWorldspawnLayer {
	int texture_idx;
	bool build_visuals;
} LMWorldspawnLayer;

class LMMapData {
	int *texture_index = nullptr;
	int texture_index_capacity = 0;
	bool rebuild_texture_index(int minimum_capacity = 0);

public:
	int entity_count = 0;
	LMEntity *entities = NULL;
	LMEntityGeometry *entity_geo = NULL;
	int geometry_entity_count = 0;

	int texture_count = 0;
	LMTextureData *textures = NULL;

	int worldspawn_layer_count = 0;
	LMWorldspawnLayer *worldspawn_layers = NULL;

	void map_data_register_worldspawn_layer(const char *name, bool build_visuals);
	int map_data_find_worldspawn_layer(int texture_idx);
	int map_data_get_worldspawn_layer_count();
	LMWorldspawnLayer *map_data_get_worldspawn_layers();

	void map_data_set_texture_size(const char *name, int width, int height);
	int map_data_get_texture_count();
	LMTextureData *map_data_get_textures();
	LMTextureData *map_data_get_texture(int texture_idx);

	void map_data_set_spawn_type_by_classname(const char *key, int spawn_type);

	void map_data_print_entities();
	int map_data_get_entity_count();
	const LMEntity *map_data_get_entities();

	LMMapData();
	~LMMapData();
	LMMapData(const LMMapData &) = delete;
	LMMapData &operator=(const LMMapData &) = delete;
	size_t retained_bytes() const;
	std::shared_ptr<LMMapData> source_clone() const;
	std::shared_ptr<LMMapData> deep_clone() const;
	void swap(LMMapData &other);
	void map_data_free_geometry();
	void map_data_reset();
	int map_data_register_texture(const char *name);
	int map_data_find_texture(const char *texture_name);
	const char *map_data_get_entity_property(int entity_idx, const char *key);
};

#endif
