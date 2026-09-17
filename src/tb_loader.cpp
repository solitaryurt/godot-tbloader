#include <tb_loader.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <builder.h>
#include <map_document.h>
#include <chrono>
#include <cmath>
#include <vector>

void TBLoader::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("set_map", "map_resource"), &TBLoader::set_map);
	ClassDB::bind_method(D_METHOD("get_map"), &TBLoader::get_map);
	ClassDB::bind_method(D_METHOD("set_inverse_scale", "map_inverse_scale"), &TBLoader::set_inverse_scale);
	ClassDB::bind_method(D_METHOD("get_inverse_scale"), &TBLoader::get_inverse_scale);

	ClassDB::bind_method(D_METHOD("set_lighting_unwrap_texel_size", "lighting_unwrap_texel_size"), &TBLoader::set_lighting_unwrap_texel_size);
	ClassDB::bind_method(D_METHOD("get_lighting_unwrap_texel_size"), &TBLoader::get_lighting_unwrap_texel_size);
	ClassDB::bind_method(D_METHOD("set_lighting_unwrap_uv2", "lighting_unwrap_uv2"), &TBLoader::set_lighting_unwrap_uv2);
	ClassDB::bind_method(D_METHOD("get_lighting_unwrap_uv2"), &TBLoader::get_lighting_unwrap_uv2);

	ClassDB::bind_method(D_METHOD("set_collision", "option_collision"), &TBLoader::set_collision);
	ClassDB::bind_method(D_METHOD("get_collision"), &TBLoader::get_collision);
	ClassDB::bind_method(D_METHOD("set_filter_nearest", "option_filter_nearest"), &TBLoader::set_filter_nearest);
	ClassDB::bind_method(D_METHOD("get_filter_nearest"), &TBLoader::get_filter_nearest);
	ClassDB::bind_method(D_METHOD("set_skip_hidden_layers", "option_skip_hidden_layers"), &TBLoader::set_skip_hidden_layers);
	ClassDB::bind_method(D_METHOD("get_skip_hidden_layers"), &TBLoader::get_skip_hidden_layers);
	ClassDB::bind_method(D_METHOD("set_skip_empty_meshes", "option_skip_empty_meshes"), &TBLoader::set_skip_empty_meshes);
	ClassDB::bind_method(D_METHOD("get_skip_empty_meshes"), &TBLoader::get_skip_empty_meshes);
	ClassDB::bind_method(D_METHOD("set_clip_texture_name", "option_clip_texture_name"), &TBLoader::set_clip_texture_name);
	ClassDB::bind_method(D_METHOD("get_clip_texture_name"), &TBLoader::get_clip_texture_name);
	ClassDB::bind_method(D_METHOD("set_cushion_texture_name", "option_cushion_texture_name"), &TBLoader::set_cushion_texture_name);
	ClassDB::bind_method(D_METHOD("get_cushion_texture_name"), &TBLoader::get_cushion_texture_name);
	ClassDB::bind_method(D_METHOD("set_ladder_texture_name", "option_ladder_texture_name"), &TBLoader::set_ladder_texture_name);
	ClassDB::bind_method(D_METHOD("get_ladder_texture_name"), &TBLoader::get_ladder_texture_name);
	ClassDB::bind_method(D_METHOD("set_no_wall_jump_texture_name", "option_no_wall_jump_texture_name"), &TBLoader::set_no_wall_jump_texture_name);
	ClassDB::bind_method(D_METHOD("get_no_wall_jump_texture_name"), &TBLoader::get_no_wall_jump_texture_name);
	ClassDB::bind_method(D_METHOD("set_skip_texture_name", "option_skip_texture_name"), &TBLoader::set_skip_texture_name);
	ClassDB::bind_method(D_METHOD("get_skip_texture_name"), &TBLoader::get_skip_texture_name);
	ClassDB::bind_method(D_METHOD("set_visual_layer_mask", "option_visual_layer_mask"), &TBLoader::set_visual_layer_mask);
	ClassDB::bind_method(D_METHOD("get_visual_layer_mask"), &TBLoader::get_visual_layer_mask);
	ClassDB::bind_method(D_METHOD("set_skybox_layer_mask", "option_skybox_layer_mask"), &TBLoader::set_skybox_layer_mask);
	ClassDB::bind_method(D_METHOD("get_skybox_layer_mask"), &TBLoader::get_skybox_layer_mask);
	ClassDB::bind_method(D_METHOD("set_collision_layer_mask", "option_collision_layer_mask"), &TBLoader::set_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_collision_layer_mask"), &TBLoader::get_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("set_clip_collision_layer_mask", "option_collision_layer_mask"), &TBLoader::set_clip_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_clip_collision_layer_mask"), &TBLoader::get_clip_collision_layer_mask);

	ClassDB::bind_method(D_METHOD("set_entity_common", "entity_common"), &TBLoader::set_entity_common);
	ClassDB::bind_method(D_METHOD("get_entity_common"), &TBLoader::get_entity_common);
	ClassDB::bind_method(D_METHOD("set_entity_path", "entity_path"), &TBLoader::set_entity_path);
	ClassDB::bind_method(D_METHOD("get_entity_path"), &TBLoader::get_entity_path);

	ClassDB::bind_method(D_METHOD("set_texture_path", "texture_path"), &TBLoader::set_texture_path);
	ClassDB::bind_method(D_METHOD("get_texture_path"), &TBLoader::get_texture_path);
	ClassDB::bind_method(D_METHOD("set_material_template", "material"), &TBLoader::set_material_template);
	ClassDB::bind_method(D_METHOD("get_material_template"), &TBLoader::get_material_template);
	ClassDB::bind_method(D_METHOD("set_material_texture_path", "texture_path"), &TBLoader::set_material_texture_path);
	ClassDB::bind_method(D_METHOD("get_material_texture_path"), &TBLoader::get_material_texture_path);

	ClassDB::bind_method(D_METHOD("set_worldspawn_chunking_enabled", "enabled"), &TBLoader::set_worldspawn_chunking_enabled);
	ClassDB::bind_method(D_METHOD("get_worldspawn_chunking_enabled"), &TBLoader::get_worldspawn_chunking_enabled);
	ClassDB::bind_method(D_METHOD("set_worldspawn_chunk_size", "size"), &TBLoader::set_worldspawn_chunk_size);
	ClassDB::bind_method(D_METHOD("get_worldspawn_chunk_size"), &TBLoader::get_worldspawn_chunk_size);
	ClassDB::bind_method(D_METHOD("set_worldspawn_chunk_triangles", "triangles"), &TBLoader::set_worldspawn_chunk_triangles);
	ClassDB::bind_method(D_METHOD("get_worldspawn_chunk_triangles"), &TBLoader::get_worldspawn_chunk_triangles);
	ClassDB::bind_method(D_METHOD("set_worldspawn_max_chunks", "max_chunks"), &TBLoader::set_worldspawn_max_chunks);
	ClassDB::bind_method(D_METHOD("get_worldspawn_max_chunks"), &TBLoader::get_worldspawn_max_chunks);

	ClassDB::bind_method(D_METHOD("clear"), &TBLoader::clear);
	ClassDB::bind_method(D_METHOD("build_meshes"), &TBLoader::build_meshes);
	ClassDB::bind_method(D_METHOD("build_meshes_checked"), &TBLoader::build_meshes_checked);
	ClassDB::bind_method(D_METHOD("build_visual_preview_checked", "document", "target"), &TBLoader::build_visual_preview_checked);
	ClassDB::bind_method(D_METHOD("resolve_material", "token"), &TBLoader::resolve_material);
	ADD_SIGNAL(MethodInfo("map_resource_changed", PropertyInfo(Variant::STRING, "path")));

	ADD_GROUP("Map", "map_");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "map_resource", PROPERTY_HINT_FILE, "*.map"), "set_map", "get_map");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "map_inverse_scale", PROPERTY_HINT_NONE, "Inverse Scale"), "set_inverse_scale", "get_inverse_scale");

	ADD_GROUP("Lighting", "lighting_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "lighting_unwrap_uv2"), "set_lighting_unwrap_uv2", "get_lighting_unwrap_uv2");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lighting_unwrap_texel_size", PROPERTY_HINT_NONE, "Unwrap Texel Size"), "set_lighting_unwrap_texel_size", "get_lighting_unwrap_texel_size");

	ADD_GROUP("Options", "option_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "option_collision"), "set_collision", "get_collision");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "option_filter_nearest"), "set_filter_nearest", "get_filter_nearest");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "option_skip_hidden_layers", PROPERTY_HINT_NONE, "Skip Hidden Layers"), "set_skip_hidden_layers", "get_skip_hidden_layers");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "option_skip_empty_meshes", PROPERTY_HINT_NONE, "Skip Empty Meshes"), "set_skip_empty_meshes", "get_skip_empty_meshes");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_clip_texture_name", PROPERTY_HINT_NONE, "Clip Texture"), "set_clip_texture_name", "get_clip_texture_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_ladder_texture_name", PROPERTY_HINT_NONE, "Ladder Texture"), "set_ladder_texture_name", "get_ladder_texture_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_cushion_texture_name", PROPERTY_HINT_NONE, "Cushion Texture"), "set_cushion_texture_name", "get_cushion_texture_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_no_wall_jump_texture_name", PROPERTY_HINT_NONE, "No Wall Jump Texture"), "set_no_wall_jump_texture_name", "get_no_wall_jump_texture_name");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_skip_texture_name", PROPERTY_HINT_NONE, "skip Texture"), "set_skip_texture_name", "get_skip_texture_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "option_visual_layer_mask", PROPERTY_HINT_LAYERS_3D_RENDER), "set_visual_layer_mask", "get_visual_layer_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "option_skybox_layer_mask", PROPERTY_HINT_LAYERS_3D_RENDER), "set_skybox_layer_mask", "get_skybox_layer_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "option_collision_layer_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_collision_layer_mask", "get_collision_layer_mask");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "option_clip_collision_layer_mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_clip_collision_layer_mask", "get_clip_collision_layer_mask");

	ADD_GROUP("Entities", "entity_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "entity_common", PROPERTY_HINT_NONE, "Common Entities"), "set_entity_common", "get_entity_common");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "entity_path", PROPERTY_HINT_DIR, "Entity Path"), "set_entity_path", "get_entity_path");

	ADD_GROUP("Textures", "texture_");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "texture_path", PROPERTY_HINT_DIR, "Textures Path"), "set_texture_path", "get_texture_path");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "texture_material_template", PROPERTY_HINT_RESOURCE_TYPE, "Material"), "set_material_template", "get_material_template");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "texture_material_texture_path", PROPERTY_HINT_NONE, "Material Texture Property Path"), "set_material_texture_path", "get_material_texture_path");

	ADD_GROUP("Worldspawn Chunking", "worldspawn_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "worldspawn_chunking_enabled"), "set_worldspawn_chunking_enabled", "get_worldspawn_chunking_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "worldspawn_chunk_size", PROPERTY_HINT_RANGE, "0.001,1024,0.001,or_greater,suffix:m"), "set_worldspawn_chunk_size", "get_worldspawn_chunk_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worldspawn_chunk_triangles", PROPERTY_HINT_RANGE, "1,1000000,1,or_greater"), "set_worldspawn_chunk_triangles", "get_worldspawn_chunk_triangles");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "worldspawn_max_chunks", PROPERTY_HINT_RANGE, "1,4096,1,or_greater"), "set_worldspawn_max_chunks", "get_worldspawn_max_chunks");
}

