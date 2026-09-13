#include "map_edit.h"
#include "map_writer.h"
#include "brush.h"
#include "patch.h"
#include "map_parser.h"
#include "geo_generator.h"

std::string LMEditEntity::property(const std::string &key) const {
	for (const auto &p : epairs) if (p.first == key) return p.second;
	return "";
}
void LMEditEntity::set_property(const std::string &key, const std::string &value) {
	for (auto &p : epairs) if (p.first == key) { p.second = value; return; }
	epairs.emplace_back(key, value);
}
LMMapEdit::LMMapEdit(const LMMapData &map) {
	for (int i = 0; i < map.entity_count; ++i) {
		const auto &source = map.entities[i];
		LMEditEntity e; e.id = source.id;
		for (int k = 0; k < source.property_count; ++k) e.epairs.emplace_back(source.properties[k].key, source.properties[k].value);
		for (int k = 0; k < source.primitive_count; ++k) {
			const auto &ref = source.primitives[k];
			LMEditPrimitive p; p.patch = ref.is_patch;
			if (p.patch) {
				p.id = source.patches[ref.index].id;
				p.patch_text = lm_write_patch(map, source.patches[ref.index]);
			} else {
				const auto &b = source.brushes[ref.index]; p.id = b.id;
				for (int f = 0; f < b.face_count; ++f) p.faces.push_back({b.faces[f], map.textures[b.faces[f].texture_idx].name});
			}
			e.primitives.push_back(std::move(p));
		}
		entities.push_back(std::move(e));
	}
}
std::string LMMapEdit::text() const {
	std::string out;
	for (const auto &e : entities) {
		out += "{\n";
		for (const auto &p : e.epairs) out += lm_quote(p.first) + " " + lm_quote(p.second) + "\n";
		for (const auto &p : e.primitives) {
			if (p.patch) out += p.patch_text;
			else {
				out += "{\n";
				for (const auto &f : p.faces) out += lm_write_face(f.plane, f.texture);
				out += "}\n";
			}
		}
		out += "}\n";
	}
	return out;
}
LMEditEntity *LMMapEdit::entity(int64_t id) {
	for (auto &e : entities) if (e.id == id) return &e;
	return nullptr;
}
LMEditPrimitive *LMMapEdit::brush(int64_t id) {
	for (auto &e : entities) for (auto &p : e.primitives) if (!p.patch && p.id == id) return &p;
	return nullptr;
}
LMEditEntity &LMMapEdit::world() {
	for (auto &e : entities) if (e.property("classname") == "worldspawn") return e;
	LMEditEntity e; e.epairs.emplace_back("classname", "worldspawn");
	entities.insert(entities.begin(), std::move(e));
	return entities.front();
}
LMEditPrimitive lm_edit_cuboid(vec3 mins, vec3 maxs, const std::string &texture) {
	LMEditPrimitive brush;
	// Parser normal is (p2-p0) cross (p1-p0). Each plane points outward.
	for (int axis = 0; axis < 3; ++axis) for (int side = 0; side < 2; ++side) {
		double lo[] = {mins.x, mins.y, mins.z}, hi[] = {maxs.x, maxs.y, maxs.z};
		double a[3] = {lo[0], lo[1], lo[2]}, b[3], c[3];
		a[axis] = side ? hi[axis] : lo[axis];
		for (int j = 0; j < 3; ++j) b[j] = c[j] = a[j];
		b[(axis + 1) % 3] = hi[(axis + 1) % 3];
		c[(axis + 2) % 3] = hi[(axis + 2) % 3];
		LMEditFace f; f.texture = texture; f.plane.uv_extra = {0, 1, 1};
		f.plane.plane_points = {{a[0], a[1], a[2]}, {b[0], b[1], b[2]}, {c[0], c[1], c[2]}};
		if (side) std::swap(f.plane.plane_points.v1, f.plane.plane_points.v2);
		brush.faces.push_back(f);
	}
	return brush;
}

bool lm_edit_prune_faces(LMEditPrimitive &brush) {
	std::string source = "{\n\"classname\" \"worldspawn\"\n{\n";
	for (const auto &f : brush.faces) source += lm_write_face(f.plane, f.texture);
	source += "}\n}\n";
	auto candidate = std::make_shared<LMMapData>();
	if (!LMMapParser(candidate).load_from_text(source)) return false;
	LMGeoGenerator(candidate).run();
	std::vector<LMEditFace> kept;
	for (size_t f = 0; f < brush.faces.size(); ++f) if (candidate->entity_geo[0].brushes[0].faces[f].vertex_count >= 3) kept.push_back(brush.faces[f]);
	if (kept.size() < 4) return false;
	brush.faces = std::move(kept);
	return true;
}
