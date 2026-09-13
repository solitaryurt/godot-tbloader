"""Black-box checks that the real engine cannot falsely pass the runner."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


class HarnessFailureTests(unittest.TestCase):
    def test_real_engine_failure_probes(self):
        for probe, reason in (
            ("assertion", "exit status 1"),
            ("engine-error", "engine/script/assertion error"),
            ("missing-marker", "missing or duplicate completion marker"),
            ("timeout", "timeout after"),
        ):
            with self.subTest(probe=probe):
                artifacts = HERE / "artifacts"
                artifacts.mkdir(exist_ok=True)
                root = Path(tempfile.mkdtemp(prefix=f"negative-{probe}-", dir=artifacts))
                command = [
                    sys.executable, str(HERE / "run_tests.py"), "--suite", "document",
                    "--probe", probe, "--timeout", "15", "--artifacts", str(root),
                ]
                # GODOT_BIN is inherited, just as in the documented shell interface.
                process = subprocess.run(command, capture_output=True, text=True, timeout=60, env=os.environ.copy())
                print(process.stdout, end="")
                print(process.stderr, end="")
                self.assertEqual(process.returncode, 1)
                summaries = list(root.glob("document-*/result.json"))
                self.assertEqual(len(summaries), 1)
                summary = json.loads(summaries[0].read_text())
                self.assertIn(reason, summary["reason"])
                # An import/setup failure must not satisfy the negative test.
                step = json.loads((summaries[0].parent / "document.json").read_text())
                if probe in ("engine-error", "missing-marker"):
                    self.assertEqual(step["exit_code"], 0)
                if probe == "timeout":
                    self.assertTrue(step["timed_out"])
                if probe == "assertion":
                    stderr = (summaries[0].parent / "document.stderr.log").read_text()
                    self.assertIn("deliberate harness failure", stderr)


if __name__ == "__main__":
    unittest.main()