TBLoader::TBLoader()
{
}

TBLoader::~TBLoader()
{
}

void TBLoader::set_worldspawn_chunking_enabled(bool enabled)
{
	m_worldspawn_chunking_enabled = enabled;
}

bool TBLoader::get_worldspawn_chunking_enabled() const
{
	return m_worldspawn_chunking_enabled;
}

void TBLoader::set_worldspawn_chunk_size(double size)
{
	m_worldspawn_chunk_size = size;
}

double TBLoader::get_worldspawn_chunk_size() const
{
	return m_worldspawn_chunk_size;
}

void TBLoader::set_worldspawn_chunk_triangles(int64_t triangles)
{
	m_worldspawn_chunk_triangles = triangles;
}

int64_t TBLoader::get_worldspawn_chunk_triangles() const
{
	return m_worldspawn_chunk_triangles;
}

void TBLoader::set_worldspawn_max_chunks(int64_t max_chunks)
{
	m_worldspawn_max_chunks = max_chunks;
}

int64_t TBLoader::get_worldspawn_max_chunks() const
{
	return m_worldspawn_max_chunks;
}

void TBLoader::set_map(const String& map)
{
	if (m_map_path == map) return;
	m_map_path = map;
	emit_signal("map_resource_changed", m_map_path);
}

