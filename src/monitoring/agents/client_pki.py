"""Host-local client identity lifecycle; only public CSRs/certificates cross SSH.

Embedded after pki.py. Private keys remain in root-private local generations and
service-owned copies. A pending generation and exact local backups survive every
publication boundary; the controller commits only after station signal proof.
"""
CLIENT_MARKER = b"DragonTools host-local client identity v1\n"
CLIENT_FILES = ("ca.crt", "client.crt", "client.key", "identity.json")
CLIENT_CSR_LIMIT = 8192
CLIENT_REISSUE_FILE = ".reissues.json"
CLIENT_RENEW_SECONDS = 30 * 24 * 60 * 60


class ClientIdentityInconsistent(ValueError):
    pass


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def client_path():
    return ETC + "/monitoring-client"


def client_host(host):
    require(isinstance(host, str) and re.fullmatch(r"dt-[0-9a-f]{32}", host))
    return host


def client_fingerprint(cert):
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.decode())).hexdigest()


def client_identity(host, endpoint, cert, previous_consumers=None):
    return encoded({"version": 1, "host": host, "station": endpoint,
                    "certificate_identity": "dragontools://hosts/" + host,
                    "certificate_sha256": client_fingerprint(cert), "key_source": "host-generated",
                    "previous_consumers": previous_consumers or {}})


def client_read_files(path, names):
    return {name: read(path + "/" + name, ROOT, ROOT, 0o400) for name in names if os.path.lexists(path + "/" + name)}


def client_private_directory(path, names):
    directory(path, 0o700, ROOT, ROOT)
    require(set(os.listdir(path)) <= set(names) | {".dragontools-managed"})
    require(read(path + "/.dragontools-managed", ROOT, ROOT, 0o400) == CLIENT_MARKER)


def client_create_directory(path, values):
    stage = tempfile.mkdtemp(prefix=".client-", dir=ETC)
    try:
        write(stage + "/.dragontools-managed", CLIENT_MARKER, ROOT, ROOT)
        for name, value in values.items():
            write(stage + "/" + name, value, ROOT, ROOT)
        os.chown(stage, ROOT, ROOT)
        os.chmod(stage, 0o700)
        sync_directory(stage)
        os.rename(stage, path)
        sync_directory(os.path.dirname(path))
        stage = None
    finally:
        if stage is not None:
            shutil.rmtree(stage)


def client_replace(path, value, uid=0, gid=0):
    # Callers first prove destination content and metadata. Publication never
    # follows destination links, and leaves no partially written credential.
    fd, stage = tempfile.mkstemp(prefix=".credential-", dir=ETC)
    os.close(fd)
    os.unlink(stage)
    try:
        write(stage, value, uid, gid)
        os.replace(stage, path)
        sync_directory(os.path.dirname(path))
    finally:
        if os.path.lexists(stage):
            os.unlink(stage)


def client_check_pair(path, host, modern=True, allow_expired=False):
    require(run("x509", "-in", path + "/client.crt", "-pubkey", "-noout") ==
            run("pkey", "-in", path + "/client.key", "-pubout"))
    if modern:
        validate_client_certificate(path + "/client.crt", host, path + "/ca.crt", allow_expired=allow_expired)
    else:
        if allow_expired:
            run("verify", "-no_check_time", "-purpose", "sslclient", "-CAfile", path + "/ca.crt", path + "/client.crt")
            require(run("x509", "-in", path + "/client.crt", "-subject", "-noout", "-nameopt", "RFC2253").strip() == ("subject=CN=" + host).encode())
        else:
            validate_pair(path, "client", "sslclient", path + "/ca.crt", subject=host)


def client_check_public_identity(path, values, host, endpoint, allow_expired=False):
    require(set(values) in (set(CLIENT_FILES), set(CLIENT_FILES) - {"client.key"}))
    metadata = json.loads(values["identity.json"])
    history = metadata.get("previous_consumers")
    require(isinstance(history, dict) and set(history) <= {"vector", "vmagent"})
    require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in history.values()))
    require(values["identity.json"] == client_identity(host, endpoint, values["client.crt"], history))
    validate_client_certificate(path + "/client.crt", host, path + "/ca.crt", allow_expired=allow_expired)


