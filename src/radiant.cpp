#include <radiant.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <builder.h>
#include <map_document.h>
#include <cmath>
#include <vector>

void Radiant::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("set_map", "map_resource"), &Radiant::set_map);
	ClassDB::bind_method(D_METHOD("get_map"), &Radiant::get_map);
	ClassDB::bind_method(D_METHOD("set_inverse_scale", "map_inverse_scale"), &Radiant::set_inverse_scale);
	ClassDB::bind_method(D_METHOD("get_inverse_scale"), &Radiant::get_inverse_scale);

	ClassDB::bind_method(D_METHOD("set_lighting_unwrap_texel_size", "lighting_unwrap_texel_size"), &Radiant::set_lighting_unwrap_texel_size);
	ClassDB::bind_method(D_METHOD("get_lighting_unwrap_texel_size"), &Radiant::get_lighting_unwrap_texel_size);
	ClassDB::bind_method(D_METHOD("set_lighting_unwrap_uv2", "lighting_unwrap_uv2"), &Radiant::set_lighting_unwrap_uv2);
	ClassDB::bind_method(D_METHOD("get_lighting_unwrap_uv2"), &Radiant::get_lighting_unwrap_uv2);

	ClassDB::bind_method(D_METHOD("set_collision", "option_collision"), &Radiant::set_collision);
	ClassDB::bind_method(D_METHOD("get_collision"), &Radiant::get_collision);
	ClassDB::bind_method(D_METHOD("set_filter_nearest", "option_filter_nearest"), &Radiant::set_filter_nearest);
	ClassDB::bind_method(D_METHOD("get_filter_nearest"), &Radiant::get_filter_nearest);
	ClassDB::bind_method(D_METHOD("set_skip_hidden_layers", "option_skip_hidden_layers"), &Radiant::set_skip_hidden_layers);
	ClassDB::bind_method(D_METHOD("get_skip_hidden_layers"), &Radiant::get_skip_hidden_layers);
	ClassDB::bind_method(D_METHOD("set_skip_empty_meshes", "option_skip_empty_meshes"), &Radiant::set_skip_empty_meshes);
	ClassDB::bind_method(D_METHOD("get_skip_empty_meshes"), &Radiant::get_skip_empty_meshes);
	ClassDB::bind_method(D_METHOD("set_clip_texture_name", "option_clip_texture_name"), &Radiant::set_clip_texture_name);
	ClassDB::bind_method(D_METHOD("get_clip_texture_name"), &Radiant::get_clip_texture_name);
	ClassDB::bind_method(D_METHOD("set_cushion_texture_name", "option_cushion_texture_name"), &Radiant::set_cushion_texture_name);
	ClassDB::bind_method(D_METHOD("get_cushion_texture_name"), &Radiant::get_cushion_texture_name);
	ClassDB::bind_method(D_METHOD("set_ladder_texture_name", "option_ladder_texture_name"), &Radiant::set_ladder_texture_name);
	ClassDB::bind_method(D_METHOD("get_ladder_texture_name"), &Radiant::get_ladder_texture_name);
	ClassDB::bind_method(D_METHOD("set_no_wall_jump_texture_name", "option_no_wall_jump_texture_name"), &Radiant::set_no_wall_jump_texture_name);
	ClassDB::bind_method(D_METHOD("get_no_wall_jump_texture_name"), &Radiant::get_no_wall_jump_texture_name);
	ClassDB::bind_method(D_METHOD("set_skip_texture_name", "option_skip_texture_name"), &Radiant::set_skip_texture_name);
	ClassDB::bind_method(D_METHOD("get_skip_texture_name"), &Radiant::get_skip_texture_name);
	ClassDB::bind_method(D_METHOD("set_lightmap_hull", "option_lightmap_hull"), &Radiant::set_lightmap_hull);
	ClassDB::bind_method(D_METHOD("get_lightmap_hull"), &Radiant::get_lightmap_hull);
	ClassDB::bind_method(D_METHOD("set_visual_layer_mask", "option_visual_layer_mask"), &Radiant::set_visual_layer_mask);
	ClassDB::bind_method(D_METHOD("get_visual_layer_mask"), &Radiant::get_visual_layer_mask);
	ClassDB::bind_method(D_METHOD("set_skybox_layer_mask", "option_skybox_layer_mask"), &Radiant::set_skybox_layer_mask);
	ClassDB::bind_method(D_METHOD("get_skybox_layer_mask"), &Radiant::get_skybox_layer_mask);
	ClassDB::bind_method(D_METHOD("set_collision_layer_mask", "option_collision_layer_mask"), &Radiant::set_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_collision_layer_mask"), &Radiant::get_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("set_clip_collision_layer_mask", "option_collision_layer_mask"), &Radiant::set_clip_collision_layer_mask);
	ClassDB::bind_method(D_METHOD("get_clip_collision_layer_mask"), &Radiant::get_clip_collision_layer_mask);

	ClassDB::bind_method(D_METHOD("set_entity_common", "entity_common"), &Radiant::set_entity_common);
	ClassDB::bind_method(D_METHOD("get_entity_common"), &Radiant::get_entity_common);
	ClassDB::bind_method(D_METHOD("set_entity_path", "entity_path"), &Radiant::set_entity_path);
	ClassDB::bind_method(D_METHOD("get_entity_path"), &Radiant::get_entity_path);

	ClassDB::bind_method(D_METHOD("set_texture_path", "texture_path"), &Radiant::set_texture_path);
	ClassDB::bind_method(D_METHOD("get_texture_path"), &Radiant::get_texture_path);
	ClassDB::bind_method(D_METHOD("set_material_template", "material"), &Radiant::set_material_template);
	ClassDB::bind_method(D_METHOD("get_material_template"), &Radiant::get_material_template);
	ClassDB::bind_method(D_METHOD("set_material_texture_path", "texture_path"), &Radiant::set_material_texture_path);
	ClassDB::bind_method(D_METHOD("get_material_texture_path"), &Radiant::get_material_texture_path);

	ClassDB::bind_method(D_METHOD("clear"), &Radiant::clear);
	ClassDB::bind_method(D_METHOD("build_meshes"), &Radiant::build_meshes);
	ClassDB::bind_method(D_METHOD("build_meshes_checked"), &Radiant::build_meshes_checked);
	ClassDB::bind_method(D_METHOD("build_visual_preview_checked", "document", "target"), &Radiant::build_visual_preview_checked);
	ClassDB::bind_method(D_METHOD("resolve_material", "token"), &Radiant::resolve_material);
	ADD_SIGNAL(MethodInfo("map_resource_changed", PropertyInfo(Variant::STRING, "path")));
	ADD_SIGNAL(MethodInfo("bake_finished"));

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
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "option_lightmap_hull", PROPERTY_HINT_NONE, "lightmap hull"), "set_lightmap_hull", "get_lightmap_hull");
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
}

