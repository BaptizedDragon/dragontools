"""Audit downloaded pinned vmutils archives without extracting or running code."""
import argparse
import hashlib
from pathlib import Path
import re
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("arch", choices=("amd64", "arm64"))
args = parser.parse_args()
source = (Path(__file__).resolve().parents[2] / "src/components/vmalert.zig").read_text()
version = re.search(r'pub const version = "([^"]+)"', source).group(1)
pin = re.search(r'[.]' + args.arch + r' => [.]\{(.*?)\n\s*\}', source, re.S).group(1)
hashes = dict(re.findall(r'[.](\w+_sha256) = "([a-f0-9]{64})"', pin))
assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == hashes["archive_sha256"]
expected = {name + "-prod" for name in ("vmagent", "vmalert", "vmalert-tool", "vmauth", "vmbackup", "vmrestore", "vmctl")}
with tarfile.open(args.archive, "r:gz") as archive:
    members = archive.getmembers()
    assert len(members) == len(expected)
    assert {member.name for member in members} == expected
    for member in members:
        assert member.isfile() and not member.issym() and not member.islnk()
        assert not member.mode & 0o6000
        if member.name == "vmalert-prod":
            assert hashlib.sha256(archive.extractfile(member).read()).hexdigest() == hashes["binary_sha256"]
print("vmalert " + version + " Linux " + args.arch + ": archive, binary and safe entry catalog verified; no execution.")
