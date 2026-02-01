const std = @import("std");
const mem = std.mem;
const time = std.time;
const sqlite = @import("../db/sqlite.zig");
const history = @import("../db/history.zig");
const schema = @import("../db/schema.zig");
const queue = @import("queue.zig");
const protocol = @import("protocol.zig");
const fallback = @import("../cli/fallback.zig");

// Use the same C import as sqlite module
const c = sqlite.c;

/// Writer errors specific to the write path
pub const WriterError = error{
    /// Database connection is not initialized
    NotInitialized,
    /// Transaction begin failed
    TransactionFailed,
    /// Transaction commit failed
    CommitFailed,
    /// Transaction rollback failed
    RollbackFailed,
    /// SQLITE_BUSY after all retries exhausted
    DatabaseBusy,
    /// Memory allocation failed
    OutOfMemory,
};

/// Configuration for the writer
pub const WriterConfig = struct {
    /// Maximum number of retries for SQLITE_BUSY errors
    max_retries: u32 = 5,
    /// Initial backoff delay in milliseconds for busy retries
    initial_backoff_ms: u64 = 10,
    /// Maximum backoff delay in milliseconds
    max_backoff_ms: u64 = 1000,
    /// Use in-memory database (for testing)
    use_memory_db: bool = false,
};

/// The Writer handles exclusive write access to the SQLite history database.
/// It processes queued StartMessage and EndMessage items, batching writes
/// into transactions for efficiency.
pub const Writer = struct {
    /// Database connection (owned by writer)
    db: sqlite.Database,
    /// Allocator for memory operations
    allocator: mem.Allocator,
    /// Configuration settings
    config: WriterConfig,
    /// Whether the writer has been initialized
    initialized: bool,

    const Self = @This();

    /// Initialize a new writer with the given allocator.
    /// Opens the database connection and initializes the schema.
    pub fn init(allocator: mem.Allocator) (WriterError || sqlite.SqliteError || schema.SchemaError)!Self {
        return initWithConfig(allocator, .{});
    }

    /// Initialize a new writer with custom configuration.
    pub fn initWithConfig(allocator: mem.Allocator, config: WriterConfig) (WriterError || sqlite.SqliteError || schema.SchemaError)!Self {
        // Open database connection
        var db = if (config.use_memory_db)
            try sqlite.initMemoryDb()
        else
            try sqlite.initHistoryDb(allocator);

        errdefer db.close();

        // Initialize schema
        try schema.initSchema(&db);

        return Self{
            .db = db,
            .allocator = allocator,
            .config = config,
            .initialized = true,
        };
    }

    /// Process a single queue item, writing it to the database.
    /// Handles SQLITE_BUSY with exponential backoff retry.
    pub fn processItem(self: *Self, item: queue.QueueItem) (WriterError || history.HistoryError || sqlite.SqliteError)!void {
        if (!self.initialized) {
            return WriterError.NotInitialized;
        }

        var retries: u32 = 0;
        var backoff_ms: u64 = self.config.initial_backoff_ms;

        while (true) {
            const result = self.processItemInternal(item);
            if (result) |_| {
                return;
            } else |err| {
                // Check if it's a busy/locked error that we should retry
                if (self.isBusyError(err) and retries < self.config.max_retries) {
                    retries += 1;
                    // Exponential backoff with jitter
                    const jitter = @as(u64, @intCast(@mod(time.nanoTimestamp(), @as(i128, backoff_ms / 2))));
                    time.sleep((backoff_ms + jitter) * time.ns_per_ms);
                    backoff_ms = @min(backoff_ms * 2, self.config.max_backoff_ms);
                    continue;
                }
                return err;
            }
        }
    }

    /// Process a batch of queue items within a single transaction.
    /// This is more efficient than processing items individually.
    /// Handles SQLITE_BUSY with exponential backoff retry for the entire transaction.
    pub fn processBatch(self: *Self, items: []queue.QueueItem) (WriterError || history.HistoryError || sqlite.SqliteError)!void {
        if (!self.initialized) {
            return WriterError.NotInitialized;
        }

        if (items.len == 0) {
            return;
        }

        var retries: u32 = 0;
        var backoff_ms: u64 = self.config.initial_backoff_ms;

        while (true) {
            const result = self.processBatchInternal(items);
            if (result) |_| {
                return;
            } else |err| {
                // Check if it's a busy/locked error that we should retry
                if (self.isBusyError(err) and retries < self.config.max_retries) {
                    retries += 1;
                    // Exponential backoff with jitter
                    const jitter = @as(u64, @intCast(@mod(time.nanoTimestamp(), @as(i128, backoff_ms / 2))));
                    time.sleep((backoff_ms + jitter) * time.ns_per_ms);
                    backoff_ms = @min(backoff_ms * 2, self.config.max_backoff_ms);
                    continue;
                }
                return err;
            }
        }
    }

    /// Close the writer and release database connection.
    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.db.close();
            self.initialized = false;
        }
    }

    // =========================================================================
    // Internal methods
    // =========================================================================

    /// Internal method to process a single item without retry logic.
    fn processItemInternal(self: *Self, item: queue.QueueItem) (history.HistoryError || sqlite.SqliteError)!void {
        switch (item) {
            .start => |start| {
                try self.processStartMessage(start);
            },
            .end => |end| {
                try self.processEndMessage(end);
            },
        }
    }

    /// Internal method to process a batch within a transaction.
    fn processBatchInternal(self: *Self, items: []queue.QueueItem) (WriterError || history.HistoryError || sqlite.SqliteError)!void {
        // Begin transaction with IMMEDIATE to acquire write lock early
        try self.beginTransaction();
        errdefer self.rollbackTransaction() catch {};

        // Process all items
        for (items) |item| {
            try self.processItemInternal(item);
        }

        // Commit transaction
        try self.commitTransaction();
    }

    /// Process a start message - INSERT new history record.
    fn processStartMessage(self: *Self, msg: protocol.StartMessage) (history.HistoryError || sqlite.SqliteError)!void {
        // Convert message fields to null-terminated strings for SQLite binding
        const id_z = self.allocator.dupeZ(u8, msg.id) catch return history.HistoryError.InsertFailed;
        defer self.allocator.free(id_z);

        const cmd_z = self.allocator.dupeZ(u8, msg.cmd) catch return history.HistoryError.InsertFailed;
        defer self.allocator.free(cmd_z);

        const cwd_z = self.allocator.dupeZ(u8, msg.cwd) catch return history.HistoryError.InsertFailed;
        defer self.allocator.free(cwd_z);

        const session_z = self.allocator.dupeZ(u8, msg.session) catch return history.HistoryError.InsertFailed;
        defer self.allocator.free(session_z);

        const hostname_z = self.allocator.dupeZ(u8, msg.hostname) catch return history.HistoryError.InsertFailed;
        defer self.allocator.free(hostname_z);

        try history.insertStart(&self.db, .{
            .id = id_z,
            .timestamp = msg.ts,
            .command = cmd_z,
            .cwd = cwd_z,
            .session = session_z,
            .hostname = hostname_z,
        });
    }

    /// Process an end message - UPDATE existing history record.
    fn processEndMessage(self: *Self, msg: protocol.EndMessage) (history.HistoryError || sqlite.SqliteError)!void {
        // Convert id to null-terminated string for SQLite binding
        const id_z = self.allocator.dupeZ(u8, msg.id) catch return history.HistoryError.UpdateFailed;
        defer self.allocator.free(id_z);

        // Note: updateEnd returns NotFound if the id doesn't exist.
        // This handles orphaned end messages gracefully - we simply skip them.
        history.updateEnd(&self.db, .{
            .id = id_z,
            .duration = msg.duration,
            .exit_code = msg.exit,
        }) catch |err| {
            // For orphaned ends (no matching start), we log and continue
            if (err == history.HistoryError.NotFound) {
                // Orphaned end message - no matching start was recorded
                // This is not a fatal error, just skip it
                return;
            }
            return err;
        };
    }

    /// Begin an immediate transaction for exclusive write access.
    fn beginTransaction(self: *Self) WriterError!void {
        self.db.execSql("BEGIN IMMEDIATE;") catch {
            return WriterError.TransactionFailed;
        };
    }

    /// Commit the current transaction.
    fn commitTransaction(self: *Self) WriterError!void {
        self.db.execSql("COMMIT;") catch {
            return WriterError.CommitFailed;
        };
    }

    /// Rollback the current transaction.
    fn rollbackTransaction(self: *Self) WriterError!void {
        self.db.execSql("ROLLBACK;") catch {
            return WriterError.RollbackFailed;
        };
    }

    /// Check if an error is a busy/locked error that should trigger a retry.
    fn isBusyError(_: *Self, err: anytype) bool {
        // Map errors that indicate database is busy/locked
        return switch (err) {
            sqlite.SqliteError.ExecFailed => true,
            history.HistoryError.InsertFailed => true,
            history.HistoryError.UpdateFailed => true,
            WriterError.TransactionFailed => true,
            WriterError.CommitFailed => true,
            else => false,
        };
    }

    /// Process any pending items from the fallback log.
    /// Called by daemon on startup to recover any records written while daemon was unavailable.
    /// Returns the number of items processed.
    pub fn processFallback(self: *Self) (WriterError || history.HistoryError || sqlite.SqliteError)!usize {
        if (!self.initialized) {
            return WriterError.NotInitialized;
        }

        // Read pending fallback items
        const items = fallback.readAndClearFallback(self.allocator) catch |err| {
            // Log warning but don't fail startup
            std.log.warn("Failed to read fallback log: {}", .{err});
            return 0;
        };
        defer fallback.freeItems(self.allocator, items);

        if (items.len == 0) {
            return 0;
        }

        // Convert FallbackItems to QueueItems and process
        var queue_items = self.allocator.alloc(queue.QueueItem, items.len) catch {
            return WriterError.OutOfMemory;
        };
        defer self.allocator.free(queue_items);

        for (items, 0..) |item, i| {
            queue_items[i] = switch (item) {
                .start => |s| queue.QueueItem{ .start = s },
                .end => |e| queue.QueueItem{ .end = e },
            };
        }

        // Process as a batch
        try self.processBatch(queue_items);

        std.log.info("Processed {} pending fallback items", .{items.len});

        return items.len;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Writer init and deinit" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    try std.testing.expect(writer.initialized);
}

