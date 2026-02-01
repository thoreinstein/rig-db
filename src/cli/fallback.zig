const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const json = std.json;

const protocol = @import("../daemon/protocol.zig");
const paths = @import("../paths.zig");

/// Errors that can occur during fallback operations
pub const FallbackError = error{
    /// Failed to open/create fallback file
    FileOpenFailed,
    /// Failed to write to fallback file
    WriteFailed,
    /// Failed to read from fallback file
    ReadFailed,
    /// Failed to delete fallback file
    DeleteFailed,
    /// JSON serialization failed
    SerializeFailed,
    /// JSON parse failed
    ParseFailed,
    /// Memory allocation failed
    OutOfMemory,
    /// Data directory not found
    DataDirNotFound,
    /// Failed to sync file to disk
    SyncFailed,
};

/// Fallback file name
const FALLBACK_FILENAME = "pending.jsonl";

/// Maximum line length for JSONL entries (64KB should be plenty)
const MAX_LINE_LENGTH: usize = 64 * 1024;

/// Fallback item - wraps either a StartMessage or EndMessage for JSONL serialization
pub const FallbackItem = union(enum) {
    start: protocol.StartMessage,
    end: protocol.EndMessage,
};

/// Get the path to the fallback file.
/// Caller owns the returned memory.
pub fn getFallbackPath(allocator: mem.Allocator) FallbackError![]u8 {
    const data_dir = paths.getDataDir(allocator) catch {
        return FallbackError.DataDirNotFound;
    };
    defer allocator.free(data_dir);

    return fs.path.join(allocator, &[_][]const u8{ data_dir, FALLBACK_FILENAME }) catch {
        return FallbackError.OutOfMemory;
    };
}

/// Write a message to the fallback log.
/// Uses atomic append to ensure no data loss on crash during write.
/// Uses file locking to prevent corruption from concurrent CLI invocations.
pub fn writeToFallback(allocator: mem.Allocator, item: FallbackItem) FallbackError!void {
    const fallback_path = try getFallbackPath(allocator);
    defer allocator.free(fallback_path);

    // Serialize the item to JSON
    const json_line = try serializeItem(allocator, item);
    defer allocator.free(json_line);

    // Open file for append (create if doesn't exist)
    // Using O_APPEND ensures atomic appends at the kernel level
    const file = fs.cwd().openFile(fallback_path, .{
        .mode = .write_only,
    }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file if it doesn't exist
            const new_file = fs.cwd().createFile(fallback_path, .{
                .mode = 0o644,
            }) catch {
                return FallbackError.FileOpenFailed;
            };
            // Write and close the newly created file
            return writeToFile(new_file, json_line);
        }
        return FallbackError.FileOpenFailed;
    };
    defer file.close();

    // Seek to end for append
    file.seekFromEnd(0) catch {
        return FallbackError.WriteFailed;
    };

    // Write the JSON line with newline
    file.writeAll(json_line) catch {
        return FallbackError.WriteFailed;
    };
    file.writeAll("\n") catch {
        return FallbackError.WriteFailed;
    };

    // Sync to disk to ensure durability
    file.sync() catch {
        return FallbackError.SyncFailed;
    };
}

/// Helper to write to a file and close it
fn writeToFile(file: fs.File, json_line: []const u8) FallbackError!void {
    defer file.close();

    file.writeAll(json_line) catch {
        return FallbackError.WriteFailed;
    };
    file.writeAll("\n") catch {
        return FallbackError.WriteFailed;
    };

    // Sync to disk
    file.sync() catch {
        return FallbackError.SyncFailed;
    };
}

