#!/usr/bin/env python3
"""Local ZIP/publication fixtures; no actual Grafana, network or Linux renameat2."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1] / "src/components/grafana_victorialogs_artifact.py"
spec = importlib.util.spec_from_file_location("plugin_artifact", SOURCE)
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def entry(output, name, content=b"", mode=None):
    directory = name.endswith("/")
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = (mode or (0o40755 if directory else 0o100644)) << 16
    output.writestr(info, content)


def fixture(path, version="0.32.0", extra=None):
    files = {
        "plugin.json": json.dumps({"id": artifact.PLUGIN, "type": "datasource", "backend": True,
                                   "executable": artifact.EXECUTABLE, "info": {"version": version}}).encode(),
        "module.js": b"frontend fixture\n",
        "img/logo.svg": b"image fixture\n",
        artifact.EXECUTABLE + "_linux_amd64": b"not a binary amd64\n",
        artifact.EXECUTABLE + "_linux_arm64": b"not a binary arm64\n",
    }
    signed = {"plugin": artifact.PLUGIN, "version": version, "signedByOrg": "victoriametrics", "signatureType": "commercial",
              "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    files["MANIFEST.txt"] = (b"-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n" + json.dumps(signed).encode() +
                             b"\n-----BEGIN PGP SIGNATURE-----\n\nfixture only\n-----END PGP SIGNATURE-----\n")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as output:
        entry(output, artifact.PLUGIN + "/")
        entry(output, artifact.PLUGIN + "/img/")
        for name, content in files.items():
            entry(output, artifact.PLUGIN + "/" + name, content, 0o100755 if name.startswith(artifact.EXECUTABLE) else None)
        if extra:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                entry(output, *extra)
    return hashlib.sha256(path.read_bytes()).hexdigest(), hashlib.sha256(artifact.archive_catalog(str(path), version)).hexdigest()


class ArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dragontools-plugin-test-")
        self.base = Path(self.temp.name)
        self.data = self.base / "state/grafana"
        self.data.mkdir(parents=True)
        self.data.parent.chmod(0o755)
        self.data.chmod(0o750)
        self.version = "0.32.0"
        self.pending = self.data.parent / "grafana-restart-required"
        self.versions = self.data / "plugins-versions" / artifact.PLUGIN
        self.active = self.data / "plugins" / artifact.PLUGIN
        self.archive = self.base / "plugin.zip"
        self.archive_hash, tree = fixture(self.archive)
        self.trusted = {self.version: tree}
        self.downloads = 0
        self.publications = []
        self.patches = [patch.object(artifact, "OWNER", (os.getuid(), os.getgid())),
                        patch.object(artifact.os, "geteuid", lambda: 0),
                        patch.object(artifact.subprocess, "run", self.download),
                        patch.object(artifact, "rename_directory", self.publish)]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    @property
    def release(self):
        return self.versions / self.version

    def download(self, argv, **kwargs):
        self.assertEqual(argv[0], "curl")
        self.assertIn("--disable", argv)
        self.assertIn("=https", argv)
        self.assertIn("--proto-redir", argv)
        self.assertIn("--max-filesize", argv)
        self.assertEqual(argv[-1], "https://example.invalid/pinned.zip")
        self.downloads += 1
        shutil.copyfile(self.archive, argv[argv.index("--output") + 1])

    def publish(self, source, destination, exchange):
        self.assertTrue(self.pending.exists(), "restart intent must exist BEFORE tree publication")
        self.publications.append(exchange)
        # A local sequencing shim: Linux renameat2 atomicity remains an integration gate.
        if exchange:
            old = source + ".old"
            os.rename(destination, old)
            os.rename(source, destination)
            os.rename(old, source)
        else:
            self.assertFalse(os.path.lexists(destination))
            os.rename(source, destination)

    def install(self):
        return artifact.install(str(self.data), self.version, "https://example.invalid/pinned.zip", self.archive_hash,
                                self.trusted, str(self.pending))

    def verify(self):
        return artifact.verify(str(self.data), self.version, self.trusted, str(self.pending))

    def snapshot(self):
        return sorted((str(p.relative_to(self.data)), p.lstat().st_ino, p.lstat().st_mtime_ns,
                       p.lstat().st_mode) for p in self.data.rglob("*"))

    def test_first_install_second_noop_and_readonly(self):
        self.assertEqual(self.install(), "changed")
        self.assertEqual(os.readlink(self.active), artifact.target(self.version))
        self.assertEqual(self.downloads, 1)
        self.assertEqual(self.publications, [False])
        self.assertTrue((self.release / artifact.MANIFEST).is_file())
        self.assertFalse((self.release / "content" / artifact.MANIFEST).exists(), "no extra files inside signed package")
        self.assertEqual((self.release / "content" / (artifact.EXECUTABLE + "_linux_amd64")).stat().st_mode & 0o777, 0o755)
        (self.versions / ".install.lock").unlink()
        before = self.snapshot()
        with patch.object(artifact.os, "open", wraps=artifact.os.open) as opened:
            self.assertEqual(self.install(), "unchanged")
            self.assertEqual(self.verify(), "verified")
        self.assertTrue(all(not args[0][1] & (os.O_WRONLY | os.O_RDWR | os.O_CREAT) for args in opened.call_args_list))
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.downloads, 1)
        self.assertTrue(self.pending.exists(), "only workflow finalization clears intent")

    def test_empty_previous_grafana_plugins_directory_is_supported(self):
        plugins = self.data / "plugins"
        plugins.mkdir(mode=0o750)
        self.assertEqual(self.install(), "changed")
        self.assertEqual(stat.S_IMODE(plugins.stat().st_mode), 0o755)
        self.assertEqual(self.install(), "unchanged")

    def test_metadata_repair_does_not_download_or_restart(self):
        self.install()
        self.pending.unlink()
        path = self.release / "content/module.js"
        path.chmod(0o600)
        with self.assertRaises(artifact.Refusal):
            self.verify()
        self.assertEqual(self.install(), "changed")
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.downloads, 1)
        self.assertEqual(self.install(), "unchanged")

    def test_known_corruption_is_replaced_with_old_tree_preserved(self):
        self.install()
        self.pending.unlink()
        (self.release / "content/module.js").write_bytes(b"broken frontend")
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.publications, [False, True])
        backups = list(self.versions.glob(".previous.0.32.0.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "release/content/module.js").read_bytes(), b"broken frontend")
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "unchanged")

    def test_upgrade_preserves_previous_version_and_atomically_switches_link(self):
        self.install()
        previous = self.release
        self.pending.unlink()
        self.version = "0.33.0"
        self.archive_hash, tree = fixture(self.archive, self.version)
        self.trusted[self.version] = tree
        original_replace = artifact.os.replace
        def replace(source, destination):
            self.assertTrue(self.pending.exists())
            self.assertEqual(os.readlink(destination), artifact.target("0.32.0"))
            original_replace(source, destination)
        with patch.object(artifact.os, "replace", replace):
            self.assertEqual(self.install(), "changed")
        self.assertTrue(previous.is_dir())
        self.assertEqual(os.readlink(self.active), artifact.target(self.version))
        self.assertEqual(self.install(), "unchanged")

    def test_missing_known_file_is_repaired(self):
        self.install()
        (self.release / "content/module.js").unlink()
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 2)

    def test_foreign_plugin_directory_is_preserved(self):
        (self.data / "plugins/foreign-plugin").mkdir(parents=True)
        path = self.data / "plugins/foreign-plugin/administrator.txt"
        path.write_bytes(b"keep me")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(path.read_bytes(), b"keep me")
        self.assertEqual(self.downloads, 0)

    def test_foreign_current_directory_or_symlink_is_refused(self):
        (self.data / "plugins").mkdir()
        self.active.mkdir()
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.active.rmdir()
        self.active.symlink_to("../../unrelated")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 0)

    def test_foreign_tree_extra_files_and_catalog_tampering_refuse(self):
        self.install()
        path = self.release / "content/administrator.txt"
        path.write_bytes(b"keep")
        with self.assertRaises(artifact.Refusal):
            self.install()
        path.unlink()
        catalog = self.release / artifact.MANIFEST
        catalog.write_bytes(catalog.read_bytes() + b" ")
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 1)

    def test_managed_file_symlink_and_hardlink_refused(self):
        self.install()
        path = self.release / "content/module.js"
        path.unlink()
        path.symlink_to(self.archive)
        with self.assertRaises(artifact.Refusal):
            self.install()
        path.unlink()
        os.link(self.release / "content/plugin.json", path)
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(self.downloads, 1)

    def test_bad_checksum_or_catalog_fails_before_publication(self):
        for archive_hash, trees in [("0" * 64, self.trusted), (self.archive_hash, {self.version: "0" * 64})]:
            with self.subTest(archive_hash=archive_hash):
                self.archive_hash, self.trusted = archive_hash, trees
                with self.assertRaises(artifact.Refusal):
                    self.install()
                self.assertFalse(self.release.exists())
                self.assertFalse(self.pending.exists())
                self.assertEqual(list(self.versions.glob(".stage.*")), [])

    def test_failed_atomic_publication_preserves_tree_intent_and_retry(self):
        self.install()
        path = self.release / "content/module.js"
        path.write_bytes(b"corrupt")
        with patch.object(artifact, "rename_directory", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(path.read_bytes(), b"corrupt")
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.install(), "unchanged")

    def test_failed_active_switch_reuses_installed_release(self):
        with patch.object(artifact.os, "replace", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                self.install()
        self.assertTrue(self.release.exists())
        self.assertTrue(self.pending.exists())
        self.assertEqual(self.install(), "changed")
        self.assertEqual(self.downloads, 1)

    def test_readonly_missing_state_makes_no_writes(self):
        before = self.snapshot()
        with self.assertRaises(artifact.Refusal):
            self.verify()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.downloads, 0)

    def test_archive_rejects_unsafe_paths_links_duplicates_and_types(self):
        cases = [(artifact.PLUGIN + "/../escape", b"bad", 0o100644),
                 ("/absolute", b"bad", 0o100644),
                 (artifact.PLUGIN + "//escape", b"bad", 0o100644),
                 (artifact.PLUGIN + "/link", b"/tmp", 0o120777),
                 (artifact.PLUGIN + "/device", b"", 0o020644),
                 (artifact.PLUGIN + "/fifo", b"", 0o010644),
                 (artifact.PLUGIN + "/module.js", b"duplicate", 0o100644),
                 (artifact.PLUGIN + "/with\nnewline", b"bad", 0o100644),
                 (artifact.PLUGIN + "/suid", b"bad", 0o104755),
                 (artifact.PLUGIN + "/bad\\name", b"bad", 0o100644),
                 (artifact.PLUGIN + "/module.js/nested", b"bad", 0o100644)]
        for item in cases:
            with self.subTest(item=item):
                with self.assertRaises(artifact.Refusal):
                    fixture(self.archive, extra=item)
        self.assertFalse((self.base / "escape").exists())

    def test_bad_archive_fails_without_changing_previous_active_release(self):
        self.install()
        previous = os.readlink(self.active)
        self.version = "0.33.0"
        self.trusted[self.version] = "0" * 64
        with zipfile.ZipFile(self.archive, "w") as output:
            entry(output, artifact.PLUGIN + "/")
            entry(output, artifact.PLUGIN + "/../escape", b"bad")
        self.archive_hash = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.pending.unlink()
        with self.assertRaises(artifact.Refusal):
            self.install()
        self.assertEqual(os.readlink(self.active), previous)
        self.assertFalse(self.release.exists())
        self.assertFalse(self.pending.exists())


if __name__ == "__main__":
    unittest.main()
