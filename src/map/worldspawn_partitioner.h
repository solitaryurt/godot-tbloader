#ifndef LIBMAP_WORLDSPAWN_PARTITIONER_H
#define LIBMAP_WORLDSPAWN_PARTITIONER_H

#include "entity.h"
#include "entity_geometry.h"

#include <cstdint>
#include <vector>

enum class LMWorldspawnPrimitiveKind {
	BRUSH,
	PATCH,
};

struct LMWorldspawnItem {
	int entity_index = -1;
	int primitive_ordinal = -1;
	LMWorldspawnPrimitiveKind kind = LMWorldspawnPrimitiveKind::BRUSH;
	int source_index = -1;
	vec3 mins = { 0, 0, 0 };
	vec3 maxs = { 0, 0, 0 };
	int64_t visual_triangle_count = 0;
	std::vector<int> texture_indices;
};

enum class LMWorldspawnExtractionStatus {
	OK,
	INVALID_SOURCE,
	INVALID_GEOMETRY,
	NONFINITE_GEOMETRY,
};

struct LMWorldspawnExtractionResult {
	LMWorldspawnExtractionStatus status = LMWorldspawnExtractionStatus::OK;
	std::vector<LMWorldspawnItem> items;

	explicit operator bool() const { return status == LMWorldspawnExtractionStatus::OK; }
};

struct LMWorldspawnPartitionSettings {
	double target_extent = 1.0;
	int64_t target_triangles = 1;
	int64_t max_chunks = 512;
};

struct LMWorldspawnChunk {
	std::vector<LMWorldspawnItem> items;
	vec3 mins = { 0, 0, 0 };
	vec3 maxs = { 0, 0, 0 };
	int64_t visual_triangle_count = 0;
	std::vector<int> texture_indices;
};

enum class LMWorldspawnPartitionStatus {
	OK,
	INVALID_SETTINGS,
	INVALID_ITEM,
	CAPACITY_EXCEEDED,
};

struct LMWorldspawnPartitionResult {
	LMWorldspawnPartitionStatus status = LMWorldspawnPartitionStatus::OK;
	std::vector<LMWorldspawnChunk> chunks;
	int64_t oversized_item_count = 0;
	int64_t isolated_oversized_item_count = 0;
	int64_t sparse_merge_count = 0;
	int64_t budget_merge_count = 0;
	int64_t forced_nonadjacent_merge_count = 0;
	int64_t chunks_with_unmet_soft_limits = 0;

	explicit operator bool() const { return status == LMWorldspawnPartitionStatus::OK; }
};

// Determinism contract:
// - Uses 16 center bins. A center on a split plane belongs to the right side.
// - Scores use normalized AABB measure * triangle share, plus fixed overlap
//   (0.25) and material-proliferation (0.01) penalties.
// - Scores within 1e-12 tie; ties prefer overlap, triangle balance, X/Y/Z,
//   then the lower split coordinate.
// - Items in chunks are ordered by source identity. Chunks are ordered by
//   bounds, then their first source identity. Input order never participates.
// - Oversized peers merge only when every axis gap is at most 25% of the
//   target extent, union measure is at most 1.25x their summed measure, merge
//   cost decreases, and union span on each axis is no greater than the largest
//   original member span on that axis plus 25% of the target extent.
// - AABBs are adjacent when their closed intervals touch or overlap on every
//   axis, including zero-extent axes. Sparse adjacent normal leaves merge only
//   within soft limits and when normalized instance cost strictly decreases.
// - Normal splitting consumes only the chunk budget left by oversized groups.
//   Budget merges choose the globally lowest-cost pair and separately report
//   when that chosen pair is nonadjacent. All pair ties use bounds and source
//   identity; input order never participates.
LMWorldspawnPartitionResult lm_partition_worldspawn_items(
		const std::vector<LMWorldspawnItem> &items,
		const LMWorldspawnPartitionSettings &settings);

// Exclusions are texture indices supplied by the caller, so this module does
// not depend on loader settings, texture names, or Godot types.
LMWorldspawnExtractionResult lm_extract_worldspawn_items(
		int entity_index,
		const LMEntity &entity,
		const LMEntityGeometry &geometry,
		const std::vector<int> &excluded_texture_indices = {});

#endif
