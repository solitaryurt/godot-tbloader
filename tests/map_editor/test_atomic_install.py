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


if __name__ == "__main__":
	unittest.main()