String TBLoader::get_map() const
{
	return m_map_path;
}

void TBLoader::set_inverse_scale(int scale)
{
	m_inverse_scale = scale;
}

int TBLoader::get_inverse_scale()
{
	return m_inverse_scale;
}

void TBLoader::set_lighting_unwrap_uv2(bool enabled)
{
	m_lighting_unwrap_uv2 = enabled;
}

bool TBLoader::get_lighting_unwrap_uv2()
{
	return m_lighting_unwrap_uv2;
}

void TBLoader::set_lighting_unwrap_texel_size(double size)
{
	m_lighting_unwrap_texel_size = size;
}

double TBLoader::get_lighting_unwrap_texel_size()
{
	return m_lighting_unwrap_texel_size;
}

void TBLoader::set_collision(bool enabled)
{
	m_collision = enabled;
}

bool TBLoader::get_collision()
{
	return m_collision;
}

void TBLoader::set_skip_hidden_layers(bool enabled)
{
	m_skip_hidden_layers = enabled;
}

bool TBLoader::get_skip_hidden_layers()
{
	return m_skip_hidden_layers;
}

void TBLoader::set_skip_empty_meshes(bool enabled)
{
	m_skip_empty_meshes = enabled;
}

bool TBLoader::get_skip_empty_meshes()
{
	return m_skip_empty_meshes;
}

