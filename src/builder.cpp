#include <builder.h>

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/omni_light3d.hpp>
#include <godot_cpp/classes/audio_stream_player3d.hpp>
#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/area3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/convex_polygon_shape3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/surface_tool.hpp>
#include <godot_cpp/templates/vmap.hpp>

#include <tb_loader.h>
#include <map_document.h>

#include <map>
#include <string>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <vector>

namespace {
bool normalized_res_path(const String& value, std::vector<std::string>& components, bool reject_navigation)
{
	auto utf8 = value.utf8();
	std::string path(utf8.get_data(), utf8.length());
	if (path.compare(0, 6, "res://") != 0 || path.find('\\') != std::string::npos) return false;
	components.clear();
	for (size_t begin = 6; begin <= path.size();) {
		size_t end = path.find('/', begin);
		if (end == std::string::npos) end = path.size();
		std::string component = path.substr(begin, end - begin);
		if (!component.empty() && component != ".") {
			if (component == "..") {
				if (reject_navigation || components.empty()) return false;
				components.pop_back();
			} else {
				components.push_back(std::move(component));
			}
		}
		if (end == path.size()) break;
		begin = end + 1;
	}
	return true;
}

String resource_under_root(const String& configured_root, const String& token, const String& suffix = String())
{
	std::vector<std::string> root;
	if (!normalized_res_path(configured_root, root, false)) return String();
	String candidate;
	bool explicit_resource = false;
	if (token.begins_with("res://")) {
		candidate = token + suffix;
		explicit_resource = true;
	} else {
		auto bytes = token.utf8();
		std::string relative(bytes.get_data(), bytes.length());
		if (relative.empty() || relative[0] == '/' || relative.find("://") != std::string::npos) return String();
		candidate = configured_root.trim_suffix("/") + "/" + token + suffix;
	}
	std::vector<std::string> path;
	if (!normalized_res_path(candidate, path, true) || (!explicit_resource && (path.size() < root.size() || !std::equal(root.begin(), root.end(), path.begin())))) return String();
	String normalized = "res://";
	for (size_t i = 0; i < path.size(); ++i) {
		if (i) normalized += "/";
		normalized += String::utf8(path[i].c_str());
	}
	return normalized;
}

bool safe_classname(const String& classname)
{
	auto bytes = classname.utf8();
	std::string value(bytes.get_data(), bytes.length());
	if (value.empty()) return false;
	bool component_start = true;
	for (unsigned char c : value) {
		if (c == '_') {
			if (component_start) return false;
			component_start = true;
		} else {
			if ((component_start && !std::isalpha(c)) || (!component_start && !std::isalnum(c))) return false;
			component_start = false;
		}
	}
	return !component_start;
}
}

Builder::Builder(TBLoader* loader, Node3D* parent)
{
	m_loader = loader;
	m_parent = parent ? parent : loader;
	m_owner = parent ? parent : (loader->get_owner() ? loader->get_owner() : loader);
	m_map = std::make_shared<LMMapData>();
}

Builder::Builder(TBLoader* loader, Node3D* parent, std::shared_ptr<LMMapData> map) : Builder(loader, parent)
{
	m_map = std::move(map);
}

Builder::~Builder()
{
}

Dictionary Builder::load_map(const String& path)
{
	// Validate geometry as well as syntax before creating any scene output. Parse
	// the validated snapshot, never reopen a file that could have changed meanwhile.
	Ref<TBMapDocument> document = memnew(TBMapDocument());
	Dictionary result = document->load_map(path);
	if (!bool(result["ok"])) return result;
	String text = document->export_text()["value"];
	auto bytes = text.utf8();
	LMMapParser parser(m_map);
	if (!parser.load_from_text(std::string(bytes.get_data(), bytes.length()))) {
		m_error = String::utf8(parser.error.message.c_str());
		return result;
	}

	prepare_map_data();
	return result;
}

bool Builder::prepare_map_data()
{
	if (!m_map) {
		m_error = "Map data is unavailable";
		return false;
	}
	load_and_cache_map_textures();
	if (!m_error.is_empty()) return false;

	// We have to manually set the size of textures
	for (int i = 0; i < m_map->texture_count; i++) {
		auto& tex = m_map->textures[i];

		auto res_texture = texture_from_name(tex.name);
		if (res_texture != nullptr && res_texture->get_width() > 0 && res_texture->get_height() > 0) {
			tex.width = res_texture->get_width();
			tex.height = res_texture->get_height();
		} else {
			// Make sure we don't divide by 0 and create NaN UV's
			tex.width = 1;
			tex.height = 1;
		}
	}

	// Run geometry generator (this also generates UV's, so we do this last)
	LMGeoGenerator geogen(m_map);
	geogen.run();
	return true;
}

bool Builder::build_map()
{
	if (!m_error.is_empty()) return false;
	std::map<String, int> entity_class_count;
	for (int i = 0; i < m_map->entity_count; i++) {
		auto& ent = m_map->entities[i];
		build_entity(i, ent, ent.get_property("classname"), entity_class_count);
		if (!m_error.is_empty()) return false;
	}
	return true;
}

