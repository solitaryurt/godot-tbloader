#include "worldspawn_partitioner.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;

std::vector<LMWorldspawnItem> make_items(int count, bool oversized) {
	std::vector<LMWorldspawnItem> items;
	items.reserve(count);
	const int side = static_cast<int>(std::ceil(std::sqrt(count)));
	for (int i = 0; i < count; ++i) {
		const double x = (i % side) * 4.0;
		const double y = (i / side) * 4.0;
		LMWorldspawnItem item;
		item.entity_index = 0;
		item.primitive_ordinal = i;
		item.source_index = i;
		item.mins = {x, y, 0};
		item.maxs = {x + 1, y + 1, 1};
		item.visual_triangle_count = oversized ? 2 : 1;
		item.texture_indices = {i % 4};
		items.push_back(std::move(item));
	}
	return items;
}

uint64_t fingerprint(const LMWorldspawnPartitionResult &result) {
	uint64_t hash = 1469598103934665603ULL;
	for (const auto &chunk : result.chunks) {
		for (const auto &item : chunk.items) {
			hash ^= static_cast<uint64_t>(item.primitive_ordinal + 1);
			hash *= 1099511628211ULL;
		}
		hash ^= 0xff;
		hash *= 1099511628211ULL;
	}
	return hash;
}

double percentile(std::vector<double> values, double fraction) {
	std::sort(values.begin(), values.end());
	return values[static_cast<size_t>(std::ceil(values.size() * fraction)) - 1];
}

void run_case(const char *name, int count, int samples, bool forced_budget, bool &first) {
	const auto items = make_items(count, forced_budget);
	LMWorldspawnPartitionSettings settings;
	settings.target_extent = forced_budget ? 1.0 : 2.0;
	settings.target_triangles = 1;
	settings.max_chunks = forced_budget ? std::max(1, count / 2) : count;
	std::vector<double> milliseconds;
	uint64_t expected_fingerprint = 0;
	int chunks = 0;
	int64_t budget_merges = 0;
	int64_t forced_merges = 0;
	for (int sample = 0; sample < samples + 1; ++sample) {
		const auto started = Clock::now();
		const auto result = lm_partition_worldspawn_items(items, settings);
		const double elapsed = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
		if (!result || result.chunks.size() > static_cast<size_t>(settings.max_chunks)) std::abort();
		const uint64_t current = fingerprint(result);
		if (sample == 0) expected_fingerprint = current;
		else if (current != expected_fingerprint) std::abort();
		chunks = static_cast<int>(result.chunks.size());
		budget_merges = result.budget_merge_count;
		forced_merges = result.forced_nonadjacent_merge_count;
		if (sample > 0) milliseconds.push_back(elapsed);
	}
	if (!first) std::cout << ",";
	first = false;
	std::cout << "{\"case\":\"" << name << "\",\"items\":" << count
			<< ",\"samples\":" << samples << ",\"median_ms\":" << percentile(milliseconds, .5)
			<< ",\"p95_ms\":" << percentile(milliseconds, .95) << ",\"chunks\":" << chunks
			<< ",\"budget_merges\":" << budget_merges << ",\"forced_nonadjacent_merges\":" << forced_merges
			<< ",\"fingerprint\":\"" << expected_fingerprint << "\"}";
}
}

int main(int argc, char **argv) {
	int samples = 5;
	int maximum = 1024;
	for (int i = 1; i < argc; ++i) {
		const std::string argument = argv[i];
		if (argument == "--samples" && i + 1 < argc) samples = std::atoi(argv[++i]);
		else if (argument == "--max-items" && i + 1 < argc) maximum = std::atoi(argv[++i]);
		else {
			std::cerr << "usage: " << argv[0] << " [--samples N] [--max-items N]\n";
			return 2;
		}
	}
	if (samples <= 0 || maximum < 64) return 2;
	std::cout << "{\"schema\":1,\"clock\":\"std::chrono::steady_clock\",\"cases\":[";
	bool first = true;
	for (int count = 64; count <= maximum; count *= 2) run_case("sah_grid", count, samples, false, first);
	for (int count = 64; count <= maximum; count *= 2) run_case("forced_pairwise_budget", count, samples, true, first);
	std::cout << "]}\n";
}
