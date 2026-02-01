const std = @import("std");
const paths = @import("../paths.zig");

// Export C bindings for use by other modules
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteError = error{
    OpenFailed,
    CloseFailed,
    PrepareFailed,
    StepFailed,
    ExecFailed,
    BindFailed,
    PragmaFailed,
    PathError,
    OutOfMemory,
    DatabaseNotFound,
};

pub const Database = struct {
    db: ?*c.sqlite3,

    const Self = @This();

    /// Opens a SQLite database at the given path.
    /// Use ":memory:" for an in-memory database.
    pub fn open(path: [:0]const u8) SqliteError!Self {
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open(path.ptr, &db);
        if (result != c.SQLITE_OK) {
            if (db) |d| {
                _ = c.sqlite3_close(d);
            }
            return SqliteError.OpenFailed;
        }
        return Self{ .db = db };
    }

    /// Opens a SQLite database in read-only mode.
    /// This is safe for concurrent reads with WAL mode.
    /// Returns DatabaseNotFound if the database file doesn't exist.
    pub fn openReadOnly(path: [:0]const u8) SqliteError!Self {
        var db: ?*c.sqlite3 = null;
        const result = c.sqlite3_open_v2(
            path.ptr,
            &db,
            c.SQLITE_OPEN_READONLY,
            null,
        );
        if (result != c.SQLITE_OK) {
            if (db) |d| {
                _ = c.sqlite3_close(d);
            }
            // SQLITE_CANTOPEN is returned when file doesn't exist in read-only mode
            if (result == c.SQLITE_CANTOPEN) {
                return SqliteError.DatabaseNotFound;
            }
            return SqliteError.OpenFailed;
        }
        return Self{ .db = db };
    }

    /// Closes the database connection.
    pub fn close(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    /// Returns the SQLite version string.
    pub fn version() []const u8 {
        return std.mem.span(c.sqlite3_libversion());
    }

    /// Executes a SQL statement that doesn't return data.
    pub fn execSql(self: *Self, sql: [:0]const u8) SqliteError!void {
        const db = self.db orelse return SqliteError.ExecFailed;
        var err_msg: [*c]u8 = null;
        const result = c.sqlite3_exec(db, sql.ptr, null, null, &err_msg);
        if (result != c.SQLITE_OK) {
            if (err_msg != null) {
                c.sqlite3_free(err_msg);
            }
            return SqliteError.ExecFailed;
        }
    }

    /// Executes a PRAGMA and returns its text value.
    /// Caller owns the returned memory.
    pub fn getPragma(self: *Self, allocator: std.mem.Allocator, pragma_sql: [:0]const u8) SqliteError![]u8 {
        const db = self.db orelse return SqliteError.PragmaFailed;

        var stmt: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(db, pragma_sql.ptr, @intCast(pragma_sql.len + 1), &stmt, null);
        if (result != c.SQLITE_OK) {
            return SqliteError.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const step_result = c.sqlite3_step(stmt);
        if (step_result != c.SQLITE_ROW) {
            return SqliteError.StepFailed;
        }

        const text_ptr = c.sqlite3_column_text(stmt, 0);
        if (text_ptr == null) {
            return SqliteError.PragmaFailed;
        }

        const text = std.mem.span(text_ptr);
        return allocator.dupe(u8, text) catch return SqliteError.OutOfMemory;
    }

    /// Returns the last error message from SQLite.
    pub fn lastError(self: *Self) []const u8 {
        if (self.db) |db| {
            return std.mem.span(c.sqlite3_errmsg(db));
        }
        return "no database connection";
    }
};

/// Initialize the history database at the XDG-compliant path.
/// Opens or creates the database and configures it with proper pragmas.
pub fn initHistoryDb(allocator: std.mem.Allocator) SqliteError!Database {
    // Get the database path
    const db_path = paths.getHistoryDbPath(allocator) catch {
        return SqliteError.PathError;
    };
    defer allocator.free(db_path);

    // Null-terminate the path for SQLite
    const db_path_z = allocator.dupeZ(u8, db_path) catch {
        return SqliteError.OutOfMemory;
    };
    defer allocator.free(db_path_z);

    // Open the database
    var db = try Database.open(db_path_z);
    errdefer db.close();

    // Configure pragmas for performance and reliability
    try db.execSql("PRAGMA journal_mode=WAL;");
    try db.execSql("PRAGMA synchronous=NORMAL;");
    try db.execSql("PRAGMA foreign_keys=ON;");
    try db.execSql("PRAGMA busy_timeout=5000;");

    return db;
}

/// Initialize an in-memory database with the same pragma configuration.
/// Useful for testing.
pub fn initMemoryDb() SqliteError!Database {
    var db = try Database.open(":memory:");
    errdefer db.close();

    // WAL mode doesn't work for :memory:, but we set other pragmas
    try db.execSql("PRAGMA synchronous=NORMAL;");
    try db.execSql("PRAGMA foreign_keys=ON;");
    try db.execSql("PRAGMA busy_timeout=5000;");

    return db;
}

test "sqlite open and close in-memory database" {
    var db = try Database.open(":memory:");
    defer db.close();

    // If we get here, open/close worked
    try std.testing.expect(db.db != null);
}

test "sqlite version" {
    const ver = Database.version();
    // SQLite version should start with "3."
    try std.testing.expect(ver.len > 0);
    try std.testing.expect(ver[0] == '3');
}

test "execSql creates table" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.execSql("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");
    try db.execSql("INSERT INTO test (name) VALUES ('hello');");
    // If we get here, exec worked
}

test "getPragma returns value" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:");
    defer db.close();

    const result = try db.getPragma(allocator, "PRAGMA foreign_keys;");
    defer allocator.free(result);

    // Default is "0" (off)
    try std.testing.expectEqualStrings("0", result);
}

