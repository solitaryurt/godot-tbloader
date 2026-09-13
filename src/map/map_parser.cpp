#include "map_parser.h"
#include "brush.h"
#include "face.h"
#include "patch.h"
#include "platform.h"
#include <cmath>
#include <cctype>
#include <cstring>
#include <fstream>
#include <limits>
#include <locale>
#include <sstream>

namespace {
template <typename T> T &append(T *&items, int &count) {
	items = static_cast<T *>(realloc(items, (count + 1) * sizeof(T)));
	items[count] = T{};
	return items[count++];
}

struct Token {
	std::string text;
	int line = 1, column = 1;
	bool quoted = false;
};

class Parser {
	const std::string &source;
	LMMapData &map;
	LMParseError &error;
	size_t offset = 0;
	int line = 1, column = 1;
	size_t work = 0;
	Token current;
	char peek(size_t ahead = 0) const { return offset + ahead < source.size() ? source[offset + ahead] : '\0'; }
	char take() {
		char c = source[offset++];
		if (c == '\n') { ++line; column = 1; } else { ++column; }
		return c;
	}
	bool fail(const char *message, const char *code = "PARSE_ERROR") {
		if (error.code.empty()) error = { code, message, current.line, current.column };
		return false;
	}
	bool next() {
		for (;;) {
			while (peek() && std::isspace(static_cast<unsigned char>(peek()))) take();
			if (peek() == '/' && peek(1) == '/') {
				while (peek() && peek() != '\n') take();
			} else if (peek() == '/' && peek(1) == '*') {
				current = { "", line, column, false };
				take(); take();
				while (peek() && !(peek() == '*' && peek(1) == '/')) take();
				if (!peek()) return fail("Unterminated block comment");
				take(); take();
			} else break;
		}
		current = { "", line, column, false };
		if (!peek()) return offset == source.size() || fail("NUL byte in map");
		char c = take();
		if (c == '"') {
			current.quoted = true;
			while (peek() && peek() != '"') {
				c = take();
				// Only quote/backslash escapes are interpreted. Unknown escapes keep
				// their slash (e.g. entity paths); writer escapes all literal slashes.
				if (c == '\\' && (peek() == '"' || peek() == '\\')) c = take();
				current.text += c;
				if (current.text.size() > 65536) return fail("Token exceeds 64 KiB", "LIMIT_EXCEEDED");
			}
			if (!peek()) return fail("Unterminated quoted string");
			take();
		} else if (std::string("{}()[]").find(c) != std::string::npos) {
			current.text += c;
		} else {
			current.text += c;
			while (peek() && !std::isspace(static_cast<unsigned char>(peek())) && std::string("{}()[]\"").find(peek()) == std::string::npos) {
				if (peek() == '/' && (peek(1) == '/' || peek(1) == '*')) break;
				current.text += take();
				if (current.text.size() > 65536) return fail("Token exceeds 64 KiB", "LIMIT_EXCEEDED");
			}
		}
		return true;
	}
	bool is(const char *s) const { return !current.quoted && current.text == s; }
	bool expect(const char *s) {
		if (!is(s)) return fail("Unexpected token or end of file");
		return next();
	}
	bool number(double &out) {
		std::istringstream in(current.text);
		in.imbue(std::locale::classic());
		if (current.quoted || !(in >> out) || !in.eof() || !std::isfinite(out)) return fail("Expected a finite number");
		if (std::abs(out) > 1e9) return fail("Numeric magnitude exceeds 1e9", "LIMIT_EXCEEDED");
		return next();
	}
	bool integer(int &out) {
		// Flags use the complete signed 32-bit range, independently of coordinate limits.
		std::istringstream in(current.text);
		in.imbue(std::locale::classic());
		int64_t value;
		if (current.quoted || !(in >> value) || !in.eof() || value < INT32_MIN || value > INT32_MAX) return fail("Expected a signed 32-bit integer");
		out = static_cast<int>(value);
		return next();
	}
	bool vector(vec3 &v) { return number(v.x) && number(v.y) && number(v.z); }
	bool point(vec3 &v) { return expect("(") && vector(v) && expect(")"); }
	bool texture(int &index) {
		if (current.text.empty() || (!current.quoted && current.text.find_first_of("{}()[]") != std::string::npos)) return fail("Expected texture name");
		index = map.map_data_register_texture(current.text.c_str());
		return next();
	}
	bool face(LMFace &f) {
		if (!point(f.plane_points.v0) || !point(f.plane_points.v1) || !point(f.plane_points.v2) || !texture(f.texture_idx)) return false;
		f.is_valve_uv = is("[");
		if (f.is_valve_uv) {
			if (!expect("[") || !vector(f.uv_valve.u.axis) || !number(f.uv_valve.u.offset) || !expect("]") ||
					!expect("[") || !vector(f.uv_valve.v.axis) || !number(f.uv_valve.v.offset) || !expect("]")) return false;
			if (vec3_dot(f.uv_valve.u.axis, f.uv_valve.u.axis) < 1e-18 || vec3_dot(f.uv_valve.v.axis, f.uv_valve.v.axis) < 1e-18) return fail("Zero Valve projection axis", "INVALID_GEOMETRY");
		} else if (!number(f.uv_standard.u) || !number(f.uv_standard.v)) return false;
		if (!number(f.uv_extra.rot) || !number(f.uv_extra.scale_x) || !number(f.uv_extra.scale_y)) return false;
		if (std::abs(f.uv_extra.scale_x) < 1e-9 || std::abs(f.uv_extra.scale_y) < 1e-9) return fail("Texture scale is zero or too small", "INVALID_GEOMETRY");
		if (!is("(") && !is("}") && !current.text.empty()) {
			f.surface_flags.specified = true;
			if (!integer(f.surface_flags.contents) || !integer(f.surface_flags.surface) || !integer(f.surface_flags.value)) return false;
		}
		vec3 n = vec3_cross(vec3_sub(f.plane_points.v2, f.plane_points.v1), vec3_sub(f.plane_points.v1, f.plane_points.v0));
		if (vec3_dot(n, n) < 1e-18) return fail("Degenerate face plane", "INVALID_GEOMETRY");
		f.plane_normal = vec3_normalize(n);
		f.plane_dist = vec3_dot(f.plane_normal, f.plane_points.v0);
		return true;
	}
	bool patch(LMPatch &p) {
		p.is_def3 = is("patchDef3");
		if (!next() || !expect("{") || !texture(p.texture_idx) || !expect("(") || !integer(p.width) || !integer(p.height)) return false;
		if (p.width < 3 || p.height < 3 || !(p.width & 1) || !(p.height & 1)) return fail("Patch dimensions must be odd and at least three");
		if (p.width > 31 || p.height > 31) return fail("Patch dimensions exceed 31", "LIMIT_EXCEEDED");
		if (p.is_def3 && (!integer(p.subdiv_x) || !integer(p.subdiv_y))) return false;
		if (p.subdiv_x < 0 || p.subdiv_y < 0) return fail("Negative patch subdivisions");
		if (p.subdiv_x > 32 || p.subdiv_y > 32) return fail("Patch subdivisions exceed 32", "LIMIT_EXCEEDED");
		for (int &flag : p.header_flags) if (!integer(flag)) return false;
		if (!expect(")") || !expect("(")) return false;
		work += size_t(p.width) * p.height * 33 * 33;
		if (work > 8000000) return fail("Geometry work budget exceeded", "LIMIT_EXCEEDED");
		p.control_points = static_cast<LMPatchControlPoint *>(calloc(p.width * p.height, sizeof(LMPatchControlPoint)));
		for (int x = 0; x < p.width; ++x) {
			if (!expect("(")) return false;
			for (int y = 0; y < p.height; ++y) {
				auto &cp = p.control_points[y * p.width + x];
				if (!expect("(") || !vector(cp.position) || !number(cp.u) || !number(cp.v) || !expect(")")) return false;
			}
			if (!expect(")")) return false;
		}
		return expect(")") && expect("}") && expect("}");
	}
	bool primitive(LMEntity &e) {
		if (!expect("{")) return false;
		auto &order = append(e.primitives, e.primitive_count);
		if (is("patchDef2") || is("patchDef3")) {
			order = { true, e.patch_count };
			return patch(append(e.patches, e.patch_count));
		}
		if (!is("(")) return fail("Unsupported or empty primitive; expected brush faces or patchDef2/3", "UNSUPPORTED_SYNTAX");
		order = { false, e.brush_count };
		auto &b = append(e.brushes, e.brush_count);
		while (is("(")) {
			if (b.face_count >= 64) return fail("Brush exceeds 64 faces", "LIMIT_EXCEEDED");
			if (!face(append(b.faces, b.face_count))) return false;
		}
		if (b.face_count < 4) return fail("Brush requires at least four planes", "INVALID_GEOMETRY");
		work += size_t(b.face_count) * b.face_count * b.face_count;
		if (work > 8000000) return fail("Geometry work budget exceeded", "LIMIT_EXCEEDED");
		return expect("}");
	}
public:
	Parser(const std::string &s, LMMapData &m, LMParseError &e) : source(s), map(m), error(e) {}
	bool run() {
		if (source.size() > LMMapParser::MAX_TEXT_BYTES) return fail("Map exceeds 16 MiB", "LIMIT_EXCEEDED");
		// Validate before any Godot String conversion: invalid bytes must return a
		// Result diagnostic, not engine Unicode errors or replacement characters.
		int byte_line = 1, byte_column = 1;
		for (size_t i = 0; i < source.size();) {
			unsigned char c = source[i];
			current.line = byte_line; current.column = byte_column;
			if (c == 0) return fail("NUL byte in map");
			int length = c < 0x80 ? 1 : c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
			if (!length || i + length > source.size()) return fail("Map is not valid UTF-8");
			for (int j = 1; j < length; ++j) {
				unsigned char next = source[i + j];
				if (next < 0x80 || next > 0xbf) return fail("Map is not valid UTF-8");
			}
			if (length >= 3) {
				unsigned char second = source[i + 1];
				if ((c == 0xe0 && second < 0xa0) || (c == 0xed && second >= 0xa0) || (c == 0xf0 && second < 0x90) || (c == 0xf4 && second >= 0x90)) return fail("Map is not valid UTF-8");
			}
			if (c == '\n') { ++byte_line; byte_column = 1; } else byte_column += length;
			i += length;
		}
		// UTF-8 BOM is formatting, not an entity or a shader token.
		if (source.compare(0, 3, "\xef\xbb\xbf") == 0) { offset = 3; column = 4; }
		if (!next()) return false;
		while (!current.text.empty() || current.quoted) {
			if (map.entity_count >= 65536) return fail("Too many entities", "LIMIT_EXCEEDED");
			if (!expect("{")) return false;
			auto &e = append(map.entities, map.entity_count);
			e.spawn_type = EST_ENTITY;
			while (!is("}")) {
				if (current.quoted) {
					auto &prop = append(e.properties, e.property_count);
					prop.key = STRDUP(current.text.c_str());
					if (!next()) return false;
					if (!current.quoted) return fail("Expected quoted entity property value");
					prop.value = STRDUP(current.text.c_str());
					if (!next()) return false;
				} else if (is("{")) {
					if (!primitive(e)) return false;
				} else return fail("Expected entity property, primitive or closing brace");
			}
			if (!next()) return false;
		}
		if (!map.entity_count) return fail("Map contains no entities");
		return true;
	}
};
}

