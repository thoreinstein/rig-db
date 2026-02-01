const std = @import("std");
const sqlite = @import("sqlite.zig");

// Use the same C import as sqlite module to avoid opaque type conflicts
const c = sqlite.c;

/// Errors specific to history operations
pub const HistoryError = error{
    InsertFailed,
    UpdateFailed,
    QueryFailed,
    DeleteFailed,
    NotFound,
    InvalidId,
    PrepareStatementFailed,
    BindFailed,
    ConstraintViolation,
};

/// A history record representing a single command execution
pub const HistoryRecord = struct {
    id: []const u8,
    timestamp: i128,
    duration: i128,
    exit_code: i32,
    command: []const u8,
    cwd: []const u8,
    session: []const u8,
    hostname: []const u8,
    deleted_at: ?i128,

    /// Free all allocated memory in this record
    pub fn deinit(self: *HistoryRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.session);
        allocator.free(self.hostname);
    }
};

/// Parameters for inserting a new history record (from start command)
pub const InsertParams = struct {
    id: [:0]const u8,
    timestamp: i128,
    command: [:0]const u8,
    cwd: [:0]const u8,
    session: [:0]const u8,
    hostname: [:0]const u8,
};

/// Parameters for updating a history record (from end command)
pub const UpdateParams = struct {
    id: [:0]const u8,
    duration: i128,
    exit_code: i32,
};

/// Parameters for querying history records
pub const QueryParams = struct {
    command_pattern: ?[:0]const u8 = null,
    cwd: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    since_timestamp: ?i128 = null,
    until_timestamp: ?i128 = null,
    include_deleted: bool = false,
    limit: u32 = 100,
    offset: u32 = 0,
};

