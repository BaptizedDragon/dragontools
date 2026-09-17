"""Read-only native VictoriaMetrics scrape checks. Never request /probe or targets.

Contracts reviewed at VictoriaMetrics v1.151.0 lib/promscrape/{scraper,targetstatus,
scrapework,client,config}.go and app/vminsert/main.go. Query timestamps are evaluation
times; timestamp(metric[90s]) supplies the actual stored sample's time instead.
"""
import datetime
import base64
import hashlib
import http.client
import json
import math
import os
import re
import stat
import sys
import time
import urllib.parse

CONFIG = "/etc/dragontools/victoriametrics/prometheus.yml"
CONFIG_PARENT = "/etc/dragontools"
CONFIG_DIR = "/etc/dragontools/victoriametrics"
PENDING = "/var/lib/dragontools/victoriametrics-scrape-reload-required"
JOB = "dragontools-blackbox"
MAX_RESPONSE = 1024 * 1024
FRESH_SECONDS = 90
# v1.151.0 serializes its loaded Config with yaml.v2. Its static target block
# follows these fields; target identity and effective periods are checked via
# /api/v1/targets. Matching disk bytes alone cannot prove a policy reload applied.
LOADED_GLOBAL = "global:\n  scrape_interval: 30s\n  scrape_timeout: 5s\n"
LOADED_POLICY = LOADED_GLOBAL + """scrape_configs:
- job_name: dragontools-blackbox
  metrics_path: /probe
  params:
    module:
    - http_2xx
  relabel_configs:
  - source_labels: [__address__]
    target_label: __param_target
  - source_labels: [__param_target]
    target_label: target
  - source_labels: [probe]
    target_label: instance
  - target_label: __address__
    replacement: 127.0.0.1:9115
  metric_relabel_configs:
  - action: keep
    source_labels: [__name__]
    regex:
    - probe_success
    - probe_duration_seconds
    - probe_dns_lookup_time_seconds
    - probe_http_duration_seconds
    - probe_http_status_code
    - probe_http_ssl
    - probe_ssl_earliest_cert_expiry
    - probe_http_redirects
    - probe_ip_protocol
  - action: labelkeep
    regex:
    - __name__
    - job
    - instance
    - probe
    - target
    - phase
  static_configs:
"""


class NotReady(Exception):
    pass


def node(path, kind, missing=False):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        if missing:
            return None
        raise
    if stat.S_ISLNK(info.st_mode):
        raise ValueError("Unexpected managed symlink")
    if kind == "dir":
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("Unexpected managed path")
    elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("Unexpected managed file")
    return info


