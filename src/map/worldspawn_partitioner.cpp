#include "worldspawn_partitioner.h"

#include "brush.h"
#include "face.h"
#include "patch.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <queue>
#include <tuple>

namespace {
bool excluded(int texture_index, const std::vector<int> &indices) {
	return std::find(indices.begin(), indices.end(), texture_index) != indices.end();
}

bool finite(const LMFaceVertex &vertex) {
	return std::isfinite(vertex.vertex.x) && std::isfinite(vertex.vertex.y) && std::isfinite(vertex.vertex.z) &&
			std::isfinite(vertex.normal.x) && std::isfinite(vertex.normal.y) && std::isfinite(vertex.normal.z) &&
			std::isfinite(vertex.uv.u) && std::isfinite(vertex.uv.v) &&
			std::isfinite(vertex.tangent.x) && std::isfinite(vertex.tangent.y) &&
			std::isfinite(vertex.tangent.z) && std::isfinite(vertex.tangent.w);
}

bool valid_mesh(const LMFaceVertex *vertices, int vertex_count, const int *indices, int index_count) {
	if (vertex_count < 0 || index_count < 0 || index_count % 3 != 0) return false;
	if ((vertex_count > 0 && vertices == nullptr) || (index_count > 0 && indices == nullptr)) return false;
	for (int i = 0; i < index_count; ++i) {
		if (indices[i] < 0 || indices[i] >= vertex_count) return false;
	}
	return true;
}

void include_vertices(LMWorldspawnItem &item, const LMFaceVertex *vertices, int count, bool &has_bounds) {
	for (int i = 0; i < count; ++i) {
		const vec3 point = vertices[i].vertex;
		if (!has_bounds) {
			item.mins = item.maxs = point;
			has_bounds = true;
		} else {
			item.mins = { std::min(item.mins.x, point.x), std::min(item.mins.y, point.y), std::min(item.mins.z, point.z) };
			item.maxs = { std::max(item.maxs.x, point.x), std::max(item.maxs.y, point.y), std::max(item.maxs.z, point.z) };
		}
	}
}

bool finite_vertices(const LMFaceVertex *vertices, int count) {
	for (int i = 0; i < count; ++i) if (!finite(vertices[i])) return false;
	return true;
}

void finish_textures(LMWorldspawnItem &item) {
	std::sort(item.texture_indices.begin(), item.texture_indices.end());
	item.texture_indices.erase(std::unique(item.texture_indices.begin(), item.texture_indices.end()), item.texture_indices.end());
}

constexpr int PARTITION_BIN_COUNT = 16;
constexpr long double SCORE_TOLERANCE = 1e-12L;
constexpr long double OVERLAP_WEIGHT = 0.25L;
constexpr long double MATERIAL_WEIGHT = 0.01L;
constexpr long double OVERSIZED_REGION_GAP = 0.25L;
constexpr long double OVERSIZED_INFLATION_LIMIT = 1.25L;

struct Bounds {
	std::array<long double, 3> mins = {};
	std::array<long double, 3> maxs = {};
};

struct ClusterMetrics {
	Bounds bounds;
	int64_t triangles = 0;
	std::vector<int> textures;
};

struct Split {
	bool valid = false;
	int axis = 0;
	long double coordinate = 0;
	long double score = 0;
	long double overlap = 0;
	int64_t triangle_balance = 0;
	std::vector<size_t> left;
	std::vector<size_t> right;
};

long double component(const vec3 &value, int axis) {
	return axis == 0 ? value.x : axis == 1 ? value.y : value.z;
}

auto item_key(const LMWorldspawnItem &item) {
	return std::make_tuple(item.entity_index, item.primitive_ordinal, static_cast<int>(item.kind), item.source_index);
}

bool finite_item(const LMWorldspawnItem &item) {
	if (item.entity_index < 0 || item.primitive_ordinal < 0 || item.source_index < 0 || item.visual_triangle_count <= 0 ||
			(item.kind != LMWorldspawnPrimitiveKind::BRUSH && item.kind != LMWorldspawnPrimitiveKind::PATCH)) return false;
	for (int axis = 0; axis < 3; ++axis) {
		const double lo = component(item.mins, axis);
		const double hi = component(item.maxs, axis);
		if (!std::isfinite(lo) || !std::isfinite(hi) || lo > hi) return false;
	}
	return true;
}

long double center(const LMWorldspawnItem &item, int axis) {
	return (static_cast<long double>(component(item.mins, axis)) + component(item.maxs, axis)) / 2.0L;
}

Bounds item_bounds(const LMWorldspawnItem &item) {
	Bounds result;
	for (int axis = 0; axis < 3; ++axis) {
		result.mins[axis] = component(item.mins, axis);
		result.maxs[axis] = component(item.maxs, axis);
	}
	return result;
}

void include(Bounds &bounds, const Bounds &other) {
	for (int axis = 0; axis < 3; ++axis) {
		bounds.mins[axis] = std::min(bounds.mins[axis], other.mins[axis]);
		bounds.maxs[axis] = std::max(bounds.maxs[axis], other.maxs[axis]);
	}
}

bool merge_textures(std::vector<int> &destination, const std::vector<int> &source) {
	if (source.size() > destination.max_size() - destination.size()) return false;
	destination.insert(destination.end(), source.begin(), source.end());
	std::sort(destination.begin(), destination.end());
	destination.erase(std::unique(destination.begin(), destination.end()), destination.end());
	return true;
}

bool cluster_metrics(const std::vector<LMWorldspawnItem> &items, const std::vector<size_t> &indices, ClusterMetrics &result) {
	result = {};
	if (indices.empty()) return false;
	if (indices.front() >= items.size()) return false;
	result.bounds = item_bounds(items[indices.front()]);
	for (size_t index : indices) {
		if (index >= items.size()) return false;
		const auto &item = items[index];
		include(result.bounds, item_bounds(item));
		if (item.visual_triangle_count > std::numeric_limits<int64_t>::max() - result.triangles) return false;
		result.triangles += item.visual_triangle_count;
		if (!merge_textures(result.textures, item.texture_indices)) return false;
	}
	return true;
}

bool finite_metric(long double value) {
	return std::isfinite(value);
}

bool extent(const Bounds &bounds, int axis, long double &result) {
	result = bounds.maxs[axis] - bounds.mins[axis];
	return result >= 0 && finite_metric(result) && std::isfinite(static_cast<double>(result));
}

// Surface area is used for volumes and planes. The lower-dimensional fallback
// keeps line and point bounds partitionable without injecting scale-dependent epsilon.
bool measure(const Bounds &bounds, long double scale, long double &result) {
	if (!(scale > 0) || !finite_metric(scale)) return false;
	std::array<long double, 3> normalized_extent;
	for (int axis = 0; axis < 3; ++axis) {
		long double physical_extent;
		if (!extent(bounds, axis, physical_extent)) return false;
		normalized_extent[axis] = physical_extent / scale;
		if (!finite_metric(normalized_extent[axis])) return false;
	}
	const long double area = normalized_extent[0] * normalized_extent[1] +
			normalized_extent[1] * normalized_extent[2] + normalized_extent[2] * normalized_extent[0];
	if (!finite_metric(area)) return false;
	if (area > 0) {
		result = area;
		return true;
	}
	const long double length = normalized_extent[0] + normalized_extent[1] + normalized_extent[2];
	if (!finite_metric(length)) return false;
	result = length;
	return true;
}

bool less_with_tolerance(long double left, long double right) {
	return left < right - SCORE_TOLERANCE;
}

struct WorkingChunk {
	std::vector<size_t> indices;
	ClusterMetrics metrics;
	std::array<long double, 3> largest_member_extent = {};
	bool normal = true;
};

bool initialize_chunk(const std::vector<LMWorldspawnItem> &items, const std::vector<size_t> &indices,
		bool normal, WorkingChunk &chunk) {
	chunk = {};
	chunk.indices = indices;
	chunk.normal = normal;
	if (!cluster_metrics(items, indices, chunk.metrics)) return false;
	for (size_t index : indices) {
		if (index >= items.size()) return false;
		const Bounds bounds = item_bounds(items[index]);
		for (int axis = 0; axis < 3; ++axis) {
			long double item_extent;
			if (!extent(bounds, axis, item_extent)) return false;
			chunk.largest_member_extent[axis] = std::max(chunk.largest_member_extent[axis], item_extent);
		}
	}
	return true;
}

bool bounds_less(const Bounds &left, const Bounds &right) {
	for (int axis = 0; axis < 3; ++axis)
		if (left.mins[axis] != right.mins[axis]) return left.mins[axis] < right.mins[axis];
	for (int axis = 0; axis < 3; ++axis)
		if (left.maxs[axis] != right.maxs[axis]) return left.maxs[axis] < right.maxs[axis];
	return false;
}

bool working_less(const WorkingChunk &left, const WorkingChunk &right) {
	if (bounds_less(left.metrics.bounds, right.metrics.bounds)) return true;
	if (bounds_less(right.metrics.bounds, left.metrics.bounds)) return false;
	return left.indices < right.indices;
}

bool adjacent(const Bounds &left, const Bounds &right) {
	for (int axis = 0; axis < 3; ++axis) {
		if (left.maxs[axis] < right.mins[axis] || right.maxs[axis] < left.mins[axis]) return false;
	}
	return true;
}

bool exceeds_soft_limits(const ClusterMetrics &metrics, const LMWorldspawnPartitionSettings &settings) {
	if (metrics.triangles > settings.target_triangles) return true;
	for (int axis = 0; axis < 3; ++axis) {
		long double physical_extent;
		if (!extent(metrics.bounds, axis, physical_extent) || physical_extent > settings.target_extent) return true;
	}
	return false;
}

bool instance_cost(const ClusterMetrics &metrics, const LMWorldspawnPartitionSettings &settings, long double &result) {
	long double bounds_measure;
	if (!measure(metrics.bounds, settings.target_extent, bounds_measure)) return false;
	const long double triangle_share = static_cast<long double>(metrics.triangles) / settings.target_triangles;
	if (!finite_metric(triangle_share)) return false;
	result = 1.0L + bounds_measure * triangle_share + MATERIAL_WEIGHT * metrics.textures.size();
	return finite_metric(result);
}

bool merge_lowers_cost(const WorkingChunk &left, const WorkingChunk &right,
		const WorkingChunk &merged, const LMWorldspawnPartitionSettings &settings) {
	long double merged_cost, left_cost, right_cost;
	if (!instance_cost(merged.metrics, settings, merged_cost) ||
			!instance_cost(left.metrics, settings, left_cost) ||
			!instance_cost(right.metrics, settings, right_cost)) return false;
	const long double separate_cost = left_cost + right_cost;
	return finite_metric(separate_cost) &&
			less_with_tolerance(merged_cost, separate_cost);
}

bool regional_oversized_pair(const WorkingChunk &left, const WorkingChunk &right,
		const WorkingChunk &merged, const LMWorldspawnPartitionSettings &settings) {
	const long double regional_allowance = OVERSIZED_REGION_GAP * settings.target_extent;
	if (!finite_metric(regional_allowance)) return false;
	for (int axis = 0; axis < 3; ++axis) {
		const long double gap = std::max(0.0L, std::max(left.metrics.bounds.mins[axis], right.metrics.bounds.mins[axis]) -
				std::min(left.metrics.bounds.maxs[axis], right.metrics.bounds.maxs[axis]));
		long double union_extent;
		const long double span_limit = merged.largest_member_extent[axis] + regional_allowance;
		if (!finite_metric(gap) || !finite_metric(span_limit) || gap > regional_allowance ||
				!extent(merged.metrics.bounds, axis, union_extent) || union_extent > span_limit) return false;
	}
	long double combined_measure, left_measure, right_measure;
	if (!measure(merged.metrics.bounds, 1.0L, combined_measure) ||
			!measure(left.metrics.bounds, 1.0L, left_measure) ||
			!measure(right.metrics.bounds, 1.0L, right_measure)) return false;
	const long double separate_measure = left_measure + right_measure;
	const long double inflation_limit = OVERSIZED_INFLATION_LIMIT * separate_measure;
	return finite_metric(separate_measure) && finite_metric(inflation_limit) &&
			combined_measure <= inflation_limit &&
			merge_lowers_cost(left, right, merged, settings);
}

bool merged_metrics(const WorkingChunk &left, const WorkingChunk &right, WorkingChunk &merged) {
	if (right.indices.size() > left.indices.max_size() - left.indices.size()) return false;
	merged.indices = left.indices;
	merged.indices.insert(merged.indices.end(), right.indices.begin(), right.indices.end());
	std::sort(merged.indices.begin(), merged.indices.end());
	merged.normal = left.normal && right.normal;
	for (int axis = 0; axis < 3; ++axis)
		merged.largest_member_extent[axis] = std::max(left.largest_member_extent[axis], right.largest_member_extent[axis]);
	merged.metrics = left.metrics;
	if (right.metrics.triangles > std::numeric_limits<int64_t>::max() - merged.metrics.triangles) return false;
	include(merged.metrics.bounds, right.metrics.bounds);
	merged.metrics.triangles += right.metrics.triangles;
	return merge_textures(merged.metrics.textures, right.metrics.textures);
}

bool merged_metrics_only(const WorkingChunk &left, const WorkingChunk &right, WorkingChunk &merged) {
	merged.normal = left.normal && right.normal;
	for (int axis = 0; axis < 3; ++axis)
		merged.largest_member_extent[axis] = std::max(left.largest_member_extent[axis], right.largest_member_extent[axis]);
	merged.metrics = left.metrics;
	if (right.metrics.triangles > std::numeric_limits<int64_t>::max() - merged.metrics.triangles) return false;
	include(merged.metrics.bounds, right.metrics.bounds);
	merged.metrics.triangles += right.metrics.triangles;
	return merge_textures(merged.metrics.textures, right.metrics.textures);
}

struct MergeCandidate {
	bool valid = false;
	size_t left = 0;
	size_t right = 0;
	long double cost = 0;
	WorkingChunk merged;
};

bool merge_better(const MergeCandidate &candidate, const MergeCandidate &best,
		const std::vector<WorkingChunk> &chunks) {
	if (!best.valid) return true;
	if (less_with_tolerance(candidate.cost, best.cost)) return true;
	if (less_with_tolerance(best.cost, candidate.cost)) return false;
	if (working_less(candidate.merged, best.merged)) return true;
	if (working_less(best.merged, candidate.merged)) return false;
	const auto candidate_pair = std::make_pair(chunks[candidate.left].indices, chunks[candidate.right].indices);
	const auto best_pair = std::make_pair(chunks[best.left].indices, chunks[best.right].indices);
	return candidate_pair < best_pair;
}

template <typename Predicate>
MergeCandidate best_merge(const std::vector<WorkingChunk> &chunks, const LMWorldspawnPartitionSettings &settings,
		Predicate predicate) {
	MergeCandidate best;
	for (size_t left = 0; left < chunks.size(); ++left) {
		for (size_t right = left + 1; right < chunks.size(); ++right) {
			MergeCandidate candidate;
			candidate.valid = merged_metrics_only(chunks[left], chunks[right], candidate.merged);
			if (!candidate.valid || !predicate(chunks[left], chunks[right], candidate.merged)) continue;
			candidate.left = left;
			candidate.right = right;
			long double merged_cost, left_cost, right_cost;
			if (!instance_cost(candidate.merged.metrics, settings, merged_cost) ||
					!instance_cost(chunks[left].metrics, settings, left_cost) ||
					!instance_cost(chunks[right].metrics, settings, right_cost)) continue;
			candidate.cost = merged_cost - left_cost - right_cost;
			if (!finite_metric(candidate.cost)) continue;
			// Membership does not affect score. Materialize it only for a candidate
			// which can win, rather than once for every pair in every merge round.
			if (best.valid && less_with_tolerance(best.cost, candidate.cost)) continue;
			if (!merged_metrics(chunks[left], chunks[right], candidate.merged)) continue;
			if (merge_better(candidate, best, chunks)) best = std::move(candidate);
		}
	}
	return best;
}

void apply_merge(std::vector<WorkingChunk> &chunks, MergeCandidate candidate) {
	chunks.erase(chunks.begin() + candidate.right);
	chunks.erase(chunks.begin() + candidate.left);
	chunks.push_back(std::move(candidate.merged));
	std::sort(chunks.begin(), chunks.end(), working_less);
}

struct BudgetChunk {
	WorkingChunk chunk;
	bool active = true;
};

struct BudgetCandidate {
	std::shared_ptr<BudgetChunk> left;
	std::shared_ptr<BudgetChunk> right;
	ClusterMetrics metrics;
	long double cost = 0;
};

struct BudgetCandidateLater {
	bool operator()(const BudgetCandidate &left, const BudgetCandidate &right) const {
		if (left.cost != right.cost) return left.cost > right.cost;
		return std::make_pair(left.left.get(), left.right.get()) > std::make_pair(right.left.get(), right.right.get());
	}
};

using BudgetQueue = std::priority_queue<BudgetCandidate, std::vector<BudgetCandidate>, BudgetCandidateLater>;

BudgetCandidate budget_candidate(const std::shared_ptr<BudgetChunk> &first,
		const std::shared_ptr<BudgetChunk> &second, const LMWorldspawnPartitionSettings &settings) {
	BudgetCandidate candidate;
	if (working_less(second->chunk, first->chunk)) {
		candidate.left = second;
		candidate.right = first;
	} else {
		candidate.left = first;
		candidate.right = second;
	}
	WorkingChunk merged;
	if (!merged_metrics_only(candidate.left->chunk, candidate.right->chunk, merged)) return {};
	candidate.metrics = std::move(merged.metrics);
	long double merged_cost, left_cost, right_cost;
	if (!instance_cost(candidate.metrics, settings, merged_cost) ||
			!instance_cost(candidate.left->chunk.metrics, settings, left_cost) ||
			!instance_cost(candidate.right->chunk.metrics, settings, right_cost)) return {};
	candidate.cost = merged_cost - left_cost - right_cost;
	if (!finite_metric(candidate.cost)) return {};
	return candidate;
}

bool budget_candidate_better(const BudgetCandidate &candidate, const BudgetCandidate &best) {
	if (less_with_tolerance(candidate.cost, best.cost)) return true;
	if (less_with_tolerance(best.cost, candidate.cost)) return false;
	WorkingChunk candidate_merged, best_merged;
	if (!merged_metrics(candidate.left->chunk, candidate.right->chunk, candidate_merged) ||
			!merged_metrics(best.left->chunk, best.right->chunk, best_merged)) return false;
	if (working_less(candidate_merged, best_merged)) return true;
	if (working_less(best_merged, candidate_merged)) return false;
	return std::make_pair(candidate.left->chunk.indices, candidate.right->chunk.indices) <
			std::make_pair(best.left->chunk.indices, best.right->chunk.indices);
}

bool active(const BudgetCandidate &candidate) {
	return candidate.left && candidate.right && candidate.left->active && candidate.right->active;
}

bool take_best_budget_candidate(BudgetQueue &queue, BudgetCandidate &best) {
	while (!queue.empty() && !active(queue.top())) queue.pop();
	if (queue.empty()) return false;
	const long double minimum = queue.top().cost;
	std::vector<BudgetCandidate> contenders;
	while (!queue.empty() && queue.top().cost <= minimum + SCORE_TOLERANCE) {
		BudgetCandidate candidate = queue.top();
		queue.pop();
		if (active(candidate)) contenders.push_back(std::move(candidate));
	}
	if (contenders.empty()) return take_best_budget_candidate(queue, best);
	size_t best_index = 0;
	for (size_t i = 1; i < contenders.size(); ++i)
		if (budget_candidate_better(contenders[i], contenders[best_index])) best_index = i;
	best = contenders[best_index];
	for (size_t i = 0; i < contenders.size(); ++i)
		if (i != best_index) queue.push(std::move(contenders[i]));
	return true;
}

bool enforce_budget(std::vector<WorkingChunk> &chunks, const LMWorldspawnPartitionSettings &settings,
		LMWorldspawnPartitionResult &result) {
	std::vector<std::shared_ptr<BudgetChunk>> storage;
	if (chunks.size() > storage.max_size() / 2) return false;
	storage.reserve(chunks.size() * 2);
	for (auto &chunk : chunks) {
		auto stored = std::make_shared<BudgetChunk>();
		stored->chunk = std::move(chunk);
		storage.push_back(std::move(stored));
	}
	BudgetQueue all_pairs;
	auto add_pair = [&](const std::shared_ptr<BudgetChunk> &left, const std::shared_ptr<BudgetChunk> &right) {
		BudgetCandidate candidate = budget_candidate(left, right, settings);
		if (!candidate.left) return false;
		all_pairs.push(std::move(candidate));
		return true;
	};
	for (size_t left = 0; left < storage.size(); ++left)
		for (size_t right = left + 1; right < storage.size(); ++right)
			if (!add_pair(storage[left], storage[right])) return false;

	size_t active_count = storage.size();
	while (active_count > static_cast<size_t>(settings.max_chunks)) {
		BudgetCandidate selected;
		if (!take_best_budget_candidate(all_pairs, selected)) return false;
		const bool was_adjacent = adjacent(selected.left->chunk.metrics.bounds, selected.right->chunk.metrics.bounds);
		WorkingChunk merged;
		if (!merged_metrics(selected.left->chunk, selected.right->chunk, merged)) return false;
		selected.left->active = false;
		selected.right->active = false;
		auto stored = std::make_shared<BudgetChunk>();
		stored->chunk = std::move(merged);
		for (const auto &other : storage)
			if (other->active && !add_pair(other, stored)) return false;
		storage.push_back(std::move(stored));
		--active_count;
		++result.budget_merge_count;
		if (!was_adjacent) ++result.forced_nonadjacent_merge_count;
	}
	chunks.clear();
	for (auto &stored : storage)
		if (stored->active) chunks.push_back(std::move(stored->chunk));
	std::sort(chunks.begin(), chunks.end(), working_less);
	return true;
}

bool overlap_measure(const Bounds &left, const Bounds &right, long double scale, long double &result) {
	Bounds overlap;
	for (int axis = 0; axis < 3; ++axis) {
		overlap.mins[axis] = std::max(left.mins[axis], right.mins[axis]);
		overlap.maxs[axis] = std::max(overlap.mins[axis], std::min(left.maxs[axis], right.maxs[axis]));
	}
	bool separated = false;
	for (int axis = 0; axis < 3; ++axis)
		if (std::min(left.maxs[axis], right.maxs[axis]) < std::max(left.mins[axis], right.mins[axis])) separated = true;
	if (separated) {
		result = 0;
		return true;
	}
	return measure(overlap, scale, result);
}

bool split_better(const Split &candidate, const Split &best) {
	if (!best.valid) return true;
	if (less_with_tolerance(candidate.score, best.score)) return true;
	if (less_with_tolerance(best.score, candidate.score)) return false;
	if (less_with_tolerance(candidate.overlap, best.overlap)) return true;
	if (less_with_tolerance(best.overlap, candidate.overlap)) return false;
	if (candidate.triangle_balance != best.triangle_balance) return candidate.triangle_balance < best.triangle_balance;
	if (candidate.axis != best.axis) return candidate.axis < best.axis;
	return candidate.coordinate < best.coordinate;
}

Split best_split(const std::vector<LMWorldspawnItem> &items, const std::vector<size_t> &indices,
		const ClusterMetrics &parent, bool &calculations_valid) {
	Split best;
	calculations_valid = false;
	long double scale = 0;
	for (int axis = 0; axis < 3; ++axis) {
		long double physical_extent;
		if (!extent(parent.bounds, axis, physical_extent)) return best;
		scale = std::max(scale, physical_extent);
	}
	if (scale == 0) {
		calculations_valid = true;
		return best;
	}
	long double parent_measure;
	if (!measure(parent.bounds, scale, parent_measure)) return best;
	const long double overlap_normalizer = std::max(1.0L, parent_measure);
	for (int axis = 0; axis < 3; ++axis) {
		long double center_min = center(items[indices.front()], axis);
		if (!finite_metric(center_min)) return {};
		long double center_max = center_min;
		for (size_t index : indices) {
			const long double item_center = center(items[index], axis);
			if (!finite_metric(item_center)) return {};
			center_min = std::min(center_min, item_center);
			center_max = std::max(center_max, item_center);
		}
		if (center_min == center_max) continue;
		const long double width = (center_max - center_min) / PARTITION_BIN_COUNT;
		if (!finite_metric(width)) return {};
		for (int split_bin = 0; split_bin < PARTITION_BIN_COUNT - 1; ++split_bin) {
			Split candidate;
			candidate.valid = true;
			candidate.axis = axis;
			candidate.coordinate = center_min + width * (split_bin + 1);
			if (!finite_metric(candidate.coordinate)) return {};
			for (size_t index : indices)
				(center(items[index], axis) < candidate.coordinate ? candidate.left : candidate.right).push_back(index);
			if (candidate.left.empty() || candidate.right.empty()) continue;
			ClusterMetrics left, right;
			if (!cluster_metrics(items, candidate.left, left) || !cluster_metrics(items, candidate.right, right)) continue;
			long double overlap, left_measure, right_measure;
			if (!overlap_measure(left.bounds, right.bounds, scale, overlap) ||
					!measure(left.bounds, scale, left_measure) || !measure(right.bounds, scale, right_measure)) return {};
			candidate.overlap = overlap / overlap_normalizer;
			candidate.triangle_balance = left.triangles >= right.triangles ?
					left.triangles - right.triangles : right.triangles - left.triangles;
			const long double sah = left_measure * left.triangles / parent.triangles +
					right_measure * right.triangles / parent.triangles;
			std::vector<int> child_textures = left.textures;
			if (!merge_textures(child_textures, right.textures)) return {};
			if (right.textures.size() > std::numeric_limits<size_t>::max() - left.textures.size()) return {};
			const size_t duplicated = left.textures.size() + right.textures.size() - child_textures.size();
			const long double material_penalty = static_cast<long double>(duplicated) / std::max<size_t>(1, parent.textures.size());
			candidate.score = sah + OVERLAP_WEIGHT * candidate.overlap + MATERIAL_WEIGHT * material_penalty;
			if (!finite_metric(candidate.overlap) || !finite_metric(sah) ||
					!finite_metric(material_penalty) || !finite_metric(candidate.score)) return {};
			if (split_better(candidate, best)) best = std::move(candidate);
		}
	}
	// A split must improve the unsplit normalized SAH cost.
	if (best.valid && !less_with_tolerance(best.score, parent_measure)) best = {};
	calculations_valid = true;
	return best;
}

bool chunk_less(const LMWorldspawnChunk &left, const LMWorldspawnChunk &right) {
	for (int axis = 0; axis < 3; ++axis) {
		if (component(left.mins, axis) != component(right.mins, axis)) return component(left.mins, axis) < component(right.mins, axis);
	}
	for (int axis = 0; axis < 3; ++axis) {
		if (component(left.maxs, axis) != component(right.maxs, axis)) return component(left.maxs, axis) < component(right.maxs, axis);
	}
	return item_key(left.items.front()) < item_key(right.items.front());
}
}

