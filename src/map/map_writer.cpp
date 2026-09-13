#include "map_writer.h"
#include "brush.h"
#include "face.h"
#include "patch.h"
#include <charconv>
#include <limits>

namespace {
std::string quote(const char *text) {
	std::string out = "\"";
	for (; *text; ++text) {
		if (*text == '\\' || *text == '"') out += '\\';
		out += *text;
	}
	return out + '"';
}
template <typename T> void number(std::string &out, T value) {
	char buffer[64];
	auto converted = std::to_chars(buffer, buffer + sizeof(buffer), value, std::chars_format::general, std::numeric_limits<T>::max_digits10);
	out.append(buffer, converted.ptr);
}
void integer(std::string &out, int value) {
	char buffer[16];
	auto converted = std::to_chars(buffer, buffer + sizeof(buffer), value);
	out.append(buffer, converted.ptr);
}
void vector(std::string &out, const vec3 &v) { number(out, v.x); out += ' '; number(out, v.y); out += ' '; number(out, v.z); }
void point(std::string &out, const vec3 &v) { out += "( "; vector(out, v); out += " ) "; }
void brush(std::string &out, const LMMapData &map, const LMBrush &b) {
	out += "{\n";
	for (int i = 0; i < b.face_count; ++i) {
		out += lm_write_face(b.faces[i], map.textures[b.faces[i].texture_idx].name);
	}
	out += "}\n";
}
void patch(std::string &out, const LMMapData &map, const LMPatch &p) {
	out += "{\n"; out += p.is_def3 ? "patchDef3" : "patchDef2"; out += "\n{\n"; out += quote(map.textures[p.texture_idx].name); out += "\n( ";
	integer(out, p.width); out += ' '; integer(out, p.height);
	if (p.is_def3) { out += ' '; integer(out, p.subdiv_x); out += ' '; integer(out, p.subdiv_y); }
	for (int flag : p.header_flags) { out += ' '; integer(out, flag); }
	out += " )\n(\n";
	for (int x = 0; x < p.width; ++x) {
		out += "( ";
		for (int y = 0; y < p.height; ++y) {
			const auto &cp = p.control_points[y * p.width + x];
			out += "( "; vector(out, cp.position); out += ' '; number(out, cp.u); out += ' '; number(out, cp.v); out += " ) ";
		}
		out += ")\n";
	}
	out += ")\n}\n}\n";
}
}

std::string lm_write_map(const LMMapData &map) {
	std::string out;
	for (int i = 0; i < map.entity_count; ++i) {
		const auto &e = map.entities[i];
		out += "{\n";
		for (int k = 0; k < e.property_count; ++k) { out += quote(e.properties[k].key); out += ' '; out += quote(e.properties[k].value); out += '\n'; }
		for (int k = 0; k < e.primitive_count; ++k) {
			const auto &p = e.primitives[k];
			if (p.is_patch) patch(out, map, e.patches[p.index]);
			else brush(out, map, e.brushes[p.index]);
		}
		out += "}\n";
	}
	return out;
}

std::string lm_quote(const std::string &text) { return quote(text.c_str()); }
std::string lm_write_face(const LMFace &f, const std::string &texture) {
	std::string out;
	point(out, f.plane_points.v0); point(out, f.plane_points.v1); point(out, f.plane_points.v2);
	out += lm_quote(texture); out += ' ';
	if (f.is_valve_uv) {
		out += "[ "; vector(out, f.uv_valve.u.axis); out += ' '; number(out, f.uv_valve.u.offset); out += " ] [ ";
		vector(out, f.uv_valve.v.axis); out += ' '; number(out, f.uv_valve.v.offset); out += " ] ";
	} else { number(out, f.uv_standard.u); out += ' '; number(out, f.uv_standard.v); out += ' '; }
	number(out, f.uv_extra.rot); out += ' '; number(out, f.uv_extra.scale_x); out += ' '; number(out, f.uv_extra.scale_y);
	if (f.surface_flags.specified) { out += ' '; integer(out, f.surface_flags.contents); out += ' '; integer(out, f.surface_flags.surface); out += ' '; integer(out, f.surface_flags.value); }
	out += '\n';
	return out;
}
std::string lm_write_patch(const LMMapData &map, const LMPatch &p) {
	std::string out;
	patch(out, map, p);
	return out;
}