def read_config(expected, metadata=True):
    for path in (CONFIG_PARENT, CONFIG_DIR):
        info = node(path, "dir")
        if metadata and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o755):
            raise ValueError("Incorrect configuration directory metadata")
    info = node(CONFIG, "file")
    if info.st_size > 128 * 1024:
        raise ValueError("Configuration too large")
    if metadata and (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (0, 0, 0o644):
        raise ValueError("Incorrect configuration metadata")
    with open(CONFIG, "rb") as source:
        actual = source.read(128 * 1024 + 1)
    matches = hashlib.sha256(actual).hexdigest() == expected[7:] if expected.startswith("sha256:") else actual == expected.encode()
    if not matches:
        raise ValueError("Incorrect managed scrape configuration")
    return info


def pending_exists():
    info = node(PENDING, "file", missing=True)
    if info is None:
        return False
    if (info.st_uid, info.st_gid) != (0, 0) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != 0:
        raise ValueError("Incorrect scrape reload intent")
    return True


def request(path, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", 8428, timeout=5)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        if response.status in (425, 429, 500, 502, 503, 504):
            raise NotReady()
        if response.status != 200:
            raise ValueError("Unexpected monitoring response")
        body = response.read(MAX_RESPONSE + 1)
        if len(body) > MAX_RESPONSE:
            raise ValueError("Monitoring response too large")
        return body
    except (OSError, http.client.HTTPException) as error:
        raise NotReady() from error
    finally:
        connection.close()


def json_response(path):
    value = json.loads(request(path))
    if not isinstance(value, dict) or value.get("status") != "success" or not isinstance(value.get("data"), dict):
        raise ValueError("Invalid monitoring response")
    return value["data"]


def definitions(probes):
    if not isinstance(probes, list) or len(probes) > 64:
        raise ValueError("Invalid configured probes")
    expected = {}
    for probe in probes:
        if not isinstance(probe, dict) or set(probe) != {"name", "url"}:
            raise ValueError("Invalid configured probe")
        name, target = probe["name"], probe["url"]
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", name) or name in expected:
            raise ValueError("Invalid configured probe identity")
        if not isinstance(target, str) or not 1 <= len(target) <= 2048 or any(ord(c) <= 32 or ord(c) >= 127 for c in target):
            raise ValueError("Invalid configured probe URL")
        url = urllib.parse.urlsplit(target)
        if url.scheme not in ("http", "https") or not url.hostname or url.username is not None or url.password is not None or url.query or url.fragment:
            raise ValueError("Invalid configured probe URL")
        expected[name] = {"job": JOB, "instance": name, "probe": name, "target": target}
    return expected


def targets_loaded(expected, require_scraped):
    # Read every active target, so an additional unexpected job cannot be hidden
    # by a scrapePool filter. The separate self-scraper is not a target here.
    data = json_response("/api/v1/targets?state=active")
    targets = data.get("activeTargets")
    if not isinstance(targets, list) or len(targets) > 64:
        raise ValueError("Invalid scrape target response")
    if len(targets) != len(expected):
        raise NotReady()
    seen = set()
    now = time.time()
    for target in targets:
        if not isinstance(target, dict) or not isinstance(target.get("labels"), dict):
            raise ValueError("Invalid scrape target")
        labels = target["labels"]
        name = labels.get("probe")
        if not isinstance(name, str) or name not in expected or name in seen or labels != expected[name]:
            raise NotReady()
        seen.add(name)
        if target.get("scrapePool") != JOB or not isinstance(target.get("scrapeUrl"), str):
            raise NotReady()
        url = urllib.parse.urlsplit(target["scrapeUrl"])
        if url.scheme != "http" or url.netloc != "127.0.0.1:9115" or url.path != "/probe" or url.fragment:
            raise NotReady()
        if urllib.parse.parse_qs(url.query, strict_parsing=True) != {"module": ["http_2xx"], "target": [labels["target"]]}:
            raise NotReady()
        discovered = target.get("discoveredLabels")
        if not isinstance(discovered, dict):
            raise ValueError("Missing discovered scrape labels")
        if discovered.get("__scrape_interval__") != "30s" or discovered.get("__scrape_timeout__") != "5s":
            raise NotReady()
        if require_scraped:
            if target.get("health") != "up" or target.get("lastError") != "":
                raise NotReady()
            value = target.get("lastScrape")
            if not isinstance(value, str):
                raise ValueError("Invalid scrape timestamp")
            stamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if stamp.tzinfo is None or not -5 <= now - stamp.timestamp() <= FRESH_SECONDS:
                raise NotReady()
    return True


def config_reloaded():
    metrics = request("/metrics").decode("utf-8")
    matches = re.findall(r"^vm_promscrape_config_last_reload_successful ([01])$", metrics, re.MULTILINE)
    if matches != ["1"]:
        raise NotReady()


def loaded_policy(expected):
    data = json_response("/api/v1/status/config")
    config = data.get("yaml")
    if not isinstance(config, str):
        raise ValueError("Invalid loaded scrape configuration")
    if not expected:
        if config != LOADED_GLOBAL:
            raise NotReady()
        return
    if not config.startswith(LOADED_POLICY):
        raise NotReady()
    static = config[len(LOADED_POLICY):].splitlines()
    # Additional jobs, global rules, discovery settings or trailing job options
    # cannot hide in the target block. Every actual target is checked separately.
    if not static or any(not (line.startswith("  - targets:") or line.startswith("    ")) for line in static):
        raise NotReady()


def scraper_ready(expected):
    if request("/ready").strip() != b"OK":
        raise ValueError("Invalid scraper readiness response")
    config_reloaded()
    loaded_policy(expected)
    targets_loaded(expected, require_scraped=True)


def query(expression):
    path = "/api/v1/query?" + urllib.parse.urlencode({"query": expression, "nocache": "1", "timeout": "4s"})
    data = json_response(path)
    # Removed target series can coexist with all 64 current probes in this
    # recent range. Bound history separately from current target cardinality;
    # request() also caps every response at 1 MiB.
    if data.get("resultType") != "vector" or not isinstance(data.get("result"), list) or len(data["result"]) > 4096:
        raise ValueError("Invalid stored probe response")
    return data["result"]


def sample_map(rows, expected, metric="probe_success"):
    samples = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("metric"), dict):
            raise ValueError("Invalid stored probe sample")
        labels = dict(row["metric"])
        metric_name = labels.pop("__name__", metric)
        if metric_name != metric:
            raise ValueError("Unexpected stored probe metric")
        name = labels.get("probe")
        if not isinstance(name, str):
            raise ValueError("Missing stored probe identity")
        if name not in expected or labels != expected[name]:
            # Removed targets may remain inside the requested range. They never
            # count toward readiness or appear as configured status rows.
            continue
        if name in samples:
            raise ValueError("Duplicate stored probe identity")
        point = row.get("value")
        if not isinstance(point, list) or len(point) != 2 or type(point[0]) not in (int, float) or not math.isfinite(point[0]) or not isinstance(point[1], str):
            raise ValueError("Invalid stored probe point")
        value = float(point[1])
        if not math.isfinite(value):
            raise ValueError("Non-finite stored probe point")
        samples[name] = value
    return samples


def stored_states(expected, check_up=False):
    if not expected:
        return {}
    selector = 'probe_success{job="dragontools-blackbox"}[90s]'
    values = sample_map(query("last_over_time(" + selector + ")"), expected)
    stamps = sample_map(query("timestamp(" + selector + ")"), expected)
    up = {}
    up_stamps = {}
    if check_up:
        up_selector = 'up{job="dragontools-blackbox"}[90s]'
        up = sample_map(query("last_over_time(" + up_selector + ")"), expected, "up")
        up_stamps = sample_map(query("timestamp(" + up_selector + ")"), expected, "up")
    now = time.time()
    states = {}
    for name in expected:
        value, stamp = values.get(name), stamps.get(name)
        if value is not None and value not in (0.0, 1.0):
            raise ValueError("Unexpected probe success value")
        scraper_current = not check_up or (up.get(name) == 1.0 and name in up_stamps and -5 <= now - up_stamps[name] <= FRESH_SECONDS)
        if value is None or stamp is None or not -5 <= now - stamp <= FRESH_SECONDS or not scraper_current:
            states[name] = "unknown"
        else:
            states[name] = "healthy" if value == 1 else "unhealthy"
    return states


def read_main():
    try:
        mode, config, raw_probes = sys.argv[1:4]
        probes = json.loads(base64.b64decode(raw_probes, validate=True))
        expected = definitions(probes)
        if mode == "managed":
            read_config(config)
            pending_exists()
        elif mode == "ready":
            scraper_ready(expected)
        elif mode == "stored":
            # A down monitored application still has exporter up=1 and a fresh
            # probe_success=0. Only a broken mechanism or missing data fails.
            scraper_ready(expected)
            if any(value == "unknown" for value in stored_states(expected).values()):
                raise NotReady()
        elif mode == "status":
            try:
                states = stored_states(expected, check_up=True)
            except NotReady:
                states = {name: "unknown" for name in expected}
            print(json.dumps([states[probe["name"]] for probe in probes], separators=(",", ":")), end="")
        else:
            raise ValueError("Unsupported scrape operation")
        return 0
    except NotReady:
        return 75
    except Exception:
        return 1