void TBLoader::set_filter_nearest(bool enabled)
{
	m_filter_nearest = enabled;
}

bool TBLoader::get_filter_nearest()
{
	return m_filter_nearest;
}

void TBLoader::set_clip_texture_name(const String& clip_texture_name)
{
	m_clip_texture_name = clip_texture_name;
}

String TBLoader::get_clip_texture_name()
{
	return m_clip_texture_name;
}

void TBLoader::set_ladder_texture_name(const String& ladder_texture_name)
{
	m_ladder_texture_name = ladder_texture_name;
}

String TBLoader::get_ladder_texture_name()
{
	return m_ladder_texture_name;
}

void TBLoader::set_cushion_texture_name(const String& cushion_texture_name)
{
	m_cushion_texture_name = cushion_texture_name;
}

String TBLoader::get_cushion_texture_name()
{
	return m_cushion_texture_name;
}

void TBLoader::set_no_wall_jump_texture_name(const String& no_wall_jump_texture_name)
{
	m_no_wall_jump_texture_name = no_wall_jump_texture_name;
}

String TBLoader::get_no_wall_jump_texture_name()
{
	return m_no_wall_jump_texture_name;
}

void TBLoader::set_skip_texture_name(const String& skip_texture_name)
{
	m_skip_texture_name = skip_texture_name;
}

String TBLoader::get_skip_texture_name()
{
	return m_skip_texture_name;
}

uint32_t TBLoader::get_visual_layer_mask()
{
	return m_visual_layer_mask;
}

void TBLoader::set_visual_layer_mask(uint32_t visual_layer_mask)
{
	m_visual_layer_mask = visual_layer_mask;
}

uint32_t TBLoader::get_skybox_layer_mask()
{
	return m_skybox_layer_mask;
}

void TBLoader::set_skybox_layer_mask(uint32_t skybox_layer_mask)
{
	m_skybox_layer_mask = skybox_layer_mask;
}

uint32_t TBLoader::get_collision_layer_mask()
{
	return m_collision_layer_mask;
}

void TBLoader::set_collision_layer_mask(uint32_t collision_layer_mask)
{
	m_collision_layer_mask = collision_layer_mask;
}

uint32_t TBLoader::get_clip_collision_layer_mask()
{
	return m_clip_collision_layer_mask;
}

