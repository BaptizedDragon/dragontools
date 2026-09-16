const std = @import("std");
const verify = @import("grafana_verify.zig");
const remote = @import("../system/remote.zig");
const install = @import("install.zig");
const grafana = @import("../components/grafana.zig");

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
        command: []const u8 = "",
        fn execute(ctx: *anyopaque, op: remote.Operation, command: []const u8) !remote.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqual(remote.Operation.health, op);
            self.command = try self.a.dupe(u8, command);
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
    const argv = try ssh.argv(capture.command);
    // Linux limits one exec argument to 128 KiB; preserve room for transport changes.
    try std.testing.expect(argv[argv.len - 1].len < 120 * 1024);
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
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, capture.command, needle) != null);
    // Root tree verification reads the pinned catalog and assets; the datasource
    // probe selects metadata only. Neither touches stored Grafana credentials.
    for ([_][]const u8{ "systemctl daemon-reload", "systemctl restart", "systemctl start", "systemctl enable", "touch ", "rm -f ", "chmod ", "chown ", "admin:admin", "-u admin", "SELECT *", "SELECT password", "SELECT secure_json_data" }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, capture.command, mutation) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), report.changes);
    try std.testing.expectEqual(@as(usize, 1), report.completed);
    // Parse the actual generated shell body, replacing only command execution.
    const script = try std.fmt.allocPrint(a, "python3() {{ :; }}\nsh() {{ command /bin/sh -n \"$@\"; }}\n{s}", .{capture.command});
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-c", script } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    const inner = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/sh", "-n", "-c", verify.health_script } });
    try std.testing.expectEqualStrings("", inner.stderr);
    try std.testing.expectEqual(@as(u8, 0), inner.term.exited);
}

test "Grafana environment override rejection reads NUL records without exposing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const start = std.mem.indexOf(u8, verify.health_script, "if grep -zq").?;
    const end = std.mem.indexOfScalarPos(u8, verify.health_script, start, '\n').?;
    const probe = try std.mem.replaceOwned(u8, a, verify.health_script[start..end], "/proc/$pid/environ", "$1");
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
        \\def check(root, db, success):
        \\    before = snapshot(root)
        \\    p = subprocess.run([sys.executable, "-I", "-B", "-c", probe, str(db)], capture_output=True)
        \\    assert (p.returncode == 0) == success, (p.returncode, p.stderr)
        \\    assert p.stdout == b"" and p.stderr == b""
        \\    assert snapshot(root) == before, "Read-only probe changed a file or created a sidecar"
        \\def create(path):
        \\    db = sqlite3.connect(path)
        \\    db.execute("CREATE TABLE data_source (org_id INTEGER, uid TEXT, name TEXT, type TEXT, access TEXT, url TEXT, is_default INTEGER, read_only INTEGER, basic_auth INTEGER, with_credentials INTEGER, json_data TEXT)")
        \\    db.executemany("INSERT INTO data_source VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
        \\        (1, "dragontools-metrics", "Metrics", "prometheus", "proxy", "http://127.0.0.1:8428", 1, 1, 0, 0, json.dumps({"httpMethod":"POST", "prometheusType":"Prometheus", "prometheusVersion":"2.24.0"})),
        \\        (1, "dragontools-traces", "Traces", "jaeger", "proxy", "http://127.0.0.1:10428/select/jaeger", 0, 1, 0, 0, "{}"),
        \\    ])
        \\    db.commit()
        \\    db.close()
        \\    os.chmod(path, 0o600)
        \\with tempfile.TemporaryDirectory(prefix="dragontools-grafana-db-") as root:
        \\    path = pathlib.Path(root) / "grafana.db"
        \\    check(root, path, False)
        \\    create(path)
        \\    check(root, path, True)
        \\    check(root, path, True)
        \\    for statement in [
        \\        "DELETE FROM data_source WHERE name = 'Traces'",
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
        \\        check(root, path, False)
        \\        path.unlink()
        \\        create(path)
        \\    os.chmod(path, 0o644)
        \\    check(root, path, False)
        \\    os.chmod(path, 0o600)
        \\    link = pathlib.Path(root) / "linked.db"
        \\    link.symlink_to(path)
        \\    check(root, link, False)
        \\    link.unlink()
        \\    os.link(path, link)
        \\    check(root, path, False)
        \\    link.unlink()
        \\    writer = sqlite3.connect(path)
        \\    writer.execute("PRAGMA journal_mode=WAL")
        \\    writer.execute("UPDATE data_source SET name = name")
        \\    writer.commit()
        \\    check(root, path, False)
        \\    writer.close()
    ;
    const result = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "python3", "-I", "-B", "-c", harness, verify.database_check } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