/// Insert a new history record from the start command.
/// Duration and exit_code are set to 0, to be updated by end command.
pub fn insertStart(db: *sqlite.Database, params: InsertParams) (HistoryError || sqlite.SqliteError)!void {
    const sql: [:0]const u8 =
        \\INSERT INTO history (id, timestamp, duration, exit, command, cwd, session, hostname)
        \\VALUES (?1, ?2, 0, 0, ?3, ?4, ?5, ?6);
    ;

    const db_ptr = db.db orelse return HistoryError.InsertFailed;

    var stmt: ?*c.sqlite3_stmt = null;
    var result = c.sqlite3_prepare_v2(db_ptr, sql.ptr, @intCast(sql.len + 1), &stmt, null);
    if (result != c.SQLITE_OK) {
        return HistoryError.PrepareStatementFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    if (c.sqlite3_bind_text(stmt, 1, params.id.ptr, @intCast(params.id.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_int64(stmt, 2, @intCast(@as(i64, @truncate(params.timestamp)))) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 3, params.command.ptr, @intCast(params.command.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 4, params.cwd.ptr, @intCast(params.cwd.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 5, params.session.ptr, @intCast(params.session.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 6, params.hostname.ptr, @intCast(params.hostname.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }

    result = c.sqlite3_step(stmt);
    if (result == c.SQLITE_CONSTRAINT) {
        return HistoryError.ConstraintViolation;
    }
    if (result != c.SQLITE_DONE) {
        return HistoryError.InsertFailed;
    }
}

/// Update a history record with duration and exit code from end command.
pub fn updateEnd(db: *sqlite.Database, params: UpdateParams) (HistoryError || sqlite.SqliteError)!void {
    const sql: [:0]const u8 = "UPDATE history SET duration = ?1, exit = ?2 WHERE id = ?3;";

    const db_ptr = db.db orelse return HistoryError.UpdateFailed;

    var stmt: ?*c.sqlite3_stmt = null;
    var result = c.sqlite3_prepare_v2(db_ptr, sql.ptr, @intCast(sql.len + 1), &stmt, null);
    if (result != c.SQLITE_OK) {
        return HistoryError.PrepareStatementFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind parameters
    if (c.sqlite3_bind_int64(stmt, 1, @intCast(@as(i64, @truncate(params.duration)))) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_int(stmt, 2, params.exit_code) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 3, params.id.ptr, @intCast(params.id.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }

    result = c.sqlite3_step(stmt);
    if (result != c.SQLITE_DONE) {
        return HistoryError.UpdateFailed;
    }

    // Check if any row was actually updated
    if (c.sqlite3_changes(db_ptr) == 0) {
        return HistoryError.NotFound;
    }
}

/// Soft delete a history record by setting deleted_at timestamp.
pub fn softDelete(db: *sqlite.Database, id: [:0]const u8) (HistoryError || sqlite.SqliteError)!void {
    const timestamp = std.time.nanoTimestamp();
    const sql: [:0]const u8 = "UPDATE history SET deleted_at = ?1 WHERE id = ?2 AND deleted_at IS NULL;";

    const db_ptr = db.db orelse return HistoryError.DeleteFailed;

    var stmt: ?*c.sqlite3_stmt = null;
    var result = c.sqlite3_prepare_v2(db_ptr, sql.ptr, @intCast(sql.len + 1), &stmt, null);
    if (result != c.SQLITE_OK) {
        return HistoryError.PrepareStatementFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_bind_int64(stmt, 1, @intCast(@as(i64, @truncate(timestamp)))) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }
    if (c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
        return HistoryError.BindFailed;
    }

    result = c.sqlite3_step(stmt);
    if (result != c.SQLITE_DONE) {
        return HistoryError.DeleteFailed;
    }

    if (c.sqlite3_changes(db_ptr) == 0) {
        return HistoryError.NotFound;
    }
}

/// Query history records with optional filters.
/// Returns records sorted by timestamp descending (most recent first).
/// Caller owns the returned ArrayList and must free it.
pub fn query(
    db: *sqlite.Database,
    allocator: std.mem.Allocator,
    params: QueryParams,
) (HistoryError || sqlite.SqliteError || std.mem.Allocator.Error)!std.ArrayList(HistoryRecord) {
    var results: std.ArrayList(HistoryRecord) = .{};
    errdefer {
        for (results.items) |*record| {
            record.deinit(allocator);
        }
        results.deinit(allocator);
    }

    // Build dynamic SQL based on filters
    var sql_buf: [1024]u8 = undefined;
    var where_clauses: std.ArrayList([]const u8) = .{};
    defer where_clauses.deinit(allocator);

    if (!params.include_deleted) {
        try where_clauses.append(allocator, "deleted_at IS NULL");
    }
    if (params.command_pattern != null) {
        try where_clauses.append(allocator, "command LIKE ?");
    }
    if (params.cwd != null) {
        try where_clauses.append(allocator, "cwd = ?");
    }
    if (params.session != null) {
        try where_clauses.append(allocator, "session = ?");
    }
    if (params.since_timestamp != null) {
        try where_clauses.append(allocator, "timestamp >= ?");
    }
    if (params.until_timestamp != null) {
        try where_clauses.append(allocator, "timestamp <= ?");
    }

    // Build WHERE clause
    var where_sql: []const u8 = "";
    var where_buf: [512]u8 = undefined;
    if (where_clauses.items.len > 0) {
        var stream = std.io.fixedBufferStream(&where_buf);
        const writer = stream.writer();
        writer.writeAll(" WHERE ") catch return HistoryError.QueryFailed;
        for (where_clauses.items, 0..) |clause, i| {
            if (i > 0) writer.writeAll(" AND ") catch return HistoryError.QueryFailed;
            writer.writeAll(clause) catch return HistoryError.QueryFailed;
        }
        where_sql = where_buf[0..stream.pos];
    }

    const sql = std.fmt.bufPrintZ(
        &sql_buf,
        "SELECT id, timestamp, duration, exit, command, cwd, session, hostname, deleted_at FROM history{s} ORDER BY timestamp DESC LIMIT {d} OFFSET {d};",
        .{ where_sql, params.limit, params.offset },
    ) catch return HistoryError.QueryFailed;

    const db_ptr = db.db orelse return HistoryError.QueryFailed;

    var stmt: ?*c.sqlite3_stmt = null;
    const result = c.sqlite3_prepare_v2(db_ptr, sql.ptr, @intCast(sql.len + 1), &stmt, null);
    if (result != c.SQLITE_OK) {
        return HistoryError.PrepareStatementFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind filter parameters
    var bind_index: c_int = 1;
    if (params.command_pattern) |pattern| {
        if (c.sqlite3_bind_text(stmt, bind_index, pattern.ptr, @intCast(pattern.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return HistoryError.BindFailed;
        }
        bind_index += 1;
    }
    if (params.cwd) |cwd| {
        if (c.sqlite3_bind_text(stmt, bind_index, cwd.ptr, @intCast(cwd.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return HistoryError.BindFailed;
        }
        bind_index += 1;
    }
    if (params.session) |session| {
        if (c.sqlite3_bind_text(stmt, bind_index, session.ptr, @intCast(session.len), c.SQLITE_STATIC) != c.SQLITE_OK) {
            return HistoryError.BindFailed;
        }
        bind_index += 1;
    }
    if (params.since_timestamp) |ts| {
        if (c.sqlite3_bind_int64(stmt, bind_index, @intCast(@as(i64, @truncate(ts)))) != c.SQLITE_OK) {
            return HistoryError.BindFailed;
        }
        bind_index += 1;
    }
    if (params.until_timestamp) |ts| {
        if (c.sqlite3_bind_int64(stmt, bind_index, @intCast(@as(i64, @truncate(ts)))) != c.SQLITE_OK) {
            return HistoryError.BindFailed;
        }
        bind_index += 1;
    }

    // Fetch results
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const record = HistoryRecord{
            .id = try dupeColumnText(allocator, stmt, 0),
            .timestamp = c.sqlite3_column_int64(stmt, 1),
            .duration = c.sqlite3_column_int64(stmt, 2),
            .exit_code = c.sqlite3_column_int(stmt, 3),
            .command = try dupeColumnText(allocator, stmt, 4),
            .cwd = try dupeColumnText(allocator, stmt, 5),
            .session = try dupeColumnText(allocator, stmt, 6),
            .hostname = try dupeColumnText(allocator, stmt, 7),
            .deleted_at = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt, 8),
        };
        try results.append(allocator, record);
    }

    return results;
}

/// Helper to duplicate column text with allocator
fn dupeColumnText(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) ![]u8 {
    const text_ptr = c.sqlite3_column_text(stmt, col);
    if (text_ptr == null) {
        return allocator.dupe(u8, "");
    }
    return allocator.dupe(u8, std.mem.span(text_ptr));
}

// =============================================================================
// Tests
// =============================================================================

test "insertStart creates record" {
    const allocator = std.testing.allocator;
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    try insertStart(&db, .{
        .id = "test-uuid-1",
        .timestamp = 1234567890000000000,
        .command = "ls -la",
        .cwd = "/home/user",
        .session = "session-123",
        .hostname = "localhost",
    });

    // Query to verify
    var results = try query(&db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("ls -la", results.items[0].command);
}

test "updateEnd updates record" {
    const allocator = std.testing.allocator;
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    // Insert a record
    try insertStart(&db, .{
        .id = "test-uuid-2",
        .timestamp = 1234567890000000000,
        .command = "sleep 1",
        .cwd = "/tmp",
        .session = "session-456",
        .hostname = "localhost",
    });

    // Update with end data
    try updateEnd(&db, .{
        .id = "test-uuid-2",
        .duration = 1000000000, // 1 second in nanoseconds
        .exit_code = 0,
    });

    // Query to verify
    var results = try query(&db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(i128, 1000000000), results.items[0].duration);
    try std.testing.expectEqual(@as(i32, 0), results.items[0].exit_code);
}

test "updateEnd returns NotFound for missing id" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    const result = updateEnd(&db, .{
        .id = "nonexistent-id",
        .duration = 100,
        .exit_code = 1,
    });

    try std.testing.expectError(HistoryError.NotFound, result);
}

test "softDelete sets deleted_at" {
    const allocator = std.testing.allocator;
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    // Insert a record
    try insertStart(&db, .{
        .id = "test-uuid-3",
        .timestamp = 1234567890000000000,
        .command = "rm -rf /",
        .cwd = "/",
        .session = "session-789",
        .hostname = "localhost",
    });

    // Soft delete
    try softDelete(&db, "test-uuid-3");

    // Query without include_deleted - should be empty
    var results = try query(&db, allocator, .{ .include_deleted = false, .limit = 10 });
    defer results.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);

    // Query with include_deleted - should find it
    var results2 = try query(&db, allocator, .{ .include_deleted = true, .limit = 10 });
    defer {
        for (results2.items) |*r| r.deinit(allocator);
        results2.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), results2.items.len);
    try std.testing.expect(results2.items[0].deleted_at != null);
}

test "query filters by command pattern" {
    const allocator = std.testing.allocator;
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    // Insert multiple records
    try insertStart(&db, .{ .id = "id-1", .timestamp = 1000, .command = "git status", .cwd = "/repo", .session = "s1", .hostname = "h1" });
    try insertStart(&db, .{ .id = "id-2", .timestamp = 2000, .command = "git commit", .cwd = "/repo", .session = "s1", .hostname = "h1" });
    try insertStart(&db, .{ .id = "id-3", .timestamp = 3000, .command = "ls -la", .cwd = "/repo", .session = "s1", .hostname = "h1" });

    // Query for git commands
    var results = try query(&db, allocator, .{ .command_pattern = "git%", .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "query returns results sorted by timestamp desc" {
    const allocator = std.testing.allocator;
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    // Insert records in random order
    try insertStart(&db, .{ .id = "id-1", .timestamp = 1000, .command = "first", .cwd = "/", .session = "s", .hostname = "h" });
    try insertStart(&db, .{ .id = "id-2", .timestamp = 3000, .command = "third", .cwd = "/", .session = "s", .hostname = "h" });
    try insertStart(&db, .{ .id = "id-3", .timestamp = 2000, .command = "second", .cwd = "/", .session = "s", .hostname = "h" });

    var results = try query(&db, allocator, .{ .limit = 10 });
    defer {
        for (results.items) |*r| r.deinit(allocator);
        results.deinit(allocator);
    }

    // Should be sorted by timestamp descending
    try std.testing.expectEqualStrings("third", results.items[0].command);
    try std.testing.expectEqualStrings("second", results.items[1].command);
    try std.testing.expectEqualStrings("first", results.items[2].command);
}

test "insertStart rejects duplicate id" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    const schema = @import("schema.zig");
    try schema.initSchema(&db);

    try insertStart(&db, .{ .id = "dup-id", .timestamp = 1000, .command = "cmd1", .cwd = "/", .session = "s", .hostname = "h" });

    const result = insertStart(&db, .{ .id = "dup-id", .timestamp = 2000, .command = "cmd2", .cwd = "/", .session = "s", .hostname = "h" });

    try std.testing.expectError(HistoryError.ConstraintViolation, result);
}