bool Builder::build_visual_map()
{
	if (!m_error.is_empty()) return false;
	for (int i = 0; i < m_map->entity_count; i++) {
		auto& ent = m_map->entities[i];
		if (ent.brush_count == 0 && ent.patch_count == 0) continue;
		if (m_loader->m_skip_hidden_layers && ent.get_property_int("_tb_layer_hidden", 0) != 0) continue;
		String classname = ent.get_property("classname");
		if (m_loader->m_entity_common && (classname == "light" || classname == "area" || classname == "target_speaker" || classname == "trigger_location")) continue;
		Node* node = build_worldspawn(i, ent, false);
		if (!m_error.is_empty()) return false;
		if (!node) continue;
		if (ent.has_property("name")) node->set_name(ent.get_property("name"));
		if (node->get_child_count() > 0 && (ent.has_property("smooth") || ent.has_property("soft"))) {
			smooth_mesh_shading(Object::cast_to<MeshInstance3D>(node->get_child(0)));
		}
	}
	return true;
}

Node* Builder::build_worldspawn(int idx, LMEntity& ent, bool collision)
{
	// Create node for this entity
	auto container_node = memnew(Node3D());
	m_parent->add_child(container_node);
	container_node->set_owner(m_owner);

	// Decide generated collision type
	ColliderType collider = ColliderType::None;
	ColliderShape collider_shape = ColliderShape::Concave;
	if (collision && m_loader->m_collision) {
		collider = ColliderType::Static;
		collider_shape = ColliderShape::Concave;
	}

	// Create mesh instance for worldspawn
	build_entity_mesh(idx, ent, container_node, collider, collider_shape);

	// Delete container if we added nothing to it
	if (container_node->get_child_count() == 0) {
		m_parent->remove_child(container_node);
		memdelete(container_node);
		return nullptr;
	}

	// Find name for entity
	const char* tb_name;
	if (!strcmp(ent.get_property("classname"), "worldspawn")) {
		tb_name = "Default Layer";
	} else {
		tb_name = ent.get_property("_tb_name", nullptr);
	}

	// Add container to loader
	if (tb_name != nullptr) {
		container_node->set_name(tb_name);
	}
	container_node->set_position(lm_transform(ent.center));

	return container_node;
}

Node* Builder::build_entity(int idx, LMEntity& ent, const String& classname, std::map<String, int>& entity_class_count)
{
	Node* newEntityNode = nullptr;

	UtilityFunctions::prints("Building entity ", idx, " of class ", classname);

	if (classname == "worldspawn" || classname == "func_group") {
		// Skip worldspawn if the layer is hidden and the "skip hidden layers" option is checked
		if (m_loader->m_skip_hidden_layers) {
			bool is_visible = (ent.get_property_int("_tb_layer_hidden", 0) == 0);
			if (!is_visible) {
				return nullptr;
			}
		}
		newEntityNode = build_worldspawn(idx, ent, true);
		if (newEntityNode) newEntityNode->add_to_group("level");
	} else {
		// Load common entities if enabled
		if (m_loader->m_entity_common) {
			if (classname == "light") {
				newEntityNode = build_entity_light(idx, ent);
			} else if (classname == "area") {
				newEntityNode = build_entity_area(idx, ent);
			} else if (classname == "nocollision") {
				newEntityNode = build_worldspawn(idx, ent, false);
			} else if (classname == "target_speaker") {
				newEntityNode = build_entity_sound(idx, ent);
			} else if (classname == "trigger_location") {
				auto location = ent.get_property("message");
				if (strlen(location) == 0) {
					m_error = "Trigger location entity has no message property";
					return nullptr;
				} else {
					UtilityFunctions::prints("Trigger location entity with message: ", location);
				}
				newEntityNode = build_entity_area(idx, ent);
				if (newEntityNode) newEntityNode->set_name("location_" + String(location));
				return newEntityNode;
			}

			//TODO: More common entities
		}

		if (!m_error.is_empty()) return nullptr;
		if (newEntityNode == nullptr) {
			// Still no entity? We're building a custom one
			newEntityNode = build_entity_custom(idx, ent, m_map->entity_geo[idx], classname, entity_class_count);
		}
	}

	if (newEntityNode != nullptr) {
		// Load common properties
		if (ent.has_property("name")) {
			newEntityNode->set_name(ent.get_property("name"));
		}
	}

	if (newEntityNode && newEntityNode->get_child_count() > 0 && (ent.has_property("smooth") || ent.has_property("soft"))) {
		smooth_mesh_shading(Object::cast_to<MeshInstance3D>(newEntityNode->get_child(0)));
	}

	return newEntityNode;
}

