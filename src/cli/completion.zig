const std = @import("std");
const spec = @import("spec.zig");

/// Generates static shell code only. Completion never runs the DragonTools binary.
pub fn render(a: std.mem.Allocator, shell: spec.Shell) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    switch (shell) {
        .bash, .zsh => try renderBourne(&out.writer, shell),
        .fish => try renderFish(&out.writer),
    }
    return out.toOwnedSlice();
}

// Shell literals contain only metadata, never command-line input. Keep quoting
// here so future descriptions with punctuation remain data in generated scripts.
fn quoteContent(w: *std.Io.Writer, value: []const u8, shell: spec.Shell) !void {
    for (value) |c| {
        if (c == '\'') {
            try w.writeAll(if (shell == .fish) "\\'" else "'\\''");
        } else if (c == '\\' and shell == .fish) {
            try w.writeAll("\\\\");
        } else try w.writeByte(c);
    }
}

fn quote(w: *std.Io.Writer, value: []const u8, shell: spec.Shell) !void {
    try w.writeByte('\'');
    try quoteContent(w, value, shell);
    try w.writeByte('\'');
}

fn key(w: *std.Io.Writer, node: spec.Node, token: []const u8, shell: spec.Shell) !void {
    try w.print("'{s}:", .{@tagName(node)});
    try quoteContent(w, token, shell);
    try w.writeByte('\'');
}

fn completionFlagAllowed(flag: spec.FlagSpec, command: spec.Command) bool {
    // --help is also valid on local/container nodes, so emit it once per node.
    return spec.flagAllowed(flag, command) and !std.mem.eql(u8, flag.name, "--help");
}

fn writeTransitions(w: *std.Io.Writer, shell: spec.Shell) !void {
    for (spec.commands) |item| {
        if (item.parent) |parent| {
            try w.writeAll("      ");
            try key(w, parent, item.name, shell);
            try w.print(") state={s} ;;\n", .{@tagName(item.node)});
        }
        try w.writeAll("      ");
        try key(w, item.node, "--help", shell);
        try w.writeAll(") ;;\n");
        if (item.command) |command| {
            for (spec.flags) |flag| {
                if (!completionFlagAllowed(flag, command)) continue;
                try w.writeAll("      ");
                try key(w, item.node, flag.name, shell);
                try w.writeAll(") ");
                if (flag.kind != .boolean) {
                    try w.writeAll("expect=");
                    try quote(w, flag.name, shell);
                }
                try w.writeAll(" ;;\n");
            }
        }
    }
}

fn writeWordList(w: *std.Io.Writer, node: spec.Node) !void {
    try w.writeAll("--help");
    for (spec.commands) |item| {
        if (item.parent == node) try w.print(" {s}", .{item.name});
    }
    if (spec.getNode(node).command) |command| {
        for (spec.flags) |flag| {
            if (completionFlagAllowed(flag, command)) try w.print(" {s}", .{flag.name});
        }
    }
}

fn writeValues(w: *std.Io.Writer, flag: spec.FlagSpec) !void {
    for (flag.values, 0..) |value, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(value);
    }
}

fn writeExpectedValues(w: *std.Io.Writer, shell: spec.Shell) !void {
    for (spec.commands) |item| {
        const command = item.command orelse continue;
        for (spec.flags) |flag| {
            if (!completionFlagAllowed(flag, command)) continue;
            if (flag.kind != .path and flag.values.len == 0) continue;
            try w.writeAll("      ");
            try key(w, item.node, flag.name, shell);
            try w.writeAll(")\n");
            if (flag.kind == .path) {
                try w.writeAll(if (shell == .bash)
                    "        while IFS= read -r word; do COMPREPLY+=(\"$word\"); done < <(compgen -f -- \"$cur\")\n        type compopt >/dev/null 2>&1 && compopt -o filenames\n"
                else
                    "        _files\n");
            } else if (shell == .bash) {
                try w.writeAll("        while IFS= read -r word; do COMPREPLY+=(\"$word\"); done < <(compgen -W '");
                try writeValues(w, flag);
                try w.writeAll("' -- \"$cur\")\n");
            } else {
                try w.writeAll("        candidates=(");
                for (flag.values) |value| {
                    try quote(w, value, shell);
                    try w.writeByte(' ');
                }
                try w.writeAll(")\n        _describe 'value' candidates\n");
            }
            try w.writeAll("        ;;\n");
        }
    }
}

