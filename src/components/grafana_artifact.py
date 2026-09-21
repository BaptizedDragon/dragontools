"""Concrete Grafana archive installer; embedded by grafana.zig, Python stdlib only.

The committed catalog digest authenticates every expected path/type/mode/hash.
The catalog is NOT authoritative until its digest matches the committed pin.
Nothing under the version tree is writable runtime state. No downloaded code runs.
"""
import ctypes
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

MANIFEST = ".dragontools-grafana-catalog.json"
MAX_ARCHIVE = 600_000_000
MAX_CONTENT = 2_000_000_000
MAX_ENTRIES = 20_000
MAX_CATALOG = 4_000_000
OWNER = (0, 0)


class Refusal(Exception):
    def __init__(self, code=40):
        self.code = code


def require(condition, code=40):
    if not condition:
        raise Refusal(code)


def safe_path(name):
    require(isinstance(name, str) and re.fullmatch(r"[-A-Za-z0-9_./@+()=,~ ]*", name))
    require(not name.startswith("/") and "\\" not in name)
    require(name == "" or all(part not in ("", ".", "..") for part in name.split("/")))
    require(name != MANIFEST)
    return name


def canonical(records):
    records.sort(key=lambda entry: entry[1].encode("ascii"))
    return (json.dumps(records, ensure_ascii=True, separators=(",", ":")) + "\n").encode("ascii")


def digest_stream(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def file_hash(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1)
        result = digest_stream(stream)
        after = os.fstat(stream.fileno())
        require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns))
        return result


def archive_catalog(path, version, destination=None):
    """Audit all entries and optionally extract only regular files/directories."""
    prefix = "grafana-" + version
    entries, seen, total = [], {}, 0
    with tarfile.open(path, "r|gz") as archive:
        for member in archive:
            require(len(entries) < MAX_ENTRIES)
            name = member.name.rstrip("/") if member.isdir() else member.name
            require(name == prefix or name.startswith(prefix + "/"))
            relative = safe_path(name[len(prefix) + 1:] if name != prefix else "")
            require(relative not in seen)
            require(member.isdir() or member.isreg(), 43 if member.issym() else 40)
            require(not member.mode & 0o7000 and member.size >= 0)
            if relative:
                parent = relative.rpartition("/")[0]
                require(seen.get(parent) == "d")
            kind = "d" if member.isdir() else "f"
            require(relative != "" or kind == "d")
            mode = 0o755 if kind == "d" or member.mode & 0o111 else 0o644
            total += member.size
            require(total <= MAX_CONTENT)
            content_hash = ""
            output_path = os.path.join(destination, relative) if destination is not None else None
            if kind == "d":
                require(member.size == 0)
                if output_path is not None:
                    if relative:
                        os.mkdir(output_path, 0o700)
            else:
                source = archive.extractfile(member)
                require(source is not None)
                if output_path is None:
                    content_hash = digest_stream(source)
                else:
                    value = hashlib.sha256()
                    fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(fd, "wb") as target:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            target.write(block)
                            value.update(block)
                        target.flush()
                        os.fsync(target.fileno())
                    content_hash = value.hexdigest()
            seen[relative] = kind
            entries.append([kind, relative, mode, content_hash])
    require(seen.get("") == "d" and seen.get("bin/grafana") == "f")
    require(seen.get("conf/defaults.ini") == "f" and seen.get("public") == "d")
    return canonical(entries)


def lstat_optional(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def checked_directory(path):
    info = lstat_optional(path)
    if info is not None:
        require(not stat.S_ISLNK(info.st_mode), 43)
        require(stat.S_ISDIR(info.st_mode))
    return info


def read_catalog(destination, expected):
    path = os.path.join(destination, MANIFEST)
    info = lstat_optional(path)
    require(info is not None)
    require(not stat.S_ISLNK(info.st_mode), 43)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= MAX_CATALOG)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        data = source.read(MAX_CATALOG + 1)
    require(hashlib.sha256(data).hexdigest() == expected)
    records = json.loads(data)
    require(isinstance(records, list) and len(records) <= MAX_ENTRIES)
    result = {}
    for kind, name, mode, value in records:
        safe_path(name)
        require(name not in result and kind in ("d", "f"))
        require(mode in (0o644, 0o755) and (kind != "d" or mode == 0o755))
        require((kind == "d" and value == "") or (kind == "f" and re.fullmatch("[0-9a-f]{64}", value)))
        result[name] = (kind, mode, value)
    return result


