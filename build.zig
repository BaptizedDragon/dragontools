const std = @import("std");
pub fn build(b: *std.Build) void {
    const requested = b.standardTargetOptions(.{});
    const target = if (requested.result.os.tag == .linux) b.resolveTargetQuery(.{ .cpu_arch = requested.result.cpu.arch, .os_tag = .linux, .abi = .musl }) else requested;
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Release version shared by controller and bundled helper") orelse "0.1.0-dev";
    if (version.len > 64) @panic("-Dversion is limited to 64 characters");
    for (version) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".+-", byte) == null) @panic("invalid release version character");
    _ = std.SemanticVersion.parse(version) catch @panic("-Dversion must be a semantic version without a v prefix");
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    @import("src/pki/build.zig").link(b, module);
    module.addOptions("build_options", options);
    const payloads = b.addWriteFiles();
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const name = if (arch == .x86_64) "linux-amd64" else "linux-arm64";
        const artifact = agentArtifact(b, b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .musl }), options);
        _ = payloads.addCopyFile(artifact.getEmittedBin(), name);
        b.getInstallStep().dependOn(&b.addInstallFile(artifact.getEmittedBin(), b.fmt("libexec/{s}/dragontool-agent", .{name})).step);
    }
    const payload_root = payloads.add("payload.zig", "pub const amd64 = @embedFile(\"linux-amd64\");\npub const arm64 = @embedFile(\"linux-arm64\");\n");
    module.addImport("agent_payload", b.createModule(.{ .root_source_file = payload_root }));
    const exe = b.addExecutable(.{ .name = "dragontool", .root_module = module });
    b.installArtifact(exe);
    const agent = agentArtifact(b, target, options);
    b.installArtifact(agent);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run DragonTools").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run unit, native PKI and fake-remote tests");
    const controller_tests = b.addRunArtifact(tests);
    const fixture_module = b.createModule(.{ .root_source_file = b.path("src/pki_fixture_main.zig"), .target = target, .optimize = .ReleaseSafe });
    @import("src/pki/build.zig").link(b, fixture_module);
    fixture_module.addOptions("build_options", options);
    fixture_module.addImport("agent_payload", b.createModule(.{ .root_source_file = payload_root }));
    fixture_module.addCSourceFile(.{ .file = b.path("src/agent/posix.c"), .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" } });
    const fixture = b.addExecutable(.{ .name = "dragontool-pki-fixture", .root_module = fixture_module });
    const install_fixture = b.addInstallArtifact(fixture, .{});
    b.step("test-fixture", "Build the isolated native PKI fixture helper").dependOn(&install_fixture.step);
    controller_tests.step.dependOn(&install_fixture.step);
    test_step.dependOn(&controller_tests.step);
    const crypto_module = b.createModule(.{ .root_source_file = b.path("src/pki/pki.zig"), .target = target, .optimize = optimize });
    @import("src/pki/build.zig").link(b, crypto_module);
    const crypto_tests = b.addTest(.{ .root_module = crypto_module });
    b.step("test-pki", "Run native PKI tests without external crypto tools").dependOn(&b.addRunArtifact(crypto_tests).step);
    const agent_module = b.createModule(.{ .root_source_file = b.path("src/agent_tests.zig"), .target = target, .optimize = optimize });
    @import("src/pki/build.zig").link(b, agent_module);
    agent_module.addCSourceFile(.{ .file = b.path("src/agent/posix.c"), .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" } });
    const agent_tests = b.addTest(.{ .root_module = agent_module });
    const binaries = b.step("test-binaries", "Build native lifecycle and TLS fixtures for isolated target execution");
    binaries.dependOn(&b.addInstallFile(agent_tests.getEmittedBin(), "tests/native-agent-tests").step);
    binaries.dependOn(&install_fixture.step);
    const agent_test_run = b.addRunArtifact(agent_tests);
    b.step("test-agent", "Run native agent lifecycle fixtures").dependOn(&agent_test_run.step);
    test_step.dependOn(&agent_test_run.step);
}
fn agentArtifact(b: *std.Build, target: std.Build.ResolvedTarget, options: *std.Build.Step.Options) *std.Build.Step.Compile {
    const artifact = b.addExecutable(.{ .name = "dragontool-agent", .root_module = b.createModule(.{ .root_source_file = b.path("src/agent_main.zig"), .target = target, .optimize = .ReleaseSafe, .strip = true }) });
    @import("src/pki/build.zig").link(b, artifact.root_module);
    artifact.root_module.addCSourceFile(.{ .file = b.path("src/agent/posix.c"), .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" } });
    artifact.root_module.addOptions("build_options", options);
    return artifact;
}
