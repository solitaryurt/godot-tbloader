#!/usr/bin/env python3
"""Install the local TBLoader addon without modifying loaded library inodes."""

import argparse
import os
from pathlib import Path
import shutil
import tempfile


ROOT = Path(__file__).resolve().parent


def atomic_copy(source: Path, destination: Path) -> None:
	destination.parent.mkdir(parents=True, exist_ok=True)
	fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
	os.close(fd)
	temporary_path = Path(temporary)
	try:
		shutil.copy2(source, temporary_path)
		os.replace(temporary_path, destination)
	finally:
		temporary_path.unlink(missing_ok=True)


def install(source: Path, project: Path) -> None:
	destination = project / "addons" / "tbloader"
	for path in source.rglob("*"):
		if path.is_file():
			atomic_copy(path, destination / path.relative_to(source))


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("project", type=Path, help="Godot project root")
	parser.add_argument("--source", type=Path, default=ROOT / "addons" / "tbloader")
	args = parser.parse_args()
	if not args.source.is_dir():
		parser.error(f"addon source does not exist: {args.source}")
	install(args.source.resolve(), args.project.resolve())


if __name__ == "__main__":
	main()