test "Writer processItem with start message" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Create a start message
    const id = try allocator.dupe(u8, "test-uuid-001");
    defer allocator.free(id);
    const cmd = try allocator.dupe(u8, "ls -la");
    defer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/home/user");
    defer allocator.free(cwd);
    const session = try allocator.dupe(u8, "session-123");
    defer allocator.free(session);
    const hostname = try allocator.dupe(u8, "localhost");
    defer allocator.free(hostname);

    const item = queue.QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 1234567890000000000,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    try writer.processItem(item);

    // Verify record was inserted by querying
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("ls -la", results.items[0].command);
}

test "Writer processItem with end message updates record" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // First insert a start message
    const id = try allocator.dupe(u8, "test-uuid-002");
    defer allocator.free(id);
    const cmd = try allocator.dupe(u8, "sleep 1");
    defer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/tmp");
    defer allocator.free(cwd);
    const session = try allocator.dupe(u8, "session-456");
    defer allocator.free(session);
    const hostname = try allocator.dupe(u8, "localhost");
    defer allocator.free(hostname);

    const start_item = queue.QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 1234567890000000000,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    try writer.processItem(start_item);

    // Now process end message
    const end_id = try allocator.dupe(u8, "test-uuid-002");
    defer allocator.free(end_id);

    const end_item = queue.QueueItem{
        .end = protocol.EndMessage{
            .id = end_id,
            .exit = 0,
            .duration = 1000000000, // 1 second in nanoseconds
        },
    };

    try writer.processItem(end_item);

    // Verify record was updated
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(i128, 1000000000), results.items[0].duration);
    try std.testing.expectEqual(@as(i32, 0), results.items[0].exit_code);
}

