"""Audit an already-downloaded pinned archive; never extract or execute it."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("arch", choices=("amd64", "arm64"))
args = parser.parse_args()
source = (Path(__file__).resolve().parents[2] / "src/components/alertmanager.zig").read_text()
version = re.search(r'pub const version = "([^"]+)"', source).group(1)
pin = re.search(r'[.]' + args.arch + r' => [.]\{(.*?)\n\s*\}', source, re.S).group(1)
hashes = dict(re.findall(r'[.](\w+_sha256) = "([a-f0-9]{64})"', pin))
assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == hashes["archive_sha256"]
prefix = "alertmanager-" + version.removeprefix("v") + ".linux-" + args.arch
expected = {prefix, *(prefix + "/" + name for name in ("alertmanager", "amtool", "LICENSE", "NOTICE", "alertmanager.yml"))}
with tarfile.open(args.archive, "r:gz") as archive:
    members = archive.getmembers()
    assert len(members) == 6
    assert {member.name.rstrip("/") for member in members} == expected
    for member in members:
        assert not PurePosixPath(member.name).is_absolute()
        assert ".." not in PurePosixPath(member.name).parts
        assert member.isdir() or member.isfile()
        assert not (member.mode & 0o6000)
        if member.isfile() and member.name.rsplit("/", 1)[-1] in ("alertmanager", "amtool"):
            key = "binary_sha256" if member.name.endswith("/alertmanager") else "amtool_sha256"
            assert hashlib.sha256(archive.extractfile(member).read()).hexdigest() == hashes[key]
print("Alertmanager " + version + " Linux " + args.arch + ": archive, regular binaries and safe entry catalog verified; no execution.")
