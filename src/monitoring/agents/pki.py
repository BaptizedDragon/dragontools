"""Station CA/signing boundary and shared host-local credential primitives.

Only public CSRs/certificates cross SSH. Client private keys are never generated
by this station signer; the client helper reuses these file-validation primitives.
"""
import base64
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
import time

BASE = "/etc/dragontools/ingestion"
ETC = "/etc/dragontools"
STATE = "/var/lib/dragontools"
ROOT = 0
MARKER = b"DragonTools agent mTLS v1\n"
FIELDS = {"version", "host", "station", "services", "metrics_targets"}
SECRET_FILES = ("ca.crt", "client.crt", "client.key")
RENEW_SECONDS = 30 * 86400
CA_MAINTENANCE_SECONDS = 366 * 86400
REGISTRY_LIMIT = 393216
PENDING_SECONDS = 86400
PENDING_FIELDS = {"pending_certificate_pem", "pending_certificate_sha256", "pending_registration", "pending_expires_at"}
MODERN_FIELDS = {"certificate_pem", "certificate_identity"}


class CAMaintenanceRequired(ValueError):
    pass


def require(condition):
    if not condition:
        raise ValueError("Agent credential state refused")


def valid_host(value):
    require(isinstance(value, str) and re.fullmatch(r"dt-[0-9a-f]{32}", value))
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
        _sync_parent(path)
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


def _sync_parent(path):
    fd = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
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
    _sync_parent(path)


def mark(name):
    path = STATE + "/" + name + "-restart-required"
    if os.path.lexists(path):
        read(path, ROOT, ROOT, 0o600, 64)
    else:
        write(path, b"", ROOT, ROOT, 0o600)


def validate_pair(path, name, purpose=None, ca=None, subject=None, endpoint=None, allow_expired=False):
    cert = path + "/" + name + ".crt"
    key = path + "/" + name + ".key"
    if not allow_expired:
        run("x509", "-in", cert, "-checkend", "0", "-noout")
    require(run("x509", "-in", cert, "-pubkey", "-noout") == run("pkey", "-in", key, "-pubout"))
    if ca:
        run("verify", *(("-no_check_time",) if allow_expired else ()), "-purpose", purpose, "-CAfile", ca, cert)
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
        _sync_parent(path)
    finally:
        if stage:
            shutil.rmtree(stage)


def identity(host):
    return "dragontools://hosts/" + valid_host(host)


def fingerprint(cert):
    require(isinstance(cert, (bytes, str)) and len(cert) <= 16384)
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.decode() if isinstance(cert, bytes) else cert)).hexdigest()


