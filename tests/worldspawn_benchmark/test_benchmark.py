import tempfile
import unittest
from pathlib import Path

from generate_fixtures import generate
from renderer_runner import refresh_cap_diagnostic, validate_acceptance_controls


class BenchmarkChecks(unittest.TestCase):
    def test_fixture_generation_is_byte_stable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = generate(root)
            contents = {path.name: path.read_bytes() for path in root.iterdir()}
            second = generate(root)
            self.assertEqual(first, second)
            self.assertEqual(contents, {path.name: path.read_bytes() for path in root.iterdir()})

    def test_refresh_cap_detection(self):
        capped = {"controls": {"screen_refresh_hz": 144.0}, "views": {
            "fully_visible": {"samples": {"frame_ms": [1000.0 / 144.0] * 60}}}}
        self.assertIsNotNone(refresh_cap_diagnostic(capped))
        uncapped = {"controls": {"screen_refresh_hz": 144.0}, "views": {
            "fully_visible": {"samples": {"frame_ms": [1.0 + index * 0.01 for index in range(60)]}}}}
        self.assertIsNone(refresh_cap_diagnostic(uncapped))

    def test_controls_require_observed_occlusion(self):
        report = {"controls": {"requested_max_fps": 0, "effective_max_fps": 0,
            "project_vsync_mode": 0, "requested_vsync_mode": 0, "effective_vsync_mode": 0,
            "project_occlusion_culling": True, "root_viewport_occlusion_culling": True,
            "occluded_gate_context_valid": True, "screen_refresh_hz": 144.0,
            "occlusion_effect_probe": {"effect_observed": False}}, "views": {}}
        with self.assertRaises(Exception):
            validate_acceptance_controls(report)
        report["controls"]["occlusion_effect_probe"]["effect_observed"] = True
        validate_acceptance_controls(report)


if __name__ == "__main__":
    unittest.main()