Node* Builder::build_entity_custom(int idx, LMEntity& ent, LMEntityGeometry& geo, const String& classname, std::map<String, int>& entity_class_count)
{
	// m_loader->m_entity_path => "res://entities/"
	// "info_player_start" => "info/player/start.tscn", "info/player_start.tscn", "info_player_start.tscn"
	// "thing" => "thing.tscn"

	auto resource_loader = ResourceLoader::get_singleton();
	if (!safe_classname(classname)) {
		m_error = "Invalid entity classname for scene lookup: " + classname;
		return nullptr;
	}

	auto arr = classname.split("_");
	for (int i = 0; i < arr.size(); i++) {
		String relative;
		for (int j = 0; j < arr.size(); j++) {
			if (j > 0) {
				if (j <= i) {
					relative = relative + "/";
				} else {
					relative = relative + "_";
				}
			}
			relative = relative + arr[j];
		}
		String path = resource_under_root(m_loader->m_entity_path, relative, ".tscn");
		if (path.is_empty()) {
			m_error = "Entity path must be a res:// directory: " + m_loader->m_entity_path;
			return nullptr;
		}

		if (resource_loader->exists(path, "PackedScene")) {
			Ref<PackedScene> scene = resource_loader->load(path);
			if (scene == nullptr) {
				m_error = "Cannot load entity scene: " + path;
				return nullptr;
			}

			auto instance = scene->instantiate();
			if (!instance) {
				m_error = "Cannot instantiate entity scene: " + path;
				return nullptr;
			}
			m_parent->add_child(instance);
			instance->set_owner(m_owner);

			if (instance->is_class("Node3D")) {
				set_entity_node_common((Node3D*)instance, ent);
				if (ent.brush_count > 0) {
					set_entity_brush_common(idx, (Node3D*)instance, ent);
				}
			}

			// Check if this entity class has been counted before
			if (!ent.has_property("targetname")) {
				auto entity_name = ent.get_property("classname");
				if (entity_class_count.find(entity_name) != entity_class_count.end()) {
					// Increment the count and update the instance name
					entity_class_count[entity_name]++;
					instance->set_name(String("{0}_{1}").format(Array::make(entity_name, entity_class_count[entity_name])));
				} else {
					// First instance of this entity class
					entity_class_count[entity_name] = 0;
				}
			}

			for (int j = 0; j < ent.property_count; j++) {
				auto& prop = ent.properties[j];

				auto var = instance->get(prop.key);
				switch (var.get_type()) {
					case Variant::BOOL: instance->set(prop.key, atoi(prop.value) == 1); break;
					case Variant::INT: instance->set(prop.key, (int64_t)atoll(prop.value)); break;
					case Variant::FLOAT: instance->set(prop.key, atof(prop.value)); break; //TODO: Locale?
					case Variant::STRING: instance->set(prop.key, prop.value); break;

					case Variant::STRING_NAME: instance->set(prop.key, StringName(prop.value)); break;
					case Variant::NODE_PATH: instance->set(prop.key, NodePath(prop.value)); break; //TODO: More TrenchBroom focused node path conversion?

					case Variant::VECTOR2: {
						vec2 v = vec2_parse(prop.value);
						instance->set(prop.key, Vector2(v.x, v.y));
						break;
					}
					case Variant::VECTOR2I: {
						vec2 v = vec2_parse(prop.value);
						instance->set(prop.key, Vector2i((int)v.x, (int)v.y));
						break;
					}
					case Variant::VECTOR3: {
						vec3 v = vec3_parse(prop.value);
						instance->set(prop.key, Vector3(v.x, v.y, v.z));
						break;
					}
					case Variant::VECTOR3I: {
						vec3 v = vec3_parse(prop.value);
						instance->set(prop.key, Vector3i((int)v.x, (int)v.y, (int)v.z));
						break;
					}

					case Variant::COLOR: {
						vec3 v = vec3_parse(prop.value);
						instance->set(prop.key, Color(v.x / 255.0f, v.y / 255.0f, v.z / 255.0f));
						break;
					}
				}
			}

			return instance;
		}
	}

	m_error = "Path to entity resource could not be resolved: " + classname;
	return nullptr;
}

Node* Builder::build_entity_light(int idx, LMEntity& ent)
{
	auto light = memnew(OmniLight3D());

	light->set_bake_mode(Light3D::BAKE_STATIC);
	light->set_param(Light3D::PARAM_RANGE, ent.get_property_double("range", 10));
	light->set_param(Light3D::PARAM_ENERGY, ent.get_property_double("energy", 1));
	light->set_param(Light3D::PARAM_ATTENUATION, ent.get_property_double("attenuation", 1));
	light->set_param(Light3D::PARAM_SPECULAR, ent.get_property_double("specular", 0.5));
	set_entity_node_common(light, ent);

	vec3 color = ent.get_property_vec3("light_color", { 255, 255, 255 });
	light->set_color(Color(color.x / 255.0f, color.y / 255.0f, color.z / 255.0f));

	m_parent->add_child(light);
	light->set_owner(m_owner);

	return light;
}

Node* Builder::build_entity_area(int idx, LMEntity& ent)
{
	Vector3 center = lm_transform(ent.center);

	// Gather surfaces for the area
	LMSurfaceGatherer surf_gather(m_map);
	surf_gather.surface_gatherer_set_entity_index_filter(idx);
	surf_gather.surface_gatherer_run();

	auto& surfs = surf_gather.out_surfaces;
	if (surfs.surface_count == 0) {
		return nullptr;
	}

	// Create the area
	auto area = memnew(Area3D());
	m_parent->add_child(area);
	area->set_owner(m_owner);
	area->set_position(center);

	for (int i = 0; i < surfs.surface_count; i++) {
		auto& surf = surfs.surfaces[i];
		if (surf.vertex_count == 0) {
			continue;
		}

		// Create the mesh
		Ref<ArrayMesh> mesh = memnew(ArrayMesh());
		add_surface_to_mesh(mesh, surf);

		// Create collision shape for the area
		add_collider_from_mesh(area, mesh, ColliderShape::Concave, nullptr);
	}

	return area;
}