def expires_soon(cert, seconds=RENEW_SECONDS):
    result = subprocess.run(["openssl", "x509", "-in", cert, "-checkend", str(seconds), "-noout"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    require(result.returncode in (0, 1))
    return result.returncode == 1


def _extension(cert, name, data=None):
    source = ("-in", cert) if cert is not None else ()
    value = run("x509", *source, "-noout", "-ext", name, data=data).decode().splitlines()
    require(len(value) == 2)
    return value[1].strip()


def validate_client_certificate(path, host, ca, allow_expired=False, data=None):
    source = ("-in", path) if path is not None else ()
    if not allow_expired:
        run("x509", *source, "-checkend", "0", "-noout", data=data)
    run("verify", *(("-no_check_time",) if allow_expired else ()), "-purpose", "sslclient", "-CAfile", ca,
        *((path,) if path is not None else ()), data=data)
    require(run("x509", *source, "-subject", "-noout", "-nameopt", "RFC2253", data=data).strip() == ("subject=CN=" + valid_host(host)).encode())
    require(_extension(path, "subjectAltName", data) == "URI:" + identity(host))
    require(_extension(path, "basicConstraints", data) == "CA:FALSE")
    require(_extension(path, "keyUsage", data) == "Digital Signature")
    require(_extension(path, "extendedKeyUsage", data) == "TLS Web Client Authentication")


def _der(data):
    """Small strict DER reader for the single permitted PKCS#10 profile."""
    values, offset = [], 0
    while offset < len(data):
        require(offset + 2 <= len(data))
        tag, length = data[offset], data[offset + 1]
        offset += 2
        require(tag & 31 != 31)
        if length & 128:
            count = length & 127
            require(0 < count <= 3 and offset + count <= len(data) and data[offset] != 0)
            length = int.from_bytes(data[offset:offset + count], "big")
            offset += count
            require(length >= 128)
        require(offset + length <= len(data))
        values.append((tag, data[offset:offset + length]))
        offset += length
    return values


def _one(data, tag):
    values = _der(data)
    require(len(values) == 1 and values[0][0] == tag)
    return values[0][1]


def validate_csr(csr, host):
    valid_host(host)
    require(isinstance(csr, str) and len(csr.encode()) <= 8192)
    match = re.fullmatch(r"-----BEGIN CERTIFICATE REQUEST-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE REQUEST-----\n?", csr)
    require(match is not None)
    der = base64.b64decode(match[1].replace("\n", ""), validate=True)
    request = _der(_one(der, 0x30))
    require(len(request) == 3 and [x[0] for x in request] == [0x30, 0x30, 0x03])
    require(_der(request[1][1]) == [(0x06, bytes.fromhex("2a8648ce3d040302"))])
    info = _der(request[0][1])
    require(len(info) == 4 and info[0] == (0x02, b"\0") and [x[0] for x in info[1:]] == [0x30, 0x30, 0xa0])
    subject = _der(_one(_one(info[1][1], 0x31), 0x30))
    require(len(subject) == 2 and subject[0] == (0x06, bytes.fromhex("550403")))
    require(subject[1][0] in (0x0c, 0x13) and subject[1][1] == host.encode())
    spki = _der(info[2][1])
    require(len(spki) == 2 and spki[0][0] == 0x30 and spki[1][0] == 0x03)
    require(_der(spki[0][1]) == [(0x06, bytes.fromhex("2a8648ce3d0201")), (0x06, bytes.fromhex("2a8648ce3d030107"))])
    require(len(spki[1][1]) == 66 and spki[1][1][:2] == b"\0\x04")
    # Accept only extensionRequest containing exactly the required URI SAN.
    # CA, serverAuth, unknown OIDs and arbitrary names are refused, not copied.
    attribute = _der(_one(info[3][1], 0x30))
    require(len(attribute) == 2 and attribute[0] == (0x06, bytes.fromhex("2a864886f70d01090e")) and attribute[1][0] == 0x31)
    extension = _der(_one(_one(attribute[1][1], 0x30), 0x30))
    require(len(extension) in (2, 3) and extension[0] == (0x06, bytes.fromhex("551d11")))
    if len(extension) == 3:
        require(extension[1] == (0x01, b"\xff"))
    require(extension[-1][0] == 0x04)
    require(_der(_one(extension[-1][1], 0x30)) == [(0x86, identity(host).encode())])
    # Structural constraints do not replace proof of possession or EC validation.
    run("req", "-verify", "-noout", data=csr.encode())
    public = run("req", "-pubkey", "-noout", data=csr.encode())
    run("pkey", "-pubin", "-pubcheck", "-noout", data=public)
    return public


def sign(csr, host, ca):
    validate_csr(csr, host)
    with tempfile.TemporaryDirectory(prefix=".sign-", dir=BASE + "/pki") as stage:
        extensions = ("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                      "extendedKeyUsage=clientAuth\nsubjectAltName=URI:" + identity(host) + "\n")
        write(stage + "/extensions", extensions.encode(), ROOT, ROOT)
        return run("x509", "-req", "-CA", ca + "/ca.crt", "-CAkey", ca + "/ca.key", "-set_serial",
                   "0x" + os.urandom(16).hex(), "-days", "365", "-sha256", "-extfile", stage + "/extensions", data=csr.encode())


def generate(ca, name, subject, endpoint=None, key=None):
    # There is intentionally no station-side client generation branch.
    require((ca is None and name == "ca") or (ca is not None and name == "server" and endpoint is not None))
    with tempfile.TemporaryDirectory(prefix=".generate-", dir=BASE + "/pki") as stage:
        if key is None:
            key = run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
        write(stage + "/key.pem", key, ROOT, ROOT)
        if ca is None:
            cert = run("req", "-new", "-x509", "-key", stage + "/key.pem", "-sha256", "-days", "3650",
                       "-subj", "/CN=DragonTools agent CA", "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                       "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        else:
            csr = run("req", "-new", "-key", stage + "/key.pem", "-subj", "/CN=" + subject)
            try:
                ipaddress.ip_address(endpoint)
                san = "IP:"
            except ValueError:
                san = "DNS:"
            extensions = "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=" + san + endpoint + "\n"
            write(stage + "/extensions", extensions.encode(), ROOT, ROOT)
            cert = run("x509", "-req", "-CA", ca + "/ca.crt", "-CAkey", ca + "/ca.key", "-set_serial",
                       "0x" + os.urandom(16).hex(), "-days", "365", "-sha256", "-extfile", stage + "/extensions", data=csr)
        return {name + ".crt": cert, name + ".key": key}


def _atomic(path, data, uid, gid, mode, stage_directory=None):
    if os.path.lexists(path):
        previous = read(path, uid, gid, mode, REGISTRY_LIMIT)
        if previous == data:
            return False
    fd, stage = tempfile.mkstemp(prefix=".public-", dir=stage_directory or os.path.dirname(path))
    os.close(fd)
    os.unlink(stage)
    try:
        write(stage, data, uid, gid, mode)
        os.replace(stage, path)
        _sync_parent(path)
    finally:
        if os.path.lexists(stage):
            os.unlink(stage)
    return True


def _validate_ca():
    ca = BASE + "/pki/ca"
    values = bundle(ca, ROOT, ROOT, ("ca.crt", "ca.key"))
    validate_pair(ca, "ca")
    run("verify", "-CAfile", ca + "/ca.crt", ca + "/ca.crt")
    require(_extension(ca + "/ca.crt", "basicConstraints") == "CA:TRUE, pathlen:0")
    require(_extension(ca + "/ca.crt", "keyUsage") == "Certificate Sign, CRL Sign")
    return values


def _station(endpoint, allow_server_renewal=False):
    account = pwd.getpwnam("dt-ingest")
    directory(BASE, 0o755, ROOT, ROOT)
    directory(BASE + "/pki", 0o700, ROOT, ROOT)
    directory(BASE + "/clients", 0o700, ROOT, ROOT)
    directory(BASE + "/registry", 0o750, ROOT, account.pw_gid)
    ca = BASE + "/pki/ca"
    values = _validate_ca()
    server = bundle(BASE + "/server", account.pw_uid, account.pw_gid, ("ca.crt", "server.crt", "server.key", "endpoint"))
    require(server["ca.crt"] == values["ca.crt"] and server["endpoint"] == valid_endpoint(endpoint).encode())
    try:
        address = ipaddress.ip_address(endpoint)
        expected_san = "IP Address:" + str(address)
    except ValueError:
        expected_san = "DNS:" + endpoint
    require(_extension(BASE + "/server/server.crt", "subjectAltName") == expected_san)
    if allow_server_renewal and expires_soon(BASE + "/server/server.crt"):
        require(run("x509", "-in", BASE + "/server/server.crt", "-pubkey", "-noout") == run("pkey", "-in", BASE + "/server/server.key", "-pubout"))
        try:
            ipaddress.ip_address(endpoint)
            option = "-verify_ip"
        except ValueError:
            option = "-verify_hostname"
        run("verify", "-no_check_time", "-purpose", "sslserver", "-CAfile", ca + "/ca.crt", option, endpoint, BASE + "/server/server.crt")
    else:
        validate_pair(BASE + "/server", "server", "sslserver", ca + "/ca.crt", endpoint=endpoint)
    return values["ca.crt"]


def _ca_issuance_check():
    if expires_soon(BASE + "/pki/ca/ca.crt", CA_MAINTENANCE_SECONDS):
        raise CAMaintenanceRequired("CA maintenance required")


def _registry(host, missing=False):
    account = pwd.getpwnam("dt-ingest")
    path = BASE + "/registry/" + valid_host(host) + ".json"
    directory(BASE + "/registry", 0o750, ROOT, account.pw_gid)
    if missing and not os.path.lexists(path):
        return None
    value = json.loads(read(path, ROOT, account.pw_gid, 0o640, REGISTRY_LIMIT))
    require(isinstance(value, dict))
    ordinary = {key: val for key, val in value.items() if key in FIELDS | {"applications"}}
    registration(ordinary, host)
    extra = set(value) - set(ordinary)
    require(extra in ({"certificate_sha256"}, {"certificate_sha256"} | MODERN_FIELDS,
                      {"certificate_sha256"} | PENDING_FIELDS, {"certificate_sha256"} | MODERN_FIELDS | PENDING_FIELDS))
    require(value["certificate_sha256"] is None or re.fullmatch(r"[0-9a-f]{64}", value["certificate_sha256"]))
    if "certificate_pem" in value:
        require(value["certificate_identity"] == identity(host))
        require(fingerprint(value["certificate_pem"]) == value["certificate_sha256"])
    if "pending_certificate_pem" in value:
        require(fingerprint(value["pending_certificate_pem"]) == value["pending_certificate_sha256"])
        registration(value["pending_registration"], host, ordinary["station"])
        require(type(value["pending_expires_at"]) is int)
    return value


def _registration(value):
    return {key: val for key, val in value.items() if key in FIELDS | {"applications"}}


def _save_registry(host, value):
    account = pwd.getpwnam("dt-ingest")
    data = encoded(value)
    require(len(data) <= REGISTRY_LIMIT)
    return _atomic(BASE + "/registry/" + host + ".json", data, ROOT, account.pw_gid, 0o640)


def _legacy(host):
    path = BASE + "/clients/" + host
    if not os.path.lexists(path):
        return False
    directory(path, 0o700, ROOT, ROOT)
    require(set(os.listdir(path)) in ({"client.crt", "client.key", ".dragontools-managed"}, {"client.crt", ".dragontools-managed"}))
    require(read(path + "/.dragontools-managed", ROOT, ROOT, 0o400) == MARKER)
    read(path + "/client.crt", ROOT, ROOT, 0o400)
    if os.path.lexists(path + "/client.key"):
        read(path + "/client.key", ROOT, ROOT, 0o400)
        return True
    return False


def inspect_station(host, endpoint):
    ca = _station(endpoint)
    value = _registry(host, True)
    legacy = _legacy(host)
    legacy_active = False
    legacy_expired = False
    if value:
        require(value["station"] == endpoint)
        if "certificate_pem" not in value and value["certificate_sha256"] is not None:
            legacy_active = True
            require(legacy)
            validate_pair(BASE + "/clients/" + host, "client", "sslclient", BASE + "/pki/ca/ca.crt", subject=host, allow_expired=True)
            legacy_expired = expires_soon(BASE + "/clients/" + host + "/client.crt", 0)
            require(fingerprint(read(BASE + "/clients/" + host + "/client.crt", ROOT, ROOT, 0o400)) == value["certificate_sha256"])
    else:
        require(not legacy)
    return {"host": host, "station": endpoint, "ca.crt": ca.decode(), "legacy": legacy, "legacy_active": legacy_active, "legacy_expired": legacy_expired,
            "certificate_sha256": value["certificate_sha256"] if value else None,
            "pending_certificate_sha256": value.get("pending_certificate_sha256") if value else None}


def ensure(value):
    registration(value)
    account = pwd.getpwnam("dt-ingest")
    endpoint = value["station"]
    directory(BASE, 0o755, ROOT, ROOT)
    changed = directory(BASE + "/pki", 0o700, ROOT, ROOT, True)
    changed = directory(BASE + "/clients", 0o700, ROOT, ROOT, True) or changed
    changed = directory(BASE + "/registry", 0o750, ROOT, account.pw_gid, True) or changed
    previous = _registry(value["host"], True)
    if previous:
        require(previous["station"] == endpoint and bool(previous.get("applications")) == bool(value.get("applications")))
    ca = BASE + "/pki/ca"
    if not os.path.lexists(ca):
        # Missing issuance material on an initialized station is maintenance,
        # never permission to silently replace its trust root.
        if os.path.lexists(BASE + "/server") or os.listdir(BASE + "/clients") or os.listdir(BASE + "/registry"):
            raise CAMaintenanceRequired("CA maintenance required")
        create_bundle(ca, ROOT, ROOT, generate(None, "ca", "DragonTools agent CA"))
        changed = True
    bundle(ca, ROOT, ROOT, ("ca.crt", "ca.key"))
    _ca_issuance_check()
    _validate_ca()
    if not os.path.lexists(BASE + "/server"):
        values = generate(ca, "server", endpoint, endpoint)
        values["ca.crt"] = read(ca + "/ca.crt", ROOT, ROOT, 0o400)
        values["endpoint"] = endpoint.encode()
        mark("ingestion")
        create_bundle(BASE + "/server", account.pw_uid, account.pw_gid, values)
        changed = True
    _station(endpoint, True)
    if expires_soon(BASE + "/server/server.crt"):
        existing = read(BASE + "/server/server.key", account.pw_uid, account.pw_gid, 0o400)
        renewed = generate(ca, "server", endpoint, endpoint, existing)
        mark("ingestion")
        # Keep interrupted public staging outside the exact server bundle;
        # an orphan must not make the next bundle inspection unrecoverable.
        changed = _atomic(BASE + "/server/server.crt", renewed["server.crt"], account.pw_uid, account.pw_gid, 0o400, BASE) or changed
    _station(endpoint)
    return "changed" if changed else "unchanged"


def stage(value, csr):
    registration(value)
    host, endpoint = value["host"], value["station"]
    ca = _station(endpoint)
    _ca_issuance_check()
    public = validate_csr(csr, host)
    current = _registry(host, True)
    if current:
        require(current["station"] == endpoint and bool(current.get("applications")) == bool(value.get("applications")))
    else:
        require(not _legacy(host))
        current = dict(value, certificate_sha256=None)
    cert = None
    # A retried CSR has a fresh ECDSA signature. Match its verified public key,
    # not its DER bytes; interrupted enrollment must not issue another cert.
    if "pending_certificate_pem" in current:
        with tempfile.TemporaryDirectory(prefix=".inspect-", dir=BASE + "/pki") as temporary:
            path = temporary + "/client.crt"
            write(path, current["pending_certificate_pem"].encode(), ROOT, ROOT)
            validate_client_certificate(path, host, BASE + "/pki/ca/ca.crt", allow_expired=True)
            # Renew near-expiry interrupted generations with the same CSR key;
            # the host preserves their public history until finalization.
            if run("x509", "-in", path, "-pubkey", "-noout") == public and not expires_soon(path):
                cert = current["pending_certificate_pem"].encode()
    if cert is None and "certificate_pem" in current:
        active = current["certificate_pem"].encode()
        validate_client_certificate(None, host, BASE + "/pki/ca/ca.crt", allow_expired=True, data=active)
        if run("x509", "-pubkey", "-noout", data=active) == public:
            validity = subprocess.run(["openssl", "x509", "-checkend", str(RENEW_SECONDS), "-noout"], input=active,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
            require(validity.returncode in (0, 1))
            if validity.returncode == 0:
                cert = active
    if cert is None:
        cert = sign(csr, host, BASE + "/pki/ca")
    result = {"host": host, "station": endpoint, "ca.crt": ca.decode(), "client.crt": cert.decode(), "certificate_sha256": fingerprint(cert)}
    if current.get("certificate_pem") == cert.decode() and _registration(current) == value and not PENDING_FIELDS.intersection(current):
        return result
    desired = dict(current, pending_certificate_pem=cert.decode(), pending_certificate_sha256=fingerprint(cert),
                   pending_registration=value)
    if current.get("pending_expires_at", 0) < int(time.time()) + 3600:
        desired["pending_expires_at"] = int(time.time()) + PENDING_SECONDS
    _save_registry(host, desired)
    return result


def stage_registration(value):
    """Stage changed authorization for an unchanged, already verified identity."""
    registration(value)
    current = _registry(value["host"])
    require("certificate_pem" in current and current["station"] == value["station"])
    _station(value["station"])
    validate_client_certificate(None, value["host"], BASE + "/pki/ca/ca.crt", data=current["certificate_pem"].encode())
    require(bool(current.get("applications")) == bool(value.get("applications")))
    if _registration(current) == value and not PENDING_FIELDS.intersection(current):
        return "unchanged"
    desired = dict(current, pending_certificate_pem=current["certificate_pem"],
                   pending_certificate_sha256=current["certificate_sha256"], pending_registration=value)
    if current.get("pending_expires_at", 0) < int(time.time()) + 3600:
        desired["pending_expires_at"] = int(time.time()) + PENDING_SECONDS
    return "changed" if _save_registry(value["host"], desired) else "unchanged"


def finalize(host, expected):
    require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected))
    current = _registry(host)
    changed = False
    if PENDING_FIELDS.issubset(current):
        require(current["pending_certificate_sha256"] == expected and current["pending_expires_at"] > int(time.time()))
        value = current["pending_registration"]
        _station(value["station"])
        validate_client_certificate(None, host, BASE + "/pki/ca/ca.crt", data=current["pending_certificate_pem"].encode())
        desired = dict(value, certificate_sha256=expected, certificate_identity=identity(host),
                       certificate_pem=current["pending_certificate_pem"])
        changed = _save_registry(host, desired)
    else:
        require(current["certificate_sha256"] == expected and "certificate_identity" in current)
        _station(current["station"])
        validate_client_certificate(None, host, BASE + "/pki/ca/ca.crt", data=current["certificate_pem"].encode())
    # The controller calls this only after candidate mTLS and current telemetry
    # verification. Registry publication precedes unlink, so interruption here is
    # recoverable and can never remove the old identity before activation.
    if _legacy(host):
        key = BASE + "/clients/" + host + "/client.key"
        os.unlink(key)
        _sync_parent(key)
        changed = True
    return "changed" if changed else "unchanged"


def read_registration(host):
    value = _registry(host)
    require(value["certificate_sha256"] is not None)
    return _registration(value), value["certificate_sha256"]


def verify_station(value):
    state = inspect_station(value["host"], value["station"])
    current = _registry(value["host"])
    require(_registration(current) == value and current["certificate_sha256"] is not None)
    require(not PENDING_FIELDS.intersection(current) and not state["legacy"])
    require("certificate_pem" in current)
    # OpenSSL consumes public PEM through stdin. Read-only verify stages no files.
    cert = current["certificate_pem"].encode()
    validate_client_certificate(None, value["host"], BASE + "/pki/ca/ca.crt", data=cert)
    require(fingerprint(cert) == current["certificate_sha256"])


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


def main():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o077)
        mode, *args = sys.argv[1:]
        if mode in ("ensure", "verify", "stage", "stage-registration"):
            require(len(args) == (4 if mode == "stage" else 3))
            value = registration(json.loads(args[2]), valid_host(args[0]), valid_endpoint(args[1]))
            if mode == "ensure":
                sys.stdout.write(ensure(value))
            elif mode == "stage":
                sys.stdout.buffer.write(encoded(stage(value, args[3])))
            elif mode == "stage-registration":
                sys.stdout.write(stage_registration(value))
            else:
                verify_station(value)
                sys.stdout.write("unchanged")
        elif mode == "inspect":
            require(len(args) == 2)
            sys.stdout.buffer.write(encoded(inspect_station(valid_host(args[0]), valid_endpoint(args[1]))))
        elif mode == "finalize":
            require(len(args) == 2)
            sys.stdout.write(finalize(valid_host(args[0]), args[1]))
        elif mode == "registration":
            require(len(args) == 1)
            sys.stdout.buffer.write(encoded(read_registration(valid_host(args[0]))[0]))
        else:
            return 86
        return 0
    except CAMaintenanceRequired:
        return 87
    except Exception:
        return 86
