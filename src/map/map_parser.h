#ifndef MAP_PARSER_H
#define MAP_PARSER_H

#include "map_data.h"
#include <memory>
#include <string>
#ifndef LM_STANDALONE
#include <godot_cpp/classes/file_access.hpp>
#endif

struct LMParseError {
	std::string code;
	std::string message;
	int line = 0;
	int column = 0;
};

// Both bake and editor use the same bounded, transactional parser. The destination
// (including its geometry) is untouched on failure. Partial candidates own all data.
class LMMapParser {
public:
	static constexpr size_t MAX_TEXT_BYTES = 16 * 1024 * 1024;
	static constexpr int MAX_ENTITIES = 65536;
	static constexpr int MAX_PROPERTIES_PER_ENTITY = 8192;
	static constexpr int MAX_TOTAL_PROPERTIES = 262144;
	static constexpr int MAX_PRIMITIVES_PER_ENTITY = 16384;
	static constexpr int MAX_TOTAL_PRIMITIVES = 65536;
	static constexpr int MAX_TEXTURES = 4096;
	std::shared_ptr<LMMapData> map_data;
	LMParseError error;
	explicit LMMapParser(std::shared_ptr<LMMapData> data) : map_data(data) {}
	bool load_from_text(const std::string &text);
	bool load_from_path(const char *path);
#ifndef LM_STANDALONE
	bool load_from_godot_file(godot::Ref<godot::FileAccess> file);
#endif
};

#endif
