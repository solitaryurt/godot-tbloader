#!/usr/bin/env python3
"""Real editor journey plus a fresh-process reopen/bake gate; full logs retained."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile

import run_tests as harness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=harness.DEFAULT_ENGINE)
    parser.add_argument("--suite", choices=("editor", "ui"), default="ui")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    artifacts = harness.HERE / "artifacts"
    artifacts.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="journey-", dir=artifacts))
    options = argparse.Namespace(
        godot=args.godot, suite=args.suite, timeout=args.timeout,
        artifacts=root, keep_project=True, probe=None,
    )
    if harness.run(options):
        return 1
    directory = next(root.glob(f"{args.suite}-*"))
    env = os.environ.copy()
    env["TB_TEST_SUITE"] = "reopen"
    env["TB_TEST_PROBE"] = ""
    for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        env[name] = str(directory / name.lower())
    try:
        output = harness.execute(
            [str(Path(args.godot).resolve()), "--path", str(directory / "project"),
             "--headless", "--editor", "--audio-driver", "Dummy"],
            directory / "project", env, args.timeout, directory, "reopen",
            "TB_TEST_COMPLETE:reopen:PASS",
        )
        counts = re.findall(r"^TB_TEST_COUNTS:reopen:(\d+):0$", output, re.MULTILINE)
        if len(counts) != 1 or int(counts[0]) == 0:
            raise harness.GateFailure("missing fresh-process check counts")
        (root / "result.json").write_text(json.dumps({
            "status": "PASS", "journey": str(directory),
            "reopen_checks": int(counts[0]),
        }, indent=2) + "\n")
        print(f"PASS fresh-process reopen: {counts[0]} checks; {root}")
    except harness.GateFailure as error:
        print(f"FAIL fresh-process reopen: {error}; {directory}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
