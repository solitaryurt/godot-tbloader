#pragma once

#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/area3d.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/static_body3d.hpp>

#include <map_parser.h>
#include <geo_generator.h>
#include <surface_gatherer.h>
#include <worldspawn_partitioner.h>

#include <map>

using namespace godot;

class TBLoader;

enum class ColliderType
{
	// Does not create any collider
	None,

	// Creates a collider from a Mesh (can create a single "merged" convex shape)
	Mesh,

	// Creates a static collider from a MeshInstance3D (can decompose into multiple convex shapes)
	Static,
};

enum class ColliderShape
{
	Convex,
	Concave,
};

struct BuilderBuildMetrics
{
	int64_t worldspawn_source_brush_items = 0;
	int64_t worldspawn_source_patch_items = 0;
	int64_t worldspawn_visual_triangles = 0;
	int64_t worldspawn_visual_chunks = 0;
	int64_t worldspawn_material_surfaces = 0;
	int64_t worldspawn_largest_chunk_triangles = 0;
	Vector3 worldspawn_largest_chunk_extent;
	int64_t worldspawn_collision_triangles = 0;
	int64_t worldspawn_collision_shapes = 0;
	int64_t worldspawn_oversized_input_items = 0;
	int64_t worldspawn_isolated_oversized_items = 0;
	int64_t worldspawn_sparse_merges = 0;
	int64_t worldspawn_budget_merges = 0;
	int64_t worldspawn_forced_nonadjacent_merges = 0;
	int64_t worldspawn_chunks_with_unmet_soft_limits = 0;
	double worldspawn_partition_duration_ms = 0.0;
};

struct BuilderWorldspawnChunkSettings
{
	bool enabled = false;
	LMWorldspawnPartitionSettings partition;
};

class Builder
{
public:
	TBLoader* m_loader;
	std::shared_ptr<LMMapData> m_map;
	Dictionary m_loaded_map_textures; // Texture Name(const char*) - Ref<Texture2D>
	Dictionary m_loaded_map_materials;
	Node3D* m_parent;
	Node* m_owner;
	String m_error;
	BuilderBuildMetrics m_metrics;
	BuilderWorldspawnChunkSettings m_worldspawn_chunk_settings;

public:
	Builder(TBLoader* loader, Node3D* parent = nullptr, const BuilderWorldspawnChunkSettings& chunk_settings = {});
	Builder(TBLoader* loader, Node3D* parent, std::shared_ptr<LMMapData> map, const BuilderWorldspawnChunkSettings& chunk_settings = {});
	~Builder();

	Dictionary load_map(const String& path);
	bool prepare_map_data();
	bool build_map();
	bool build_visual_map();
	Dictionary resolve_material(const String& token);
	Dictionary get_build_metrics() const;

	Node* build_worldspawn(int idx, LMEntity& ent, bool collision);
	void build_brush(int idx, Node3D* node, LMEntity& ent);

	Node* build_entity(int idx, LMEntity& ent, const String& classname, std::map<String, int>& entity_class_count);
	Node* build_entity_custom(int idx, LMEntity& ent, LMEntityGeometry& geo, const String& classname, std::map<String, int>& entity_class_count);
	Node* build_entity_light(int idx, LMEntity& ent);
	Node* build_entity_area(int idx, LMEntity& ent);
	Node* build_entity_sound(int idx, LMEntity& ent);

	void set_entity_node_common(Node3D* node, LMEntity& ent);
	void set_entity_brush_common(int idx, Node3D* node, LMEntity& ent);

protected:
	Vector3 lm_transform(const vec3& v);

	void add_collider_from_mesh(Node3D* area, Ref<ArrayMesh>& mesh, ColliderShape colshape, Color* debug_color = nullptr);
	void add_surface_to_mesh(Ref<ArrayMesh>& mesh, LMSurface& surf);
	MeshInstance3D* build_entity_mesh(int idx, LMEntity& ent, Node3D* parent, ColliderType coltype, ColliderShape colshape);
	MeshInstance3D* build_entity_visual_mesh(LMEntity& ent, Node3D* parent, const LMEntitySurfacePlan& plan, const String& instance_name,
			const std::vector<LMEntitySurfacePrimitive>* primitives = nullptr);
	bool build_entity_collisions(LMEntity& ent, Node3D* parent, const LMEntitySurfacePlan& plan, const String& instance_name, ColliderType coltype, ColliderShape colshape);

protected:
	void load_and_cache_map_textures();

	String texture_path(const char* name, const char* extension);
	String material_path(const char* name);
	Ref<Texture2D> texture_from_name(const char* name);
	Ref<Material> material_from_name(const char* name);

	void smooth_mesh_shading(MeshInstance3D* mesh_instance);
};