def inspect_tree(destination, expected):
    """Read only: refuse foreign paths/types; return valid bytes and metadata drift."""
    base = checked_directory(destination)
    if base is None:
        return False, []
    expected_entries = read_catalog(destination, expected)
    seen, repairs, valid = set(), [], True
    stack = [("", base)]
    while stack:
        relative, info = stack.pop()
        path = os.path.join(destination, relative)
        require(not stat.S_ISLNK(info.st_mode), 43)
        require(info.st_dev == base.st_dev)
        if relative == MANIFEST:
            kind, mode, value = "f", 0o644, expected
        else:
            require(relative in expected_entries)
            kind, mode, value = expected_entries[relative]
            seen.add(relative)
        require((kind == "d" and stat.S_ISDIR(info.st_mode)) or
                (kind == "f" and stat.S_ISREG(info.st_mode)))
        if kind == "f":
            require(info.st_nlink == 1)
            valid = file_hash(path) == value and valid
        else:
            for entry in os.scandir(path):
                child = entry.name if not relative else relative + "/" + entry.name
                stack.append((child, entry.stat(follow_symlinks=False)))
        if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (*OWNER, mode):
            repairs.append((path, mode))
    valid = seen == set(expected_entries) and valid
    return valid, repairs


def metadata(path, mode):
    info = os.lstat(path)
    require(not stat.S_ISLNK(info.st_mode), 43)
    if (info.st_uid, info.st_gid) != OWNER:
        os.chown(path, *OWNER, follow_symlinks=False)
    if stat.S_IMODE(info.st_mode) != mode:
        os.chmod(path, mode, follow_symlinks=False)


def pending_check(path):
    info = lstat_optional(path)
    if info is not None:
        require(not stat.S_ISLNK(info.st_mode), 43)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and (info.st_uid, info.st_gid) == OWNER)


def mark_dirty(path):
    pending_check(path)
    if not os.path.exists(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fsync(fd)
        os.close(fd)


def current_version(root, version):
    path = os.path.join(root, "current")
    info = lstat_optional(path)
    if info is None:
        return None
    require(stat.S_ISLNK(info.st_mode))
    value = os.readlink(path)
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value))
    target = checked_directory(os.path.join(root, value))
    if value != version:
        require(target is not None and (target.st_uid, target.st_gid, stat.S_IMODE(target.st_mode)) == (*OWNER, 0o755))
        # Foreign version links are never selected implicitly; recognize only our catalog.
        marker = os.path.join(root, value, MANIFEST)
        marker_info = lstat_optional(marker)
        require(marker_info is not None and stat.S_ISREG(marker_info.st_mode) and marker_info.st_nlink == 1)
        require((marker_info.st_uid, marker_info.st_gid) == OWNER)
    return value