def client_check_identity(path, values, host, endpoint, allow_expired=False):
    require(set(values) == set(CLIENT_FILES))
    client_check_public_identity(path, values, host, endpoint, allow_expired)
    require(run("x509", "-in", path + "/client.crt", "-pubkey", "-noout") == run("pkey", "-in", path + "/client.key", "-pubout"))


def client_inspect_root(host, endpoint, allow_missing_key=False):
    path = client_path()
    if not os.path.lexists(path):
        return None
    client_private_directory(path, CLIENT_FILES + (".pending", ".completed"))
    values = client_read_files(path, CLIENT_FILES)
    if os.path.lexists(path + "/.pending"):
        # A crash during final commit may leave a mixture of complete previous
        # and candidate files. Every byte must belong to one of those generations.
        pending, previous, txn = client_pending(host, endpoint)
        candidate = {name: pending[name] for name in CLIENT_FILES if name in pending}
        generations = client_generations(pending, txn)
        for name, data in values.items():
            require(data == previous.get(name) or data == candidate.get(name) or any(data == generation.get(name) for generation in generations))
        if values == previous:
            return previous or None
        require(set(candidate) == set(CLIENT_FILES))
        return candidate
    if values:
        if allow_missing_key:
            client_check_public_identity(path, values, host, endpoint, allow_expired=True)
        else:
            client_check_identity(path, values, host, endpoint, allow_expired=True)
        return values
    return None


def client_pending(host, endpoint):
    path = client_path() + "/.pending"
    names = CLIENT_FILES + ("request.csr", "transaction.json", "previous", "backups", CLIENT_REISSUE_FILE)
    client_private_directory(path, names)
    values = client_read_files(path, CLIENT_FILES + ("request.csr", "transaction.json", CLIENT_REISSUE_FILE))
    require({"client.key", "request.csr", "transaction.json"} <= set(values))
    txn = json.loads(values["transaction.json"])
    require(set(txn) == {"version", "host", "station", "action", "certificate_sha256", "previous_consumers", "ca_sha256"} and txn["version"] == 1)
    require(txn["host"] == host and txn["station"] == endpoint and txn["action"] in ("enroll", "renew", "migrate", "reenroll"))
    require(txn["certificate_sha256"] is None or re.fullmatch(r"[0-9a-f]{64}", txn["certificate_sha256"]))
    require(isinstance(txn["ca_sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", txn["ca_sha256"]))
    require(isinstance(txn["previous_consumers"], dict) and set(txn["previous_consumers"]) <= {"vector", "vmagent"})
    require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in txn["previous_consumers"].values()))
    require(len(values["request.csr"]) <= CLIENT_CSR_LIMIT)
    run("req", "-verify", "-noout", data=values["request.csr"])
    require(run("req", "-pubkey", "-noout", data=values["request.csr"]) == run("pkey", "-in", path + "/client.key", "-pubout"))
    require(run("req", "-subject", "-noout", "-nameopt", "RFC2253", data=values["request.csr"]).strip() == ("subject=CN=" + host).encode())
    client_private_directory(path + "/previous", CLIENT_FILES)
    previous = client_read_files(path + "/previous", CLIENT_FILES)
    if previous:
        if txn["action"] == "reenroll":
            require("client.key" not in previous)
            client_check_public_identity(path + "/previous", previous, host, endpoint, allow_expired=True)
        else:
            require(txn["action"] == "renew")
            client_check_identity(path + "/previous", previous, host, endpoint, allow_expired=True)
            require(previous["client.key"] == values["client.key"])
        require(client_fingerprint(previous["client.crt"]) == txn["certificate_sha256"])
    else:
        require(txn["action"] in ("enroll", "migrate"))
    directory(path + "/backups", 0o700, ROOT, ROOT)
    require(set(os.listdir(path + "/backups")) <= {"vector", "vmagent"})
    if CLIENT_REISSUE_FILE in values:
        require(all(name in values for name in CLIENT_FILES))
        journal = json.loads(values[CLIENT_REISSUE_FILE])
        require(set(journal) == {"version", "certificates"} and journal["version"] == 1)
        certs = journal["certificates"]
        require(isinstance(certs, list) and 2 <= len(certs) <= 16 and len(set(certs)) == len(certs))
        for cert in certs:
            require(isinstance(cert, str) and len(cert) <= 16384)
            validate_client_certificate(None, host, path + "/ca.crt", allow_expired=True, data=cert.encode())
            require(run("x509", "-pubkey", "-noout", data=cert.encode()) == run("pkey", "-in", path + "/client.key", "-pubout"))
        require(values["client.crt"].decode() in certs)
        require(values["identity.json"] in [client_identity(host, endpoint, cert.encode(), txn["previous_consumers"]) for cert in certs])
        values["client.crt"] = certs[-1].encode()
        values["identity.json"] = client_identity(host, endpoint, values["client.crt"], txn["previous_consumers"])
    if "identity.json" in values:
        candidate = {name: values[name] for name in CLIENT_FILES if name in values}
        client_check_identity(path, candidate, host, endpoint, allow_expired=True)
    return values, previous, txn