LMWorldspawnPartitionResult lm_partition_worldspawn_items(
		const std::vector<LMWorldspawnItem> &input,
		const LMWorldspawnPartitionSettings &settings) {
	LMWorldspawnPartitionResult result;
	if (!std::isfinite(settings.target_extent) || settings.target_extent <= 0 ||
			settings.target_triangles <= 0 || settings.max_chunks <= 0) {
		result.status = LMWorldspawnPartitionStatus::INVALID_SETTINGS;
		return result;
	}
	std::vector<LMWorldspawnItem> items = input;
	if (items.size() > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	for (const auto &item : items) {
		if (!finite_item(item) || item.texture_indices.size() > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
			result.status = LMWorldspawnPartitionStatus::INVALID_ITEM;
			return result;
		}
	}
	std::sort(items.begin(), items.end(), [](const auto &left, const auto &right) { return item_key(left) < item_key(right); });
	for (size_t i = 1; i < items.size(); ++i) {
		if (item_key(items[i - 1]) == item_key(items[i])) {
			result.status = LMWorldspawnPartitionStatus::INVALID_ITEM;
			return result;
		}
	}
	if (items.empty()) return result;
	std::vector<size_t> all_indices(items.size());
	for (size_t i = 0; i < items.size(); ++i) all_indices[i] = i;
	ClusterMetrics all_metrics;
	if (!cluster_metrics(items, all_indices, all_metrics)) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	long double checked_measure, checked_cost;
	if (!measure(all_metrics.bounds, 1.0L, checked_measure) ||
			!measure(all_metrics.bounds, settings.target_extent, checked_measure) ||
			!instance_cost(all_metrics, settings, checked_cost)) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	for (const auto &item : items) {
		const Bounds bounds = item_bounds(item);
		for (int axis = 0; axis < 3; ++axis) {
			long double item_extent;
			if (!extent(bounds, axis, item_extent) || !finite_metric(center(item, axis))) {
				result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
				return result;
			}
		}
	}

	std::vector<size_t> normal_indices;
	std::vector<bool> oversized_items(items.size());
	std::vector<WorkingChunk> chunks;
	for (size_t i = 0; i < items.size(); ++i) {
		bool oversized = items[i].visual_triangle_count > settings.target_triangles;
		for (int axis = 0; axis < 3; ++axis) {
			long double item_extent;
			if (!extent(item_bounds(items[i]), axis, item_extent)) {
				result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
				return result;
			}
			oversized |= item_extent > settings.target_extent;
		}
		if (oversized) {
			WorkingChunk chunk;
			if (!initialize_chunk(items, {i}, false, chunk)) {
				result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
				return result;
			}
			chunks.push_back(std::move(chunk));
			oversized_items[i] = true;
			++result.oversized_item_count;
		} else {
			normal_indices.push_back(i);
		}
	}
	std::sort(chunks.begin(), chunks.end(), working_less);
	while (true) {
		const MergeCandidate merge = best_merge(chunks, settings,
				[&](const WorkingChunk &left, const WorkingChunk &right, const WorkingChunk &merged) {
					return !left.normal && !right.normal &&
							regional_oversized_pair(left, right, merged, settings);
				});
		if (!merge.valid) break;
		apply_merge(chunks, merge);
	}

	std::vector<std::vector<size_t>> pending;
	if (!normal_indices.empty()) pending.push_back(std::move(normal_indices));
	std::vector<std::vector<size_t>> leaves;
	const size_t hard_budget = settings.max_chunks >= static_cast<int64_t>(items.size()) ?
			items.size() : static_cast<size_t>(settings.max_chunks);
	const size_t normal_chunk_budget = pending.empty() ? 0 :
			(chunks.size() < hard_budget ? hard_budget - chunks.size() : 1);
	while (!pending.empty()) {
		auto indices = std::move(pending.back());
		pending.pop_back();
		ClusterMetrics metrics;
		if (!cluster_metrics(items, indices, metrics)) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			return result;
		}
		const bool soft_limits_exceeded = exceeds_soft_limits(metrics, settings);
		if (leaves.size() > std::numeric_limits<size_t>::max() - pending.size() - 1) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			return result;
		}
		const size_t normal_partition_count = leaves.size() + pending.size() + 1;
		if (indices.size() > 1 && soft_limits_exceeded && normal_partition_count < normal_chunk_budget) {
			bool calculations_valid;
			Split split = best_split(items, indices, metrics, calculations_valid);
			if (!calculations_valid) {
				result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
				return result;
			}
			if (split.valid) {
				pending.push_back(std::move(split.right));
				pending.push_back(std::move(split.left));
				continue;
			}
		}
		leaves.push_back(std::move(indices));
	}
	if (leaves.size() > items.size()) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	for (const auto &indices : leaves) {
		ClusterMetrics metrics;
		if (!cluster_metrics(items, indices, metrics)) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			result.chunks.clear();
			return result;
		}
		WorkingChunk chunk;
		if (!initialize_chunk(items, indices, true, chunk)) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			return result;
		}
		chunks.push_back(std::move(chunk));
	}
	std::sort(chunks.begin(), chunks.end(), working_less);
	while (true) {
		const MergeCandidate merge = best_merge(chunks, settings,
				[&](const WorkingChunk &left, const WorkingChunk &right, const WorkingChunk &merged) {
					return left.normal && right.normal && adjacent(left.metrics.bounds, right.metrics.bounds) &&
							!exceeds_soft_limits(merged.metrics, settings) &&
							merge_lowers_cost(left, right, merged, settings);
				});
		if (!merge.valid) break;
		apply_merge(chunks, merge);
		++result.sparse_merge_count;
	}
	if (chunks.size() > static_cast<uint64_t>(settings.max_chunks) &&
			!enforce_budget(chunks, settings, result)) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	std::vector<bool> seen(items.size());
	int64_t conserved_triangles = 0;
	for (const auto &working : chunks) {
		if (working.metrics.triangles > std::numeric_limits<int64_t>::max() - conserved_triangles) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			return result;
		}
		conserved_triangles += working.metrics.triangles;
		for (size_t index : working.indices) {
			if (index >= seen.size() || seen[index]) {
				result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
				return result;
			}
			seen[index] = true;
		}
	}
	if (conserved_triangles != all_metrics.triangles ||
			std::find(seen.begin(), seen.end(), false) != seen.end()) {
		result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
		return result;
	}
	for (const auto &working : chunks) {
		LMWorldspawnChunk chunk;
		chunk.mins = { static_cast<double>(working.metrics.bounds.mins[0]), static_cast<double>(working.metrics.bounds.mins[1]), static_cast<double>(working.metrics.bounds.mins[2]) };
		chunk.maxs = { static_cast<double>(working.metrics.bounds.maxs[0]), static_cast<double>(working.metrics.bounds.maxs[1]), static_cast<double>(working.metrics.bounds.maxs[2]) };
		chunk.visual_triangle_count = working.metrics.triangles;
		chunk.texture_indices = working.metrics.textures;
		if (working.indices.size() > chunk.items.max_size()) {
			result.status = LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED;
			result.chunks.clear();
			return result;
		}
		chunk.items.reserve(working.indices.size());
		for (size_t index : working.indices) chunk.items.push_back(items[index]);
		if (working.indices.size() == 1 && oversized_items[working.indices.front()])
			++result.isolated_oversized_item_count;
		if (exceeds_soft_limits(working.metrics, settings)) ++result.chunks_with_unmet_soft_limits;
		result.chunks.push_back(std::move(chunk));
	}
	std::sort(result.chunks.begin(), result.chunks.end(), chunk_less);
	return result;
}