Node* Builder::build_entity_sound(int idx, LMEntity& ent)
{
	auto player = memnew(AudioStreamPlayer3D());

	// Load the audio stream resource
	const char* sound_path = ent.get_property("sound", "");
	if (strlen(sound_path) > 0) {
		String path = resource_under_root("res://", String::utf8(sound_path));
		if (path.is_empty()) {
			m_error = "Audio stream path must stay under res://: " + String::utf8(sound_path);
			memdelete(player);
			return nullptr;
		}
		auto resource_loader = ResourceLoader::get_singleton();
		if (resource_loader->exists(path, "AudioStream")) {
			Ref<AudioStream> stream = resource_loader->load(path);
			if (stream.is_valid()) {
				player->set_stream(stream);
			} else {
				m_error = "Failed to load audio stream: " + String::utf8(sound_path);
			}
		} else {
			m_error = "Audio stream resource not found: " + String::utf8(sound_path);
		}
	}
	if (!m_error.is_empty()) {
		memdelete(player);
		return nullptr;
	}

	// Volume
	player->set_max_db(ent.get_property_float("max_db", 0.0f));

	// Distance attenuation
	player->set_unit_size(ent.get_property_float("unit_size", 10.0f));
	player->set_max_distance(ent.get_property_float("max_distance", 0.0f));

	// Attenuation model
	const char* attenuation = ent.get_property("attenuation_model", "");
	if (strlen(attenuation) > 0) {
		if (!strcmp(attenuation, "inverse") || !strcmp(attenuation, "0")) {
			player->set_attenuation_model(AudioStreamPlayer3D::ATTENUATION_INVERSE_DISTANCE);
		} else if (!strcmp(attenuation, "inverse_square") || !strcmp(attenuation, "1")) {
			player->set_attenuation_model(AudioStreamPlayer3D::ATTENUATION_INVERSE_SQUARE_DISTANCE);
		} else if (!strcmp(attenuation, "logarithmic") || !strcmp(attenuation, "2")) {
			player->set_attenuation_model(AudioStreamPlayer3D::ATTENUATION_LOGARITHMIC);
		} else if (!strcmp(attenuation, "disabled") || !strcmp(attenuation, "3")) {
			player->set_attenuation_model(AudioStreamPlayer3D::ATTENUATION_DISABLED);
		}
	}

	// Audio bus
	const char* bus = ent.get_property("bus", "");
	if (strlen(bus) > 0) {
		player->set_bus(StringName(bus));
	}

	// Autoplay (default true for ambient sounds)
	bool autoplay = ent.get_property_int("autoplay", 1) != 0;
	player->set_autoplay(autoplay);

	// Position and rotation
	set_entity_node_common(player, ent);

	// Add to scene tree
	m_parent->add_child(player);
	player->set_owner(m_owner);

	return player;
}

void Builder::set_entity_node_common(Node3D* node, LMEntity& ent)
{
	// Target name
	auto targetname = ent.get_property("targetname", nullptr);
	if (targetname != nullptr) {
		node->set_name(targetname);
	}

	// Position
	if (ent.has_property("origin")) {
		Vector3 origin = lm_transform(ent.get_property_vec3("origin"));
		node->set_position(origin);
	}

	// Brush entities shouldn't be rotated as they are already in mesh space
	if (ent.brush_count == 0) {
		// Rotation
		double pitch = 0;
		double yaw = 0;
		double roll = 0;

		if (ent.has_property("angle")) {
			// "angle" is yaw rotation only
			yaw = ent.get_property_double("angle");

		} else if (ent.has_property("angles")) {
			// "angles" is "pitch yaw roll"
			vec3 angles = ent.get_property_vec3("angles");
			pitch = angles.x;
			yaw = angles.y;
			roll = angles.z;

		} else if (ent.has_property("mangle")) {
			vec3 mangle = ent.get_property_vec3("mangle");
			// "mangle" depends on whether the classname starts with "light"
			const char* classname = ent.get_property("classname");
			if (strstr(classname, "light") == classname) {
				// "yaw pitch roll", if classname starts with "light"
				yaw = mangle.x;
				pitch = mangle.y;
				roll = mangle.z;
			} else {
				// "pitch yaw roll", just like "angles"
				pitch = mangle.x;
				yaw = mangle.y;
				roll = mangle.z;
			}
		}

		node->set_rotation(Vector3(
			Math::deg_to_rad(-pitch),
			Math::deg_to_rad(yaw + 180),
			Math::deg_to_rad(-roll)
		));
	}
}

void Builder::set_entity_brush_common(int idx, Node3D* node, LMEntity& ent)
{
	// Position
	Vector3 center = lm_transform(ent.center);
	node->set_position(center);

	// Check what we actually need
	bool need_visual = node->is_class("Node3D");
	ColliderType need_collider = ColliderType::None;
	ColliderShape need_collider_shape = ColliderShape::Concave;

	if (node->is_class("RigidBody3D")) {
		// RigidBody3D requires convex collision meshes
		need_collider = ColliderType::Mesh;
		need_collider_shape = ColliderShape::Convex;

	} else if (node->is_class("Area3D")) {
		// Area3D works best with convex collision meshes
		need_collider = ColliderType::Mesh;
		need_collider_shape = ColliderShape::Convex;

	} else if (node->is_class("CollisionObject3D")) {
		// If it's not a dynamic body, we can just use a concave trimesh collider
		need_collider = ColliderType::Mesh;
		need_collider_shape = ColliderShape::Concave;
	}

	// Stop if we don't need to do anything
	if (!need_visual && need_collider == ColliderType::None) {
		UtilityFunctions::printerr("Brush entity class has no need for visual nor collision: ", node->get_class());
		return;
	}

	build_entity_mesh(idx, ent, node, need_collider, need_collider_shape);
}

Vector3 Builder::lm_transform(const vec3& v)
{
	vec3 sv = vec3_div_double(v, m_loader->m_inverse_scale);
	return Vector3(sv.y, sv.z, sv.x);
}

