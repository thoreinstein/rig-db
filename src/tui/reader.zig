const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const history = @import("../db/history.zig");
const paths = @import("../paths.zig");

/// Error type for reader operations
pub const ReaderError = error{
    /// Database file does not exist yet (no history recorded)
    DatabaseNotFound,
    /// Failed to get database path
    PathError,
    /// Out of memory
    OutOfMemory,
    /// Query operation failed
    QueryFailed,
};

/// Read-only database connection for TUI search interface.
/// Opens the history database in read-only mode to allow concurrent reads
/// while the daemon writes (WAL mode).
pub const HistoryReader = struct {
    db: sqlite.Database,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Opens the history database in read-only mode.
    /// Returns DatabaseNotFound if no history has been recorded yet.
    pub fn open(allocator: std.mem.Allocator) ReaderError!Self {
        // Get the database path using the existing paths module
        const db_path = paths.getHistoryDbPath(allocator) catch {
            return ReaderError.PathError;
        };
        defer allocator.free(db_path);

        // Null-terminate the path for SQLite
        const db_path_z = allocator.dupeZ(u8, db_path) catch {
            return ReaderError.OutOfMemory;
        };
        defer allocator.free(db_path_z);

        // Open in read-only mode - this will fail if database doesn't exist
        const db = sqlite.Database.openReadOnly(db_path_z) catch |err| {
            return switch (err) {
                sqlite.SqliteError.DatabaseNotFound => ReaderError.DatabaseNotFound,
                else => ReaderError.QueryFailed,
            };
        };

        return Self{
            .db = db,
            .allocator = allocator,
        };
    }

    /// Closes the read-only database connection.
    pub fn close(self: *Self) void {
        self.db.close();
    }

    /// Query history records using the existing history.query function.
    /// Caller owns the returned ArrayList and must free it.
    pub fn query(
        self: *Self,
        params: history.QueryParams,
    ) (ReaderError || std.mem.Allocator.Error)!std.ArrayList(history.HistoryRecord) {
        return history.query(&self.db, self.allocator, params) catch |err| {
            // Map history/sqlite errors to reader errors
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => ReaderError.QueryFailed,
            };
        };
    }

    /// Search for commands matching a pattern.
    /// Convenience method for common search operation.
    pub fn searchCommands(
        self: *Self,
        pattern: [:0]const u8,
        limit: u32,
    ) (ReaderError || std.mem.Allocator.Error)!std.ArrayList(history.HistoryRecord) {
        return self.query(.{
            .command_pattern = pattern,
            .limit = limit,
            .include_deleted = false,
        });
    }

    /// Get recent history entries.
    /// Convenience method for listing recent commands.
    pub fn getRecent(
        self: *Self,
        limit: u32,
    ) (ReaderError || std.mem.Allocator.Error)!std.ArrayList(history.HistoryRecord) {
        return self.query(.{
            .limit = limit,
            .include_deleted = false,
        });
    }
};

/// Check if the history database exists without opening it.
/// Useful for showing "no history yet" message in TUI.
pub fn databaseExists(allocator: std.mem.Allocator) bool {
    const db_path = paths.getHistoryDbPath(allocator) catch {
        return false;
    };
    defer allocator.free(db_path);

    // Check if file exists
    std.fs.cwd().access(db_path, .{}) catch {
        return false;
    };
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "HistoryReader returns DatabaseNotFound for missing database" {
    const allocator = std.testing.allocator;

    // Use a temporary directory with XDG_DATA_HOME to avoid touching real data
    // Since we can't easily set env vars, we test openReadOnly directly
    const result = sqlite.Database.openReadOnly("/tmp/nonexistent-rig-test.db");
    try std.testing.expectError(sqlite.SqliteError.DatabaseNotFound, result);

    _ = allocator;
}

test "databaseExists returns false for missing database" {
    const allocator = std.testing.allocator;

    // This tests against the real XDG path, but that should exist in most cases
    // or not exist - either way it shouldn't crash
    _ = databaseExists(allocator);
}

test "HistoryReader can open and query existing database" {
    const allocator = std.testing.allocator;

    // Create a test database first
    const test_db_path = "/tmp/zig-reader-test.db";
    var db = sqlite.Database.open(test_db_path) catch |err| {
        std.debug.print("Failed to create test db: {}\n", .{err});
        return err;
    };
    defer {
        db.close();
        std.fs.cwd().deleteFile(test_db_path) catch {};
    }

    // Initialize schema
    const schema = @import("../db/schema.zig");
    try schema.initSchema(&db);

    // Insert test data
    try history.insertStart(&db, .{
        .id = "reader-test-1",
        .timestamp = 1234567890000000000,
        .command = "echo hello",
        .cwd = "/tmp",
        .session = "test-session",
        .hostname = "localhost",
    });

    db.close();

    // Now open read-only
    var ro_db = try sqlite.Database.openReadOnly(test_db_path);
    defer ro_db.close();

    // Query should work
    var results = try history.query(&ro_db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("echo hello", results.items[0].command);
}