def client_consumer_state(kind, host, endpoint, modern=False, allow_expired=False):
    require(kind in ("vector", "vmagent"))
    account = pwd.getpwnam("dt-" + kind)
    values = agent_state(kind, account)
    if values is not None:
        require(set(values) == set(SECRET_FILES) | {".agent-identity"})
        require(values[".agent-identity"] == encoded({"host": host, "station": endpoint}))
        client_check_pair(ETC + "/" + kind, host, modern=modern, allow_expired=allow_expired)
    return values


def client_check_public_consumer(kind, host):
    path = ETC + "/" + kind
    run("verify", "-no_check_time", "-purpose", "sslclient", "-CAfile", path + "/ca.crt", path + "/client.crt")
    require(run("x509", "-in", path + "/client.crt", "-subject", "-noout", "-nameopt", "RFC2253").strip() == ("subject=CN=" + host).encode())
    if os.path.lexists(path + "/client.key"):
        require(run("x509", "-in", path + "/client.crt", "-pubkey", "-noout") == run("pkey", "-in", path + "/client.key", "-pubout"))


def client_recover_key(host, endpoint, inspection):
    path = client_path()
    if (not os.path.lexists(path) or os.path.lexists(path + "/.pending") or
            os.path.lexists(path + "/client.key") or not os.path.lexists(path + "/client.crt")):
        return False
    client_private_directory(path, CLIENT_FILES + (".completed",))
    values = client_read_files(path, CLIENT_FILES)
    require(set(values) == {"ca.crt", "client.crt", "identity.json"})
    require(values["ca.crt"] == inspection["ca.crt"].encode())
    require(client_fingerprint(values["client.crt"]) == inspection["certificate_sha256"])
    client_check_public_identity(path, values, host, endpoint, allow_expired=True)
    history = json.loads(values["identity.json"])["previous_consumers"]
    canonical_public = run("x509", "-in", path + "/client.crt", "-pubkey", "-noout")
    for kind in ("vector", "vmagent"):
        if not os.path.lexists(ETC + "/" + kind + "/.dragontools-credentials"):
            continue
        consumer = agent_state(kind, pwd.getpwnam("dt-" + kind))
        if not consumer or not all(name in consumer for name in SECRET_FILES):
            continue
        if consumer["ca.crt"] != values["ca.crt"] or client_fingerprint(consumer["client.crt"]) not in (inspection["certificate_sha256"], history.get(kind)):
            continue
        require(consumer.get(".agent-identity") == encoded({"host": host, "station": endpoint}))
        client_check_public_consumer(kind, host)
        if run("pkey", "-in", ETC + "/" + kind + "/client.key", "-pubout") != canonical_public:
            continue
        restored = dict(values, **{"client.key": consumer["client.key"]})
        # Prove the canonical public metadata before recovering only its exact
        # matching local key. No fresh key, CSR, certificate or restart is needed.
        with tempfile.TemporaryDirectory(prefix=".recover-client-", dir=ETC) as stage:
            for name, value in restored.items():
                write(stage + "/" + name, value, ROOT, ROOT)
            client_check_identity(stage, restored, host, endpoint, allow_expired=True)
        client_replace(path + "/client.key", consumer["client.key"], ROOT, ROOT)
        return True
    # All local copies are unavailable. The station still binds this exact
    # public identity; preserve it as the previous generation and reenroll with
    # a fresh local key. No healthy result is possible before candidate proof.
    client_check_public_identity(path, values, host, endpoint, allow_expired=True)
    return None