void Builder::add_collider_from_mesh(Node3D* node, Ref<ArrayMesh>& mesh, ColliderShape colshape, Color* debug_color)
{
	Ref<Shape3D> mesh_shape;
	switch (colshape) {
	case ColliderShape::Convex: mesh_shape = mesh->create_convex_shape(); break;
	case ColliderShape::Concave: mesh_shape = mesh->create_trimesh_shape(); break;
	}

	if (mesh_shape == nullptr) {
		m_error = "Unable to create collider shape from mesh";
		return;
	}

	auto collision_shape = memnew(CollisionShape3D());
	collision_shape->set_shape(mesh_shape);
	if (colshape == ColliderShape::Concave) {
		auto concave_shape = Object::cast_to<ConcavePolygonShape3D>(mesh_shape.ptr());
		concave_shape->set_backface_collision_enabled(true); // useful for raycasting exit bullets
	}
	node->add_child(collision_shape, true);
	collision_shape->set_owner(m_owner);

	if (debug_color != nullptr) {
		collision_shape->set("debug_color", *debug_color);
	}
}

void Builder::add_surface_to_mesh(Ref<ArrayMesh>& mesh, LMSurface& surf)
{
	if (surf.vertex_count < 3 || surf.index_count < 3 || surf.index_count % 3 != 0) {
		m_error = "Generated surface has invalid triangle counts";
		return;
	}
	PackedVector3Array vertices;
	PackedFloat32Array tangents;
	PackedVector3Array normals;
	PackedVector2Array uvs;
	PackedInt32Array indices;

	// Add all vertices
	for (int k = 0; k < surf.vertex_count; k++) {
		auto& v = surf.vertices[k];

		vertices.push_back(lm_transform(v.vertex));
		if (!vertices[vertices.size() - 1].is_finite() || !std::isfinite(v.uv.u) || !std::isfinite(v.uv.v)
				|| !std::isfinite(v.normal.x) || !std::isfinite(v.normal.y) || !std::isfinite(v.normal.z)
				|| !std::isfinite(v.tangent.x) || !std::isfinite(v.tangent.y) || !std::isfinite(v.tangent.z) || !std::isfinite(v.tangent.w)) {
			m_error = "Generated surface contains non-finite vertex attributes";
			return;
		}
		tangents.push_back(v.tangent.y);
		tangents.push_back(v.tangent.z);
		tangents.push_back(v.tangent.x);
		tangents.push_back(v.tangent.w);
		normals.push_back(Vector3(v.normal.y, v.normal.z, v.normal.x));
		uvs.push_back(Vector2(v.uv.u, v.uv.v));
	}

	// Add all indices
	for (int k = 0; k < surf.index_count; k++) {
		if (surf.indices[k] < 0 || surf.indices[k] >= surf.vertex_count) {
			m_error = "Generated surface contains an invalid triangle index";
			return;
		}
		indices.push_back(surf.indices[k]);
	}

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = vertices;
	arrays[Mesh::ARRAY_TANGENT] = tangents;
	arrays[Mesh::ARRAY_NORMAL] = normals;
	arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_INDEX] = indices;

	// Create mesh
	int previous_count = mesh->get_surface_count();
	mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	if (mesh->get_surface_count() != previous_count + 1) m_error = "Unable to create mesh surface";
}

bool check_texture(const std::string& texture_name, const std::string& substring) {
    // Create uppercase copies of the input strings
    std::string texture_upper(texture_name);
    std::string substring_upper(substring);

    // Convert both to uppercase
    auto uppercase = [](unsigned char c) { return std::toupper(c); };
    std::transform(texture_name.begin(), texture_name.end(), texture_upper.begin(), uppercase);
    std::transform(substring.begin(), substring.end(), substring_upper.begin(), uppercase);

    // Check if the uppercase substring is in the uppercase texture name
    return texture_upper.find(substring_upper) != std::string::npos;
}