Radiant::Radiant()
{
}

Radiant::~Radiant()
{
}

void Radiant::set_map(const String& map)
{
	if (m_map_path == map) return;
	m_map_path = map;
	emit_signal("map_resource_changed", m_map_path);
}

String Radiant::get_map() const
{
	return m_map_path;
}

void Radiant::set_inverse_scale(int scale)
{
	m_inverse_scale = scale;
}

int Radiant::get_inverse_scale()
{
	return m_inverse_scale;
}

void Radiant::set_lighting_unwrap_uv2(bool enabled)
{
	m_lighting_unwrap_uv2 = enabled;
}

bool Radiant::get_lighting_unwrap_uv2()
{
	return m_lighting_unwrap_uv2;
}

void Radiant::set_lighting_unwrap_texel_size(double size)
{
	m_lighting_unwrap_texel_size = size;
}

double Radiant::get_lighting_unwrap_texel_size()
{
	return m_lighting_unwrap_texel_size;
}

void Radiant::set_collision(bool enabled)
{
	m_collision = enabled;
}

bool Radiant::get_collision()
{
	return m_collision;
}

void Radiant::set_skip_hidden_layers(bool enabled)
{
	m_skip_hidden_layers = enabled;
}

bool Radiant::get_skip_hidden_layers()
{
	return m_skip_hidden_layers;
}

void Radiant::set_skip_empty_meshes(bool enabled)
{
	m_skip_empty_meshes = enabled;
}

bool Radiant::get_skip_empty_meshes()
{
	return m_skip_empty_meshes;
}

void Radiant::set_filter_nearest(bool enabled)
{
	m_filter_nearest = enabled;
}

bool Radiant::get_filter_nearest()
{
	return m_filter_nearest;
}

void Radiant::set_clip_texture_name(const String& clip_texture_name)
{
	m_clip_texture_name = clip_texture_name;
}

String Radiant::get_clip_texture_name()
{
	return m_clip_texture_name;
}

void Radiant::set_ladder_texture_name(const String& ladder_texture_name)
{
	m_ladder_texture_name = ladder_texture_name;
}

String Radiant::get_ladder_texture_name()
{
	return m_ladder_texture_name;
}

void Radiant::set_cushion_texture_name(const String& cushion_texture_name)
{
	m_cushion_texture_name = cushion_texture_name;
}

String Radiant::get_cushion_texture_name()
{
	return m_cushion_texture_name;
}

void Radiant::set_no_wall_jump_texture_name(const String& no_wall_jump_texture_name)
{
	m_no_wall_jump_texture_name = no_wall_jump_texture_name;
}

