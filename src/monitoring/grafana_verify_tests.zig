const std = @import("std");
const verify = @import("grafana_verify.zig");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const grafana = @import("../components/grafana.zig");

test "direct LogsQL backend fixtures accept empty responses and keep failures read-only" {
    const a = std.testing.allocator;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "tests/grafana_logs_backend_test.py" } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "Grafana health requires application identity stored metrics and valid Jaeger results" {
    const a = std.testing.allocator;
    try verify.validate(a, verify.healthy_fixture);
    for ([_][]const u8{ "", "ok", "<html>Grafana</html>", "[]", "{}" }) |invalid| {
        try std.testing.expectError(error.InvalidGrafanaHealthResponse, verify.validate(a, invalid));
    }
    const Case = struct { before: []const u8, after: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .before = grafana.version, .after = "0.0.0", .expected = error.GrafanaIdentityOrDatabaseFailed },
        .{ .before = "\"database\":\"ok\"", .after = "\"database\":\"failed\"", .expected = error.GrafanaIdentityOrDatabaseFailed },
        .{ .before = "\"provisioning\":\"verified\"", .after = "\"provisioning\":\"missing\"", .expected = error.GrafanaProvisioningFailed },
        .{ .before = "\"status\":\"success\"", .after = "\"status\":\"error\"", .expected = error.GrafanaMetricsQueryFailed },
        .{ .before = "\"resultType\":\"vector\"", .after = "\"resultType\":\"matrix\"", .expected = error.GrafanaMetricsQueryFailed },
        .{ .before = "vm_app_version", .after = "up", .expected = error.GrafanaMetricsQueryFailed },
        .{ .before = "\"value\":[1,\"1\"]", .after = "\"value\":[1,\"NaN\"]", .expected = error.GrafanaMetricsQueryFailed },
        .{ .before = "\"data\":[]", .after = "\"data\":null", .expected = error.GrafanaTracesQueryFailed },
        .{ .before = "\"data\":[]", .after = "\"data\":[123]", .expected = error.GrafanaTracesQueryFailed },
        .{ .before = "\"errors\":null", .after = "\"errors\":[{\"code\":500}]", .expected = error.GrafanaTracesQueryFailed },
        .{ .before = "\"total\":0", .after = "\"total\":1", .expected = error.GrafanaTracesQueryFailed },
    }) |case| {
        const altered = try std.mem.replaceOwned(u8, a, verify.healthy_fixture, case.before, case.after);
        defer a.free(altered);
        try std.testing.expectError(case.expected, verify.validate(a, altered));
    }
    const empty = try std.mem.replaceOwned(u8, a, verify.healthy_fixture, "[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]", "[]");
    defer a.free(empty);
    try std.testing.expectError(error.GrafanaMetricsQueryFailed, verify.validate(a, empty));
}

test "Grafana rendered verification checks actual policy and never mutates remote configuration" {
    const Capture = struct {
        a: std.mem.Allocator,
        commands: std.ArrayList([]const u8) = .empty,
        fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(remote.Operation.health, op);
            try self.commands.append(self.a, try self.a.dupe(u8, command));
            return .{ .code = 0, .output = verify.healthy_fixture };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var capture: Capture = .{ .a = a };
    var report: install.Report = .{};
    try verify.health(a, .{ .context = &capture, .execute = Capture.execute }, &report, .arm64);
    var ssh: @import("../system/ssh.zig").Ssh = .{ .allocator = a, .io = std.testing.io, .options = .{ .ssh_host = "monitoring" } };
    for (capture.commands.items) |command| {
        const argv = try ssh.argv(command);
        // Linux limits one exec argument to 128 KiB.
        try std.testing.expect(argv[argv.len - 1].len < 120 * 1024);
    }
    const combined = try std.mem.join(a, "\n", capture.commands.items);
    for ([_][]const u8{
        "check_property LoadState loaded",                         "check_property UnitFileState enabled",        "check_property DropInPaths \"\"",
        "check_property NeedDaemonReload no",                      "check_property Environment \"\"",             "check_property EnvironmentFiles \"\"",
        "check_property User dt-grafana",                          "check_property Group dt-grafana",             "check_property ProtectSystem strict",
        "check_property CapabilityBoundingSet \"\"",               "check_property AmbientCapabilities \"\"",     "check_property ReadWritePaths /var/lib/dragontools/grafana",
        "systemctl is-active --quiet dragontools-grafana.service", "test \"$actual_args\" = \"$expected_args\"",  "\"/proc/$pid/exe\" | sha256sum --check --status",
        "http://127.0.0.1:3000/api/health",                        "test \"$code\" = 401",                        "http://127.0.0.1:3000/api/datasources",
        "runuser --user dt-grafana -- python3 -I -B -c",           "runuser --user dt-grafana -- curl --disable", "http://127.0.0.1:8428/api/v1/query?query=vm_app_version",
        "http://127.0.0.1:10428/select/jaeger/api/services",       "all_listeners=$(ss -H -ltnp)",                "owned=$(printf",
        "--max-filesize 1048576",                                  "?mode=ro",                                    "PRAGMA query_only=ON",
        grafana.artifact(.arm64).binary_sha256,                    grafana.artifact(.arm64).tree_sha256,
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, combined, needle) != null);
    // Root tree verification reads the pinned catalog and assets; the datasource
    // probe selects metadata only. Neither touches stored Grafana credentials.
    for ([_][]const u8{ "systemctl daemon-reload", "systemctl restart", "systemctl start", "systemctl enable", "touch ", "rm -f ", "chmod ", "chown ", "admin:admin", "-u admin", "SELECT *", "SELECT password", "SELECT secure_json_data" }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, combined, mutation) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 7), report.completed);
    try std.testing.expectEqual(@as(usize, 7), capture.commands.items.len);
    // Parse every actual generated shell body without running its commands.
    for (capture.commands.items) |command| {
        const script = try std.fmt.allocPrint(a, "python3() {{ :; }}\nsh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{command});
        const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    }
    for ([_][]const u8{ verify.managed_script, verify.active_script, verify.http_script, verify.provisioning_script, verify.backend_script, verify.logs_backend_script }) |body| {
        const inner = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", body } });
        try std.testing.expectEqualStrings("", inner.stderr);
        try std.testing.expectEqual(@as(u8, 0), inner.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, body, "sleep ") == null);
    }
}