def client_prepare(host, endpoint, inspection):
    client_host(host)
    valid_endpoint(endpoint)
    require(set(inspection) == {"host", "station", "ca.crt", "legacy", "legacy_active", "legacy_expired", "certificate_sha256", "pending_certificate_sha256"})
    require(inspection["host"] == host and inspection["station"] == endpoint and type(inspection["legacy"]) is bool and type(inspection["legacy_expired"]) is bool and type(inspection["legacy_active"]) is bool)
    require(not inspection["legacy_expired"] or inspection["legacy_active"])
    require(not inspection["legacy_active"] or inspection["legacy"])
    require(isinstance(inspection["ca.crt"], str) and len(inspection["ca.crt"]) <= 16384)
    fingerprint = inspection["certificate_sha256"]
    require(fingerprint is None or isinstance(fingerprint, str) and re.fullmatch(r"[0-9a-f]{64}", fingerprint))
    pending_fingerprint = inspection["pending_certificate_sha256"]
    require(pending_fingerprint is None or isinstance(pending_fingerprint, str) and re.fullmatch(r"[0-9a-f]{64}", pending_fingerprint))
    directory(ETC, 0o755, ROOT, ROOT)
    recovered = client_recover_key(host, endpoint, inspection)
    current = client_inspect_root(host, endpoint, allow_missing_key=recovered is None)
    if os.path.lexists(client_path() + "/.completed"):
        require(current is not None and client_fingerprint(current["client.crt"]) == fingerprint)
    pending_path = client_path() + "/.pending"
    if os.path.lexists(pending_path):
        pending, previous, txn = client_pending(host, endpoint)
        allowed = {txn["certificate_sha256"]}
        if "identity.json" in pending:
            allowed.add(client_fingerprint(pending["client.crt"]))
            allowed.update(client_fingerprint(generation["client.crt"]) for generation in client_generations(pending, txn))
        require(fingerprint in allowed)
        require(hashlib.sha256(inspection["ca.crt"].encode()).hexdigest() == txn["ca_sha256"])
        if previous:
            require(previous["ca.crt"] == inspection["ca.crt"].encode())
        if "ca.crt" in pending:
            require(pending["ca.crt"] == inspection["ca.crt"].encode())
        return {"action": txn["action"], "csr": pending["request.csr"].decode(), "certificate_sha256": txn["certificate_sha256"]}
    if current:
        require(current["ca.crt"] == inspection["ca.crt"].encode())
        require(client_fingerprint(current["client.crt"]) == fingerprint)
        result = subprocess.run(["openssl", "x509", "-in", client_path() + "/client.crt", "-checkend", str(CLIENT_RENEW_SECONDS), "-noout"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
        require(result.returncode in (0, 1))
        if result.returncode == 0 and recovered is not None:
            result = {"action": "unchanged", "csr": None, "certificate_sha256": fingerprint}
            if recovered:
                result["recovered_key"] = True
            return result
        if recovered is None:
            action = "reenroll"
            key = run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
        else:
            action, key = "renew", current["client.key"]
    else:
        require(fingerprint is None or inspection["legacy"])
        if inspection["legacy"]:
            legacy = client_consumer_state("vector", host, endpoint, allow_expired=inspection["legacy_expired"])
            require(legacy is not None and legacy["ca.crt"] == inspection["ca.crt"].encode())
            require(client_fingerprint(legacy["client.crt"]) == fingerprint)
            if os.path.lexists(ETC + "/vmagent/.dragontools-credentials"):
                require(client_consumer_state("vmagent", host, endpoint, allow_expired=inspection["legacy_expired"]) == legacy)
            action = "migrate"
        else:
            for kind in ("vector", "vmagent"):
                if os.path.lexists(ETC + "/" + kind):
                    require(agent_state(kind, pwd.getpwnam("dt-" + kind)) is None)
            action = "enroll"
        key = run("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
    previous_consumers = {}
    for kind in ("vector", "vmagent"):
        if os.path.lexists(ETC + "/" + kind + "/.dragontools-credentials"):
            if action == "reenroll":
                prior = agent_state(kind, pwd.getpwnam("dt-" + kind))
                require(set(prior) in ({"ca.crt", "client.crt", ".agent-identity"}, set(SECRET_FILES) | {".agent-identity"}))
                require(prior["ca.crt"] == current["ca.crt"])
                require(client_fingerprint(prior["client.crt"]) in (fingerprint, json.loads(current["identity.json"])["previous_consumers"].get(kind)))
                require(prior[".agent-identity"] == encoded({"host": host, "station": endpoint}))
                client_check_public_consumer(kind, host)
            else:
                prior = client_consumer_state(kind, host, endpoint, allow_expired=action == "renew" or inspection["legacy_expired"])
            require(prior["ca.crt"] == inspection["ca.crt"].encode())
            prior_fp = client_fingerprint(prior["client.crt"])
            if current:
                require(prior_fp in (fingerprint, json.loads(current["identity.json"])["previous_consumers"].get(kind)))
            else:
                require(prior_fp == fingerprint)
            previous_consumers[kind] = prior_fp
    # The identity directory and candidate generation become visible only when
    # complete. A failed signing operation never touches running consumer files.
    if not os.path.lexists(client_path()):
        client_create_directory(client_path(), {})
    stage = tempfile.mkdtemp(prefix=".enrollment-", dir=ETC)
    try:
        os.chown(stage, ROOT, ROOT)
        write(stage + "/.dragontools-managed", CLIENT_MARKER, ROOT, ROOT)
        write(stage + "/client.key", key, ROOT, ROOT)
        csr = run("req", "-new", "-key", stage + "/client.key", "-sha256", "-subj", "/CN=" + host,
                  "-addext", "subjectAltName=URI:dragontools://hosts/" + host)
        require(len(csr) <= CLIENT_CSR_LIMIT)
        write(stage + "/request.csr", csr, ROOT, ROOT)
        write(stage + "/transaction.json", encoded({"version": 1, "host": host, "station": endpoint, "action": action, "certificate_sha256": fingerprint, "previous_consumers": previous_consumers, "ca_sha256": hashlib.sha256(inspection["ca.crt"].encode()).hexdigest()}), ROOT, ROOT)
        client_create_directory(stage + "/previous", current or {})
        directory(stage + "/backups", 0o700, ROOT, ROOT, True)
        sync_directory(stage)
        os.rename(stage, pending_path)
        sync_directory(client_path())
        stage = None
    finally:
        if stage is not None:
            shutil.rmtree(stage)
    result = {"action": action, "csr": csr.decode(), "certificate_sha256": fingerprint}
    if recovered:
        result["recovered_key"] = True
    return result


def client_stage(payload):
    require(set(payload) == {"host", "station", "ca.crt", "client.crt", "certificate_sha256"})
    host, endpoint = client_host(payload["host"]), valid_endpoint(payload["station"])
    require(all(isinstance(payload[name], str) and len(payload[name]) <= 16384 for name in ("ca.crt", "client.crt")))
    pending, previous, txn = client_pending(host, endpoint)
    path = client_path() + "/.pending"
    desired = {"ca.crt": payload["ca.crt"].encode(), "client.crt": payload["client.crt"].encode(), "client.key": pending["client.key"]}
    require(payload["certificate_sha256"] == client_fingerprint(desired["client.crt"]))
    desired["identity.json"] = client_identity(host, endpoint, desired["client.crt"], txn["previous_consumers"])
    require(hashlib.sha256(desired["ca.crt"]).hexdigest() == txn["ca_sha256"])
    if previous:
        require(desired["ca.crt"] == previous["ca.crt"])
    # Validate the complete public response against the local key before staging
    # any certificate. A station can never supply or replace a private key.
    with tempfile.TemporaryDirectory(prefix=".validate-client-", dir=ETC) as stage:
        for name, value in desired.items():
            write(stage + "/" + name, value, ROOT, ROOT)
        client_check_identity(stage, desired, host, endpoint)
    changed = False
    if "identity.json" in pending and pending["client.crt"] != desired["client.crt"]:
        # Preserve public recognition of every abandoned candidate before a
        # replacement can reach disk or a consumer. Their single local key and
        # original rollback generation do not change. The 16-certificate bound
        # exceeds annual reissues within the non-rotating ten-year CA lifetime.
        certs = json.loads(pending[CLIENT_REISSUE_FILE])["certificates"] if CLIENT_REISSUE_FILE in pending else [pending["client.crt"].decode()]
        require(desired["client.crt"].decode() not in certs and len(certs) < 16)
        certs.append(desired["client.crt"].decode())
        client_replace(path + "/" + CLIENT_REISSUE_FILE, encoded({"version": 1, "certificates": certs}), ROOT, ROOT)
        changed = True
    physical = client_read_files(path, CLIENT_FILES)
    for name in ("ca.crt", "client.crt", "identity.json"):
        if physical.get(name) != desired[name]:
            if name == "ca.crt" and name in physical:
                require(physical[name] == desired[name])
            client_replace(path + "/" + name, desired[name], ROOT, ROOT)
            changed = True
    return "changed" if changed else "unchanged"


def client_desired(host, endpoint):
    current = client_inspect_root(host, endpoint)
    if os.path.lexists(client_path() + "/.pending"):
        pending, _, _ = client_pending(host, endpoint)
        require(all(name in pending for name in CLIENT_FILES))
        current = {name: pending[name] for name in CLIENT_FILES}
    require(current is not None)
    return {name: current[name] for name in SECRET_FILES} | {".agent-identity": encoded({"host": host, "station": endpoint})}


def client_systemctl(verb, kind):
    result = subprocess.run(["systemctl", verb, "dragontools-" + kind + ".service"], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=30, check=verb != "is-active")
    if verb == "is-active":
        if result.stdout.strip() in (b"active", b"activating", b"reloading", b"deactivating"):
            require(result.returncode == 0)
            return True
        require(result.returncode in (3, 4) and result.stdout.strip() in (b"inactive", b"failed", b"unknown"))
        return False


def client_backup(kind, current, active):
    path = client_path() + "/.pending/backups/" + kind
    if not os.path.lexists(path):
        values = dict(current or {})
        values["state.json"] = encoded({"present": current is not None, "active": active, "missing_key": current is not None and "client.key" not in current})
        client_create_directory(path, values)
    client_private_directory(path, SECRET_FILES + (".agent-identity", "state.json"))
    values = client_read_files(path, SECRET_FILES + (".agent-identity", "state.json"))
    state = json.loads(values.pop("state.json"))
    require(set(state) == {"present", "active", "missing_key"} and all(type(x) is bool for x in state.values()))
    require(not state["missing_key"] or state["present"])
    expected = set(SECRET_FILES) | {".agent-identity"} if state["present"] else set()
    if state["missing_key"]:
        expected.remove("client.key")
    require(set(values) == expected)
    txn = json.loads(read(client_path() + "/.pending/transaction.json", ROOT, ROOT, 0o400))
    if values:
        require(values[".agent-identity"] == encoded({"host": txn["host"], "station": txn["station"]}))
        require(client_fingerprint(values["client.crt"]) == txn["previous_consumers"].get(kind))
        require(hashlib.sha256(values["ca.crt"]).hexdigest() == txn["ca_sha256"])
        if state["missing_key"]:
            require(txn["action"] == "reenroll")
            run("verify", "-no_check_time", "-purpose", "sslclient", "-CAfile", path + "/ca.crt", path + "/client.crt")
        else:
            client_check_pair(path, txn["host"], modern=False, allow_expired=True)
    else:
        require(kind not in txn["previous_consumers"])
    return values or None, state["active"]


def client_generations(pending, txn):
    if CLIENT_REISSUE_FILE not in pending:
        return []
    return [{"ca.crt": pending["ca.crt"], "client.key": pending["client.key"], "client.crt": cert.encode(),
             "identity.json": client_identity(txn["host"], txn["station"], cert.encode(), txn["previous_consumers"]),
             ".agent-identity": encoded({"host": txn["host"], "station": txn["station"]})}
            for cert in json.loads(pending[CLIENT_REISSUE_FILE])["certificates"]]


def client_allowed_state(current, old, desired, host, endpoint):
    require(current is not None or old is None)
    pending, _, txn = client_pending(host, endpoint)
    generations = client_generations(pending, txn)
    for name, value in (current or {}).items():
        require(value == (old or {}).get(name) or value == desired.get(name) or any(value == generation.get(name) for generation in generations))


def client_publish_consumer(kind, desired, current):
    account = pwd.getpwnam("dt-" + kind)
    path = ETC + "/" + kind
    mark(kind)
    if client_systemctl("is-active", kind):
        client_systemctl("stop", kind)
    if current is None:
        client_replace(path + "/.dragontools-credentials", MARKER, ROOT, ROOT)
    for name, data in desired.items():
        if (current or {}).get(name) != data:
            client_replace(path + "/" + name, data, ROOT if name == ".agent-identity" else account.pw_uid,
                           ROOT if name == ".agent-identity" else account.pw_gid)


def client_install(kind, host, endpoint):
    require(kind in ("vector", "vmagent"))
    client_host(host)
    valid_endpoint(endpoint)
    desired = client_desired(host, endpoint)
    account = pwd.getpwnam("dt-" + kind)
    current = agent_state(kind, account)
    if current == desired:
        verify_credentials(kind, host, endpoint)
        return "unchanged"
    if os.path.lexists(client_path() + "/.pending"):
        backup_path = client_path() + "/.pending/backups/" + kind
        if not os.path.lexists(backup_path):
            if current:
                # First publication must preserve a complete valid old pair.
                _, previous, txn = client_pending(host, endpoint)
                if txn["action"] == "reenroll":
                    prior = current
                    require(set(prior) in ({"ca.crt", "client.crt", ".agent-identity"}, set(SECRET_FILES) | {".agent-identity"}))
                    require(prior["ca.crt"] == previous["ca.crt"])
                    require(prior[".agent-identity"] == encoded({"host": host, "station": endpoint}))
                    client_check_public_consumer(kind, host)
                else:
                    prior = client_consumer_state(kind, host, endpoint, allow_expired=True)
                require(client_fingerprint(prior["client.crt"]) == txn["previous_consumers"].get(kind))
            old, _ = client_backup(kind, current, client_systemctl("is-active", kind))
        else:
            old, _ = client_backup(kind, None, False)
        client_allowed_state(current, old, desired, host, endpoint)
    else:
        # Copying the canonical identity into a newly enabled consumer is safe;
        # an edited existing pair is never silently adopted.
        if current is not None:
            missing_key = set(current) == {"ca.crt", "client.crt", ".agent-identity"} and all(data == desired[name] for name, data in current.items())
            if not missing_key:
                canonical = client_inspect_root(host, endpoint)
                previous = json.loads(canonical["identity.json"])["previous_consumers"].get(kind)
                require(previous is not None and client_fingerprint(current["client.crt"]) == previous)
                require(current["ca.crt"] == canonical["ca.crt"])
                client_consumer_state(kind, host, endpoint, allow_expired=True)
    client_publish_consumer(kind, desired, current)
    verify_credentials(kind, host, endpoint)
    return "changed"


def client_rollback(host, endpoint):
    client_host(host)
    valid_endpoint(endpoint)
    if not os.path.lexists(client_path() + "/.pending"):
        return "unchanged"
    pending, _, _ = client_pending(host, endpoint)
    if "identity.json" not in pending:
        return "unchanged"
    desired = client_desired(host, endpoint)
    changed = False
    for kind in ("vector", "vmagent"):
        backup_path = client_path() + "/.pending/backups/" + kind
        if not os.path.lexists(backup_path):
            continue
        old, active = client_backup(kind, None, False)
        current = agent_state(kind, pwd.getpwnam("dt-" + kind))
        client_allowed_state(current, old, desired, host, endpoint)
        if current != old:
            if old:
                client_publish_consumer(kind, old, current)
                client_consumer_state(kind, host, endpoint, allow_expired=True)
            else:
                mark(kind)
                if client_systemctl("is-active", kind):
                    client_systemctl("stop", kind)
                for name in (current or {}):
                    os.unlink(ETC + "/" + kind + "/" + name)
                if current is not None:
                    os.unlink(ETC + "/" + kind + "/.dragontools-credentials")
            changed = True
        if old and active and not client_systemctl("is-active", kind):
            client_systemctl("start", kind)
            changed = True
    return "changed" if changed else "unchanged"


def client_commit(host, endpoint):
    client_host(host)
    valid_endpoint(endpoint)
    if not os.path.lexists(client_path() + "/.pending"):
        require(client_inspect_root(host, endpoint) is not None)
        if os.path.lexists(client_path() + "/.completed"):
            client_clean_completed()
            return "changed"
        return "unchanged"
    client_inspect_root(host, endpoint)
    pending, _, _ = client_pending(host, endpoint)
    require(all(name in pending for name in CLIENT_FILES))
    desired = client_desired(host, endpoint)
    for kind in os.listdir(client_path() + "/.pending/backups"):
        client_backup(kind, None, False)
        require(agent_state(kind, pwd.getpwnam("dt-" + kind)) == desired)
        verify_credentials(kind, host, endpoint)
    # .pending remains complete through each atomic replace and is the recovery
    # generation if interrupted. identity.json is published last.
    for name in CLIENT_FILES:
        destination = client_path() + "/" + name
        if not os.path.lexists(destination) or read(destination, ROOT, ROOT, 0o400) != pending[name]:
            client_replace(destination, pending[name], ROOT, ROOT)
    client_check_identity(client_path(), client_read_files(client_path(), CLIENT_FILES), host, endpoint)
    os.rename(client_path() + "/.pending", client_path() + "/.completed")
    sync_directory(client_path())
    client_clean_completed()
    return "changed"


def client_clean_completed():
    # A committed generation is moved away from .pending before unlinking it.
    # Interrupted cleanup never turns a complete active identity into a partial
    # pending identity. Only this exact, private, bounded tree may be removed.
    path = client_path() + "/.completed"
    directory(path, 0o700, ROOT, ROOT)
    allowed = set(CLIENT_FILES) | {".dragontools-managed", "request.csr", "transaction.json", "previous", "backups", CLIENT_REISSUE_FILE}
    require(set(os.listdir(path)) <= allowed)
    for base, dirs, files in os.walk(path, followlinks=False):
        directory(base, 0o700, ROOT, ROOT)
        relative = os.path.relpath(base, path)
        if relative == ".":
            require(set(dirs) <= {"previous", "backups"})
            valid = allowed - {"previous", "backups"}
        elif relative == "backups":
            require(set(dirs) <= {"vector", "vmagent"})
            valid = set()
        elif relative == "previous":
            require(not dirs)
            valid = set(CLIENT_FILES) | {".dragontools-managed"}
        else:
            require(relative in ("backups/vector", "backups/vmagent") and not dirs)
            valid = set(SECRET_FILES) | {".dragontools-managed", ".agent-identity", "state.json"}
        require(set(files) <= valid)
        for name in dirs:
            directory(base + "/" + name, 0o700, ROOT, ROOT)
        for name in files:
            read(base + "/" + name, ROOT, ROOT, 0o400)
    shutil.rmtree(path)
    sync_directory(client_path())


def verify_credentials(kind, host, endpoint):
    client_host(host)
    valid_endpoint(endpoint)
    state = client_consumer_state(kind, host, endpoint)
    require(state is not None)
    if os.path.lexists(client_path()):
        current = client_inspect_root(host, endpoint)
        choices = []
        if current and all(name in current for name in SECRET_FILES):
            choices.append({name: current[name] for name in SECRET_FILES})
        if os.path.lexists(client_path() + "/.pending"):
            pending, previous, txn = client_pending(host, endpoint)
            if previous and all(name in previous for name in SECRET_FILES):
                choices.append({name: previous[name] for name in SECRET_FILES})
            if "identity.json" in pending:
                choices.append({name: pending[name] for name in SECRET_FILES})
            # Legacy credentials are accepted only for a recorded migration's
            # exact old fingerprint; candidate verification always requires SAN.
            if txn["action"] == "migrate" and client_fingerprint(state["client.crt"]) == txn["certificate_sha256"]:
                return
        require({name: state[name] for name in SECRET_FILES} in choices)
        client_check_pair(ETC + "/" + kind, host)


def client_main():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o077)
        mode, *args = sys.argv[1:]
        require(all(len(arg) <= 65536 for arg in args))
        if mode == "client-prepare":
            require(len(args) == 3)
            sys.stdout.buffer.write(encoded(client_prepare(args[0], args[1], json.loads(args[2]))))
        elif mode == "client-stage":
            require(len(args) == 1)
            sys.stdout.write(client_stage(json.loads(args[0])))
        elif mode == "client-install":
            require(len(args) == 3)
            sys.stdout.write(client_install(*args))
        elif mode in ("client-commit", "client-rollback"):
            require(len(args) == 2)
            sys.stdout.write((client_commit if mode == "client-commit" else client_rollback)(*args))
        elif mode == "verify-agent":
            require(len(args) == 3)
            verify_credentials(*args)
            sys.stdout.write("unchanged")
        else:
            return 86
        return 0
    except ClientIdentityInconsistent:
        return 88
    except Exception:
        return 86