test "Writer processItem handles orphaned end message gracefully" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Process an end message without a matching start
    const id = try allocator.dupe(u8, "nonexistent-uuid");
    defer allocator.free(id);

    const end_item = queue.QueueItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = 1,
            .duration = 500000000,
        },
    };

    // Should not error - orphaned ends are silently skipped
    try writer.processItem(end_item);

    // Verify no records exist
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "Writer processBatch processes multiple items in transaction" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Create multiple items
    var items_list = std.ArrayList(queue.QueueItem).init(allocator);
    defer items_list.deinit();

    // Track allocated memory for cleanup
    var allocated_strings = std.ArrayList([]u8).init(allocator);
    defer {
        for (allocated_strings.items) |s| {
            allocator.free(s);
        }
        allocated_strings.deinit();
    }

    for (0..5) |i| {
        const id = try std.fmt.allocPrint(allocator, "batch-uuid-{d}", .{i});
        try allocated_strings.append(id);
        const cmd = try std.fmt.allocPrint(allocator, "command-{d}", .{i});
        try allocated_strings.append(cmd);
        const cwd = try allocator.dupe(u8, "/home/user");
        try allocated_strings.append(cwd);
        const session = try allocator.dupe(u8, "session-batch");
        try allocated_strings.append(session);
        const hostname = try allocator.dupe(u8, "localhost");
        try allocated_strings.append(hostname);

        const item = queue.QueueItem{
            .start = protocol.StartMessage{
                .id = id,
                .cmd = cmd,
                .ts = @as(i64, @intCast(1234567890000000000 + i * 1000000000)),
                .cwd = cwd,
                .session = session,
                .hostname = hostname,
            },
        };
        try items_list.append(item);
    }

    // Process batch
    try writer.processBatch(items_list.items);

    // Verify all records were inserted
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 5), results.items.len);
}