test "Grafana environment override rejection reads NUL records without exposing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const start = std.mem.indexOf(u8, verify.runtime_guard, "if grep -zq").?;
    const end = std.mem.indexOfScalarPos(u8, verify.runtime_guard, start, '\n').?;
    const probe = try std.mem.replaceOwned(u8, a, verify.runtime_guard[start..end], "/proc/$pid/environ", "$1");
    const harness =
        \\import os, pathlib, subprocess, sys, tempfile
        \\probe = sys.argv[1]
        \\with tempfile.TemporaryDirectory(prefix="dragontools-grafana-env-") as root:
        \\    path = pathlib.Path(root) / "environ"
        \\    for data, success in [
        \\        (b"", True),
        \\        (b"HOME=/safe\0PATH=/usr/bin\0", True),
        \\        (b"OTHER=GF_AUTH_ANONYMOUS_ENABLED=true\0", True),
        \\        (b"GF_AUTH_ANONYMOUS_ENABLED=true\0", False),
        \\        (b"HOME=/safe\0GF_SERVER_HTTP_ADDR=0.0.0.0\0", False),
        \\        (b"GF_SECURITY_ADMIN_PASSWORD=PRIVATE_SENTINEL\nwith-newline\0", False),
        \\    ]:
        \\        path.write_bytes(data)
        \\        before = path.stat()
        \\        result = subprocess.run(["/bin/sh", "-eu", "-c", probe, "probe", str(path)], capture_output=True)
        \\        assert (result.returncode == 0) == success
        \\        assert result.stdout == b"" and result.stderr == b""
        \\        assert path.read_bytes() == data and path.stat().st_mtime_ns == before.st_mtime_ns
        \\    path.unlink()
        \\    result = subprocess.run(["/bin/sh", "-eu", "-c", probe, "probe", str(path)], capture_output=True)
        \\    assert result.returncode != 0
        \\    assert result.stdout == b"" and result.stderr == b""
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", harness, probe } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "Grafana actual SQLite probe rejects drift and leaves database bytes metadata and sidecars unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // This executes the production Python probe against temporary fixture DBs.
    // No Grafana process, remote host, credentials, or systemd are involved.
    const harness =
        \\import hashlib, json, os, pathlib, sqlite3, subprocess, sys, tempfile
        \\probe = sys.argv[1]
        \\def snapshot(root):
        \\    result = {}
        \\    for p in pathlib.Path(root).iterdir():
        \\        s = p.lstat()
        \\        content = os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest()
        \\        result[p.name] = (s.st_mode, s.st_uid, s.st_gid, s.st_size, s.st_mtime_ns, s.st_ctime_ns, content)
        \\    return result
        \\def check(root, db, expected):
        \\    before = snapshot(root)
        \\    p = subprocess.run([sys.executable, "-I", "-B", "-c", probe, str(db)], capture_output=True)
        \\    assert p.returncode == expected, (p.returncode, p.stderr)
        \\    assert p.stdout == b"" and p.stderr == b""
        \\    assert snapshot(root) == before, "Read-only probe changed a file or created a sidecar"
        \\def create(path):
        \\    db = sqlite3.connect(path)
        \\    db.execute("CREATE TABLE data_source (org_id INTEGER, uid TEXT, name TEXT, type TEXT, access TEXT, url TEXT, is_default INTEGER, read_only INTEGER, basic_auth INTEGER, with_credentials INTEGER, json_data TEXT)")
        \\    db.executemany("INSERT INTO data_source VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
        \\        (1, "dragontools-logs", "Logs", "victoriametrics-logs-datasource", "proxy", "http://127.0.0.1:9428", 0, 1, 0, 0, "{}"),
        \\        (1, "dragontools-metrics", "Metrics", "prometheus", "proxy", "http://127.0.0.1:8428", 1, 1, 0, 0, json.dumps({"httpMethod":"POST", "prometheusType":"Prometheus", "prometheusVersion":"2.24.0"})),
        \\        (1, "dragontools-traces", "Traces", "jaeger", "proxy", "http://127.0.0.1:10428/select/jaeger", 0, 1, 0, 0, "{}"),
        \\    ])
        \\    db.commit()
        \\    db.close()
        \\    os.chmod(path, 0o600)
        \\with tempfile.TemporaryDirectory(prefix="dragontools-grafana-db-") as root:
        \\    path = pathlib.Path(root) / "grafana.db"
        \\    check(root, path, 75)
        \\    sqlite3.connect(path).close()
        \\    os.chmod(path, 0o600)
        \\    check(root, path, 75)
        \\    path.unlink()
        \\    create(path)
        \\    check(root, path, 0)
        \\    check(root, path, 0)
        \\    # The pinned provisioner always writes an object, including its empty
        \\    # default. Whitespace is immaterial; null/scalars/arrays are not policy.
        \\    for options in ["{}", " { } \n"]:
        \\        with sqlite3.connect(path) as db:
        \\            db.execute("UPDATE data_source SET json_data = ? WHERE name = 'Logs'", (options,))
        \\        check(root, path, 0)
        \\    for options in [None, "null", "[]", "0", "false", '""', "not-json",
        \\                    json.dumps({"customQueryParameters": "extra_filters=secret"}),
        \\                    json.dumps({"multitenancyHeaders": {"AccountID": "1"}}),
        \\                    json.dumps({"oauthPassThru": True}),
        \\                    json.dumps({"httpHeaderName1": "Authorization"}),
        \\                    json.dumps({"maxLines": 1000}),
        \\                    json.dumps({"unknown": None})]:
        \\        with sqlite3.connect(path) as db:
        \\            db.execute("UPDATE data_source SET json_data = ? WHERE name = 'Logs'", (options,))
        \\        check(root, path, 1)
        \\    path.unlink()
        \\    create(path)
        \\    for statement in [
        \\        "DELETE FROM data_source WHERE name = 'Traces'",
        \\        "DELETE FROM data_source WHERE name = 'Logs'",
        \\        "UPDATE data_source SET url = 'http://public.invalid:9428' WHERE name = 'Logs'",
        \\        "UPDATE data_source SET type = 'loki' WHERE name = 'Logs'",
        \\        "UPDATE data_source SET url = 'http://127.0.0.1:10428' WHERE name = 'Traces'",
        \\        "UPDATE data_source SET read_only = 0",
        \\        "UPDATE data_source SET type = 'loki' WHERE name = 'Traces'",
        \\        "UPDATE data_source SET org_id = 2",
        \\        "UPDATE data_source SET is_default = 0 WHERE name = 'Metrics'",
        \\        "UPDATE data_source SET json_data = '{}' WHERE name = 'Metrics'",
        \\        "UPDATE data_source SET basic_auth = 1",
        \\        "INSERT INTO data_source SELECT * FROM data_source WHERE name = 'Metrics'",
        \\    ]:
        \\        with sqlite3.connect(path) as db:
        \\            db.execute(statement)
        \\        check(root, path, 75 if statement.startswith("DELETE ") else 1)
        \\        path.unlink()
        \\        create(path)
        \\    os.chmod(path, 0o644)
        \\    check(root, path, 1)
        \\    os.chmod(path, 0o600)
        \\    link = pathlib.Path(root) / "linked.db"
        \\    link.symlink_to(path)
        \\    check(root, link, 1)
        \\    link.unlink()
        \\    os.link(path, link)
        \\    check(root, path, 1)
        \\    link.unlink()
        \\    writer = sqlite3.connect(path)
        \\    writer.execute("PRAGMA journal_mode=WAL")
        \\    writer.execute("UPDATE data_source SET name = name")
        \\    writer.commit()
        \\    check(root, path, 1)
        \\    writer.close()
    ;
    const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", harness, verify.database_check } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "Grafana stage validators retry database readiness and absent self scrape only" {
    const a = std.testing.allocator;
    try verify.validateHttp(a, verify.healthy_fixture);
    try verify.validateBackend(a, verify.healthy_fixture);
    const database_starting = try std.mem.replaceOwned(u8, a, verify.healthy_fixture, "\"database\":\"ok\"", "\"database\":\"starting\"");
    defer a.free(database_starting);
    try std.testing.expectError(error.NotReady, verify.validateHttp(a, database_starting));
    const wrong_version = try std.mem.replaceOwned(u8, a, database_starting, grafana.version, "0.0.0");
    defer a.free(wrong_version);
    try std.testing.expectError(error.GrafanaIdentityOrDatabaseFailed, verify.validateHttp(a, wrong_version));
    const empty = try std.mem.replaceOwned(u8, a, verify.healthy_fixture, "[{\"metric\":{\"__name__\":\"vm_app_version\"},\"value\":[1,\"1\"]}]", "[]");
    defer a.free(empty);
    try std.testing.expectError(error.NotReady, verify.validateBackend(a, empty));
    try std.testing.expectError(error.InvalidGrafanaHealthResponse, verify.validateHttp(a, "{}"));
    try std.testing.expectError(error.InvalidGrafanaHealthResponse, verify.validateBackend(a, "{}"));
}

