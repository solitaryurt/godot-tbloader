#ifndef LM_EDITOR_BRUSH_GEOMETRY_H
#define LM_EDITOR_BRUSH_GEOMETRY_H

#include "brush.h"
#include "entity_geometry.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

struct LMEditorTextureSize {
	int width = 0;
	int height = 0;
};

struct LMEditorBrushBuildContext {
	const LMEditorTextureSize *textures = nullptr;
	size_t texture_count = 0;
};

struct LMEditorBrushCorner {
	uint32_t position = 0;
	LMVertexUV uv{};
};

struct LMEditorBrushEdge {
	uint32_t a = 0;
	uint32_t b = 0;
	uint32_t first_face = 0;
	uint32_t second_face = UINT32_MAX;
	uint32_t use_count = 0;
};

struct LMEditorBrushFace {
	uint32_t corner_begin = 0;
	uint32_t corner_count = 0;
	uint32_t index_count = 0;
	vec3 center{};
	vec3 plane_normal{};
	int texture_idx = -1;
};

// Editor-local, flat, owning geometry. Face windings are spans in corners and
// triangles are implicit fans: 0, i + 1, i + 2.
struct LMEditorBrushGeometry {
	int64_t brush_id = 0;
	uint64_t source_generation = 0;
	std::vector<vec3> positions;
	std::vector<LMEditorBrushCorner> corners;
	std::vector<LMEditorBrushFace> faces;
	std::vector<LMEditorBrushEdge> edges;
	vec3 mins{};
	vec3 maxs{};
	bool has_bounds = false;

	uint32_t face_index(uint32_t face, uint32_t index) const;
	size_t retained_bytes() const;
};

enum class LMEditorBrushBuildStatus : uint8_t {
	OK,
	INVALID_FACE_STORAGE,
	INVALID_TEXTURE_CONTEXT,
	SOURCE_TOKEN_MISMATCH,
	NONFINITE_SOURCE,
	LIMIT_EXCEEDED,
};

struct LMEditorBrushBuildResult {
	LMEditorBrushBuildStatus status = LMEditorBrushBuildStatus::OK;
	LMEditorBrushGeometry geometry;
	explicit operator bool() const { return status == LMEditorBrushBuildStatus::OK; }
};

// Builds one brush directly from source planes. It neither accepts generated
// LMBrushGeometry nor invokes LMGeoGenerator.
LMEditorBrushBuildResult lm_build_editor_brush_geometry(const LMBrush &brush, const LMEditorBrushBuildContext &context);
bool lm_validate_editor_brush_geometry(const LMBrush &brush, const LMEditorBrushGeometry &geometry);

struct LMEditorBrushUVUpdateResult {
	LMEditorBrushBuildStatus status = LMEditorBrushBuildStatus::OK;
	std::shared_ptr<const LMEditorBrushGeometry> geometry;
	size_t updated_faces = 0;
	size_t copied_bytes = 0;
	explicit operator bool() const { return status == LMEditorBrushBuildStatus::OK; }
};

// Reuses validated compact topology and updates only face-corner UVs whose
// texture dimensions differ. If no used dimension changed, geometry is shared.
LMEditorBrushUVUpdateResult lm_update_editor_brush_uvs(const LMBrush &brush,
		const std::shared_ptr<const LMEditorBrushGeometry> &geometry,
		const LMEditorBrushBuildContext &old_context, const LMEditorBrushBuildContext &new_context,
		uint64_t source_generation = 0);

enum class LMEditorBrushDirtyDomain : uint8_t {
	NONE = 0,
	TOPOLOGY = 1 << 0,
	POSITIONS = 1 << 1,
	UVS = 1 << 2,
	MATERIAL = 1 << 3,
	BOUNDS = 1 << 4,
	SPATIAL = 1 << 5,
	PREVIEW = 1 << 6,
	ALL = (1 << 7) - 1,
};

constexpr LMEditorBrushDirtyDomain operator|(LMEditorBrushDirtyDomain a, LMEditorBrushDirtyDomain b) {
	return static_cast<LMEditorBrushDirtyDomain>(static_cast<uint8_t>(a) | static_cast<uint8_t>(b));
}
constexpr LMEditorBrushDirtyDomain operator&(LMEditorBrushDirtyDomain a, LMEditorBrushDirtyDomain b) {
	return static_cast<LMEditorBrushDirtyDomain>(static_cast<uint8_t>(a) & static_cast<uint8_t>(b));
}

LMEditorBrushDirtyDomain lm_editor_brush_dirty_dependencies(LMEditorBrushDirtyDomain domains);

struct LMEditorBrushSourceToken {
	int64_t brush_id = 0;
	uint64_t source_generation = 0;
	uint64_t context_generation = 0;
	bool operator==(const LMEditorBrushSourceToken &other) const {
		return brush_id == other.brush_id && source_generation == other.source_generation &&
				context_generation == other.context_generation;
	}
	bool operator!=(const LMEditorBrushSourceToken &other) const { return !(*this == other); }
};

struct LMEditorBrushInstrumentation {
	uint64_t builds = 0;
	uint64_t cache_hits = 0;
	size_t retained_bytes = 0;
};

LMEditorBrushInstrumentation lm_editor_brush_instrumentation();
void lm_reset_editor_brush_instrumentation();

// Future document caches must supply a token that changes with source content.
// Phase 1 deliberately does not install slots into production document state.
class LMEditorBrushCacheSlot {
public:
	LMEditorBrushCacheSlot() = default;
	~LMEditorBrushCacheSlot();
	LMEditorBrushCacheSlot(const LMEditorBrushCacheSlot &) = delete;
	LMEditorBrushCacheSlot &operator=(const LMEditorBrushCacheSlot &) = delete;
	LMEditorBrushCacheSlot(LMEditorBrushCacheSlot &&other) noexcept;
	LMEditorBrushCacheSlot &operator=(LMEditorBrushCacheSlot &&other) noexcept;

	const LMEditorBrushBuildResult &ensure_geometry(const LMBrush &brush, const LMEditorBrushBuildContext &context,
			LMEditorBrushSourceToken token, LMEditorBrushDirtyDomain required = LMEditorBrushDirtyDomain::ALL);
	void invalidate(LMEditorBrushDirtyDomain domains = LMEditorBrushDirtyDomain::ALL);
	void clear();
	LMEditorBrushDirtyDomain dirty_domains() const { return dirty; }
	bool has_geometry() const { return populated; }
	size_t retained_bytes() const { return retained; }
	LMEditorBrushSourceToken source_token() const { return token; }

private:
	LMEditorBrushBuildResult value;
	LMEditorBrushSourceToken token{};
	LMEditorBrushDirtyDomain dirty = LMEditorBrushDirtyDomain::ALL;
	size_t retained = 0;
	bool populated = false;
};

#endif