def rename_directory(source, destination, exchange):
    """Linux atomic directory publication: NOREPLACE or EXCHANGE, never copy/delete."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 2 if exchange else 1):
        raise OSError(ctypes.get_errno(), "atomic Grafana publication failed")


def install(root, version, url, archive_hash, binary_hash, tree_hash, pending, readonly=False):
    require(os.geteuid() == 0, 10)
    os.umask(0o077)
    destination = os.path.join(root, version)
    for parent in (os.path.dirname(os.path.dirname(root)), os.path.dirname(root), os.path.dirname(pending)):
        info = checked_directory(parent)
        require(info is not None and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (*OWNER, 0o755))
    base = checked_directory(root)
    pending_check(pending)
    current = current_version(root, version) if base else None
    valid, repairs = inspect_tree(destination, tree_hash)
    base_correct = base is not None and (base.st_uid, base.st_gid, stat.S_IMODE(base.st_mode)) == (*OWNER, 0o755)
    lock = os.path.join(root, ".install.lock")
    lock_info = lstat_optional(lock)
    if lock_info is not None:
        require(not stat.S_ISLNK(lock_info.st_mode), 43)
        require(stat.S_ISREG(lock_info.st_mode) and lock_info.st_nlink == 1 and (lock_info.st_uid, lock_info.st_gid) == OWNER)
    if readonly:
        require(valid and not repairs and base_correct and current == version)
        require(file_hash(os.path.join(destination, "bin/grafana")) == binary_hash)
        return "verified"
    # Pristine no-op returns before lock creation, metadata writes, staging, or download.
    if valid and not repairs and base_correct and current == version:
        return "unchanged"
    if base is None:
        os.mkdir(root, 0o755)
    metadata(root, 0o755)
    changed = not base_correct
    lock_fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        locked_info = os.fstat(lock_fd)
        require(stat.S_ISREG(locked_info.st_mode) and locked_info.st_nlink == 1 and (locked_info.st_uid, locked_info.st_gid) == OWNER)
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < deadline)
                time.sleep(0.1)
        # Reinspect under the lock; another DragonTools process may have completed.
        current = current_version(root, version)
        valid, repairs = inspect_tree(destination, tree_hash)
        if valid:
            for path, mode in repairs:
                metadata(path, mode)
                changed = True
        stage = None
        try:
            if not valid or current != version:
                stage = tempfile.mkdtemp(prefix=".download.", dir=root)
            if not valid:
                archive = os.path.join(stage, "archive.tar.gz")
                subprocess.run(["curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                                "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "600", "--retry", "2",
                                "--retry-max-time", "600", "--max-filesize", str(MAX_ARCHIVE), "--output", archive, url],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                require(file_hash(archive) == archive_hash)
                replacement = os.path.join(stage, "release")
                os.mkdir(replacement, 0o700)
                catalog = archive_catalog(archive, version, replacement)
                require(hashlib.sha256(catalog).hexdigest() == tree_hash)
                require(file_hash(os.path.join(replacement, "bin/grafana")) == binary_hash)
                with open(os.path.join(replacement, MANIFEST), "xb") as manifest:
                    manifest.write(catalog)
                    manifest.flush()
                    os.fsync(manifest.fileno())
                for kind, name, mode, value in json.loads(catalog):
                    metadata(os.path.join(replacement, name), mode)
                metadata(os.path.join(replacement, MANIFEST), 0o644)
                require(inspect_tree(replacement, tree_hash) == (True, []))
                # Refuse a raced foreign tree before atomically replacing only our managed one.
                existing = checked_directory(destination)
                if existing is not None:
                    require(existing.st_dev == os.stat(root).st_dev)
                    inspect_tree(destination, tree_hash)
                mark_dirty(pending)
                rename_directory(replacement, destination, existing is not None)
                changed = True
            if current != version:
                link = os.path.join(stage, "current.new")
                os.symlink(version, link)
                mark_dirty(pending)
                os.replace(link, os.path.join(root, "current"))
                changed = True
        finally:
            if stage is not None:
                # Only our private stage; a replaced known tree may now be here.
                shutil.rmtree(stage)
    finally:
        os.close(lock_fd)
    return "changed" if changed else "unchanged"


def main():
    try:
        require(len(sys.argv) == 10)
        mode, root, version, url, archive_hash, binary_hash, tree_hash, pending = sys.argv[2:]
        require(mode in ("install", "verify"))
        print(install(root, version, url, archive_hash, binary_hash, tree_hash, pending, mode == "verify"), end="")
    except Refusal as failure:
        sys.exit(failure.code)
    except Exception:
        # Remote failures are intentionally opaque; never print paths, commands or data.
        sys.exit(1)


if __name__ == "__main__":
    main()