test "Grafana actual runtime guard distinguishes missing readiness from deterministic unsafe state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const guard = try std.mem.replaceOwned(u8, a, verify.runtime_guard, "/proc/$pid", "$DT_ROOT/proc/$pid");
    const harness =
        \\import os, pathlib, subprocess, sys, tempfile
        \\guard = sys.argv[1]
        \\fixture = '''
        \\DT_ROOT=$2
        \\systemctl() {
        \\  if test "$1" = show; then
        \\    case "$CASE" in no_pid|no_pid_public) printf 0;; *) printf 777;; esac
        \\  elif test "$1" = is-active; then test "$CASE" != inactive
        \\  else return 90; fi
        \\}
        \\stat() { if test "$CASE" = user; then printf root:root; else printf dt-grafana:dt-grafana; fi; }
        \\sha256sum() { cat >/dev/null; test "$CASE" != hash; }
        \\ss() {
        \\  case "$CASE" in
        \\    missing|no_pid) return 0;;
        \\    public|no_pid_public) printf '%s\\n' 'LISTEN 0 4096 0.0.0.0:3000 0.0.0.0:* users:(("grafana",pid=777,fd=8))';;
        \\    *) printf '%s\\n' 'LISTEN 0 4096 127.0.0.1:3000 0.0.0.0:* users:(("grafana",pid=777,fd=8))';;
        \\  esac
        \\  if test "$CASE" = extra && test "$#" = 3; then
        \\    printf '%s\\n' 'LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:* users:(("grafana",pid=777,fd=9))'
        \\  fi
        \\}
        \\'''
        \\with tempfile.TemporaryDirectory(prefix="dragontools-grafana-runtime-") as root:
        \\    proc = pathlib.Path(root) / "proc" / "777"
        \\    proc.mkdir(parents=True)
        \\    argv = b"/opt/dragontools/components/grafana/current/bin/grafana\0server\0--homepath=/opt/dragontools/components/grafana/current\0--config=/etc/dragontools/grafana/grafana.ini\0"
        \\    for case, expected in [("good", 0), ("missing", 75), ("no_pid", 75), ("inactive", 75), ("public", 1), ("no_pid_public", 1), ("extra", 1), ("args", 1), ("hash", 1), ("env", 1), ("user", 1)]:
        \\        (proc / "cmdline").write_bytes(argv if case != "args" else argv + b"--unexpected\0")
        \\        (proc / "environ").write_bytes(b"GF_SERVER_HTTP_ADDR=PRIVATE_SENTINEL\0" if case == "env" else b"PATH=/usr/bin\0")
        \\        result = subprocess.run(["/bin/sh", "-eu", "-c", fixture + guard + "\ncheck_runtime listener\n", "probe", "hash", root], env=dict(os.environ, CASE=case), capture_output=True)
        \\        assert result.returncode == expected, (case, result.returncode, result.stderr)
        \\        assert result.stdout == b"" and result.stderr == b"", case
    ;
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", harness, guard } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