fn describeCandidate(w: *std.Io.Writer, name: []const u8, description: []const u8, unavailable: bool) !void {
    try w.writeAll("        '");
    try quoteContent(w, name, .zsh);
    try w.writeByte(':');
    try quoteContent(w, description, .zsh);
    if (unavailable) try w.writeAll(" [unavailable]");
    try w.writeAll("'\n");
}

fn renderBourne(w: *std.Io.Writer, shell: spec.Shell) !void {
    if (shell == .zsh) try w.writeAll("#compdef dragontool\n");
    try w.writeAll("# Generated from DragonTools CLI metadata; local and side-effect free.\n_dragontool() {\n  local state=root expect='' word\n");
    if (shell == .bash) {
        try w.writeAll("  local cur=\"${COMP_WORDS[COMP_CWORD]}\" i\n  COMPREPLY=()\n  for ((i=1; i<COMP_CWORD; i++)); do\n    word=\"${COMP_WORDS[i]}\"\n");
    } else {
        try w.writeAll("  local -a candidates\n  integer i\n  for ((i=2; i<CURRENT; i++)); do\n    word=\"${words[i]}\"\n");
    }
    try w.writeAll("    if [[ -n \"$expect\" ]]; then expect=''; continue; fi\n    case \"$state:$word\" in\n");
    try writeTransitions(w, shell);
    try w.writeAll("      *) return 0 ;;\n    esac\n  done\n  if [[ -n \"$expect\" ]]; then\n    case \"$state:$expect\" in\n");
    try writeExpectedValues(w, shell);
    try w.writeAll("    esac\n    return 0\n  fi\n  case \"$state\" in\n");
    for (spec.commands) |item| {
        try w.print("    {s})\n", .{@tagName(item.node)});
        if (shell == .bash) {
            try w.writeAll("      while IFS= read -r word; do COMPREPLY+=(\"$word\"); done < <(compgen -W '");
            try writeWordList(w, item.node);
            try w.writeAll("' -- \"$cur\")\n");
        } else {
            try w.writeAll("      candidates=(\n");
            try describeCandidate(w, "--help", "Show help for this command", false);
            for (spec.commands) |child| {
                if (child.parent == item.node) try describeCandidate(w, child.name, child.description, false);
            }
            if (item.command) |command| {
                for (spec.flags) |flag| {
                    if (completionFlagAllowed(flag, command)) try describeCandidate(w, flag.name, flag.description, flag.unavailable);
                }
            }
            try w.writeAll("      )\n      _describe 'command or option' candidates\n");
        }
        try w.writeAll("      ;;\n");
    }
    try w.writeAll("  esac\n}\n");
    try w.writeAll(if (shell == .bash) "complete -F _dragontool dragontool\n" else "_dragontool \"$@\"\n");
}

fn fishCondition(w: *std.Io.Writer, node: spec.Node) !void {
    try w.print("complete -c dragontool -n '__dragontool_context {s}'", .{@tagName(node)});
}