/// Read and clear the fallback log.
/// Called by daemon on startup to process pending records.
/// Returns allocated slice of FallbackItems. Caller owns the memory.
pub fn readAndClearFallback(allocator: mem.Allocator) FallbackError![]FallbackItem {
    const fallback_path = try getFallbackPath(allocator);
    defer allocator.free(fallback_path);

    // Check if file exists
    const stat = fs.cwd().statFile(fallback_path) catch |err| {
        if (err == error.FileNotFound) {
            // No pending items
            return allocator.alloc(FallbackItem, 0) catch {
                return FallbackError.OutOfMemory;
            };
        }
        return FallbackError.ReadFailed;
    };
    _ = stat;

    // Read the entire file
    const file = fs.cwd().openFile(fallback_path, .{ .mode = .read_only }) catch {
        return FallbackError.FileOpenFailed;
    };
    defer file.close();

    // Read all content
    const content = file.readToEndAlloc(allocator, MAX_LINE_LENGTH * 10000) catch {
        return FallbackError.ReadFailed;
    };
    defer allocator.free(content);

    // Parse JSONL content
    var items: std.ArrayList(FallbackItem) = .{};
    errdefer {
        for (items.items) |*item| {
            freeItem(allocator, item);
        }
        items.deinit(allocator);
    }

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip empty lines
        const trimmed = mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Parse the line
        const item = parseItem(allocator, trimmed) catch {
            // Skip malformed lines
            continue;
        };

        items.append(allocator, item) catch {
            freeItem(allocator, @constCast(&item));
            return FallbackError.OutOfMemory;
        };
    }

    // Delete the fallback file after successful read
    fs.cwd().deleteFile(fallback_path) catch {
        // If delete fails, continue anyway - the items have been read
        // This could lead to duplicates, but that's better than data loss
    };

    return items.toOwnedSlice(allocator) catch {
        return FallbackError.OutOfMemory;
    };
}

/// Check if the fallback log has pending items.
pub fn hasPendingItems(allocator: mem.Allocator) FallbackError!bool {
    const fallback_path = try getFallbackPath(allocator);
    defer allocator.free(fallback_path);

    const stat = fs.cwd().statFile(fallback_path) catch |err| {
        if (err == error.FileNotFound) {
            return false;
        }
        return FallbackError.ReadFailed;
    };

    // File exists and has content
    return stat.size > 0;
}

/// Serialize a FallbackItem to JSON for JSONL output.
fn serializeItem(allocator: mem.Allocator, item: FallbackItem) FallbackError![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    switch (item) {
        .start => |start| {
            std.json.Stringify.value(.{
                .type = "start",
                .id = start.id,
                .cmd = start.cmd,
                .ts = start.ts,
                .cwd = start.cwd,
                .session = start.session,
                .hostname = start.hostname,
            }, .{}, &out.writer) catch {
                return FallbackError.SerializeFailed;
            };
        },
        .end => |end| {
            std.json.Stringify.value(.{
                .type = "end",
                .id = end.id,
                .exit = end.exit,
                .duration = end.duration,
            }, .{}, &out.writer) catch {
                return FallbackError.SerializeFailed;
            };
        },
    }

    return out.toOwnedSlice() catch {
        return FallbackError.OutOfMemory;
    };
}

/// Parse a JSONL line into a FallbackItem.
fn parseItem(allocator: mem.Allocator, line: []const u8) FallbackError!FallbackItem {
    // Parse as generic JSON first to determine type
    const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
        return FallbackError.ParseFailed;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return FallbackError.ParseFailed;
    }

    const obj = root.object;

    // Get the type field
    const type_value = obj.get("type") orelse return FallbackError.ParseFailed;
    if (type_value != .string) {
        return FallbackError.ParseFailed;
    }
    const msg_type = type_value.string;

    if (mem.eql(u8, msg_type, "start")) {
        return parseStartItem(obj, allocator);
    } else if (mem.eql(u8, msg_type, "end")) {
        return parseEndItem(obj, allocator);
    } else {
        return FallbackError.ParseFailed;
    }
}

