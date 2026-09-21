"""Pinned signed VictoriaLogs Grafana plugin. Python stdlib; no downloaded code runs.

Each release contains `content/` (the exact signed package) and a sibling trusted
catalog. Keeping our catalog outside content preserves Grafana signature checks.
The version/catalog allowlist is embedded by Zig, never downloaded at runtime.
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
import tempfile
import time
import zipfile

PLUGIN = "victoriametrics-logs-datasource"
EXECUTABLE = "victoriametrics_logs_backend_plugin"
MANIFEST = ".dragontools-plugin-catalog.json"
MAX_ARCHIVE = 100_000_000
MAX_CONTENT = 300_000_000
MAX_ENTRIES = 100
MAX_CATALOG = 32_000
OWNER = (0, 0)


class Refusal(Exception):
    def __init__(self, code=40):
        self.code = code


def require(condition, code=40):
    if not condition:
        raise Refusal(code)


def safe_path(name):
    require(isinstance(name, str) and re.fullmatch(r"[-A-Za-z0-9_./]*", name))
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
        value = digest_stream(stream)
        after = os.fstat(stream.fileno())
        require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns))
        return value


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


def correct_metadata(info, mode):
    return info is not None and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (*OWNER, mode)


def inspect_release(release, expected):
    """Read only; a digest-authenticated catalog is required before any repair."""
    base = checked_directory(release)
    if base is None:
        return False, []
    require(set(os.listdir(release)) == {"content", MANIFEST})
    path = os.path.join(release, MANIFEST)
    info = lstat_optional(path)
    require(info is not None and not stat.S_ISLNK(info.st_mode), 43)
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= MAX_CATALOG)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as source:
        data = source.read(MAX_CATALOG + 1)
    require(hashlib.sha256(data).hexdigest() == expected)
    records = json.loads(data)
    require(isinstance(records, list) and len(records) <= MAX_ENTRIES)
    expected_entries = {}
    for kind, name, mode, value in records:
        safe_path(name)
        require(name not in expected_entries and kind in ("d", "f"))
        require(mode in (0o644, 0o755) and (kind != "d" or mode == 0o755))
        require((kind == "d" and value == "") or (kind == "f" and re.fullmatch("[0-9a-f]{64}", value)))
        expected_entries[name] = (kind, mode, value)
    repairs = []
    if not correct_metadata(base, 0o755):
        repairs.append((release, 0o755))
    if not correct_metadata(info, 0o644):
        repairs.append((path, 0o644))
    content = os.path.join(release, "content")
    content_info = checked_directory(content)
    require(content_info is not None)
    seen, valid, stack = set(), True, [("", content_info)]
    while stack:
        relative, info = stack.pop()
        path = os.path.join(content, relative)
        require(not stat.S_ISLNK(info.st_mode), 43)
        require(info.st_dev == base.st_dev and relative in expected_entries)
        kind, mode, value = expected_entries[relative]
        seen.add(relative)
        require((kind == "d" and stat.S_ISDIR(info.st_mode)) or (kind == "f" and stat.S_ISREG(info.st_mode)))
        if kind == "f":
            require(info.st_nlink == 1)
            valid = file_hash(path) == value and valid
        else:
            for entry in os.scandir(path):
                child = entry.name if not relative else relative + "/" + entry.name
                stack.append((child, entry.stat(follow_symlinks=False)))
        if not correct_metadata(info, mode):
            repairs.append((path, mode))
    return valid and seen == set(expected_entries), repairs


def pending_check(path):
    info = lstat_optional(path)
    if info is not None:
        require(not stat.S_ISLNK(info.st_mode), 43)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and (info.st_uid, info.st_gid) == OWNER)


def target(version):
    return "../plugins-versions/" + PLUGIN + "/" + version + "/content"


def current_version(active, versions, trusted):
    info = lstat_optional(active)
    if info is None:
        return None
    require(stat.S_ISLNK(info.st_mode), 43)
    require((info.st_uid, info.st_gid) == OWNER)
    value = os.readlink(active)
    matches = [version for version in trusted if value == target(version)]
    require(len(matches) == 1, 43)
    current = matches[0]
    # Only reviewed historical releases may be replaced. No marker-only adoption.
    inspect_release(os.path.join(versions, current), trusted[current])
    return current


def verify(data, version, trusted, pending):
    require(os.geteuid() == 0, 10)
    require(version in trusted)
    require(checked_directory(data) is not None)
    require(correct_metadata(checked_directory(os.path.dirname(data)), 0o755))
    pending_check(pending)
    plugins = os.path.join(data, "plugins")
    store = os.path.join(data, "plugins-versions")
    versions = os.path.join(store, PLUGIN)
    for path in (plugins, store, versions):
        require(correct_metadata(checked_directory(path), 0o755))
    require(set(os.listdir(plugins)) == {PLUGIN} and set(os.listdir(store)) == {PLUGIN})
    require(current_version(os.path.join(plugins, PLUGIN), versions, trusted) == version)
    require(inspect_release(os.path.join(versions, version), trusted[version]) == (True, []))
    return "verified"


# BEGIN MUTATING INSTALLATION

def archive_catalog(path, version, destination=None):
    """Validate the whole ZIP before extracting exclusively regular known paths."""
    entries, seen, total = [], {}, 0
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        require(len(members) <= MAX_ENTRIES)
        for member in members:
            require(member.orig_filename == member.filename and "\x00" not in member.filename)
            name = member.filename[:-1] if member.is_dir() else member.filename
            require(name == PLUGIN or name.startswith(PLUGIN + "/"))
            relative = safe_path(name[len(PLUGIN) + 1:] if name != PLUGIN else "")
            require(relative not in seen)
            archive_mode = member.external_attr >> 16
            require(member.create_system == 3 and not archive_mode & 0o7000)
            kind = "d" if member.is_dir() else "f"
            require((kind == "d" and stat.S_ISDIR(archive_mode)) or
                    (kind == "f" and stat.S_ISREG(archive_mode)), 43 if stat.S_ISLNK(archive_mode) else 40)
            require(not member.flag_bits & 1 and member.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED))
            require(member.file_size >= 0 and (kind != "d" or member.file_size == 0))
            require(relative != "" or kind == "d")
            total += member.file_size
            require(total <= MAX_CONTENT)
            seen[relative] = kind
        require(seen.get("") == "d")
        for relative in seen:
            if relative:
                require(seen.get(relative.rpartition("/")[0]) == "d")
        for required in ("plugin.json", "MANIFEST.txt", "module.js", EXECUTABLE + "_linux_amd64", EXECUTABLE + "_linux_arm64"):
            require(seen.get(required) == "f")
        for metadata_name in ("plugin.json", "MANIFEST.txt"):
            require(archive.getinfo(PLUGIN + "/" + metadata_name).file_size <= MAX_CATALOG)
        plugin_bytes = archive.read(PLUGIN + "/plugin.json")
        require(len(plugin_bytes) <= MAX_CATALOG)
        plugin = json.loads(plugin_bytes)
        require(plugin.get("id") == PLUGIN and plugin.get("type") == "datasource")
        require(plugin.get("info", {}).get("version") == version and plugin.get("backend") is True)
        require(plugin.get("executable") == EXECUTABLE)
        signed = archive.read(PLUGIN + "/MANIFEST.txt")
        require(len(signed) <= MAX_CATALOG)
        require(signed.startswith(b"-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n"))
        require(b"\n-----BEGIN PGP SIGNATURE-----\n" in signed and signed.rstrip().endswith(b"-----END PGP SIGNATURE-----"))
        signed_payload = json.loads(signed.split(b"\n\n", 1)[1].split(b"\n-----BEGIN PGP SIGNATURE-----", 1)[0])
        require(signed_payload.get("plugin") == PLUGIN and signed_payload.get("version") == version)
        require(signed_payload.get("signedByOrg") == "victoriametrics" and signed_payload.get("signatureType") == "commercial")
        signed_files = signed_payload.get("files")
        require(isinstance(signed_files, dict) and set(signed_files) == {name for name, kind in seen.items() if kind == "f" and name != "MANIFEST.txt"})
        # Sorting creates parent directories first even if ZIP entries were unordered.
        for member in sorted(members, key=lambda item: item.filename):
            name = member.filename[:-1] if member.is_dir() else member.filename
            relative = name[len(PLUGIN) + 1:] if name != PLUGIN else ""
            kind = seen[relative]
            mode = 0o755 if kind == "d" or (member.external_attr >> 16) & 0o111 else 0o644
            target = os.path.join(destination, relative) if destination is not None else None
            content_hash = ""
            if kind == "d":
                if target is not None and relative:
                    os.mkdir(target, 0o700)
            else:
                with archive.open(member) as source:
                    if target is None:
                        content_hash = digest_stream(source)
                    else:
                        value = hashlib.sha256()
                        count = 0
                        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                        with os.fdopen(fd, "wb") as output:
                            for block in iter(lambda: source.read(1024 * 1024), b""):
                                count += len(block)
                                require(count <= member.file_size)
                                output.write(block)
                                value.update(block)
                            output.flush()
                            os.fsync(output.fileno())
                        require(count == member.file_size)
                        content_hash = value.hexdigest()
                if relative != "MANIFEST.txt":
                    require(signed_files[relative] == content_hash)
            entries.append([kind, relative, mode, content_hash])
        return canonical(entries)


def metadata(path, mode):
    info = os.lstat(path)
    require(not stat.S_ISLNK(info.st_mode), 43)
    if (info.st_uid, info.st_gid) != OWNER:
        os.chown(path, *OWNER, follow_symlinks=False)
    if stat.S_IMODE(info.st_mode) != mode:
        os.chmod(path, mode, follow_symlinks=False)


def mark_dirty(path):
    pending_check(path)
    if not os.path.exists(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fsync(fd)
        os.close(fd)


def rename_directory(source, destination, exchange):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(source), -100, os.fsencode(destination), 2 if exchange else 1):
        raise OSError(ctypes.get_errno(), "atomic plugin publication failed")


def install(data, version, url, archive_hash, trusted, pending):
    require(os.geteuid() == 0, 10)
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) and version in trusted)
    require(url.startswith("https://") and re.fullmatch("[0-9a-f]{64}", archive_hash))
    for item, digest in trusted.items():
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", item) and re.fullmatch("[0-9a-f]{64}", digest))
    os.umask(0o077)
    require(checked_directory(data) is not None)
    require(correct_metadata(checked_directory(os.path.dirname(data)), 0o755))
    require(os.path.dirname(data) == os.path.dirname(pending))
    pending_check(pending)
    plugins = os.path.join(data, "plugins")
    store = os.path.join(data, "plugins-versions")
    versions = os.path.join(store, PLUGIN)
    active = os.path.join(plugins, PLUGIN)
    release = os.path.join(versions, version)
    directories = (plugins, store, versions)
    infos = [checked_directory(path) for path in directories]
    # Old Grafana may have created an empty writable plugins directory. That sole
    # empty directory is an explicit supported metadata migration to root:root.
    if infos[0] is not None:
        require(set(os.listdir(plugins)) <= {PLUGIN})
    if infos[1] is not None:
        require(set(os.listdir(store)) <= {PLUGIN})
    for info, path in zip(infos[1:], directories[1:]):
        if info is not None:
            require((info.st_uid, info.st_gid) == OWNER)
    current = current_version(active, versions, trusted)
    valid, repairs = inspect_release(release, trusted[version])
    dirs_correct = all(correct_metadata(info, 0o755) for info in infos)
    lock = os.path.join(versions, ".install.lock")
    lock_info = lstat_optional(lock)
    if lock_info is not None:
        require(not stat.S_ISLNK(lock_info.st_mode), 43)
        require(stat.S_ISREG(lock_info.st_mode) and lock_info.st_nlink == 1 and (lock_info.st_uid, lock_info.st_gid) == OWNER)
    if valid and not repairs and dirs_correct and current == version:
        return "unchanged"
    for info, path in zip(infos, directories):
        if info is None:
            os.mkdir(path, 0o755)
        metadata(path, 0o755)
    changed = not dirs_correct
    lock_fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock_fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and (info.st_uid, info.st_gid) == OWNER)
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < deadline)
                time.sleep(0.1)
        current = current_version(active, versions, trusted)
        valid, repairs = inspect_release(release, trusted[version])
        if valid:
            for path, mode in repairs:
                metadata(path, mode)
                changed = True
        stage, preserve_stage = None, False
        try:
            if not valid or current != version:
                stage = tempfile.mkdtemp(prefix=".stage.", dir=versions)
            if not valid:
                archive = os.path.join(stage, "plugin.zip")
                subprocess.run(["curl", "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                                "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "300", "--retry", "2",
                                "--retry-max-time", "300", "--max-filesize", str(MAX_ARCHIVE), "--output", archive, url],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                require(file_hash(archive) == archive_hash)
                replacement = os.path.join(stage, "release")
                os.mkdir(replacement, 0o700)
                content = os.path.join(replacement, "content")
                os.mkdir(content, 0o700)
                catalog = archive_catalog(archive, version, content)
                require(hashlib.sha256(catalog).hexdigest() == trusted[version])
                with open(os.path.join(replacement, MANIFEST), "xb") as output:
                    output.write(catalog)
                    output.flush()
                    os.fsync(output.fileno())
                for kind, name, mode, value in json.loads(catalog):
                    metadata(os.path.join(content, name), mode)
                metadata(replacement, 0o755)
                metadata(os.path.join(replacement, MANIFEST), 0o644)
                require(inspect_release(replacement, trusted[version]) == (True, []))
                existing = checked_directory(release)
                if existing is not None:
                    inspect_release(release, trusted[version])
                mark_dirty(pending)
                rename_directory(replacement, release, existing is not None)
                # A replaced same-version tree remains recoverable until an operator
                # removes it deliberately. Different historical versions stay put.
                if existing is not None:
                    preserve_stage = True
                    os.unlink(archive)
                    backup = os.path.join(versions, ".previous." + version + "." + os.path.basename(stage)[7:])
                    os.rename(stage, backup)
                    stage = None
                    preserve_stage = False
                changed = True
            if current != version:
                if stage is None:
                    stage = tempfile.mkdtemp(prefix=".stage.", dir=versions)
                link = os.path.join(stage, "active.new")
                os.symlink(target(version), link)
                mark_dirty(pending)
                # Recheck the destination immediately before atomic replacement.
                require(current_version(active, versions, trusted) == current)
                os.replace(link, active)
                changed = True
        finally:
            if stage is not None and not preserve_stage:
                shutil.rmtree(stage)
    finally:
        os.close(lock_fd)
    return "changed" if changed else "unchanged"


def main():
    try:
        require(len(sys.argv) == 9)
        mode, data, version, url, archive_hash, trusted, pending = sys.argv[2:]
        require(mode in ("install", "verify"))
        trusted = json.loads(trusted)
        result = verify(data, version, trusted, pending) if mode == "verify" else install(data, version, url, archive_hash, trusted, pending)
        print(result, end="")
    except Refusal as failure:
        sys.exit(failure.code)
    except Exception:
        sys.exit(1)


if __name__ == "__main__":
    main()