bool LMMapParser::load_from_text(const std::string &text) {
	error = {};
	LMMapData candidate;
	if (!Parser(text, candidate, error).run()) return false;
	map_data->swap(candidate);
	return true;
}

bool LMMapParser::load_from_path(const char *path) {
	error = {};
	std::ifstream file(path, std::ios::binary | std::ios::ate);
	if (!file) { error = { "IO_READ", "Cannot open map", 0, 0 }; return false; }
	auto size = file.tellg();
	if (size < 0 || size > static_cast<std::streamoff>(MAX_TEXT_BYTES)) { error = { "LIMIT_EXCEEDED", "Map exceeds 16 MiB", 0, 0 }; return false; }
	std::string text(static_cast<size_t>(size), '\0');
	file.seekg(0);
	if (!file.read(&text[0], size)) { error = { "IO_READ", "Cannot read map", 0, 0 }; return false; }
	return load_from_text(text);
}

#ifndef LM_STANDALONE
bool LMMapParser::load_from_godot_file(godot::Ref<godot::FileAccess> file) {
	error = {};
	if (file.is_null()) { error = { "IO_READ", "Cannot open map", 0, 0 }; return false; }
	if (file->get_length() > MAX_TEXT_BYTES) { error = { "LIMIT_EXCEEDED", "Map exceeds 16 MiB", 0, 0 }; return false; }
	file->seek(0);
	auto bytes = file->get_buffer(file->get_length());
	if (static_cast<uint64_t>(bytes.size()) != file->get_length()) { error = { "IO_READ", "Short map read", 0, 0 }; return false; }
	return load_from_text(std::string(reinterpret_cast<const char *>(bytes.ptr()), bytes.size()));
}
#endif