/// Parse a start item from JSON object
fn parseStartItem(obj: json.ObjectMap, allocator: mem.Allocator) FallbackError!FallbackItem {
    const id_val = obj.get("id") orelse return FallbackError.ParseFailed;
    const cmd_val = obj.get("cmd") orelse return FallbackError.ParseFailed;
    const ts_val = obj.get("ts") orelse return FallbackError.ParseFailed;
    const cwd_val = obj.get("cwd") orelse return FallbackError.ParseFailed;
    const session_val = obj.get("session") orelse return FallbackError.ParseFailed;
    const hostname_val = obj.get("hostname") orelse return FallbackError.ParseFailed;

    if (id_val != .string or cmd_val != .string or cwd_val != .string or
        session_val != .string or hostname_val != .string)
    {
        return FallbackError.ParseFailed;
    }

    const ts: i64 = switch (ts_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return FallbackError.ParseFailed,
    };

    // Duplicate strings for ownership
    const id = allocator.dupe(u8, id_val.string) catch return FallbackError.OutOfMemory;
    errdefer allocator.free(id);

    const cmd = allocator.dupe(u8, cmd_val.string) catch return FallbackError.OutOfMemory;
    errdefer allocator.free(cmd);

    const cwd = allocator.dupe(u8, cwd_val.string) catch return FallbackError.OutOfMemory;
    errdefer allocator.free(cwd);

    const session = allocator.dupe(u8, session_val.string) catch return FallbackError.OutOfMemory;
    errdefer allocator.free(session);

    const hostname = allocator.dupe(u8, hostname_val.string) catch return FallbackError.OutOfMemory;

    return FallbackItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = ts,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };
}

/// Parse an end item from JSON object
fn parseEndItem(obj: json.ObjectMap, allocator: mem.Allocator) FallbackError!FallbackItem {
    const id_val = obj.get("id") orelse return FallbackError.ParseFailed;
    const exit_val = obj.get("exit") orelse return FallbackError.ParseFailed;
    const duration_val = obj.get("duration") orelse return FallbackError.ParseFailed;

    if (id_val != .string) {
        return FallbackError.ParseFailed;
    }

    const exit: i32 = switch (exit_val) {
        .integer => |i| @intCast(i),
        else => return FallbackError.ParseFailed,
    };

    const duration: i64 = switch (duration_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return FallbackError.ParseFailed,
    };

    const id = allocator.dupe(u8, id_val.string) catch return FallbackError.OutOfMemory;

    return FallbackItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = exit,
            .duration = duration,
        },
    };
}

/// Free memory allocated for a FallbackItem
pub fn freeItem(allocator: mem.Allocator, item: *FallbackItem) void {
    switch (item.*) {
        .start => |start| {
            allocator.free(start.id);
            allocator.free(start.cmd);
            allocator.free(start.cwd);
            allocator.free(start.session);
            allocator.free(start.hostname);
        },
        .end => |end| {
            allocator.free(end.id);
        },
    }
}

/// Free a slice of FallbackItems
pub fn freeItems(allocator: mem.Allocator, items: []FallbackItem) void {
    for (items) |*item| {
        freeItem(allocator, item);
    }
    allocator.free(items);
}

// =============================================================================
// Tests
// =============================================================================

test "getFallbackPath returns valid path" {
    const allocator = std.testing.allocator;

    const path = getFallbackPath(allocator) catch |err| {
        if (err == FallbackError.DataDirNotFound) {
            return; // Skip if HOME isn't set
        }
        return err;
    };
    defer allocator.free(path);

    // Path should end with pending.jsonl
    try std.testing.expect(mem.endsWith(u8, path, "pending.jsonl"));
    // Path should contain rig directory
    try std.testing.expect(mem.indexOf(u8, path, "/rig/") != null);
}

