"""Local Linux process fixture; not systemd, SSH, or station integration.

Run only with already-audited binaries. No network sinks or listeners are created.
Optional generated configurations are checked by their pinned native validators.
The caller can additionally isolate this in a no-network disposable container.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def pinned(path, component):
    source = (ROOT / "src/components" / (component + ".zig")).read_text()
    hashes = re.findall(r'[.]binary_sha256 = "([a-f0-9]{64})"', source)
    assert hashlib.sha256(path.read_bytes()).hexdigest() in hashes, "binary pin mismatch"


def run(vector, vmagent=None, vector_config=None, vmagent_config=None):
    pinned(vector, "vector")
    if vector_config:
        subprocess.run([str(vector), "validate", "--no-environment", "--skip-healthchecks", str(vector_config)], check=True)
    if vmagent:
        pinned(vmagent, "vmagent")
        if vmagent_config:
            subprocess.run([str(vmagent), "-promscrape.config=" + str(vmagent_config), "-dryRun"], check=True)
    with tempfile.TemporaryDirectory(prefix="dragontools-vector-contract-") as temporary:
        base = Path(temporary)
        config = base / "fixture.json"
        config.write_text(json.dumps({
            "data_dir": temporary,
            "api": {"enabled": False},
            "sources": {
                "host": {"type": "host_metrics", "namespace": "host", "collectors": ["cpu", "memory", "filesystem", "disk", "network"], "scrape_interval_secs": 1},
                "internal": {"type": "internal_metrics", "scrape_interval_secs": 1},
            },
            "sinks": {"out": {"type": "console", "inputs": ["host", "internal"], "encoding": {"codec": "json"}}},
        }))
        with (base / "output").open("w+") as output, (base / "errors").open("w+") as errors:
            process = subprocess.Popen([str(vector), "--config", str(config)], stdout=output, stderr=errors)
            try:
                # This bounded capture is a metric-contract experiment, not the
                # install readiness policy. Stop after one short capture window.
                process.wait(timeout=4)
                raise AssertionError("Vector exited before fixture capture")
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise AssertionError("Vector did not stop cleanly")
            output.seek(0)
            events = [json.loads(line) for line in output]
    names = {event.get("namespace", "") + "_" + event["name"] for event in events}
    required = set(re.findall(r'pub const \w+ = "([a-z_]+)";', (ROOT / "src/monitoring/agents/metric_contract.zig").read_text()))
    assert required <= names, "missing emitted contract names: " + repr(sorted(required - names))
    cpu = next(event for event in events if event["name"] == "cpu_seconds_total")
    disk = next(event for event in events if event["name"] == "filesystem_inodes_used_ratio")
    assert {"host", "cpu", "mode"} <= cpu["tags"].keys()
    assert {"host", "mountpoint", "filesystem", "device"} <= disk["tags"].keys()
    print("PASS: pinned Vector Linux metric contract; process fixture only, no station/systemd validation.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vector", type=Path, required=True)
    parser.add_argument("--vmagent", type=Path)
    parser.add_argument("--vector-config", type=Path)
    parser.add_argument("--vmagent-config", type=Path)
    args = parser.parse_args()
    run(args.vector, args.vmagent, args.vector_config, args.vmagent_config)