LMWorldspawnExtractionResult lm_extract_worldspawn_items(
		int entity_index,
		const LMEntity &entity,
		const LMEntityGeometry &geometry,
		const std::vector<int> &excluded_texture_indices) {
	LMWorldspawnExtractionResult result;
	if (entity_index < 0 || entity.primitive_count < 0 || entity.brush_count < 0 || entity.patch_count < 0 ||
			entity.primitive_count != entity.brush_count + entity.patch_count ||
			(entity.primitive_count > 0 && entity.primitives == nullptr) ||
			(entity.brush_count > 0 && entity.brushes == nullptr) ||
			(entity.patch_count > 0 && entity.patches == nullptr)) {
		result.status = LMWorldspawnExtractionStatus::INVALID_SOURCE;
		return result;
	}
	if (geometry.brush_count != entity.brush_count || geometry.patch_count != entity.patch_count ||
			(geometry.brush_count > 0 && geometry.brushes == nullptr) ||
			(geometry.patch_count > 0 && geometry.patches == nullptr)) {
		result.status = LMWorldspawnExtractionStatus::INVALID_GEOMETRY;
		return result;
	}

	std::vector<LMWorldspawnItem> items;
	std::vector<bool> seen_brushes(entity.brush_count);
	std::vector<bool> seen_patches(entity.patch_count);
	items.reserve(entity.primitive_count);
	for (int ordinal = 0; ordinal < entity.primitive_count; ++ordinal) {
		const LMPrimitive primitive = entity.primitives[ordinal];
		LMWorldspawnItem item;
		item.entity_index = entity_index;
		item.primitive_ordinal = ordinal;
		item.source_index = primitive.index;
		bool has_bounds = false;

		if (primitive.is_patch) {
			item.kind = LMWorldspawnPrimitiveKind::PATCH;
			if (primitive.index < 0 || primitive.index >= entity.patch_count || seen_patches[primitive.index]) {
				result.status = LMWorldspawnExtractionStatus::INVALID_SOURCE;
				return result;
			}
			seen_patches[primitive.index] = true;
			const LMPatch &patch = entity.patches[primitive.index];
			const LMPatchGeometry &mesh = geometry.patches[primitive.index];
			if (!valid_mesh(mesh.vertices, mesh.vertex_count, mesh.indices, mesh.index_count)) {
				result.status = LMWorldspawnExtractionStatus::INVALID_GEOMETRY;
				return result;
			}
			if (!finite_vertices(mesh.vertices, mesh.vertex_count)) {
				result.status = LMWorldspawnExtractionStatus::NONFINITE_GEOMETRY;
				return result;
			}
			if (excluded(patch.texture_idx, excluded_texture_indices)) continue;
			item.visual_triangle_count = mesh.index_count / 3;
			if (item.visual_triangle_count == 0) continue;
			item.texture_indices.push_back(patch.texture_idx);
			include_vertices(item, mesh.vertices, mesh.vertex_count, has_bounds);
		} else {
			item.kind = LMWorldspawnPrimitiveKind::BRUSH;
			if (primitive.index < 0 || primitive.index >= entity.brush_count || seen_brushes[primitive.index]) {
				result.status = LMWorldspawnExtractionStatus::INVALID_SOURCE;
				return result;
			}
			seen_brushes[primitive.index] = true;
			const LMBrush &brush = entity.brushes[primitive.index];
			const LMBrushGeometry &brush_geometry = geometry.brushes[primitive.index];
			if (brush.face_count < 0 || brush_geometry.face_count != brush.face_count ||
					(brush.face_count > 0 && (brush.faces == nullptr || brush_geometry.faces == nullptr))) {
				result.status = LMWorldspawnExtractionStatus::INVALID_GEOMETRY;
				return result;
			}
			for (int face = 0; face < brush.face_count; ++face) {
				const LMFaceGeometry &mesh = brush_geometry.faces[face];
				if (!valid_mesh(mesh.vertices, mesh.vertex_count, mesh.indices, mesh.index_count)) {
					result.status = LMWorldspawnExtractionStatus::INVALID_GEOMETRY;
					return result;
				}
				if (!finite_vertices(mesh.vertices, mesh.vertex_count)) {
					result.status = LMWorldspawnExtractionStatus::NONFINITE_GEOMETRY;
					return result;
				}
				if (excluded(brush.faces[face].texture_idx, excluded_texture_indices)) continue;
				const int64_t triangles = mesh.index_count / 3;
				if (triangles == 0) continue;
				if (triangles > std::numeric_limits<int64_t>::max() - item.visual_triangle_count) {
					result.status = LMWorldspawnExtractionStatus::INVALID_GEOMETRY;
					return result;
				}
				item.visual_triangle_count += triangles;
				item.texture_indices.push_back(brush.faces[face].texture_idx);
				include_vertices(item, mesh.vertices, mesh.vertex_count, has_bounds);
			}
			if (item.visual_triangle_count == 0) continue;
		}

		if (!has_bounds || !std::isfinite(item.mins.x) || !std::isfinite(item.mins.y) || !std::isfinite(item.mins.z) ||
				!std::isfinite(item.maxs.x) || !std::isfinite(item.maxs.y) || !std::isfinite(item.maxs.z)) {
			result.status = LMWorldspawnExtractionStatus::NONFINITE_GEOMETRY;
			return result;
		}
		finish_textures(item);
		items.push_back(std::move(item));
	}

	result.items = std::move(items);
	return result;
}
