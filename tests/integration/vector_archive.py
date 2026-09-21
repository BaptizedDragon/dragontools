"""Audit pinned Vector archives without extracting or executing downloaded code."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("arch", choices=("amd64", "arm64"))
args = parser.parse_args()
source = (Path(__file__).resolve().parents[2] / "src/components/vector.zig").read_text()
version = re.search(r'pub const version = "([^"]+)"', source).group(1)
pin = re.search(r'[.]' + args.arch + r' => [.]\{(.*?)\n\s*\}', source, re.S).group(1)
hashes = dict(re.findall(r'[.](\w+_sha256) = "([a-f0-9]{64})"', pin))
cpu = re.search(r'[.]cpu = "([^"]+)"', pin).group(1)
assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == hashes["archive_sha256"]
root = "vector-" + cpu + "-unknown-linux-musl"
with tarfile.open(args.archive, "r:gz") as archive:
    members = archive.getmembers()
    assert len(members) == 53 and len({m.name for m in members}) == 53
    assert sum(m.isfile() for m in members) == 42
    for member in members:
        path = PurePosixPath(member.name)
        assert not path.is_absolute() and ".." not in path.parts
        assert path.parts[0] == root
        assert member.isfile() or member.isdir()
        assert not member.mode & 0o6000
    binary = archive.getmember("./" + root + "/bin/vector")
    assert binary.isfile() and binary.mode == 0o755
    assert hashlib.sha256(archive.extractfile(binary).read()).hexdigest() == hashes["binary_sha256"]
print("Vector " + version + " Linux " + args.arch + ": archive, binary and safe member catalog verified; no execution.")