fn renderFish(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# Generated from DragonTools CLI metadata; local and side-effect free.
        \\function __dragontool_context
        \\    # Tokenize without expanding variables, globs or command substitutions.
        \\    # -o also works in Fish 3.x; option values are skipped, never evaluated.
        \\    set -l tokens (commandline -opc)
        \\    set -l state root
        \\    set -l expect ''
        \\    for word in $tokens[2..-1]
        \\        if test -n "$expect"
        \\            set expect ''
        \\            continue
        \\        end
        \\        switch "$state:$word"
        \\
    );
    for (spec.commands) |item| {
        if (item.parent) |parent| {
            try w.writeAll("            case ");
            try key(w, parent, item.name, .fish);
            try w.print("\n                set state {s}\n", .{@tagName(item.node)});
        }
        try w.writeAll("            case ");
        try key(w, item.node, "--help", .fish);
        try w.writeAll("\n                continue\n");
        if (item.command) |command| {
            for (spec.flags) |flag| {
                if (!completionFlagAllowed(flag, command)) continue;
                try w.writeAll("            case ");
                try key(w, item.node, flag.name, .fish);
                if (flag.kind == .boolean) {
                    try w.writeAll("\n                continue\n");
                } else {
                    try w.writeAll("\n                set expect ");
                    try quote(w, flag.name, .fish);
                    try w.writeByte('\n');
                }
            }
        }
    }
    try w.writeAll("            case '*'\n                return 1\n        end\n    end\n    test \"$state\" = \"$argv[1]\"\nend\n\ncomplete -c dragontool -f\n");
    for (spec.commands) |item| {
        if (item.parent) |parent| {
            try fishCondition(w, parent);
            try w.writeAll(" -a ");
            try quote(w, item.name, .fish);
            try w.writeAll(" -d ");
            try quote(w, item.description, .fish);
            try w.writeByte('\n');
        }
        try fishCondition(w, item.node);
        try w.writeAll(" -l help -d 'Show help for this command'\n");
        if (item.command) |command| {
            for (spec.flags) |flag| {
                if (!completionFlagAllowed(flag, command)) continue;
                try fishCondition(w, item.node);
                try w.writeAll(" -l ");
                try quote(w, flag.name[2..], .fish);
                if (flag.kind != .boolean) try w.writeAll(if (flag.kind == .path) " -r -F" else " -x");
                if (flag.values.len > 0) {
                    try w.writeAll(" -a '");
                    try writeValues(w, flag);
                    try w.writeByte('\'');
                }
                try w.writeAll(" -d '");
                try quoteContent(w, flag.description, .fish);
                if (flag.unavailable) try w.writeAll(" [unavailable]");
                try w.writeAll("'\n");
            }
        }
    }
}

test "shell completion encodes the nested tree and contextual flags" {
    const a = std.testing.allocator;
    for ([_]spec.Shell{ .bash, .zsh, .fish }) |shell| {
        const output = try render(a, shell);
        defer a.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "'root:monitoring'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'root:host'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'host:install-oh-my-zsh'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--ssh-host'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--target-user'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--set-default-shell'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--update-managed-zshrc'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--set-default-shell'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--update-managed-zshrc'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--tls'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--ssh-host'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--config'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'verify:--config'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'status:--config'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--grafana-user-op'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'verify:--grafana-password-op'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'status:--grafana-password-op'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install_oh_my_zsh:--config'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'monitoring:agents'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'agents:install'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'install:--tls'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'verify:--tls'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'agents_install:--service'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'agents_install:--metrics-target'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'agents_status:--station'") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "'status:--plan'") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "ssh -") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "op read") == null);
    }
}

test "bash completion provides enum values and native paths" {
    const a = std.testing.allocator;
    const output = try render(a, .bash);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "compgen -W 'manual cloudflare'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "compgen -f --") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "complete -F _dragontool dragontool") != null);
}

test "zsh completion supplies descriptions enum choices and native paths" {
    const a = std.testing.allocator;
    const output = try render(a, .zsh);
    defer a.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "#compdef dragontool\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "candidates=('manual' 'cloudflare' ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_files\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_describe 'command or option'") != null);
}

test "fish completion declares constrained values and forces native path completion" {
    const a = std.testing.allocator;
    const output = try render(a, .fish);
    defer a.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "commandline -opc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "commandline -xpc") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__dragontool_context install' -l 'tls' -x -a 'manual cloudflare'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__dragontool_context install' -l 'identity' -r -F") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__dragontool_context install' -l 'config' -r -F") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__dragontool_context verify' -l 'tls'") == null);
}