MeshInstance3D* Builder::build_entity_mesh(int idx, LMEntity& ent, Node3D* parent, ColliderType coltype, ColliderShape colshape)
{
	// Create instance name based on entity idx
	String instance_name = String("entity_{0}_geometry").format(Array::make(idx));

	auto mesh_instance = memnew(MeshInstance3D());

	parent->add_child(mesh_instance);

	// Set the layers that the mesh instance will be rendered in
	mesh_instance->set_layer_mask(m_loader->get_visual_layer_mask());

	if (ent.has_property("skybox")) {
		mesh_instance->set_layer_mask(m_loader->get_skybox_layer_mask());
	}

	mesh_instance->set_owner(m_owner);
	mesh_instance->set_name(instance_name);

	// Create mesh
	Ref<ArrayMesh> mesh = memnew(ArrayMesh());

	// Create a map to store different types of collision meshes
	// std::unordered_map<String, Ref<ArrayMesh>> collision_mesh_map;

	std::map<String, Ref<ArrayMesh>> collision_mesh_map;

	const String SURFACE_GRASS = "GRASS";
	const String SURFACE_DIRT = "DIRT";
	const String SURFACE_METAL = "METAL";
	const String SURFACE_WOOD = "WOOD";
	const String SURFACE_GLASS = "GLASS";
	const String SURFACE_WINDOW = "WINDOW";
	const String SURFACE_SAND = "SAND";
	const String SURFACE_TILE = "TILE";
	const String SURFACE_SNOW = "SNOW";
	const String SURFACE_VENT = "VENT";
	const String SURFACE_WATER = "WATER";

	const String SURFACE_DEFAULT = "DEFAULT";
	const String SURFACE_PLAYER_CLIP = "PLAYER_CLIP";
	const String SURFACE_LADDER_CLIP = "LADDER_CLIP";
	const String SURFACE_CUSHION_CLIP = "CUSHION_CLIP";
	const String SURFACE_NO_WALL_JUMP = "NO_WALL_JUMP";

	std::vector<String> collision_surface_types = {SURFACE_GRASS, SURFACE_DIRT, SURFACE_METAL, SURFACE_WOOD, SURFACE_GLASS, SURFACE_WINDOW, SURFACE_SAND, SURFACE_TILE, SURFACE_SNOW, SURFACE_VENT, SURFACE_WATER};
	std::vector<String> collision_special_types = {SURFACE_DEFAULT, SURFACE_PLAYER_CLIP, SURFACE_LADDER_CLIP, SURFACE_CUSHION_CLIP, SURFACE_NO_WALL_JUMP};

	const bool need_collision = coltype != ColliderType::None;
	if (need_collision) {
		for (auto& collision_type : collision_surface_types) {
			collision_mesh_map.emplace(collision_type, memnew(ArrayMesh()));
		}
		for (auto& collision_type : collision_special_types) {
			collision_mesh_map.emplace(collision_type, memnew(ArrayMesh()));
		}
	}

	// Example usage: Assign the collision mesh to the map
	// collision_mesh_map["GRASS"]->add_surface_from_arrays(...);

	// Give mesh to mesh instance
	mesh_instance->set_mesh(mesh);

	for (int i = 0; i < m_map->texture_count; i++) {
		LMTextureData tex = m_map->textures[i];

		// Create material
		Ref<Material> material;

		// Skip processing a surface when it's using the skip material
		if (tex.name == m_loader->get_skip_texture_name()) {
			continue;
		}

		// Attempt to load material
		material = material_from_name(tex.name);

		// Gather surfaces for this texture
		LMSurfaceGatherer surf_gather(m_map);
		surf_gather.surface_gatherer_set_entity_index_filter(idx);
		surf_gather.surface_gatherer_set_texture_filter(tex.name);
		surf_gather.surface_gatherer_run();

		auto& surfs = surf_gather.out_surfaces;
		if (surfs.surface_count == 0) {
			continue;
		}

		for (int i = 0; i < surfs.surface_count; i++) {
			auto& surf = surfs.surfaces[i];
			if (surf.vertex_count == 0) {
				continue;
			}

			// Add surface to collision mesh
			// Skip if the texture specifies that we only want collision (invisible walls)
			if (tex.name == m_loader->get_clip_texture_name()) {
				if (need_collision) add_surface_to_mesh(collision_mesh_map[SURFACE_PLAYER_CLIP], surf);
				continue;
			} else if (tex.name == m_loader->get_ladder_texture_name()) {
				if (need_collision) add_surface_to_mesh(collision_mesh_map[SURFACE_LADDER_CLIP], surf);
				continue;
			} else if (tex.name == m_loader->get_cushion_texture_name()) {
				if (need_collision) add_surface_to_mesh(collision_mesh_map[SURFACE_CUSHION_CLIP], surf);
				continue;
			} else if (tex.name == m_loader->get_no_wall_jump_texture_name()) {
				if (need_collision) add_surface_to_mesh(collision_mesh_map[SURFACE_NO_WALL_JUMP], surf);
				continue;
			} else if (need_collision) {
				bool added = false;
				for (const auto& collision_type : collision_surface_types) {
					if (check_texture(tex.name, collision_type.utf8().get_data())) {
						add_surface_to_mesh(collision_mesh_map[collision_type.utf8().get_data()], surf);
						added = true;
						break;
					}
				}
				if (!added) {
					add_surface_to_mesh(collision_mesh_map[SURFACE_DEFAULT], surf);
				}
			}

			// Add surface to visual mesh
			add_surface_to_mesh(mesh, surf);
			if (!m_error.is_empty()) return mesh_instance;

			// Give mesh material
			if (material != nullptr) {
				mesh->surface_set_material(mesh->get_surface_count() - 1, material);
			}
		}
	}

	// Unwrap UV2's if needed
	if (m_loader->m_lighting_unwrap_uv2 && mesh->get_surface_count() > 0) {
		Transform3D transform = mesh_instance->get_transform();
		for (Node3D* ancestor = parent; ancestor && ancestor != m_parent; ancestor = Object::cast_to<Node3D>(ancestor->get_parent())) {
			transform = ancestor->get_transform() * transform;
		}
		transform = (m_loader->is_inside_tree() ? m_loader->get_global_transform() : m_loader->get_transform()) * transform;
		if (mesh->lightmap_unwrap(transform, m_loader->m_lighting_unwrap_texel_size) != OK) {
			m_error = "Unable to unwrap mesh lightmap UVs";
			return mesh_instance;
		}
		mesh_instance->set_gi_mode(GeometryInstance3D::GI_MODE_STATIC);
	}

	// Create collisions if needed
	// iterate the map and add the surfaces to the appropriate mesh
	for (auto& [key, collision_mesh] : collision_mesh_map) {
		if (collision_mesh->get_surface_count() > 0) {
			switch (coltype) {
			case ColliderType::Mesh:
				add_collider_from_mesh(parent, collision_mesh, colshape, nullptr);
				break;

			case ColliderType::Static:
				CollisionObject3D *container;
				Color *debug_color = nullptr;
				if (key == SURFACE_LADDER_CLIP || key == SURFACE_CUSHION_CLIP || key == SURFACE_NO_WALL_JUMP) {
					container = memnew(Area3D());
					auto container_area3d = Object::cast_to<Area3D>(container);
					container_area3d->set_monitorable(true);
					container_area3d->set_monitoring(false);
					debug_color = memnew(Color(1.0, 1.0, 0.0, 0.5));
				} else {
					container = memnew(StaticBody3D());
				}

				container->set_name(String(mesh_instance->get_name()) + "_" + key + "_col");
				if (key == SURFACE_PLAYER_CLIP) {
					container->set_collision_layer(m_loader->get_clip_collision_layer_mask());
				} else {
					container->set_collision_layer(m_loader->get_collision_layer_mask());
				}

				parent->add_child(container, true);
				container->set_owner(m_owner);
				add_collider_from_mesh(container, collision_mesh, colshape, nullptr);
				break;
			}
		}
	}

	// Remove the empty mesh instances if enabled
	if (m_loader->m_skip_empty_meshes && mesh->get_surface_count() == 0) {
		parent->remove_child(mesh_instance);
		memdelete(mesh_instance);
		return nullptr;
	}

	return mesh_instance;
}

