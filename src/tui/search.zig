const std = @import("std");
const tui_reader = @import("reader.zig");
const history = @import("../db/history.zig");

/// Options for searching history
pub const SearchOptions = struct {
    /// Search query string
    query: []const u8 = "",
    /// false = prefix match (default), true = substring match
    substring_match: bool = false,
    /// Only show commands from current working directory
    current_dir_only: bool = false,
    /// Path to filter by (used when current_dir_only is true)
    current_dir: ?[]const u8 = null,
    /// Deduplicate commands (show most recent occurrence only)
    unique: bool = true,
    /// Maximum number of results to return
    limit: u32 = 100,
};

/// A search result record, reusing HistoryRecord from history module
pub const SearchResult = history.HistoryRecord;

/// Error type for search operations
pub const SearchError = error{
    QueryFailed,
    OutOfMemory,
    DatabaseNotFound,
    PathError,
};

/// Search history with the given options.
/// Uses the HistoryReader for database access and applies filtering.
/// Caller owns the returned slice and must free each record and the slice itself.
pub fn search(
    reader: *tui_reader.HistoryReader,
    allocator: std.mem.Allocator,
    options: SearchOptions,
) SearchError![]SearchResult {
    // Build the SQL pattern for command matching
    var pattern_buf: [512]u8 = undefined;
    var pattern: ?[:0]const u8 = null;

    if (options.query.len > 0) {
        // Build pattern based on match type
        if (options.substring_match) {
            // Substring match: %query%
            const len = std.fmt.bufPrintZ(&pattern_buf, "%{s}%", .{options.query}) catch {
                return SearchError.OutOfMemory;
            };
            pattern = pattern_buf[0..len.len :0];
        } else {
            // Prefix match: query%
            const len = std.fmt.bufPrintZ(&pattern_buf, "{s}%", .{options.query}) catch {
                return SearchError.OutOfMemory;
            };
            pattern = pattern_buf[0..len.len :0];
        }
    }

    // Build cwd filter if current_dir_only is set
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_filter: ?[:0]const u8 = null;

    if (options.current_dir_only) {
        if (options.current_dir) |dir| {
            // Use provided directory
            const cwd_z = std.fmt.bufPrintZ(&cwd_buf, "{s}", .{dir}) catch {
                return SearchError.OutOfMemory;
            };
            cwd_filter = cwd_buf[0..cwd_z.len :0];
        }
    }

    // Query parameters - request more if unique is enabled to account for deduplication
    const query_limit: u32 = if (options.unique)
        @min(options.limit * 5, 1000) // Request more to have enough after deduplication
    else
        options.limit;

    const params = history.QueryParams{
        .command_pattern = pattern,
        .cwd = cwd_filter,
        .limit = query_limit,
        .include_deleted = false,
    };

    // Execute the query
    var results = reader.query(params) catch |err| {
        return switch (err) {
            error.OutOfMemory => SearchError.OutOfMemory,
            else => SearchError.QueryFailed,
        };
    };
    defer results.deinit(allocator);

    // Apply deduplication if unique is enabled
    if (options.unique) {
        return deduplicateResults(allocator, results.items, options.limit);
    }

    // No deduplication - transfer ownership of items up to limit
    const actual_limit = @min(results.items.len, options.limit);
    const output = allocator.alloc(SearchResult, actual_limit) catch {
        // Free all records on allocation failure
        for (results.items) |*r| r.deinit(allocator);
        return SearchError.OutOfMemory;
    };

    // Copy records up to limit, free the rest
    for (results.items, 0..) |*r, i| {
        if (i < actual_limit) {
            output[i] = r.*;
        } else {
            r.deinit(allocator);
        }
    }

    return output;
}

/// Deduplicate results by command, keeping the most recent occurrence.
/// Results are already sorted by timestamp descending, so we keep first occurrence.
fn deduplicateResults(
    allocator: std.mem.Allocator,
    items: []history.HistoryRecord,
    limit: u32,
) SearchError![]SearchResult {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    // First pass: count unique items up to limit
    var unique_count: usize = 0;
    for (items) |*record| {
        if (!seen.contains(record.command)) {
            seen.put(record.command, {}) catch {
                // Free all records on failure
                for (items) |*r| r.deinit(allocator);
                return SearchError.OutOfMemory;
            };
            unique_count += 1;
            if (unique_count >= limit) break;
        }
    }

    // Allocate output array
    const output = allocator.alloc(SearchResult, unique_count) catch {
        for (items) |*r| r.deinit(allocator);
        return SearchError.OutOfMemory;
    };
    errdefer allocator.free(output);

    // Reset seen map for second pass
    seen.clearRetainingCapacity();

    // Second pass: copy unique items, free duplicates
    var out_idx: usize = 0;
    for (items) |*record| {
        if (out_idx >= unique_count) {
            // Already have enough unique items, free the rest
            record.deinit(allocator);
        } else if (!seen.contains(record.command)) {
            seen.put(record.command, {}) catch {
                // This shouldn't fail since we already sized the map
                record.deinit(allocator);
                continue;
            };
            output[out_idx] = record.*;
            out_idx += 1;
        } else {
            // Duplicate - free it
            record.deinit(allocator);
        }
    }

    return output;
}

/// Free search results returned by search().
pub fn freeResults(allocator: std.mem.Allocator, results: []SearchResult) void {
    for (results) |*r| {
        r.deinit(allocator);
    }
    allocator.free(results);
}