void TBLoader::set_clip_collision_layer_mask(uint32_t collision_layer_mask)
{
	m_clip_collision_layer_mask = collision_layer_mask;
}

void TBLoader::set_entity_common(bool enabled)
{
	m_entity_common = enabled;
}

bool TBLoader::get_entity_common()
{
	return m_entity_common;
}

void TBLoader::set_entity_path(const String& path)
{
	m_entity_path = path;
}

String TBLoader::get_entity_path()
{
	return m_entity_path;
}

void TBLoader::set_texture_path(const String& path)
{
	if (path.is_empty()) {
		UtilityFunctions::push_warning("WARNING: texture_path should not be empty");
	}
	m_texture_path = path;
}

String TBLoader::get_texture_path()
{
	return m_texture_path;
}

void TBLoader::set_material_template(const Ref<Material>& material)
{
	m_material_template = material;
}

Ref<Material> TBLoader::get_material_template()
{
	return m_material_template;
}

void TBLoader::set_material_texture_path(const String& texture_path)
{
	m_material_texture_path = texture_path;
}

String TBLoader::get_material_texture_path()
{
	return m_material_texture_path;
}

bool TBLoader::get_validated_worldspawn_chunk_settings(BuilderWorldspawnChunkSettings& settings, String& error) const
{
	settings.enabled = m_worldspawn_chunking_enabled;
	if (!settings.enabled) return true;

	const double map_extent = m_worldspawn_chunk_size * static_cast<double>(m_inverse_scale);
	if (!std::isfinite(m_worldspawn_chunk_size) || m_worldspawn_chunk_size <= 0.0 || !std::isfinite(map_extent) || map_extent <= 0.0) {
		error = "Worldspawn chunk size must convert to a finite positive map-space extent";
		return false;
	}
	if (m_worldspawn_chunk_triangles <= 0 || m_worldspawn_max_chunks <= 0) {
		error = "Worldspawn chunk triangle target and maximum chunk count must be positive";
		return false;
	}
	settings.partition.target_extent = map_extent;
	settings.partition.target_triangles = m_worldspawn_chunk_triangles;
	settings.partition.max_chunks = m_worldspawn_max_chunks;
	return true;
}

void TBLoader::clear()
{
	while (get_child_count() > 0) {
		auto child = get_child(0);
		remove_child(child);
		child->queue_free();
	}
}

void TBLoader::build_meshes()
{
	Dictionary result = build_meshes_checked();
	if (!bool(result["ok"])) {
		Dictionary error = result["error"];
		UtilityFunctions::printerr("Map bake failed: ", error["message"], " (", error["path"], ":", error["line"], ":", error["column"], ")");
	}
}

namespace {
Dictionary build_failure(const StringName& code, const String& message, const String& path, const StringName& operation)
{
	Dictionary error;
	error["code"] = code; error["message"] = message; error["operation"] = operation; error["path"] = path;
	error["line"] = 0; error["column"] = 0; error["entity_id"] = int64_t(0); error["brush_id"] = int64_t(0); error["face"] = -1;
	Dictionary result;
	result["ok"] = false; result["changed"] = false; result["value"] = Variant(); result["error"] = error;
	return result;
}
void collect_generated_owners(Node* node, Node* owner, std::vector<Node*>& nodes)
{
	if (node->get_owner() == owner) nodes.push_back(node);
	for (int i = 0; i < node->get_child_count(); ++i) collect_generated_owners(node->get_child(i), owner, nodes);
}
}