String Radiant::get_no_wall_jump_texture_name()
{
	return m_no_wall_jump_texture_name;
}

void Radiant::set_skip_texture_name(const String& skip_texture_name)
{
	m_skip_texture_name = skip_texture_name;
}

String Radiant::get_skip_texture_name()
{
	return m_skip_texture_name;
}

void Radiant::set_lightmap_hull(const String& lightmap_hull)
{
	m_lightmap_hull = lightmap_hull;
}

String Radiant::get_lightmap_hull()
{
	return m_lightmap_hull;
}

uint32_t Radiant::get_visual_layer_mask()
{
	return m_visual_layer_mask;
}

void Radiant::set_visual_layer_mask(uint32_t visual_layer_mask)
{
	m_visual_layer_mask = visual_layer_mask;
}

uint32_t Radiant::get_skybox_layer_mask()
{
	return m_skybox_layer_mask;
}

void Radiant::set_skybox_layer_mask(uint32_t skybox_layer_mask)
{
	m_skybox_layer_mask = skybox_layer_mask;
}

uint32_t Radiant::get_collision_layer_mask()
{
	return m_collision_layer_mask;
}

void Radiant::set_collision_layer_mask(uint32_t collision_layer_mask)
{
	m_collision_layer_mask = collision_layer_mask;
}

uint32_t Radiant::get_clip_collision_layer_mask()
{
	return m_clip_collision_layer_mask;
}

void Radiant::set_clip_collision_layer_mask(uint32_t collision_layer_mask)
{
	m_clip_collision_layer_mask = collision_layer_mask;
}

void Radiant::set_entity_common(bool enabled)
{
	m_entity_common = enabled;
}

bool Radiant::get_entity_common()
{
	return m_entity_common;
}

void Radiant::set_entity_path(const String& path)
{
	m_entity_path = path;
}

String Radiant::get_entity_path()
{
	return m_entity_path;
}

void Radiant::set_texture_path(const String& path)
{
	if (path.is_empty()) {
		UtilityFunctions::push_warning("WARNING: texture_path should not be empty");
	}
	m_texture_path = path;
}

String Radiant::get_texture_path()
{
	return m_texture_path;
}

void Radiant::set_material_template(const Ref<Material>& material)
{
	m_material_template = material;
}

Ref<Material> Radiant::get_material_template()
{
	return m_material_template;
}

void Radiant::set_material_texture_path(const String& texture_path)
{
	m_material_texture_path = texture_path;
}

String Radiant::get_material_texture_path()
{
	return m_material_texture_path;
}

void Radiant::clear()
{
	while (get_child_count() > 0) {
		auto child = get_child(0);
		remove_child(child);
		child->queue_free();
	}
}

void Radiant::build_meshes()
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

Dictionary Radiant::build_meshes_checked()
{
	if (m_building) return build_failure("BUSY", "A map build is already in progress", m_map_path, "build_meshes_checked");
	if (m_inverse_scale <= 0 || (m_lighting_unwrap_uv2 && (!std::isfinite(m_lighting_unwrap_texel_size) || m_lighting_unwrap_texel_size <= 0))) {
		return build_failure("INVALID_ARGUMENT", "Inverse scale and lightmap texel size must be positive and finite", m_map_path, "build_meshes_checked");
	}
	m_building = true;
	auto staging = memnew(Node3D());
	Builder builder(this, staging);
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
		result["ok"] = true; result["changed"] = changed; result["value"] = value; result["error"] = Dictionary();
	}
	memdelete(staging);
	m_building = false;
	if (bool(result["ok"])) {
		emit_signal("bake_finished");
	}
	return result;
}

Dictionary Radiant::build_visual_preview_checked(const Ref<TBMapDocument>& document, Node3D* target)
{
	const StringName operation = "build_visual_preview_checked";
	String path = document.is_valid() ? document->get_path() : String();
	if (m_building) return build_failure("BUSY", "A map build is already in progress", path, operation);
	if (document.is_null() || !target) return build_failure("INVALID_ARGUMENT", "Document and preview target are required", path, operation);
	if (m_inverse_scale <= 0 || (m_lighting_unwrap_uv2 && (!std::isfinite(m_lighting_unwrap_texel_size) || m_lighting_unwrap_texel_size <= 0))) {
		return build_failure("INVALID_ARGUMENT", "Inverse scale and lightmap texel size must be positive and finite", path, operation);
	}
	m_building = true;
	auto staging = memnew(Node3D());
	Builder builder(this, staging, document->clone_map_for_build());
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

Dictionary Radiant::resolve_material(const String& token)
{
	return Builder(this).resolve_material(token);
}
