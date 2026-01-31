const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(stdout);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try printVersion(stdout);
    } else {
        try stdout.print("Unknown command: {s}\n", .{command});
        try printUsage(stdout);
        std.process.exit(1);
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\rig-db - A database CLI tool
        \\
        \\Usage:
        \\  rig-db <command> [options]
        \\
        \\Commands:
        \\  help, --help, -h       Show this help message
        \\  version, --version, -v Show version information
        \\
        \\Examples:
        \\  rig-db help
        \\  rig-db version
        \\
    );
}

fn printVersion(writer: anytype) !void {
    try writer.writeAll("rig-db version 0.1.0\n");
}

test "basic functionality" {
    const expect = std.testing.expect;
    try expect(true);
}