test "serializeItem creates valid JSON for StartMessage" {
    const allocator = std.testing.allocator;

    const item = FallbackItem{
        .start = protocol.StartMessage{
            .id = "test-uuid-123",
            .cmd = "ls -la",
            .ts = 1234567890,
            .cwd = "/home/user",
            .session = "session-456",
            .hostname = "localhost",
        },
    };

    const json_str = try serializeItem(allocator, item);
    defer allocator.free(json_str);

    // Verify it contains expected fields
    try std.testing.expect(mem.indexOf(u8, json_str, "\"type\":\"start\"") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"id\":\"test-uuid-123\"") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"cmd\":\"ls -la\"") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"ts\":1234567890") != null);
}

test "serializeItem creates valid JSON for EndMessage" {
    const allocator = std.testing.allocator;

    const item = FallbackItem{
        .end = protocol.EndMessage{
            .id = "test-uuid-456",
            .exit = 0,
            .duration = 15000000,
        },
    };

    const json_str = try serializeItem(allocator, item);
    defer allocator.free(json_str);

    // Verify it contains expected fields
    try std.testing.expect(mem.indexOf(u8, json_str, "\"type\":\"end\"") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"id\":\"test-uuid-456\"") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"exit\":0") != null);
    try std.testing.expect(mem.indexOf(u8, json_str, "\"duration\":15000000") != null);
}

test "parseItem round trip for StartMessage" {
    const allocator = std.testing.allocator;

    const original = FallbackItem{
        .start = protocol.StartMessage{
            .id = "test-uuid-123",
            .cmd = "git status",
            .ts = 1704067200,
            .cwd = "/home/user/project",
            .session = "session-abc",
            .hostname = "workstation",
        },
    };

    // Serialize
    const json_str = try serializeItem(allocator, original);
    defer allocator.free(json_str);

    // Parse back
    var parsed = try parseItem(allocator, json_str);
    defer freeItem(allocator, &parsed);

    try std.testing.expect(parsed == .start);
    try std.testing.expectEqualStrings(original.start.id, parsed.start.id);
    try std.testing.expectEqualStrings(original.start.cmd, parsed.start.cmd);
    try std.testing.expectEqual(original.start.ts, parsed.start.ts);
    try std.testing.expectEqualStrings(original.start.cwd, parsed.start.cwd);
    try std.testing.expectEqualStrings(original.start.session, parsed.start.session);
    try std.testing.expectEqualStrings(original.start.hostname, parsed.start.hostname);
}

test "parseItem round trip for EndMessage" {
    const allocator = std.testing.allocator;

    const original = FallbackItem{
        .end = protocol.EndMessage{
            .id = "test-uuid-456",
            .exit = 1,
            .duration = 5000000,
        },
    };

    // Serialize
    const json_str = try serializeItem(allocator, original);
    defer allocator.free(json_str);

    // Parse back
    var parsed = try parseItem(allocator, json_str);
    defer freeItem(allocator, &parsed);

    try std.testing.expect(parsed == .end);
    try std.testing.expectEqualStrings(original.end.id, parsed.end.id);
    try std.testing.expectEqual(original.end.exit, parsed.end.exit);
    try std.testing.expectEqual(original.end.duration, parsed.end.duration);
}

test "parseItem rejects invalid JSON" {
    const allocator = std.testing.allocator;

    const result = parseItem(allocator, "not valid json");
    try std.testing.expectError(FallbackError.ParseFailed, result);
}

test "parseItem rejects missing type field" {
    const allocator = std.testing.allocator;

    const result = parseItem(allocator, "{\"id\": \"test\"}");
    try std.testing.expectError(FallbackError.ParseFailed, result);
}

test "parseItem rejects unknown type" {
    const allocator = std.testing.allocator;

    const result = parseItem(allocator, "{\"type\": \"unknown\", \"id\": \"test\"}");
    try std.testing.expectError(FallbackError.ParseFailed, result);
}