// =============================================================================
// Tests
// =============================================================================

const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");

/// Test helper to create a test database with sample data
fn setupTestDb(allocator: std.mem.Allocator) !struct { db: sqlite.Database, path: [:0]const u8 } {
    const test_path: [:0]const u8 = "/tmp/zig-search-test.db";

    // Remove existing test db
    std.fs.cwd().deleteFile(test_path) catch {};

    var db = sqlite.Database.open(test_path) catch |err| {
        std.debug.print("Failed to create test db: {}\n", .{err});
        return err;
    };

    try schema.initSchema(&db);

    // Insert test data with various commands and directories
    const test_data = [_]struct {
        id: [:0]const u8,
        timestamp: i128,
        command: [:0]const u8,
        cwd: [:0]const u8,
    }{
        .{ .id = "1", .timestamp = 1000, .command = "ls -la", .cwd = "/home/user" },
        .{ .id = "2", .timestamp = 2000, .command = "ls", .cwd = "/home/user" },
        .{ .id = "3", .timestamp = 3000, .command = "ls -la", .cwd = "/tmp" }, // duplicate command, different dir
        .{ .id = "4", .timestamp = 4000, .command = "git status", .cwd = "/home/user/repo" },
        .{ .id = "5", .timestamp = 5000, .command = "git commit -m 'test'", .cwd = "/home/user/repo" },
        .{ .id = "6", .timestamp = 6000, .command = "echo hello", .cwd = "/home/user" },
        .{ .id = "7", .timestamp = 7000, .command = "cat file.txt", .cwd = "/home/user" },
        .{ .id = "8", .timestamp = 8000, .command = "ls", .cwd = "/home/user" }, // duplicate of id=2
    };

    for (test_data) |data| {
        try history.insertStart(&db, .{
            .id = data.id,
            .timestamp = data.timestamp,
            .command = data.command,
            .cwd = data.cwd,
            .session = "test-session",
            .hostname = "localhost",
        });
    }

    db.close();

    _ = allocator;
    return .{ .db = undefined, .path = test_path };
}

test "prefix search matches commands starting with query" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Search for "ls" prefix
    const results = try search(&reader, allocator, .{
        .query = "ls",
        .substring_match = false,
        .unique = false,
    });
    defer freeResults(allocator, results);

    // Should find all "ls" commands (ls, ls -la)
    try std.testing.expect(results.len >= 2);
    for (results) |r| {
        try std.testing.expect(std.mem.startsWith(u8, r.command, "ls"));
    }
}

test "substring search matches commands containing query" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Search for "la" substring
    const results = try search(&reader, allocator, .{
        .query = "la",
        .substring_match = true,
        .unique = false,
    });
    defer freeResults(allocator, results);

    // Should find "ls -la" commands
    try std.testing.expect(results.len >= 1);
    for (results) |r| {
        try std.testing.expect(std.mem.indexOf(u8, r.command, "la") != null);
    }
}

test "current_dir_only filters by directory" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Search only in /home/user/repo
    const results = try search(&reader, allocator, .{
        .query = "",
        .current_dir_only = true,
        .current_dir = "/home/user/repo",
        .unique = false,
    });
    defer freeResults(allocator, results);

    // Should only find git commands from that directory
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expectEqualStrings("/home/user/repo", r.cwd);
    }
}

test "unique option deduplicates commands" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Search for "ls" with unique enabled
    const results = try search(&reader, allocator, .{
        .query = "ls",
        .substring_match = false,
        .unique = true,
    });
    defer freeResults(allocator, results);

    // Should have exactly 2 unique commands: "ls" and "ls -la"
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // Verify no duplicates
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (results) |r| {
        try std.testing.expect(!seen.contains(r.command));
        try seen.put(r.command, {});
    }
}

test "results are sorted by timestamp descending" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Get all results
    const results = try search(&reader, allocator, .{
        .query = "",
        .unique = false,
    });
    defer freeResults(allocator, results);

    // Verify sorted by timestamp descending (most recent first)
    for (results[0 .. results.len - 1], 0..) |_, i| {
        try std.testing.expect(results[i].timestamp >= results[i + 1].timestamp);
    }
}

test "limit restricts number of results" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Limit to 3 results
    const results = try search(&reader, allocator, .{
        .query = "",
        .unique = false,
        .limit = 3,
    });
    defer freeResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "empty query returns all results" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    const results = try search(&reader, allocator, .{
        .query = "",
        .unique = false,
    });
    defer freeResults(allocator, results);

    // Should return all 8 test records
    try std.testing.expectEqual(@as(usize, 8), results.len);
}

test "combined prefix search with current_dir_only" {
    const allocator = std.testing.allocator;

    const setup = try setupTestDb(allocator);
    defer std.fs.cwd().deleteFile(setup.path) catch {};

    const db = try sqlite.Database.openReadOnly(setup.path);
    var reader = tui_reader.HistoryReader{
        .db = db,
        .allocator = allocator,
    };
    defer reader.close();

    // Search for "git" in /home/user/repo
    const results = try search(&reader, allocator, .{
        .query = "git",
        .current_dir_only = true,
        .current_dir = "/home/user/repo",
        .unique = false,
    });
    defer freeResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(std.mem.startsWith(u8, r.command, "git"));
        try std.testing.expectEqualStrings("/home/user/repo", r.cwd);
    }
}
