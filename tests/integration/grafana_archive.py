#!/usr/bin/env python3
"""Review one already-downloaded official Grafana OSS archive; never extract/run it."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import sys
import tarfile

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("grafana_artifact", root / "src/components/grafana_artifact.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("amd64", "arm64"):
        raise SystemExit("usage: grafana_archive.py LOCAL_ARCHIVE.tar.gz amd64|arm64")
    path, arch = Path(sys.argv[1]), sys.argv[2]
    source = (root / "src/components/grafana.zig").read_text()
    version = re.search(r'pub const version = "([^"]+)";', source).group(1)
    block = re.search(r"\." + arch + r" => \.\{(.*?)\n        \},", source, re.S).group(1)
    pins = {name: value for name, value in re.findall(r'\.(\w+_sha256) = "([a-f0-9]{64})"', block)}
    with path.open("rb") as stream:
        assert artifact.digest_stream(stream) == pins["archive_sha256"], "archive SHA-256 mismatch"
    catalog = artifact.archive_catalog(str(path), version)
    assert hashlib.sha256(catalog).hexdigest() == pins["tree_sha256"], "catalog SHA-256 mismatch"
    records = json.loads(catalog)
    assert sum(row[0] == "f" for row in records) == 13358
    assert sum(row[0] == "d" for row in records) == 1689
    binary = next(row for row in records if row[1] == "bin/grafana")
    assert binary[3] == pins["binary_sha256"] and binary[2] == 0o755
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            if member.name == "grafana-" + version + "/bin/grafana":
                header = archive.extractfile(member).read(20)
                assert header[:6] == b"\x7fELF\x02\x01", "expected ELF64 little-endian executable"
                assert struct.unpack_from("<H", header, 18)[0] == {"amd64": 62, "arm64": 183}[arch]
                break
        else:
            raise AssertionError("missing Grafana executable")
    print(f"PASS Grafana OSS {version} linux {arch}: archive, executable, complete catalog and ELF architecture")
    print("13,358 regular files; 1,689 directories; no links, special entries, traversal or duplicate names.")
    print("Archive audit only; no extraction, execution, SSH or disposable-host validation.")


if __name__ == "__main__":
    main()
