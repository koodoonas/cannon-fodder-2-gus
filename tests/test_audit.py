from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.audit_repository import audit


class RepositoryAuditTests(unittest.TestCase):
    def test_allows_release_binary_at_approved_path(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "dist").mkdir()
            (root / "dist" / "CF2GUS.COM").write_bytes(b"launcher")
            self.assertEqual(audit(root), [])

    def test_rejects_unapproved_com_binary(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "GAME.COM").write_bytes(b"not redistributable")
            self.assertTrue(audit(root))

    def test_rejects_game_asset_extension(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "MENU.AMF").write_bytes(b"private game data")
            self.assertTrue(audit(root))

    def test_rejects_disguised_archive(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "notes.txt").write_bytes(b"PK\x03\x04payload")
            self.assertTrue(audit(root))

    def test_rejects_disguised_dos_executable(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / "notes.txt").write_bytes(b"MZpayload")
            self.assertTrue(audit(root))


if __name__ == "__main__":
    unittest.main()
