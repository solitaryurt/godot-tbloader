#!/usr/bin/env python3
"""Install the local TBLoader addon without modifying loaded library inodes."""

import argparse
import os
from pathlib import Path
import shutil
import tempfile


ROOT = Path(__file__).resolve().parent


def _under(path: Path, root: Path) -> bool:
	try:
		path.relative_to(root)
		return True
	except ValueError:
		return False


def _ensure_directory(root: Path, relative: Path) -> Path:
	current = root
	for component in relative.parts:
		current /= component
		if current.is_symlink():
			raise ValueError(f"destination contains a symlink: {current}")
		current.mkdir(exist_ok=True)
		if not current.is_dir() or not _under(current.resolve(), root):
			raise ValueError(f"destination escapes project root: {current}")
	return current


def atomic_copy(source: Path, destination: Path, *, source_root: Path | None = None,
			destination_root: Path | None = None) -> None:
	if source.is_symlink() or destination.is_symlink():
		raise ValueError("addon installation does not permit symlinks")
	resolved_source = source.resolve(strict=True)
	resolved_destination = destination.resolve(strict=False)
	if source_root is not None and not _under(resolved_source, source_root):
		raise ValueError(f"source escapes addon root: {source}")
	if destination_root is not None and not _under(resolved_destination, destination_root):
		raise ValueError(f"destination escapes project root: {destination}")
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
	if source.is_symlink() or project.is_symlink():
		raise ValueError("addon installation does not permit symlink roots")
	source = source.resolve(strict=True)
	project = project.resolve(strict=True)
	destination = _ensure_directory(project, Path("addons") / "tbloader")
	for path in source.rglob("*"):
		if path.is_symlink():
			raise ValueError(f"addon source contains a symlink: {path}")
		resolved = path.resolve(strict=True)
		if not _under(resolved, source):
			raise ValueError(f"source escapes addon root: {path}")
		if path.is_file():
			relative = path.relative_to(source)
			parent = _ensure_directory(destination, relative.parent)
			atomic_copy(path, parent / relative.name, source_root=source, destination_root=destination)


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("project", type=Path, help="Godot project root")
	parser.add_argument("--source", type=Path, default=ROOT / "addons" / "tbloader")
	args = parser.parse_args()
	if not args.source.is_dir():
		parser.error(f"addon source does not exist: {args.source}")
	install(args.source, args.project)


if __name__ == "__main__":
	main()