test "initMemoryDb sets pragmas correctly" {
    const allocator = std.testing.allocator;
    var db = try initMemoryDb();
    defer db.close();

    // Check foreign_keys is ON
    const fk = try db.getPragma(allocator, "PRAGMA foreign_keys;");
    defer allocator.free(fk);
    try std.testing.expectEqualStrings("1", fk);

    // Check busy_timeout is 5000
    const timeout = try db.getPragma(allocator, "PRAGMA busy_timeout;");
    defer allocator.free(timeout);
    try std.testing.expectEqualStrings("5000", timeout);

    // Check synchronous is NORMAL (1)
    const sync = try db.getPragma(allocator, "PRAGMA synchronous;");
    defer allocator.free(sync);
    try std.testing.expectEqualStrings("1", sync);
}

test "initHistoryDb creates database with WAL mode" {
    const allocator = std.testing.allocator;

    // Create a temporary test database
    var db = try initHistoryDb(allocator);
    defer db.close();

    // Check WAL mode is set
    const journal = try db.getPragma(allocator, "PRAGMA journal_mode;");
    defer allocator.free(journal);
    try std.testing.expectEqualStrings("wal", journal);

    // Check foreign_keys is ON
    const fk = try db.getPragma(allocator, "PRAGMA foreign_keys;");
    defer allocator.free(fk);
    try std.testing.expectEqualStrings("1", fk);
}

test "openReadOnly returns DatabaseNotFound for missing file" {
    const result = Database.openReadOnly("/tmp/nonexistent-test-db-12345.db");
    try std.testing.expectError(SqliteError.DatabaseNotFound, result);
}

test "openReadOnly opens existing database" {
    // First create a database
    var db = try Database.open("/tmp/zig-test-readonly.db");
    try db.execSql("CREATE TABLE IF NOT EXISTS test (id INTEGER);");
    db.close();
    defer std.fs.cwd().deleteFile("/tmp/zig-test-readonly.db") catch {};

    // Now open it read-only
    var ro_db = try Database.openReadOnly("/tmp/zig-test-readonly.db");
    defer ro_db.close();

    // Should be able to read
    try std.testing.expect(ro_db.db != null);

    // Write should fail in read-only mode
    const write_result = ro_db.execSql("INSERT INTO test VALUES (1);");
    try std.testing.expectError(SqliteError.ExecFailed, write_result);
}