void Builder::load_and_cache_map_textures()
{
	m_loaded_map_textures.clear();
	m_loaded_map_materials.clear();
	for (int tex_i = 0; tex_i < m_map->texture_count; tex_i++) {
		const LMTextureData& tex = m_map->textures[tex_i];
		String token = String::utf8(tex.name);
		if (resource_under_root(m_loader->m_texture_path, token).is_empty()) {
			m_error = "Texture or material path must stay under texture_path: " + token;
			return;
		}
		Dictionary resolved = resolve_material(token);
		m_loaded_map_textures[token] = resolved["texture"];
		m_loaded_map_materials[token] = resolved["material"];
		// Missing legacy shaders still use the historical untextured fallback.
		// An explicit resource token promises an exact resource, so fail the bake.
		String extension = token.get_extension().to_lower();
		if ((token.begins_with("res://") || extension == "material" || extension == "tres" || extension == "res") && !bool(resolved["resolved"])) {
			m_error = "Cannot resolve texture or Material resource: " + token;
		}
	}
}

String Builder::texture_path(const char* name, const char* extension)
{
	return resource_under_root(m_loader->m_texture_path, String::utf8(name), "." + String(extension));
}

String Builder::material_path(const char* name)
{
	String token = String::utf8(name);
	auto root_path = resource_under_root(m_loader->m_texture_path, token);
	if (root_path.is_empty()) return String();
	String extension = token.get_extension().to_lower();
	if (token.begins_with("res://")) return root_path;
	if (extension == "material" || extension == "tres" || extension == "res") return root_path;
	String material_path;

	if (FileAccess::file_exists(root_path + ".material")) {
		material_path = root_path + ".material";
	} else if (FileAccess::file_exists(root_path + ".tres")) {
		material_path = root_path + ".tres";
	}

	return material_path;
}

Ref<Texture2D> Builder::texture_from_name(const char* name)
{
	return m_loaded_map_textures.get(String::utf8(name), Variant());
}

Ref<Material> Builder::material_from_name(const char* name)
{
	return m_loaded_map_materials.get(String::utf8(name), Variant());
}

Dictionary Builder::resolve_material(const String& token)
{
	auto resource_loader = ResourceLoader::get_singleton();
	auto bytes = token.utf8();
	bool direct = token.begins_with("res://");
	String extension = token.get_extension().to_lower();
	bool direct_material = extension == "material" || extension == "tres" || extension == "res";
	String path = material_path(bytes.get_data());
	String resource_path;
	Ref<Material> material;
	Ref<Texture2D> texture;
	if (!path.is_empty() && resource_loader->exists(path)) {
		Ref<Resource> resource = resource_loader->load(path);
		material = resource;
		if (direct) texture = resource;
		if (material.is_valid() || texture.is_valid()) resource_path = path;
	}
	if (!direct && !direct_material) {
		// Preserve legacy extension order and companion texture UV dimensions,
		// even when a .material/.tres overrides the generated visual material.
		const char* extensions[] = { "png", "dds", "tga", "jpg", "jpeg", "bmp", "webp", "exr", "hdr" };
		for (const char* extension : extensions) {
			path = texture_path(bytes.get_data(), extension);
			if (!resource_loader->exists(path, "Texture2D")) continue;
			texture = resource_loader->load(path);
			if (texture.is_valid()) {
				if (resource_path.is_empty()) resource_path = path;
				break;
			}
		}
	}
	if (texture.is_null() && material.is_valid()) {
		Ref<BaseMaterial3D> base = material;
		if (base.is_valid()) texture = base->get_texture(BaseMaterial3D::TEXTURE_ALBEDO);
	}
	if (material.is_null() && texture.is_valid()) {
		if (m_loader->m_material_template.is_valid()) {
			material = m_loader->m_material_template->duplicate();
			material->set(m_loader->m_material_texture_path, texture);
		} else {
			Ref<StandardMaterial3D> standard = memnew(StandardMaterial3D());
			standard->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, texture);
			if (m_loader->m_filter_nearest) standard->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_NEAREST);
			material = standard;
		}
	}
	Dictionary result;
	result["resolved"] = material.is_valid();
	result["resource_path"] = resource_path;
	result["material"] = material;
	result["texture"] = texture;
	result["texture_size"] = texture.is_valid() && texture->get_width() > 0 && texture->get_height() > 0
		? Vector2i(texture->get_width(), texture->get_height()) : Vector2i(1, 1);
	return result;
}

