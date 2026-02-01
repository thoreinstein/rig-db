const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout_file = std.fs.File.stdout();
    var buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.Writer.init(stdout_file, &buffer);
    defer stdout.interface.flush() catch {};

    if (args.len < 2) {
        try printUsage(&stdout.interface);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(&stdout.interface);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion(&stdout.interface);
    } else if (std.mem.eql(u8, command, "history")) {
        try runHistoryCommand(allocator, args[2..], &stdout.interface);
    } else if (std.mem.eql(u8, command, "init")) {
        try runInitCommand(args[2..], &stdout.interface);
    } else {
        try stdout.interface.print("Unknown command: {s}\n", .{command});
        try printUsage(&stdout.interface);
        std.process.exit(1);
    }
}

fn printUsage(writer: *std.Io.Writer) !void {
    _ = try writer.write(
        \\rig-db - A database CLI tool
        \\
        \\Usage:
        \\  rig-db <command> [options]
        \\
        \\Commands:
        \\  init <shell>           Generate shell integration script (zsh, bash)
        \\  history <subcommand>   Shell history tracking
        \\  help, --help, -h       Show this help message
        \\  version, --version, -v Show version information
        \\
        \\Examples:
        \\  rig-db help
        \\  rig-db version
        \\  rig-db init zsh
        \\  rig-db history start -- "ls -la"
        \\
    );
}

fn printVersion(writer: *std.Io.Writer) !void {
    _ = try writer.write("rig-db version 0.1.0\n");
}

/// Handle history subcommands
fn runHistoryCommand(allocator: std.mem.Allocator, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len == 0) {
        try printHistoryUsage(writer);
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "start")) {
        // Run the start command with remaining args
        commands.start.run(allocator, args) catch |err| {
            switch (err) {
                commands.start.StartError.MissingCommand => {
                    _ = try writer.write("Error: Missing command after 'rig history start --'\n");
                    try printHistoryUsage(writer);
                    std.process.exit(1);
                },
                commands.start.StartError.CwdFailed => {
                    _ = try writer.write("Error: Failed to get current working directory\n");
                    std.process.exit(1);
                },
                commands.start.StartError.HostnameFailed => {
                    _ = try writer.write("Error: Failed to get hostname\n");
                    std.process.exit(1);
                },
                else => {
                    _ = try writer.write("Error: Command execution failed\n");
                    std.process.exit(1);
                },
            }
        };
    } else if (std.mem.eql(u8, subcommand, "end")) {
        // Run the end command with remaining args (fire-and-forget, silent)
        commands.end.run(allocator, args[1..]) catch {
            // Silent failure for end command (fire-and-forget semantics)
        };
    } else if (std.mem.eql(u8, subcommand, "help") or std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        try printHistoryUsage(writer);
    } else {
        try writer.print("Unknown history subcommand: {s}\n", .{subcommand});
        try printHistoryUsage(writer);
        std.process.exit(1);
    }
}

/// Handle init subcommands
fn runInitCommand(args: []const []const u8, writer: *std.Io.Writer) !void {
    commands.init.run(args, writer) catch |err| {
        switch (err) {
            commands.init.InitError.UnknownShell => {
                if (args.len > 0) {
                    try writer.print("Unknown shell: {s}\n", .{args[0]});
                }
                _ = try writer.write("Supported shells: zsh, bash\n");
                std.process.exit(1);
            },
            else => {
                _ = try writer.write("Error: Failed to generate init script\n");
                std.process.exit(1);
            },
        }
    };
}

fn printHistoryUsage(writer: *std.Io.Writer) !void {
    _ = try writer.write(
        \\rig-db history - Shell history tracking
        \\
        \\Usage:
        \\  rig-db history <subcommand> [options]
        \\
        \\Subcommands:
        \\  start -- <command>          Record start of a shell command (pre-exec hook)
        \\  end --id <uuid> --exit <n>  Record end of a shell command (post-exec hook)
        \\  help                        Show this help message
        \\
        \\Examples:
        \\  rig-db history start -- "ls -la"
        \\  rig-db history end --id 01234567-89ab-cdef-0123-456789abcdef --exit 0
        \\
        \\The start command outputs a UUID that should be captured and passed
        \\to 'rig history end' when the command completes.
        \\
    );
}

// Database modules
pub const db = @import("db/sqlite.zig");
pub const schema = @import("db/schema.zig");
pub const history = @import("db/history.zig");
pub const paths = @import("paths.zig");

// Daemon modules
pub const daemon = struct {
    pub const server = @import("daemon/server.zig");
    pub const lifecycle = @import("daemon/lifecycle.zig");
    pub const protocol = @import("daemon/protocol.zig");
    pub const queue = @import("daemon/queue.zig");
    pub const writer = @import("daemon/writer.zig");
};

// TUI modules
pub const terminal = @import("tui/terminal.zig");
pub const tui_reader = @import("tui/reader.zig");
pub const tui_search = @import("tui/search.zig");
pub const tui_display = @import("tui/display.zig");

// CLI modules
pub const cli = struct {
    pub const client = @import("cli/client.zig");
    pub const uuid = @import("cli/uuid.zig");
    pub const fallback = @import("cli/fallback.zig");
};

// CLI command modules
pub const commands = struct {
    pub const start = @import("cli/commands/start.zig");
    pub const end = @import("cli/commands/end.zig");
    pub const init = @import("cli/commands/init.zig");
};

test "basic functionality" {
    const expect = std.testing.expect;
    try expect(true);
}

test {
    // Reference all tests in submodules
    std.testing.refAllDecls(@This());
}
