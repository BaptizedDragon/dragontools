#!/usr/bin/env python3
"""Read-only review of an already-downloaded official ZIP; no network/execution."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
source = (root / "src/components/grafana_victorialogs_plugin.zig").read_text()
spec = importlib.util.spec_from_file_location("plugin_artifact", root / "src/components/grafana_victorialogs_artifact.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


def pin(name):
    return re.search(r'pub const ' + name + r' = "([^"]+)";', source).group(1)


if len(sys.argv) != 2:
    raise SystemExit("usage: grafana_victorialogs_archive.py PATH_TO_REVIEWED_ZIP")
path = Path(sys.argv[1])
assert artifact.file_hash(str(path)) == pin("archive_sha256")
catalog = artifact.archive_catalog(str(path), pin("version"))
assert hashlib.sha256(catalog).hexdigest() == pin("tree_sha256")
records = json.loads(catalog)
assert len([r for r in records if r[0] == "f"]) == 36
assert len([r for r in records if r[0] == "d"]) == 2
print("Pinned VictoriaLogs plugin ZIP and complete signed-content catalog verified (36 files, 2 directories).")
print("No plugin execution or disposable-host integration performed.")
