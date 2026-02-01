const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;

const uuid = @import("../uuid.zig");
const client = @import("../client.zig");
const fallback = @import("../fallback.zig");
const protocol = @import("../../daemon/protocol.zig");

/// Errors specific to the start command
pub const StartError = error{
    /// No command provided after --
    MissingCommand,
    /// Failed to get current working directory
    CwdFailed,
    /// Failed to get hostname
    HostnameFailed,
    /// Failed to write to stdout
    WriteFailed,
    /// Memory allocation failed
    OutOfMemory,
};

/// Run the 'rig history start' command.
/// Generates a UUID v7, captures command context, sends to daemon, prints UUID.
///
/// Args format: ["start", "--", "command", "arg1", "arg2", ...]
/// The command string after -- is joined with spaces.
pub fn run(allocator: mem.Allocator, args: []const []const u8) !void {
    // Parse command from args (everything after --)
    const command = try parseCommand(args);

    // Generate UUID v7 for this command execution
    const cmd_uuid = uuid.Uuid7.generate();
    var uuid_str: [36]u8 = undefined;
    cmd_uuid.toString(&uuid_str);

    // Get current working directory
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&cwd_buf) catch {
        return StartError.CwdFailed;
    };

    // Get hostname
    var hostname_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = posix.gethostname(&hostname_buf) catch {
        return StartError.HostnameFailed;
    };

    // Get session UUID from environment, or generate one
    const session_env = posix.getenv("RIG_SESSION");
    var session_uuid_buf: [36]u8 = undefined;
    const session: []const u8 = if (session_env) |s| s else blk: {
        // Generate a new session UUID - suggest user set it
        const session_uuid = uuid.Uuid7.generate();
        session_uuid.toString(&session_uuid_buf);
        break :blk &session_uuid_buf;
    };

    // Get current timestamp in milliseconds
    const timestamp_ms = std.time.milliTimestamp();

    // Create start message
    const start_msg = protocol.StartMessage{
        .id = &uuid_str,
        .cmd = command,
        .ts = timestamp_ms,
        .cwd = cwd,
        .session = session,
        .hostname = hostname,
    };

    // Try to connect and send to daemon
    var connect_result = client.Client.connect(allocator);
    if (connect_result) |*c| {
        defer c.close();

        // Send the start message
        const response = c.sendStart(start_msg) catch {
            // Write to fallback log when daemon communication fails
            writeFallbackStart(&uuid_str, command, cwd, session, hostname, timestamp_ms, allocator);
            printUuid(&uuid_str) catch return StartError.WriteFailed;
            return; // Exit gracefully, command was recorded to fallback
        };

        if (!response.ok) {
            // Write to fallback log when daemon returns error
            writeFallbackStart(&uuid_str, command, cwd, session, hostname, timestamp_ms, allocator);
        }
    } else |_| {
        // Write to fallback log when daemon is unreachable
        writeFallbackStart(&uuid_str, command, cwd, session, hostname, timestamp_ms, allocator);
    }

    // Always print UUID to stdout
    printUuid(&uuid_str) catch return StartError.WriteFailed;
}

/// Write a start message to the fallback log when daemon is unreachable
fn writeFallbackStart(
    uuid_str: *const [36]u8,
    command: []const u8,
    cwd: []const u8,
    session: []const u8,
    hostname: []const u8,
    timestamp_ms: i64,
    allocator: mem.Allocator,
) void {
    const item = fallback.FallbackItem{
        .start = protocol.StartMessage{
            .id = uuid_str,
            .cmd = command,
            .ts = timestamp_ms,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    fallback.writeToFallback(allocator, item) catch {
        // Last resort fallback failed - data loss unavoidable
        std.log.warn("rig: fallback write failed, command not recorded", .{});
    };
}

/// Parse the command string from arguments.
/// Expects args format: ["start", "--", "command..."] or ["start", "command..."]
/// Returns the command string (everything after -- if present, or first arg after "start").
fn parseCommand(args: []const []const u8) StartError![]const u8 {
    if (args.len == 0) {
        return StartError.MissingCommand;
    }

    // Find the command - skip "start" and optional "--"
    var start_idx: usize = 0;

    // Skip "start" if present
    if (args.len > 0 and mem.eql(u8, args[0], "start")) {
        start_idx = 1;
    }

    // Skip "--" if present
    if (args.len > start_idx and mem.eql(u8, args[start_idx], "--")) {
        start_idx += 1;
    }

    // Remaining args form the command
    if (start_idx >= args.len) {
        return StartError.MissingCommand;
    }

    // For shell commands, the entire command is typically passed as a single arg
    // by the shell hook: rig history start -- "$command"
    // So we just return the first arg after --
    return args[start_idx];
}

/// Print UUID to stdout followed by newline.
fn printUuid(uuid_str: *const [36]u8) !void {
    const stdout_file = std.fs.File.stdout();
    var buffer: [128]u8 = undefined;
    var stdout = std.fs.File.Writer.init(stdout_file, &buffer);
    defer stdout.interface.flush() catch {};
    try stdout.interface.writeAll(uuid_str);
    try stdout.interface.writeAll("\n");
}

// =============================================================================
// Tests
// =============================================================================

test "parseCommand extracts command after --" {
    const args = [_][]const u8{ "start", "--", "ls -la" };
    const cmd = try parseCommand(&args);
    try std.testing.expectEqualStrings("ls -la", cmd);
}

test "parseCommand extracts command without --" {
    const args = [_][]const u8{ "start", "git status" };
    const cmd = try parseCommand(&args);
    try std.testing.expectEqualStrings("git status", cmd);
}

test "parseCommand handles just command" {
    const args = [_][]const u8{"echo hello"};
    const cmd = try parseCommand(&args);
    try std.testing.expectEqualStrings("echo hello", cmd);
}

test "parseCommand returns error for empty args" {
    const args = [_][]const u8{};
    const result = parseCommand(&args);
    try std.testing.expectError(StartError.MissingCommand, result);
}

test "parseCommand returns error for just start" {
    const args = [_][]const u8{"start"};
    const result = parseCommand(&args);
    try std.testing.expectError(StartError.MissingCommand, result);
}

test "parseCommand returns error for start with only --" {
    const args = [_][]const u8{ "start", "--" };
    const result = parseCommand(&args);
    try std.testing.expectError(StartError.MissingCommand, result);
}

test "parseCommand handles special characters in command" {
    const args = [_][]const u8{ "start", "--", "echo 'hello \"world\"' | grep hello" };
    const cmd = try parseCommand(&args);
    try std.testing.expectEqualStrings("echo 'hello \"world\"' | grep hello", cmd);
}

test "parseCommand handles unicode in command" {
    const args = [_][]const u8{ "start", "--", "echo \xe4\xb8\xad\xe6\x96\x87" };
    const cmd = try parseCommand(&args);
    try std.testing.expectEqualStrings("echo \xe4\xb8\xad\xe6\x96\x87", cmd);
}
