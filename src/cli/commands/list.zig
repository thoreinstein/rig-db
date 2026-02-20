const std = @import("std");
const mem = std.mem;
const reader_mod = @import("../../tui/reader.zig");
const history = @import("../../db/history.zig");

/// Errors specific to the list command
pub const ListError = error{
    InvalidLimit,
};

/// Run the 'rigdb history list' command.
/// Lists recent history entries to stdout.
pub fn run(allocator: mem.Allocator, args: []const []const u8, writer: anytype) !void {
    const opts = parseArgs(args) catch {
        _ = try writer.write("Error: --limit must be a positive integer\n");
        return;
    };

    // Open database read-only
    var reader = reader_mod.HistoryReader.open(allocator) catch |err| {
        switch (err) {
            reader_mod.ReaderError.DatabaseNotFound => {
                _ = try writer.write("No history recorded yet.\n");
                return;
            },
            else => {
                _ = try writer.write("Error: Failed to open history database\n");
                return;
            },
        }
    };
    defer reader.close();

    // Build query params with null-terminated strings for SQLite
    var pattern_buf: [512]u8 = undefined;
    var pattern: ?[:0]const u8 = null;
    if (opts.pattern) |p| {
        const formatted = std.fmt.bufPrintZ(&pattern_buf, "%{s}%", .{p}) catch {
            _ = try writer.write("Error: Pattern too long\n");
            return;
        };
        pattern = formatted;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_filter: ?[:0]const u8 = null;
    if (opts.cwd) |c| {
        const formatted = std.fmt.bufPrintZ(&cwd_buf, "{s}", .{c}) catch {
            _ = try writer.write("Error: CWD path too long\n");
            return;
        };
        cwd_filter = formatted;
    }

    var results = reader.query(.{
        .command_pattern = pattern,
        .cwd = cwd_filter,
        .limit = opts.limit,
        .include_deleted = false,
    }) catch {
        _ = try writer.write("Error: Query failed\n");
        return;
    };
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    if (results.items.len == 0) {
        _ = try writer.write("No matching history entries.\n");
        return;
    }

    for (results.items) |record| {
        _ = try writer.write(record.command);
        _ = try writer.write("\n");
    }
}

const ListOptions = struct {
    limit: u32 = 25,
    pattern: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) ListError!ListOptions {
    var opts = ListOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--limit") or mem.eql(u8, arg, "-n")) {
            if (i + 1 >= args.len) return ListError.InvalidLimit;
            i += 1;
            opts.limit = std.fmt.parseInt(u32, args[i], 10) catch return ListError.InvalidLimit;
        } else if (mem.eql(u8, arg, "--cwd")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.cwd = args[i];
            }
        } else if (mem.eql(u8, arg, "--pattern") or mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.pattern = args[i];
            }
        }
    }
    return opts;
}

// =============================================================================
// Tests
// =============================================================================

test "parseArgs default values" {
    const args = [_][]const u8{};
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 25), opts.limit);
    try std.testing.expect(opts.pattern == null);
    try std.testing.expect(opts.cwd == null);
}

test "parseArgs limit flag" {
    const args = [_][]const u8{ "--limit", "50" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 50), opts.limit);
}

test "parseArgs short limit flag" {
    const args = [_][]const u8{ "-n", "10" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 10), opts.limit);
}

test "parseArgs pattern flag" {
    const args = [_][]const u8{ "--pattern", "git" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("git", opts.pattern.?);
}

test "parseArgs cwd flag" {
    const args = [_][]const u8{ "--cwd", "/home/user" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("/home/user", opts.cwd.?);
}

test "parseArgs invalid limit" {
    const args = [_][]const u8{ "--limit", "abc" };
    const result = parseArgs(&args);
    try std.testing.expectError(ListError.InvalidLimit, result);
}

test "parseArgs combined flags" {
    const args = [_][]const u8{ "-n", "20", "--pattern", "docker", "--cwd", "/tmp" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 20), opts.limit);
    try std.testing.expectEqualStrings("docker", opts.pattern.?);
    try std.testing.expectEqualStrings("/tmp", opts.cwd.?);
}
