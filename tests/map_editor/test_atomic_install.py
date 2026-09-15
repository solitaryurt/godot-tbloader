import importlib.util
import mmap
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_addon", ROOT / "install_addon.py")
INSTALL_ADDON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL_ADDON)


class AtomicInstallTests(unittest.TestCase):
	def test_replacing_loaded_library_preserves_existing_mapping(self):
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			source = root / "source.so"
			destination = root / "project/addons/tbloader/bin/library.so"
			source.write_bytes(b"new-library-page")
			destination.parent.mkdir(parents=True)
			destination.write_bytes(b"old-library-page")
			old_inode = destination.stat().st_ino
			with destination.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as loaded:
				INSTALL_ADDON.atomic_copy(source, destination)
				self.assertEqual(loaded[:], b"old-library-page")
			self.assertEqual(destination.read_bytes(), b"new-library-page")
			self.assertNotEqual(destination.stat().st_ino, old_inode)

	def test_install_rejects_source_symlinks(self):
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			source = root / "source"
			project = root / "project"
			source.mkdir()
			project.mkdir()
			outside = root / "outside.txt"
			outside.write_text("outside")
			(source / "linked.txt").symlink_to(outside)
			with self.assertRaisesRegex(ValueError, "symlink"):
				INSTALL_ADDON.install(source, project)

	def test_install_rejects_destination_symlinks(self):
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			source = root / "source"
			project = root / "project"
			outside = root / "outside"
			source.mkdir()
			project.mkdir()
			outside.mkdir()
			(source / "file.txt").write_text("addon")
			(project / "addons").symlink_to(outside, target_is_directory=True)
			with self.assertRaisesRegex(ValueError, "symlink"):
				INSTALL_ADDON.install(source, project)


if __name__ == "__main__":
	unittest.main()
