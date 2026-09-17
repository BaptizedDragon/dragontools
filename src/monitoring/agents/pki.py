"""Dedicated credential boundary. Private data only enters/leaves protected SSH I/O."""
import hashlib
import ipaddress
import json
import os
import pwd
import re
import resource
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile

BASE = "/etc/dragontools/ingestion"
ETC = "/etc/dragontools"
STATE = "/var/lib/dragontools"
ROOT = 0
MARKER = b"DragonTools agent mTLS v1\n"
FIELDS = {"version", "host", "station", "services", "metrics_targets"}
SECRET_FILES = ("ca.crt", "client.crt", "client.key")


def require(condition):
    if not condition:
        raise ValueError("Agent credential state refused")


def valid_host(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,62}", value))
    return value


def valid_endpoint(value):
    require(isinstance(value, str) and 0 < len(value) <= 253)
    try:
        ipaddress.ip_address(value)
    except ValueError:
        require(all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x)
                    for x in value.split(".")))
    return value


def registration(value, host=None, endpoint=None):
    require(isinstance(value, dict) and set(value) in (FIELDS, FIELDS | {"applications"}) and value["version"] == 1)
    valid_host(value["host"])
    valid_endpoint(value["station"])
    require(host is None or host == value["host"])
    require(endpoint is None or endpoint == value["station"])
    services = value["services"]
    require(isinstance(services, list) and 0 <= len(services) <= 64)
    require(all(isinstance(x, str) and len(x) <= 253 and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@:-]*[.]service", x) for x in services))
    require(services == sorted(set(services)))
    targets = value["metrics_targets"]
    require(isinstance(targets, list) and len(targets) <= 64)
    names = []
    for target in targets:
        require(isinstance(target, dict) and set(target) == {"name", "url"})
        require(isinstance(target["name"], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", target["name"]))
        require(isinstance(target["url"], str) and len(target["url"]) <= 2048 and "\n" not in target["url"])
        names.append(target["name"])
    require(names == sorted(set(names)))
    applications = value.get("applications", [])
    require(isinstance(applications, list) and len(applications) <= 32)
    require(services or applications)
    require(not applications or not targets)
    application_names, selected, all_units = [], [], set()
    total = 0
    for app in applications:
        require(isinstance(app, dict) and set(app) == {"name", "environment", "services"})
        for key in ("name", "environment"):
            require(isinstance(app[key], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", app[key]))
        application_names.append(app["name"])
        require(isinstance(app["services"], list))
        service_names = []
        for service in app["services"]:
            total += 1
            require(isinstance(service, dict) and set(service) == {"name", "systemd", "logs", "metrics_url"})
            require(isinstance(service["name"], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", service["name"]))
            require(isinstance(service["systemd"], str) and len(service["systemd"]) <= 253 and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@:-]*[.]service", service["systemd"]))
            require(type(service["logs"]) is bool)
            require(service["metrics_url"] is None or isinstance(service["metrics_url"], str) and len(service["metrics_url"]) <= 2048)
            require(service["systemd"] not in all_units)
            all_units.add(service["systemd"])
            service_names.append(service["name"])
            if service["logs"]: selected.append(service["systemd"])
        require(service_names == sorted(set(service_names)))
    require(application_names == sorted(set(application_names)) and total <= 64)
    if applications:
        require(services == sorted(selected))
    return value


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def run(*args, data=None):
    result = subprocess.run(["openssl", *args], input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=20, check=True)
    require(len(result.stdout) <= 32768)
    return result.stdout


def directory(path, mode, uid, gid, create=False):
    changed = False
    if not os.path.lexists(path) and create:
        os.mkdir(path, mode)
        os.chown(path, uid, gid)
        changed = True
    st = os.lstat(path)
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == uid and st.st_gid == gid and stat.S_IMODE(st.st_mode) == mode)
    return changed


def read(path, uid, gid, mode, limit=32768):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and st.st_uid == uid and st.st_gid == gid)
        require(stat.S_IMODE(st.st_mode) == mode and st.st_size <= limit)
        data = os.read(fd, limit + 1)
        require(len(data) <= limit)
        return data
    finally:
        os.close(fd)


def write(path, data, uid, gid, mode=0o400):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(data)
            output.flush()
            os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
    finally:
        os.close(fd)


def mark(name):
    path = STATE + "/" + name + "-restart-required"
    if os.path.lexists(path):
        read(path, ROOT, ROOT, 0o600, 64)
    else:
        write(path, b"", ROOT, ROOT, 0o600)


def validate_pair(path, name, purpose=None, ca=None, subject=None, endpoint=None):
    cert = path + "/" + name + ".crt"
    key = path + "/" + name + ".key"
    run("x509", "-in", cert, "-checkend", "0", "-noout")
    require(run("x509", "-in", cert, "-pubkey", "-noout") == run("pkey", "-in", key, "-pubout"))
    if ca:
        run("verify", "-purpose", purpose, "-CAfile", ca, cert)
    if subject:
        require(run("x509", "-in", cert, "-subject", "-noout", "-nameopt", "RFC2253").strip() == ("subject=CN=" + subject).encode())
    if endpoint:
        try:
            ipaddress.ip_address(endpoint)
            option = "-verify_ip"
        except ValueError:
            option = "-verify_hostname"
        run("verify", "-purpose", "sslserver", "-CAfile", ca, option, endpoint, cert)


def bundle(path, uid, gid, names):
    directory(path, 0o700 if uid == ROOT else 0o750, ROOT, gid)
    require(set(os.listdir(path)) == set(names) | {".dragontools-managed"})
    require(read(path + "/.dragontools-managed", ROOT, ROOT, 0o400) == MARKER)
    return {name: read(path + "/" + name, uid, gid, 0o400) for name in names}


def create_bundle(path, uid, gid, values):
    stage = tempfile.mkdtemp(prefix=".pki-", dir=os.path.dirname(path))
    try:
        write(stage + "/.dragontools-managed", MARKER, ROOT, ROOT)
        for name, data in values.items():
            write(stage + "/" + name, data, uid, gid)
        os.chown(stage, ROOT, gid)
        os.chmod(stage, 0o700 if uid == ROOT else 0o750)
        os.rename(stage, path)
        stage = None
    finally:
        if stage:
            shutil.rmtree(stage)


def generate(ca, name, subject, endpoint=None):
    with tempfile.TemporaryDirectory(prefix=".generate-", dir=BASE + "/pki") as stage:
        key = run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
        write(stage + "/key.pem", key, ROOT, ROOT)
        if ca is None:
            cert = run("req", "-new", "-x509", "-key", stage + "/key.pem", "-sha256", "-days", "3650",
                       "-subj", "/CN=DragonTools agent CA", "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                       "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        else:
            csr = run("req", "-new", "-key", stage + "/key.pem", "-subj", "/CN=" + subject)
            extensions = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage="
            if endpoint:
                try:
                    ipaddress.ip_address(endpoint)
                    san = "IP:"
                except ValueError:
                    san = "DNS:"
                extensions += "serverAuth\nsubjectAltName=" + san + endpoint + "\n"
            else:
                extensions += "clientAuth\n"
            write(stage + "/extensions", extensions.encode(), ROOT, ROOT)
            cert = run("x509", "-req", "-CA", ca + "/ca.crt", "-CAkey", ca + "/ca.key", "-set_serial",
                       "0x" + os.urandom(16).hex(), "-days", "365", "-sha256", "-extfile", stage + "/extensions", data=csr)
        return {name + ".crt": cert, name + ".key": key}


def inspect_station(host, endpoint):
    account = pwd.getpwnam("dt-ingest")
    directory(BASE, 0o755, ROOT, ROOT)
    directory(BASE + "/pki", 0o700, ROOT, ROOT)
    directory(BASE + "/clients", 0o700, ROOT, ROOT)
    directory(BASE + "/registry", 0o750, ROOT, account.pw_gid)
    bundle(BASE + "/pki/ca", ROOT, ROOT, ("ca.crt", "ca.key"))
    validate_pair(BASE + "/pki/ca", "ca")
    server = bundle(BASE + "/server", account.pw_uid, account.pw_gid, ("ca.crt", "server.crt", "server.key", "endpoint"))
    require(server["ca.crt"] == read(BASE + "/pki/ca/ca.crt", ROOT, ROOT, 0o400))
    require(read(BASE + "/server/endpoint", account.pw_uid, account.pw_gid, 0o400) == endpoint.encode())
    validate_pair(BASE + "/server", "server", "sslserver", BASE + "/pki/ca/ca.crt", endpoint=endpoint)
    client = bundle(BASE + "/clients/" + host, ROOT, ROOT, ("client.crt", "client.key"))
    validate_pair(BASE + "/clients/" + host, "client", "sslclient", BASE + "/pki/ca/ca.crt", subject=host)
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(client["client.crt"].decode())).hexdigest()


def ensure(value):
    host, endpoint = value["host"], value["station"]
    account = pwd.getpwnam("dt-ingest")
    directory(BASE, 0o755, ROOT, ROOT)
    changed = directory(BASE + "/pki", 0o700, ROOT, ROOT, True)
    changed = directory(BASE + "/clients", 0o700, ROOT, ROOT, True) or changed
    changed = directory(BASE + "/registry", 0o750, ROOT, account.pw_gid, True) or changed
    ca = BASE + "/pki/ca"
    if not os.path.lexists(ca):
        create_bundle(ca, ROOT, ROOT, generate(None, "ca", "DragonTools agent CA"))
        changed = True
    bundle(ca, ROOT, ROOT, ("ca.crt", "ca.key"))
    validate_pair(ca, "ca")
    if not os.path.lexists(BASE + "/server"):
        values = generate(ca, "server", endpoint, endpoint)
        values["ca.crt"] = read(ca + "/ca.crt", ROOT, ROOT, 0o400)
        values["endpoint"] = endpoint.encode()
        mark("ingestion")
        create_bundle(BASE + "/server", account.pw_uid, account.pw_gid, values)
        changed = True
    if not os.path.lexists(BASE + "/clients/" + host):
        create_bundle(BASE + "/clients/" + host, ROOT, ROOT, generate(ca, "client", host))
        changed = True
    fingerprint = inspect_station(host, endpoint)
    desired = encoded(dict(value, certificate_sha256=fingerprint))
    path = BASE + "/registry/" + host + ".json"
    current = None
    if os.path.lexists(path):
        current = read(path, ROOT, account.pw_gid, 0o640, 196608)
        previous = json.loads(current)
        require(set(previous) in (FIELDS | {"certificate_sha256"}, FIELDS | {"applications", "certificate_sha256"}))
        registration({key: val for key, val in previous.items() if key != "certificate_sha256"}, host)
        # Raw-host and repository namespaces must never silently adopt each other.
        require(bool(previous.get("applications")) == bool(value.get("applications")))
    if current != desired:
        fd, stage = tempfile.mkstemp(prefix=".registration-", dir=BASE + "/registry")
        os.close(fd)
        os.unlink(stage)
        try:
            write(stage, desired, ROOT, account.pw_gid, 0o640)
            os.replace(stage, path)
        finally:
            if os.path.lexists(stage):
                os.unlink(stage)
        changed = True
    return "changed" if changed else "unchanged"


def read_registration(host):
    account = pwd.getpwnam("dt-ingest")
    directory(BASE + "/registry", 0o750, ROOT, account.pw_gid)
    value = json.loads(read(BASE + "/registry/" + host + ".json", ROOT, account.pw_gid, 0o640, 196608))
    require(set(value) in (FIELDS | {"certificate_sha256"}, FIELDS | {"applications", "certificate_sha256"}))
    return registration({key: val for key, val in value.items() if key != "certificate_sha256"}, host), value["certificate_sha256"]


def verify_station(value):
    actual, fingerprint = read_registration(value["host"])
    require(actual == value)
    require(inspect_station(value["host"], value["station"]) == fingerprint)


def export(host):
    value, _ = read_registration(host)
    verify_station(value)
    result = {"host": host, "station": value["station"]}
    result["ca.crt"] = read(BASE + "/pki/ca/ca.crt", ROOT, ROOT, 0o400).decode()
    for name in ("client.crt", "client.key"):
        result[name] = read(BASE + "/clients/" + host + "/" + name, ROOT, ROOT, 0o400).decode()
    return encoded(result)


def agent_state(kind, account):
    path = ETC + "/" + kind
    directory(path, 0o755, ROOT, ROOT)
    marker = path + "/.dragontools-credentials"
    present = any(os.path.lexists(path + "/" + name) for name in SECRET_FILES + (".agent-identity",))
    if not os.path.lexists(marker):
        require(not present)
        return None
    require(read(marker, ROOT, ROOT, 0o400) == MARKER)
    result = {}
    for name in SECRET_FILES:
        if os.path.lexists(path + "/" + name):
            result[name] = read(path + "/" + name, account.pw_uid, account.pw_gid, 0o400)
    if os.path.lexists(path + "/.agent-identity"):
        result[".agent-identity"] = read(path + "/.agent-identity", ROOT, ROOT, 0o400)
    return result


def import_credentials(kind, payload):
    require(set(payload) == set(SECRET_FILES) | {"host", "station"})
    host, endpoint = valid_host(payload["host"]), valid_endpoint(payload["station"])
    account = pwd.getpwnam("dt-" + kind)
    current = agent_state(kind, account)
    desired = {name: payload[name].encode() for name in SECRET_FILES}
    require(all(len(x) <= 16384 for x in desired.values()))
    desired[".agent-identity"] = encoded({"host": host, "station": endpoint})
    if current == desired:
        # A real no-op performs only read-only cryptographic verification. It
        # does not stage another plaintext key, touch a marker or stop a unit.
        verify_credentials(kind, host, endpoint)
        return "unchanged"
    # Validate the supplied pair before publishing anything or stopping a process.
    with tempfile.TemporaryDirectory(prefix=".credentials-", dir=ETC + "/" + kind) as stage:
        for name, value in desired.items():
            write(stage + "/" + name, value, ROOT, ROOT)
        validate_pair(stage, "client", "sslclient", stage + "/ca.crt", subject=host)
        for name in SECRET_FILES:
            os.chown(stage + "/" + name, account.pw_uid, account.pw_gid)
        mark(kind)
        state = subprocess.run(["systemctl", "is-active", "dragontools-" + kind + ".service"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=False)
        if state.stdout.strip() in (b"active", b"activating", b"reloading", b"deactivating"):
            subprocess.run(["systemctl", "stop", "dragontools-" + kind + ".service"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
        else:
            require(state.returncode in (3, 4) and state.stdout.strip() in (b"inactive", b"failed", b"unknown"))
        if current is None:
            write(ETC + "/" + kind + "/.dragontools-credentials", MARKER, ROOT, ROOT)
        for name in desired:
            os.replace(stage + "/" + name, ETC + "/" + kind + "/" + name)
    return "changed"


def verify_credentials(kind, host, endpoint):
    account = pwd.getpwnam("dt-" + kind)
    state = agent_state(kind, account)
    require(state is not None and set(state) == set(SECRET_FILES) | {".agent-identity"})
    require(state[".agent-identity"] == encoded({"host": host, "station": endpoint}))
    validate_pair(ETC + "/" + kind, "client", "sslclient", ETC + "/" + kind + "/ca.crt", subject=host)


def main():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o077)
        mode, *args = sys.argv[1:]
        if mode in ("ensure", "verify"):
            require(len(args) == 3)
            value = registration(json.loads(args[2]), valid_host(args[0]), valid_endpoint(args[1]))
            if mode == "ensure":
                sys.stdout.write(ensure(value))
            else:
                verify_station(value)
                sys.stdout.write("unchanged")
        elif mode in ("export", "registration"):
            require(len(args) == 1)
            host = valid_host(args[0])
            if mode == "export":
                sys.stdout.buffer.write(export(host))
            else:
                sys.stdout.buffer.write(encoded(read_registration(host)[0]))
        elif mode in ("import", "verify-agent"):
            require(args and args[0] in ("vector", "vmagent"))
            if mode == "import":
                require(len(args) == 1)
                data = sys.stdin.buffer.read(65537)
                require(len(data) <= 65536)
                sys.stdout.write(import_credentials(args[0], json.loads(data)))
            else:
                require(len(args) == 3)
                verify_credentials(args[0], valid_host(args[1]), valid_endpoint(args[2]))
                sys.stdout.write("unchanged")
        else:
            return 86
        return 0
    except Exception:
        return 86


if __name__ == "__main__":
    sys.exit(main())