namespace {
void regenerate_tangents(Array& arrays)
{
	PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
	PackedVector3Array normals = arrays[Mesh::ARRAY_NORMAL];
	PackedVector2Array uvs = arrays[Mesh::ARRAY_TEX_UV];
	PackedInt32Array indices = arrays[Mesh::ARRAY_INDEX];
	PackedFloat32Array previous = arrays[Mesh::ARRAY_TANGENT];
	if (vertices.size() != normals.size() || vertices.size() != uvs.size()) return;
	std::vector<Vector3> tangent_sum(vertices.size());
	std::vector<Vector3> bitangent_sum(vertices.size());
	int index_count = indices.is_empty() ? vertices.size() : indices.size();
	for (int i = 0; i + 2 < index_count; i += 3) {
		int a = indices.is_empty() ? i : indices[i];
		int b = indices.is_empty() ? i + 1 : indices[i + 1];
		int c = indices.is_empty() ? i + 2 : indices[i + 2];
		if (a < 0 || b < 0 || c < 0 || a >= vertices.size() || b >= vertices.size() || c >= vertices.size()) continue;
		Vector3 edge1 = vertices[b] - vertices[a];
		Vector3 edge2 = vertices[c] - vertices[a];
		Vector2 uv1 = uvs[b] - uvs[a];
		Vector2 uv2 = uvs[c] - uvs[a];
		double determinant = uv1.x * uv2.y - uv1.y * uv2.x;
		if (!std::isfinite(determinant) || std::abs(determinant) < 1e-12) continue;
		Vector3 tangent = (edge1 * uv2.y - edge2 * uv1.y) / determinant;
		Vector3 bitangent = (edge2 * uv1.x - edge1 * uv2.x) / determinant;
		for (int index : {a, b, c}) {
			tangent_sum[index] += tangent;
			bitangent_sum[index] += bitangent;
		}
	}
	PackedFloat32Array tangents;
	tangents.resize(vertices.size() * 4);
	for (int i = 0; i < vertices.size(); ++i) {
		Vector3 normal = normals[i].normalized();
		Vector3 tangent = tangent_sum[i] - normal * normal.dot(tangent_sum[i]);
		bool used_previous = false;
		if (tangent.length_squared() < 1e-12 && previous.size() == vertices.size() * 4) {
			tangent = Vector3(previous[i * 4], previous[i * 4 + 1], previous[i * 4 + 2]);
			tangent -= normal * normal.dot(tangent);
			used_previous = tangent.length_squared() >= 1e-12;
		}
		if (tangent.length_squared() < 1e-12) {
			tangent = normal.cross(std::abs(normal.y) < 0.99 ? Vector3(0, 1, 0) : Vector3(1, 0, 0));
		}
		tangent.normalize();
		double handedness = used_previous && bitangent_sum[i].length_squared() < 1e-12
			? previous[i * 4 + 3] : (normal.cross(tangent).dot(bitangent_sum[i]) < 0.0 ? -1.0 : 1.0);
		tangents.set(i * 4, tangent.x);
		tangents.set(i * 4 + 1, tangent.y);
		tangents.set(i * 4 + 2, tangent.z);
		tangents.set(i * 4 + 3, handedness);
	}
	arrays[Mesh::ARRAY_TANGENT] = tangents;
}
}

void Builder::smooth_mesh_shading(MeshInstance3D* mesh_instance) {
    if (!mesh_instance || !mesh_instance->get_mesh().is_valid()) {
        return;
    }

    Ref<Mesh> source_mesh = mesh_instance->get_mesh();
    Ref<ArrayMesh> array_mesh = source_mesh;
    if (array_mesh.is_null()) {
        UtilityFunctions::push_error("Only ArrayMesh is supported.");
        return;
    }

    // Create a new ArrayMesh to avoid modifying the original
    Ref<ArrayMesh> new_mesh = memnew(ArrayMesh);

    // Process each surface
    for (int surface_idx = 0; surface_idx < array_mesh->get_surface_count(); surface_idx++) {
        Array arrays = array_mesh->surface_get_arrays(surface_idx);
        if (arrays.size() <= Mesh::ARRAY_NORMAL) {
            continue;
        }

        PackedVector3Array vertices = arrays[Mesh::ARRAY_VERTEX];
        PackedVector3Array normals = arrays[Mesh::ARRAY_NORMAL];

        // Map to track unique vertices and their normals
        std::map<Vector3, std::pair<Vector3, std::vector<int>>> vertex_data;

        // First pass: collect all vertex data
        for (int idx = 0; idx < vertices.size(); idx++) {
            Vector3 vertex = vertices[idx];
            Vector3 normal = normals[idx];

            if (vertex_data.find(vertex) == vertex_data.end()) {
                vertex_data[vertex] = std::make_pair(Vector3(), std::vector<int>());
            }
            vertex_data[vertex].first += normal;
            vertex_data[vertex].second.push_back(idx);
        }

        // Second pass: average normals and apply
        PackedVector3Array new_normals = normals.duplicate();
        for (auto& pair : vertex_data) {
            // Normalize the accumulated normal
            Vector3 avg_normal = pair.second.first.normalized();

            // Apply to all instances of this vertex
            for (int idx : pair.second.second) {
                new_normals.set(idx, avg_normal);
            }
        }

        // Update the arrays with new normals
        arrays[Mesh::ARRAY_NORMAL] = new_normals;
		regenerate_tangents(arrays);

        // Add surface to new mesh
        Dictionary format_info;
        format_info["primitive"] = array_mesh->surface_get_format(surface_idx);
        new_mesh->add_surface_from_arrays(
            array_mesh->surface_get_primitive_type(surface_idx),
            arrays,
            Array(), // No blend shapes
            format_info
        );

        // Copy surface material
        new_mesh->surface_set_material(surface_idx, 
            array_mesh->surface_get_material(surface_idx));
    }

    // Assign new mesh to the MeshInstance3D
    mesh_instance->set_mesh(new_mesh);
}
