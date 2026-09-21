"""Mutation-only continuation of scrape.py; never embedded in verification."""
import fcntl
import subprocess
import tempfile

VERSION_DIR = "/opt/dragontools/components/victoriametrics/v1.151.0"
BINARY = VERSION_DIR + "/victoria-metrics-prod"
LOCK = CONFIG_DIR + "/.scrape.lock"


def sync_dir(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def mark_reload():
    if pending_exists():
        return
    descriptor = os.open(PENDING, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    sync_dir(os.path.dirname(PENDING))


def directory(path):
    info = node(path, "dir", missing=True)
    changed = False
    if info is None:
        os.mkdir(path, 0o755)
        info = node(path, "dir")
        changed = True
    if (info.st_uid, info.st_gid) != (0, 0):
        os.chown(path, 0, 0, follow_symlinks=False)
        changed = True
    if stat.S_IMODE(info.st_mode) != 0o755:
        os.chmod(path, 0o755, follow_symlinks=False)
        changed = True
    return changed


def validate_binary(expected):
    node("/opt/dragontools", "dir")
    node("/opt/dragontools/components", "dir")
    node("/opt/dragontools/components/victoriametrics", "dir")
    node(VERSION_DIR, "dir")
    info = node(BINARY, "file")
    if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o755):
        raise ValueError("Incorrect pinned binary metadata")
    digest = hashlib.sha256()
    with open(BINARY, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError("Incorrect pinned binary")


def inspect_config():
    for path in (CONFIG_PARENT, CONFIG_DIR):
        node(path, "dir", missing=True)
    pending_exists()
    info = node(CONFIG, "file", missing=True)
    if info is None:
        return None, None
    if info.st_size > 128 * 1024:
        raise ValueError("Configuration too large")
    with open(CONFIG, "rb") as source:
        actual = source.read(128 * 1024 + 1)
    if not actual.startswith(b"# Managed by DragonTools\n"):
        raise ValueError("Unmanaged scrape configuration")
    return info, actual


def prepare_config(config, binary_hash):
    # Validate every native include before staging or activating the config.
    if "app_all" in globals():
        app_all()
    desired = config.encode()
    if len(desired) > 128 * 1024 or not desired.startswith(b"# Managed by DragonTools\n"):
        raise ValueError("Invalid generated configuration")
    info, actual = inspect_config()
    # A correct rerun returns before lock/staging/validation subprocesses or writes.
    if actual == desired:
        try:
            read_config(config)
            return False
        except ValueError:
            pass
    changed = False
    for path in (CONFIG_PARENT, CONFIG_DIR):
        changed = directory(path) or changed
    lock_info = node(LOCK, "file", missing=True)
    if lock_info is not None and (lock_info.st_uid, lock_info.st_gid, stat.S_IMODE(lock_info.st_mode)) != (0, 0, 0o600):
        raise ValueError("Incorrect scrape lock")
    lock = os.open(LOCK, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        # Install operations are serialized per host. Refuse contention instead
        # of introducing unbounded waiting or a polling daemon.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        info, actual = inspect_config()
        if actual == desired:
            if (info.st_uid, info.st_gid) != (0, 0):
                os.chown(CONFIG, 0, 0, follow_symlinks=False)
                changed = True
            if stat.S_IMODE(info.st_mode) != 0o644:
                os.chmod(CONFIG, 0o644, follow_symlinks=False)
                changed = True
            return changed
        validate_binary(binary_hash)
        descriptor, staging = tempfile.mkstemp(prefix=".prometheus.", dir=CONFIG_DIR)
        try:
            with os.fdopen(descriptor, "wb") as target:
                target.write(desired)
                target.flush()
                os.fsync(target.fileno())
            # This pinned binary's dry-run parses static configuration and exits
            # before storage/HTTP/scraper startup. No target or notifier contact.
            result = subprocess.run([BINARY, "-promscrape.config=" + staging, "-promscrape.config.dryRun", "-loggerLevel=ERROR"],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=15, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"})
            if result.returncode != 0:
                raise ValueError("Invalid scrape configuration")
            info = node(staging, "file")
            with open(staging, "rb") as source:
                if source.read(128 * 1024 + 1) != desired:
                    raise ValueError("Changed staged configuration")
            os.chown(staging, 0, 0, follow_symlinks=False)
            os.chmod(staging, 0o644, follow_symlinks=False)
            # Record intent durably before publishing. Failures after publication
            # leave this marker for a later config reload, never a VM restart.
            mark_reload()
            os.replace(staging, CONFIG)
            sync_dir(CONFIG_DIR)
            return True
        finally:
            if os.path.lexists(staging):
                os.unlink(staging)
    finally:
        os.close(lock)


def reconcile_config(config, expected):
    read_config(config)
    reload_needed = pending_exists()
    if not reload_needed:
        try:
            targets_loaded(expected, require_scraped=False)
            config_reloaded()
            loaded_policy(expected)
            if request("/ready").strip() != b"OK":
                raise ValueError("Invalid scraper readiness response")
        except NotReady:
            # An interrupted/out-of-band reload can leave desired disk bytes but
            # stale runtime definitions; recover from actual state on every run.
            reload_needed = True
    if not reload_needed:
        return False
    mark_reload()
    request("/-/reload", method="POST")
    # HTTP200 only schedules SIGHUP. Read-only bounded health runs afterwards.
    return True


def finalize_config(config):
    read_config(config)
    if pending_exists():
        os.unlink(PENDING)
        sync_dir(os.path.dirname(PENDING))


def mutate_main():
    try:
        mode, config, raw_probes, binary_hash = sys.argv[1:5]
        expected = definitions(json.loads(base64.b64decode(raw_probes, validate=True)))
        if mode == "prepare":
            config = base64.b64decode(config, validate=True).decode()
            changed = prepare_config(config, binary_hash)
        elif mode == "reconcile":
            changed = reconcile_config(config, expected)
        elif mode == "finalize":
            finalize_config(config)
            return 0
        else:
            raise ValueError("Unsupported scrape mutation")
        print("changed" if changed else "unchanged", end="")
        return 0
    except Exception:
        return 1