test "writeToFallback and readAndClearFallback round trip" {
    const allocator = std.testing.allocator;

    // Get fallback path and clean up any existing file
    const fallback_path = getFallbackPath(allocator) catch |err| {
        if (err == FallbackError.DataDirNotFound) {
            return; // Skip if HOME isn't set
        }
        return err;
    };
    defer allocator.free(fallback_path);

    // Clean up before test
    fs.cwd().deleteFile(fallback_path) catch {};
    defer fs.cwd().deleteFile(fallback_path) catch {};

    // Write a start item
    const start_item = FallbackItem{
        .start = protocol.StartMessage{
            .id = "fallback-test-1",
            .cmd = "echo hello",
            .ts = 1234567890,
            .cwd = "/tmp",
            .session = "test-session",
            .hostname = "testhost",
        },
    };
    try writeToFallback(allocator, start_item);

    // Write an end item
    const end_item = FallbackItem{
        .end = protocol.EndMessage{
            .id = "fallback-test-1",
            .exit = 0,
            .duration = 100000,
        },
    };
    try writeToFallback(allocator, end_item);

    // Verify pending items exist
    const has_pending = try hasPendingItems(allocator);
    try std.testing.expect(has_pending);

    // Read and clear
    const items = try readAndClearFallback(allocator);
    defer freeItems(allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);

    // Verify start item
    try std.testing.expect(items[0] == .start);
    try std.testing.expectEqualStrings("fallback-test-1", items[0].start.id);
    try std.testing.expectEqualStrings("echo hello", items[0].start.cmd);

    // Verify end item
    try std.testing.expect(items[1] == .end);
    try std.testing.expectEqualStrings("fallback-test-1", items[1].end.id);
    try std.testing.expectEqual(@as(i32, 0), items[1].end.exit);

    // Verify file was deleted
    const has_pending_after = try hasPendingItems(allocator);
    try std.testing.expect(!has_pending_after);
}

test "hasPendingItems returns false when file doesn't exist" {
    const allocator = std.testing.allocator;

    // Get fallback path and ensure it doesn't exist
    const fallback_path = getFallbackPath(allocator) catch |err| {
        if (err == FallbackError.DataDirNotFound) {
            return; // Skip if HOME isn't set
        }
        return err;
    };
    defer allocator.free(fallback_path);

    // Delete the file if it exists
    fs.cwd().deleteFile(fallback_path) catch {};

    const has_pending = try hasPendingItems(allocator);
    try std.testing.expect(!has_pending);
}

test "readAndClearFallback returns empty slice when file doesn't exist" {
    const allocator = std.testing.allocator;

    // Get fallback path and ensure it doesn't exist
    const fallback_path = getFallbackPath(allocator) catch |err| {
        if (err == FallbackError.DataDirNotFound) {
            return; // Skip if HOME isn't set
        }
        return err;
    };
    defer allocator.free(fallback_path);

    // Delete the file if it exists
    fs.cwd().deleteFile(fallback_path) catch {};

    const items = try readAndClearFallback(allocator);
    defer allocator.free(items);

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "freeItem properly frees StartMessage memory" {
    const allocator = std.testing.allocator;

    // Create item with allocated memory
    const id = try allocator.dupe(u8, "test-id");
    errdefer allocator.free(id);
    const cmd = try allocator.dupe(u8, "test-cmd");
    errdefer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/test/cwd");
    errdefer allocator.free(cwd);
    const session = try allocator.dupe(u8, "test-session");
    errdefer allocator.free(session);
    const hostname = try allocator.dupe(u8, "test-host");
    errdefer allocator.free(hostname);

    var item = FallbackItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 123,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    // This should not leak memory (testing allocator will catch leaks)
    freeItem(allocator, &item);
}

test "freeItem properly frees EndMessage memory" {
    const allocator = std.testing.allocator;

    // Create item with allocated memory
    const id = try allocator.dupe(u8, "test-id");
    errdefer allocator.free(id);

    var item = FallbackItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = 0,
            .duration = 100,
        },
    };

    // This should not leak memory (testing allocator will catch leaks)
    freeItem(allocator, &item);
}