Dictionary TBLoader::build_meshes_checked()
{
	if (m_building) return build_failure("BUSY", "A map build is already in progress", m_map_path, "build_meshes_checked");
	if (m_inverse_scale <= 0 || (m_lighting_unwrap_uv2 && (!std::isfinite(m_lighting_unwrap_texel_size) || m_lighting_unwrap_texel_size <= 0))) {
		return build_failure("INVALID_ARGUMENT", "Inverse scale and lightmap texel size must be positive and finite", m_map_path, "build_meshes_checked");
	}
	BuilderWorldspawnChunkSettings chunk_settings;
	String settings_error;
	if (!get_validated_worldspawn_chunk_settings(chunk_settings, settings_error)) {
		return build_failure("INVALID_ARGUMENT", settings_error, m_map_path, "build_meshes_checked");
	}
	m_building = true;
	auto build_started = std::chrono::steady_clock::now();
	auto staging = memnew(Node3D());
	Builder builder(this, staging, chunk_settings);
	Dictionary result = builder.load_map(m_map_path);
	if (!bool(result["ok"])) {
		Dictionary error = result["error"];
		error["operation"] = StringName("build_meshes_checked");
	} else if (!builder.m_error.is_empty()) {
		result = build_failure("RESOURCE_LOAD_FAILED", builder.m_error, m_map_path, "build_meshes_checked");
	} else if (!builder.build_map()) {
		result = build_failure("GENERATION_FAILED", builder.m_error, m_map_path, "build_meshes_checked");
	} else {
		// Only generated ownership changes. Owners internal to instantiated scenes
		// remain internal; the staging owner is replaced by the edited scene owner.
		std::vector<Node*> generated;
		collect_generated_owners(staging, staging, generated);
		Node* scene_owner = get_owner() ? get_owner() : this;
		int count = staging->get_child_count();
		bool changed = get_child_count() > 0 || count > 0;
		for (Node* node : generated) node->set_owner(nullptr);
		clear();
		while (staging->get_child_count() > 0) {
			Node* child = staging->get_child(0);
			staging->remove_child(child);
			add_child(child);
		}
		for (Node* node : generated) node->set_owner(scene_owner);
		Dictionary value;
		value["path"] = m_map_path;
		value["child_count"] = count;
		Dictionary metrics = builder.get_build_metrics();
		metrics["total_build_duration_ms"] = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - build_started).count();
		value["metrics"] = metrics;
		result["ok"] = true; result["changed"] = changed; result["value"] = value; result["error"] = Dictionary();
	}
	memdelete(staging);
	m_building = false;
	return result;
}

Dictionary TBLoader::build_visual_preview_checked(const Ref<TBMapDocument>& document, Node3D* target)
{
	const StringName operation = "build_visual_preview_checked";
	String path = document.is_valid() ? document->get_path() : String();
	if (m_building) return build_failure("BUSY", "A map build is already in progress", path, operation);
	if (document.is_null() || !target) return build_failure("INVALID_ARGUMENT", "Document and preview target are required", path, operation);
	if (m_inverse_scale <= 0 || (m_lighting_unwrap_uv2 && (!std::isfinite(m_lighting_unwrap_texel_size) || m_lighting_unwrap_texel_size <= 0))) {
		return build_failure("INVALID_ARGUMENT", "Inverse scale and lightmap texel size must be positive and finite", path, operation);
	}
	BuilderWorldspawnChunkSettings chunk_settings;
	String settings_error;
	if (!get_validated_worldspawn_chunk_settings(chunk_settings, settings_error)) {
		return build_failure("INVALID_ARGUMENT", settings_error, path, operation);
	}
	m_building = true;
	auto staging = memnew(Node3D());
	Builder builder(this, staging, document->clone_map_for_build(), chunk_settings);
	Dictionary result;
	if (!builder.prepare_map_data()) {
		result = build_failure("RESOURCE_LOAD_FAILED", builder.m_error, path, operation);
	} else if (!builder.build_visual_map()) {
		result = build_failure("GENERATION_FAILED", builder.m_error, path, operation);
	} else {
		std::vector<Node*> generated;
		collect_generated_owners(staging, staging, generated);
		for (Node* node : generated) node->set_owner(nullptr);
		while (target->get_child_count() > 0) {
			Node* child = target->get_child(0);
			target->remove_child(child);
			child->queue_free();
		}
		int count = staging->get_child_count();
		while (staging->get_child_count() > 0) {
			Node* child = staging->get_child(0);
			staging->remove_child(child);
			target->add_child(child);
		}
		Dictionary value;
		value["child_count"] = count;
		value["document_epoch"] = document->get_epoch();
		value["document_revision"] = document->get_revision();
		result["ok"] = true; result["changed"] = true; result["value"] = value; result["error"] = Dictionary();
	}
	memdelete(staging);
	m_building = false;
	return result;
}

Dictionary TBLoader::resolve_material(const String& token)
{
	return Builder(this).resolve_material(token);
}
