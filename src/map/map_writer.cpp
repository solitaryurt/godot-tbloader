#include "map_writer.h"
#include "brush.h"
#include "face.h"
#include "patch.h"
#include <iomanip>
#include <limits>
#include <locale>
#include <sstream>

namespace {
std::string quote(const char *text) {
	std::string out = "\"";
	for (; *text; ++text) {
		if (*text == '\\' || *text == '"') out += '\\';
		out += *text;
	}
	return out + '"';
}
void vector(std::ostream &out, const vec3 &v) { out << v.x << ' ' << v.y << ' ' << v.z; }
void point(std::ostream &out, const vec3 &v) { out << "( "; vector(out, v); out << " ) "; }
void brush(std::ostream &out, const LMMapData &map, const LMBrush &b) {
	out << "{\n";
	for (int i = 0; i < b.face_count; ++i) {
		const auto &f = b.faces[i];
		point(out, f.plane_points.v0); point(out, f.plane_points.v1); point(out, f.plane_points.v2);
		out << quote(map.textures[f.texture_idx].name) << ' ';
		if (f.is_valve_uv) {
			out << "[ "; vector(out, f.uv_valve.u.axis); out << ' ' << f.uv_valve.u.offset << " ] [ ";
			vector(out, f.uv_valve.v.axis); out << ' ' << f.uv_valve.v.offset << " ] ";
		} else out << f.uv_standard.u << ' ' << f.uv_standard.v << ' ';
		out << f.uv_extra.rot << ' ' << f.uv_extra.scale_x << ' ' << f.uv_extra.scale_y;
		if (f.surface_flags.specified) out << ' ' << f.surface_flags.contents << ' ' << f.surface_flags.surface << ' ' << f.surface_flags.value;
		out << '\n';
	}
	out << "}\n";
}
void patch(std::ostream &out, const LMMapData &map, const LMPatch &p) {
	out << "{\n" << (p.is_def3 ? "patchDef3" : "patchDef2") << "\n{\n" << quote(map.textures[p.texture_idx].name) << "\n( " << p.width << ' ' << p.height;
	if (p.is_def3) out << ' ' << p.subdiv_x << ' ' << p.subdiv_y;
	for (int flag : p.header_flags) out << ' ' << flag;
	out << " )\n(\n";
	for (int x = 0; x < p.width; ++x) {
		out << "( ";
		for (int y = 0; y < p.height; ++y) {
			const auto &cp = p.control_points[y * p.width + x];
			out << "( "; vector(out, cp.position); out << ' ' << cp.u << ' ' << cp.v << " ) ";
		}
		out << ")\n";
	}
	out << ")\n}\n}\n";
}
}

std::string lm_write_map(const LMMapData &map) {
	std::ostringstream out;
	out.imbue(std::locale::classic());
	out << std::setprecision(std::numeric_limits<double>::max_digits10);
	for (int i = 0; i < map.entity_count; ++i) {
		const auto &e = map.entities[i];
		out << "{\n";
		for (int k = 0; k < e.property_count; ++k) out << quote(e.properties[k].key) << ' ' << quote(e.properties[k].value) << '\n';
		for (int k = 0; k < e.primitive_count; ++k) {
			const auto &p = e.primitives[k];
			if (p.is_patch) patch(out, map, e.patches[p.index]);
			else brush(out, map, e.brushes[p.index]);
		}
		out << "}\n";
	}
	return out.str();
}
