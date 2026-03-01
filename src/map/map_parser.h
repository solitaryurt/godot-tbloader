#ifndef MAP_PARSER_H
#define MAP_PARSER_H

#include "brush.h"
#include "entity.h"
#include "face.h"
#include "libmap.h"
#include "map_data.h"
#include "patch.h"
#include <memory>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/ref.hpp>

typedef enum PARSE_SCOPE {
	PS_FILE,
	PS_COMMENT,
	PS_ENTITY,
	PS_PROPERTY_VALUE,
	PS_BRUSH,
	PS_PLANE_0,
	PS_PLANE_1,
	PS_PLANE_2,
	PS_TEXTURE,
	PS_U,
	PS_V,
	PS_VALVE_U,
	PS_VALVE_V,
	PS_ROT,
	PS_U_SCALE,
	PS_V_SCALE,
	// Patch parsing scopes
	PS_PATCH_DEF,           // saw patchDef2/patchDef3, waiting for '{'
	PS_PATCH_TEXTURE,       // reading texture name
	PS_PATCH_HEADER,        // reading ( width height ... ) header
	PS_PATCH_ROWS,          // waiting for outer '(' to start rows
	PS_PATCH_ROW,           // inside a row '(', reading control points
	PS_PATCH_CP,            // inside a control point '( x y z u v )'
	PS_PATCH_DONE,          // done reading rows, waiting for closing braces
} PARSE_SCOPE;

class LMMapParser {
private:
	PARSE_SCOPE scope = PS_FILE;
	bool comment = false;
	int entity_idx = -1;
	int brush_idx = -1;
	int face_idx = -1;
	int component_idx = 0;
	char *current_property = NULL;
	bool valve_uvs = false;

	LMFace current_face;
	LMBrush current_brush;
	LMEntity current_entity;

	// Patch parsing state
	LMPatch current_patch;
	int patch_idx = -1;
	int patch_row_idx = 0;       // current column in the control point grid (outer loop)
	int patch_cp_idx = 0;        // current row within the column (inner loop)
	int patch_header_idx = 0;    // index within the header ( W H 0 0 0 )
	bool patch_is_def3 = false;  // true for patchDef3
	int patch_done_brace_count = 0;  // counts '}' in PS_PATCH_DONE

	bool strings_match(const char *lhs, const char *rhs);

public:
	std::shared_ptr<LMMapData> map_data;

	bool load_from_path(const char *map_file);
	void load_from_godot_file(godot::Ref<godot::FileAccess> f);

	void token(const char *buf);
	void newline();

	void commit_face();
	void commit_brush();
	void commit_patch();
	void commit_entity();
	LMMapParser(std::shared_ptr<LMMapData> _map_data) :
			map_data(_map_data){};

private:
	void reset_current_face();
	void reset_current_entity();
	void reset_current_brush();
	void reset_current_patch();
	void set_scope(PARSE_SCOPE new_scope);
};

#endif