test "Writer processBatch with mixed start and end messages" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Track allocated memory for cleanup
    var allocated_strings = std.ArrayList([]u8).init(allocator);
    defer {
        for (allocated_strings.items) |s| {
            allocator.free(s);
        }
        allocated_strings.deinit();
    }

    // Create batch with start then end for same id
    const id1 = try allocator.dupe(u8, "mixed-uuid-001");
    try allocated_strings.append(id1);
    const cmd1 = try allocator.dupe(u8, "echo hello");
    try allocated_strings.append(cmd1);
    const cwd1 = try allocator.dupe(u8, "/tmp");
    try allocated_strings.append(cwd1);
    const session1 = try allocator.dupe(u8, "session-mixed");
    try allocated_strings.append(session1);
    const hostname1 = try allocator.dupe(u8, "localhost");
    try allocated_strings.append(hostname1);
    const end_id1 = try allocator.dupe(u8, "mixed-uuid-001");
    try allocated_strings.append(end_id1);

    var items = [_]queue.QueueItem{
        queue.QueueItem{
            .start = protocol.StartMessage{
                .id = id1,
                .cmd = cmd1,
                .ts = 1234567890000000000,
                .cwd = cwd1,
                .session = session1,
                .hostname = hostname1,
            },
        },
        queue.QueueItem{
            .end = protocol.EndMessage{
                .id = end_id1,
                .exit = 0,
                .duration = 50000000,
            },
        },
    };

    try writer.processBatch(&items);

    // Verify record was inserted and updated
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("echo hello", results.items[0].command);
    try std.testing.expectEqual(@as(i128, 50000000), results.items[0].duration);
    try std.testing.expectEqual(@as(i32, 0), results.items[0].exit_code);
}

test "Writer processBatch with empty batch" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    var empty_items: [0]queue.QueueItem = undefined;

    // Should not error on empty batch
    try writer.processBatch(&empty_items);
}

