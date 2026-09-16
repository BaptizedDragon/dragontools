#!/usr/bin/env python3
"""Local fixture tests: no real root paths, downloads, service or executable runs."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1] / "src/components/grafana_artifact.py"
spec = importlib.util.spec_from_file_location("grafana_artifact", SOURCE)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def tar_entry(archive, name, content=None, kind=None, mode=None, linkname=""):
    item = tarfile.TarInfo(name)
    item.type = kind or (tarfile.DIRTYPE if content is None else tarfile.REGTYPE)
    item.mode = mode or (0o775 if content is None else 0o664)
    item.linkname = linkname
    item.size = len(content or b"")
    archive.addfile(item, None if content is None else io.BytesIO(content))


class ArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dragontools-grafana-test-")
        self.base = Path(self.temp.name)
        self.root = self.base / "opt/dragontools/components/grafana"
        self.pending = self.base / "state/grafana-restart-required"
        self.destination = self.root / "13.2.2"
        for path in (self.root.parent.parent, self.root.parent, self.pending.parent):
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o755)
        self.archive = self.base / "archive.tar.gz"
        with tarfile.open(self.archive, "w:gz") as output:
            for name in ("", "bin", "conf", "public"):
                tar_entry(output, "grafana-13.2.2" + ("/" + name if name else ""))
            tar_entry(output, "grafana-13.2.2/bin/grafana", b"not an executable\n", mode=0o775)
            tar_entry(output, "grafana-13.2.2/conf/defaults.ini", b"[server]\nhttp_port=3000\n")
            tar_entry(output, "grafana-13.2.2/public/index.html", b"grafana fixture\n")
        catalog = artifact.archive_catalog(str(self.archive), "13.2.2")
        self.archive_hash = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.binary_hash = hashlib.sha256(b"not an executable\n").hexdigest()
        self.tree_hash = hashlib.sha256(catalog).hexdigest()
        self.downloads = 0
        self.publications = []
        self.patches = [
            patch.object(artifact, "OWNER", (os.getuid(), os.getgid())),
            patch.object(artifact.os, "geteuid", lambda: 0),
            patch.object(artifact.subprocess, "run", self.download),
            patch.object(artifact, "rename_directory", self.publish),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def download(self, argv, **kwargs):
        self.assertEqual(argv[0], "curl")
        self.assertIn("=https", argv)
        self.assertIn("--max-filesize", argv)
        self.assertEqual(argv[-1], "https://example.invalid/pinned.tar.gz")
        self.downloads += 1
        shutil.copyfile(self.archive, argv[argv.index("--output") + 1])

    def publish(self, source, destination, exchange):
        self.assertTrue(self.pending.exists(), "restart intent must precede publication")
        self.publications.append(exchange)
        # Test the sequencing contract; this local shim does not validate Linux renameat2.
        if exchange:
            previous = str(source) + ".old"
            os.rename(destination, previous)
            os.rename(source, destination)
            os.rename(previous, source)
        else:
            self.assertFalse(os.path.lexists(destination))
            os.rename(source, destination)

    def install(self, readonly=False):
        return artifact.install(str(self.root), "13.2.2", "https://example.invalid/pinned.tar.gz",
                                self.archive_hash, self.binary_hash, self.tree_hash, str(self.pending), readonly)

    def snapshot(self):
        return sorted((str(p.relative_to(self.root)), p.lstat().st_ino, p.lstat().st_mtime_ns,
                       p.lstat().st_mode) for p in self.root.rglob("*"))

    def test_first_install_second_noop_and_readonly_verification(self):
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 1)
        self.assertEqual(self.publications, [False])
        self.assertEqual(os.readlink(self.root / "current"), "13.2.2")
        self.assertEqual((self.destination / "bin/grafana").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.destination / "conf/defaults.ini").stat().st_mode & 0o777, 0o644)
        (self.root / ".install.lock").unlink()
        before = self.snapshot()
        self.assertEqual(self.install(), "unchanged")
        self.assertEqual(self.install(readonly=True), "verified")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.downloads, 1)
        self.assertTrue(self.pending.exists(), "only orchestration finalization clears intent")

    def test_metadata_only_repair_does_not_download_or_request_restart(self):
        self.install()
        self.pending.unlink()
        binary = self.destination / "bin/grafana"
        binary.chmod(0o600)
        (self.destination / "public").chmod(0o700)
        before = self.snapshot()
        with self.assertRaises(artifact.Refusal):
            self.install(readonly=True)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 1)
        self.assertFalse(self.pending.exists())
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.install(), "unchanged")

    def test_changed_file_replaces_complete_known_tree_and_preserves_intent(self):
        self.install()
        self.pending.unlink()
        (self.destination / "public/index.html").write_text("corrupt asset")
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 2)
        self.assertEqual(self.publications, [False, True])
        self.assertEqual((self.destination / "public/index.html").read_bytes(), b"grafana fixture\n")
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "unchanged")

    def test_missing_known_file_is_repaired(self):
        self.install()
        (self.destination / "conf/defaults.ini").unlink()
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 2)

    def test_foreign_directory_is_preserved_before_download(self):
        self.destination.mkdir(parents=True)
        foreign = self.destination / "administrator.txt"
        foreign.write_bytes(b"keep me\x00")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(foreign.read_bytes(), b"keep me\x00")
        self.assertEqual(self.downloads, 0)
        self.assertFalse(self.pending.exists())

    def test_extra_file_and_tampered_catalog_refuse_replacement(self):
        self.install()
        extra = self.destination / "administrator.txt"
        extra.write_bytes(b"keep")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 1)
        extra.unlink()
        catalog = self.destination / artifact.MANIFEST
        catalog.write_bytes(catalog.read_bytes() + b" ")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 1)

    def test_unexpected_symlink_and_hardlink_refused(self):
        self.install()
        file = self.destination / "public/index.html"
        file.unlink()
        file.symlink_to(self.archive)
        with self.assertRaises(artifact.Refusal) as caught:
            self.install()
        self.assertEqual(caught.exception.code, 43)
        file.unlink()
        os.link(self.destination / "bin/grafana", file)
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 1)

    def test_checksum_failure_does_not_publish_or_mark_restart(self):
        self.archive_hash = "0" * 64
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.pending.exists())
        self.assertEqual(list(self.root.glob(".download.*")), [])

    def test_failed_atomic_replacement_retains_prior_tree_and_retry(self):
        self.install()
        self.pending.unlink()
        file = self.destination / "public/index.html"
        file.write_bytes(b"corrupt bytes")
        with patch.object(artifact, "rename_directory", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(file.read_bytes(), b"corrupt bytes")
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.install(), "unchanged")

    def test_failed_current_publication_reuses_installed_tree_on_retry(self):
        with patch.object(artifact.os, "replace", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                self.install()
        self.assertTrue(self.destination.exists())
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 1)
        self.assertEqual(self.install(), "unchanged")

    def test_archive_rejects_traversal_links_duplicates_and_special_entries(self):
        examples = [
            ("grafana-13.2.2/../escape", tarfile.REGTYPE),
            ("/absolute", tarfile.REGTYPE),
            ("grafana-13.2.2//escape", tarfile.REGTYPE),
            ("grafana-13.2.2/link", tarfile.SYMTYPE),
            ("grafana-13.2.2/hardlink", tarfile.LNKTYPE),
            ("grafana-13.2.2/device", tarfile.CHRTYPE),
            ("grafana-13.2.2/fifo", tarfile.FIFOTYPE),
            ("grafana-13.2.2", tarfile.DIRTYPE),
            ("grafana-13.2.2/with\nnewline", tarfile.REGTYPE),
        ]
        for name, kind in examples:
            with self.subTest(name=name):
                path = self.base / "malformed.tar.gz"
                with tarfile.open(path, "w:gz") as output:
                    tar_entry(output, "grafana-13.2.2")
                    tar_entry(output, name, b"bad" if kind == tarfile.REGTYPE else None, kind, linkname="/tmp")
                with self.assertRaises(artifact.Refusal):
                    artifact.archive_catalog(str(path), "13.2.2")
        self.assertFalse((self.base / "escape").exists())

    def test_suid_and_member_beneath_regular_file_are_rejected(self):
        for invalid_mode in (0o4755, 0o2755, 0o1755):
            with tarfile.open(self.base / "malformed.tar.gz", "w:gz") as output:
                tar_entry(output, "grafana-13.2.2")
                tar_entry(output, "grafana-13.2.2/bin", b"bad", mode=invalid_mode)
            with self.assertRaises(artifact.Refusal):
                artifact.archive_catalog(str(self.base / "malformed.tar.gz"), "13.2.2")
        with tarfile.open(self.base / "malformed.tar.gz", "w:gz") as output:
            tar_entry(output, "grafana-13.2.2")
            tar_entry(output, "grafana-13.2.2/bin", b"bad")
            tar_entry(output, "grafana-13.2.2/bin/grafana", b"bad")
        with self.assertRaises(artifact.Refusal):
            artifact.archive_catalog(str(self.base / "malformed.tar.gz"), "13.2.2")


if __name__ == "__main__":
    unittest.main()
