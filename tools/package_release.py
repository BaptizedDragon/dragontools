#!/usr/bin/env python3
"""Package already-built DragonTools binaries; no network or publishing access."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import re
import tarfile

TARGETS = {
    "aarch64-macos": "darwin_arm64",
    "x86_64-macos": "darwin_amd64",
    "aarch64-linux": "linux_arm64",
    "x86_64-linux": "linux_amd64",
}
ROOT = Path(__file__).resolve().parent.parent


def version(value):
    value = value.removeprefix("v")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?", value):
        raise ValueError("invalid release version")
    return value


def filename(release, target):
    return f"dragontool_{version(release)}_{TARGETS[target]}.tar.gz"


def package(release, target, binary, output):
    output.mkdir(parents=True, exist_ok=True)
    destination = output / filename(release, target)
    entries = [("dragontool", binary.read_bytes(), 0o755),
               ("LICENSE", (ROOT / "LICENSE").read_bytes(), 0o644),
               ("README.md", (ROOT / "README.md").read_bytes(), 0o644)]
    # Stable metadata and gzip timestamp make repeated packaging reproducible.
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for name, content, mode in entries:
                    info = tarfile.TarInfo(name)
                    info.size, info.mode, info.mtime = len(content), mode, 0
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    archive.addfile(info, io.BytesIO(content))
    return destination


def checksums(release, output):
    names = sorted(filename(release, target) for target in TARGETS)
    if sorted(path.name for path in output.glob("*.tar.gz")) != names:
        raise ValueError("exactly four matching release archives are required")
    lines = [f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n" for name in names]
    (output / "SHA256SUMS").write_text("".join(lines), encoding="ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["package", "checksums"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", choices=TARGETS)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        version(args.version)
        if args.operation == "package":
            if not args.target or args.binary is None:
                parser.error("package requires --target and --binary")
            package(args.version, args.target, args.binary, args.output)
        else:
            checksums(args.version, args.output)
    except (OSError, ValueError):
        parser.exit(1, "Release packaging failed: check version, binary and archive set.\n")


if __name__ == "__main__":
    main()
