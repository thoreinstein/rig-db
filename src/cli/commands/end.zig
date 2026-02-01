const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const uuid = @import("../uuid.zig");
const client = @import("../client.zig");
const fallback = @import("../fallback.zig");
const protocol = @import("../../daemon/protocol.zig");

/// Errors specific to the end command
pub const EndError = error{
    MissingIdArg,
    MissingExitArg,
    InvalidExitCode,
    InvalidUuid,
    ConnectionFailed,
    SendFailed,
};

/// Run the 'rig history end' command.
/// Called by shell post-exec hook after command completes.
/// Records duration and exit code.
///
/// Usage: rig history end --id <uuid> --exit <code>
///
/// This command is designed for fire-and-forget operation:
/// - Handles missing arguments gracefully (no crash, no output)
/// - Completes quickly (<5ms target)
/// - Works even if start was never recorded
/// - Returns immediately after send (does not wait for confirmation)
pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // 1. Parse --id and --exit from args
    // Handle missing args gracefully (no crash, silent return)
    const parsed = parseArgs(args) catch {
        return;
    };

    // 2. Extract timestamp from UUID v7
    const parsed_uuid = uuid.Uuid7.fromString(parsed.id) catch {
        // Invalid UUID format - silently return
        return;
    };

    // 3. Calculate duration = now - uuid_timestamp
    const uuid_timestamp_ms = parsed_uuid.getTimestamp();
    const current_ns = std.time.nanoTimestamp();
    const uuid_timestamp_ns = @as(i128, uuid_timestamp_ms) * std.time.ns_per_ms;
    const duration_ns: i64 = @intCast(@max(0, current_ns - uuid_timestamp_ns));

    // 4. Send to daemon via client (fire-and-forget)
    const end_msg = protocol.EndMessage{
        .id = parsed.id,
        .exit = parsed.exit_code,
        .duration = duration_ns,
    };

    var cli = client.Client.connect(allocator) catch {
        // Connection failed - write to fallback log
        writeFallbackEnd(end_msg, allocator);
        return;
    };
    defer cli.close();

    // Send and ignore response (fire-and-forget)
    _ = cli.sendEnd(end_msg) catch {
        // Send failed - write to fallback log
        writeFallbackEnd(end_msg, allocator);
        return;
    };

    // 5. Silent success (no output)
}

/// Write an end message to the fallback log when daemon is unreachable
fn writeFallbackEnd(msg: protocol.EndMessage, allocator: Allocator) void {
    const item = fallback.FallbackItem{
        .end = msg,
    };

    fallback.writeToFallback(allocator, item) catch {
        // Last resort fallback failed - data loss unavoidable
        // Silent failure for fire-and-forget semantics
    };
}

/// Parsed arguments for the end command
const ParsedArgs = struct {
    id: []const u8,
    exit_code: i32,
};

/// Parse command line arguments for --id and --exit
fn parseArgs(args: []const []const u8) EndError!ParsedArgs {
    var id: ?[]const u8 = null;
    var exit_code: ?i32 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, arg, "--id")) {
            if (i + 1 >= args.len) {
                return EndError.MissingIdArg;
            }
            i += 1;
            id = args[i];
        } else if (mem.startsWith(u8, arg, "--id=")) {
            id = arg["--id=".len..];
        } else if (mem.eql(u8, arg, "--exit")) {
            if (i + 1 >= args.len) {
                return EndError.MissingExitArg;
            }
            i += 1;
            exit_code = std.fmt.parseInt(i32, args[i], 10) catch {
                return EndError.InvalidExitCode;
            };
        } else if (mem.startsWith(u8, arg, "--exit=")) {
            const exit_str = arg["--exit=".len..];
            exit_code = std.fmt.parseInt(i32, exit_str, 10) catch {
                return EndError.InvalidExitCode;
            };
        }
    }

    if (id == null) {
        return EndError.MissingIdArg;
    }
    if (exit_code == null) {
        return EndError.MissingExitArg;
    }

    return ParsedArgs{
        .id = id.?,
        .exit_code = exit_code.?,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "parseArgs extracts --id and --exit correctly" {
    const args = &[_][]const u8{ "--id", "01894c77-7b1c-7234-89ab-cdef01234567", "--exit", "0" };
    const parsed = try parseArgs(args);

    try std.testing.expectEqualStrings("01894c77-7b1c-7234-89ab-cdef01234567", parsed.id);
    try std.testing.expectEqual(@as(i32, 0), parsed.exit_code);
}

test "parseArgs extracts --id= and --exit= syntax" {
    const args = &[_][]const u8{ "--id=test-uuid", "--exit=42" };
    const parsed = try parseArgs(args);

    try std.testing.expectEqualStrings("test-uuid", parsed.id);
    try std.testing.expectEqual(@as(i32, 42), parsed.exit_code);
}

test "parseArgs handles mixed syntax" {
    const args = &[_][]const u8{ "--exit", "1", "--id=my-uuid" };
    const parsed = try parseArgs(args);

    try std.testing.expectEqualStrings("my-uuid", parsed.id);
    try std.testing.expectEqual(@as(i32, 1), parsed.exit_code);
}

test "parseArgs returns MissingIdArg when id missing" {
    const args = &[_][]const u8{ "--exit", "0" };
    const result = parseArgs(args);

    try std.testing.expectError(EndError.MissingIdArg, result);
}

test "parseArgs returns MissingExitArg when exit missing" {
    const args = &[_][]const u8{ "--id", "test-uuid" };
    const result = parseArgs(args);

    try std.testing.expectError(EndError.MissingExitArg, result);
}

test "parseArgs returns InvalidExitCode for non-numeric exit" {
    const args = &[_][]const u8{ "--id", "test-uuid", "--exit", "abc" };
    const result = parseArgs(args);

    try std.testing.expectError(EndError.InvalidExitCode, result);
}

test "parseArgs handles negative exit codes" {
    const args = &[_][]const u8{ "--id", "test-uuid", "--exit", "-1" };
    const parsed = try parseArgs(args);

    try std.testing.expectEqual(@as(i32, -1), parsed.exit_code);
}

test "parseArgs handles empty args" {
    const args = &[_][]const u8{};
    const result = parseArgs(args);

    try std.testing.expectError(EndError.MissingIdArg, result);
}

test "duration calculation from UUID timestamp" {
    // This test verifies the duration calculation logic conceptually.
    // Create a UUID with a known timestamp (1700000000028 ms = ~2023-11-14)
    var test_uuid: uuid.Uuid7 = undefined;
    test_uuid.bytes = .{ 0x01, 0x89, 0x4c, 0x77, 0x7b, 0x1c, 0x72, 0x34, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 };

    const uuid_timestamp_ms = test_uuid.getTimestamp();
    try std.testing.expectEqual(@as(i64, 0x01894c777b1c), uuid_timestamp_ms);

    // Verify conversion to nanoseconds
    const uuid_timestamp_ns = @as(i128, uuid_timestamp_ms) * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(i128, 0x01894c777b1c) * 1_000_000, uuid_timestamp_ns);
}
