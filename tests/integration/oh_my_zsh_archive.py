#!/usr/bin/env python3
"""Audit an already-downloaded pinned Oh My Zsh archive; never extract or download."""
import argparse
import hashlib
from pathlib import Path
import re
import sys
import tarfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_pin(name, length):
    source = Path(__file__).resolve().parents[2] / "src/host/oh_my_zsh.zig"
    matches = re.findall(
        rf'^pub const {name} = "([0-9a-f]{{{length}}})";$',
        source.read_text(), re.MULTILINE,
    )
    require(len(matches) == 1, f"Expected one literal {name} pin in source")
    return matches[0]


def safe_text(value):
    return bool(value) and "\\" not in value and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def audit(archive):
    revision = read_pin("revision", 40)
    expected_sha256 = read_pin("archive_sha256", 64)
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    require(digest.hexdigest() == expected_sha256, "Archive SHA-256 does not match the source pin")

    root = "ohmyzsh-" + revision
    members = {}
    counts = {"regular": 0, "directory": 0, "symlink": 0}
    with tarfile.open(archive, "r:gz") as tree:
        for member in tree:
            name = member.name[:-1] if member.isdir() and member.name.endswith("/") else member.name
            require(safe_text(name) and not name.startswith("/"), "Unsafe archive member name")
            parts = name.split("/")
            require(all(part not in ("", ".", "..") for part in parts), "Traversal or noncanonical member path")
            require(parts[0] == root, "Archive member outside the pinned source root")
            require(name not in members, "Duplicate archive member")
            require(member.mode & 0o6000 == 0, "Setuid/setgid archive member")
            if member.isreg():
                counts["regular"] += 1
            elif member.isdir():
                counts["directory"] += 1
            elif member.issym():
                counts["symlink"] += 1
            else:
                raise ValueError("Hardlink or special archive member")
            members[name] = member

    require(root in members and members[root].isdir(), "Missing source root directory")
    for name, member in members.items():
        parts = name.split("/")
        for index in range(1, len(parts)):
            parent = members.get("/".join(parts[:index]))
            require(parent is not None and parent.isdir(), "Member beneath a symlink or non-directory")
        if not member.issym():
            continue
        link = member.linkname
        require(safe_text(link) and not link.startswith("/"), "Unsafe or absolute symlink target")
        target = parts[:-1]
        for part in link.split("/"):
            require(part != "", "Noncanonical symlink target")
            if part == ".":
                continue
            if part == "..":
                require(len(target) > 1, "Symlink escapes the source root")
                target.pop()
            else:
                target.append(part)
        resolved = members.get("/".join(target))
        require(resolved is not None and resolved.isreg(), "Symlink target is not an internal regular member")

    require(counts == {"regular": 1159, "directory": 417, "symlink": 9}, "Reviewed member catalog changed")
    print(f"PASS: Oh My Zsh {revision}; SHA-256 {expected_sha256}")
    print("PASS: 1159 regular files, 417 directories, 9 internal relative symlinks; safe archive catalog")
    print("Source archive audit only; no extraction, network access, or disposable-host integration.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Existing official source .tar.gz to audit")
    args = parser.parse_args()
    try:
        audit(args.archive)
    except (OSError, tarfile.TarError, ValueError) as error:
        # Error kinds are sufficient; never echo arbitrary paths or archive names.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        print(f"FAIL: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