test "Writer rejects operations when not initialized" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });

    // Close the writer
    writer.deinit();

    // Create a test item
    const id = try allocator.dupe(u8, "test-id");
    defer allocator.free(id);

    const item = queue.QueueItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = 0,
            .duration = 100,
        },
    };

    // Should error because writer is not initialized
    const result = writer.processItem(item);
    try std.testing.expectError(WriterError.NotInitialized, result);
}

test "Writer handles duplicate id constraint violation" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Create two start messages with same id
    const id = try allocator.dupe(u8, "duplicate-uuid");
    defer allocator.free(id);
    const cmd = try allocator.dupe(u8, "first command");
    defer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/home");
    defer allocator.free(cwd);
    const session = try allocator.dupe(u8, "session");
    defer allocator.free(session);
    const hostname = try allocator.dupe(u8, "host");
    defer allocator.free(hostname);

    const item1 = queue.QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 1234567890000000000,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    // First insert should succeed
    try writer.processItem(item1);

    // Second insert with same id should fail with constraint violation
    const id2 = try allocator.dupe(u8, "duplicate-uuid");
    defer allocator.free(id2);
    const cmd2 = try allocator.dupe(u8, "second command");
    defer allocator.free(cmd2);
    const cwd2 = try allocator.dupe(u8, "/home");
    defer allocator.free(cwd2);
    const session2 = try allocator.dupe(u8, "session");
    defer allocator.free(session2);
    const hostname2 = try allocator.dupe(u8, "host");
    defer allocator.free(hostname2);

    const item2 = queue.QueueItem{
        .start = protocol.StartMessage{
            .id = id2,
            .cmd = cmd2,
            .ts = 1234567890000000001,
            .cwd = cwd2,
            .session = session2,
            .hostname = hostname2,
        },
    };

    const result = writer.processItem(item2);
    try std.testing.expectError(history.HistoryError.ConstraintViolation, result);
}

test "Writer processFallback returns 0 when no fallback file exists" {
    const allocator = std.testing.allocator;

    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Clean up any existing fallback file first
    const fallback_path = fallback.getFallbackPath(allocator) catch {
        // Skip test if data dir not available
        return;
    };
    defer allocator.free(fallback_path);

    std.fs.cwd().deleteFile(fallback_path) catch {};

    // Should return 0 when no fallback file exists
    const count = try writer.processFallback();
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "Writer processFallback processes pending items" {
    const allocator = std.testing.allocator;

    // Get fallback path and clean up first
    const fallback_path = fallback.getFallbackPath(allocator) catch {
        // Skip test if data dir not available
        return;
    };
    defer allocator.free(fallback_path);
    std.fs.cwd().deleteFile(fallback_path) catch {};
    defer std.fs.cwd().deleteFile(fallback_path) catch {};

    // Write some items to fallback
    const start_item = fallback.FallbackItem{
        .start = protocol.StartMessage{
            .id = "fallback-writer-test-1",
            .cmd = "echo test",
            .ts = 1234567890,
            .cwd = "/tmp",
            .session = "test-session",
            .hostname = "testhost",
        },
    };
    try fallback.writeToFallback(allocator, start_item);

    const end_item = fallback.FallbackItem{
        .end = protocol.EndMessage{
            .id = "fallback-writer-test-1",
            .exit = 0,
            .duration = 500000,
        },
    };
    try fallback.writeToFallback(allocator, end_item);

    // Create writer and process fallback
    var writer = try Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    const count = try writer.processFallback();
    try std.testing.expectEqual(@as(usize, 2), count);

    // Verify items were written to database
    var results = try history.query(&writer.db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("echo test", results.items[0].command);
    try std.testing.expectEqual(@as(i32, 0), results.items[0].exit_code);

    // Verify fallback file was deleted
    const has_pending = try fallback.hasPendingItems(allocator);
    try std.testing.expect(!has_pending);
}
