const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Current schema version. Increment when making schema changes.
pub const SCHEMA_VERSION: u32 = 1;

/// Schema-related errors
pub const SchemaError = error{
    MigrationFailed,
    VersionCheckFailed,
    TableCreationFailed,
    IndexCreationFailed,
};

/// SQL for creating the history table (from ADR)
const CREATE_HISTORY_TABLE: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS history (
    \\    id TEXT PRIMARY KEY,        -- UUID v7 (time-ordered)
    \\    timestamp INTEGER NOT NULL, -- Nanoseconds since epoch
    \\    duration INTEGER NOT NULL,  -- Nanoseconds
    \\    exit INTEGER NOT NULL,      -- Exit code
    \\    command TEXT NOT NULL,      -- The command string
    \\    cwd TEXT NOT NULL,          -- Working directory
    \\    session TEXT NOT NULL,      -- Session UUID
    \\    hostname TEXT NOT NULL,     -- Hostname
    \\    deleted_at INTEGER          -- Soft delete timestamp
    \\);
;

/// SQL for creating the schema version table
const CREATE_SCHEMA_VERSION_TABLE: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS schema_version (
    \\    version INTEGER PRIMARY KEY,
    \\    applied_at INTEGER NOT NULL
    \\);
;

/// SQL for indexes on commonly queried columns
const CREATE_INDEXES = [_][:0]const u8{
    "CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_history_cwd ON history(cwd);",
    "CREATE INDEX IF NOT EXISTS idx_history_session ON history(session);",
    "CREATE INDEX IF NOT EXISTS idx_history_deleted ON history(deleted_at) WHERE deleted_at IS NULL;",
};

/// Initialize the database schema.
/// Creates tables and indexes if they don't exist.
/// Handles migrations for schema version upgrades.
pub fn initSchema(db: *sqlite.Database) (SchemaError || sqlite.SqliteError)!void {
    // Create schema version table first
    try db.execSql(CREATE_SCHEMA_VERSION_TABLE);

    // Check current schema version
    const current_version = getSchemaVersion(db) catch 0;

    if (current_version < SCHEMA_VERSION) {
        // Run migrations
        try migrate(db, current_version);
    }
}

/// Get the current schema version from the database.
/// Returns 0 if no version is recorded.
pub fn getSchemaVersion(db: *sqlite.Database) (SchemaError || sqlite.SqliteError)!u32 {
    const allocator = std.heap.page_allocator;

    // Try to get the max version - will fail if table doesn't exist
    const result = db.getPragma(allocator, "SELECT COALESCE(MAX(version), 0) FROM schema_version;") catch {
        return 0; // Table doesn't exist yet
    };
    defer allocator.free(result);

    return std.fmt.parseInt(u32, result, 10) catch 0;
}

/// Run migrations from current_version to SCHEMA_VERSION.
fn migrate(db: *sqlite.Database, current_version: u32) (SchemaError || sqlite.SqliteError)!void {
    // Migration 0 -> 1: Initial schema
    if (current_version < 1) {
        try migrateToV1(db);
    }

    // Future migrations would go here:
    // if (current_version < 2) {
    //     try migrateToV2(db);
    // }
}

/// Migration to schema version 1: Create initial tables and indexes.
fn migrateToV1(db: *sqlite.Database) (SchemaError || sqlite.SqliteError)!void {
    // Create history table
    db.execSql(CREATE_HISTORY_TABLE) catch {
        return SchemaError.TableCreationFailed;
    };

    // Create indexes
    for (CREATE_INDEXES) |index_sql| {
        db.execSql(index_sql) catch {
            return SchemaError.IndexCreationFailed;
        };
    }

    // Record the migration
    try recordVersion(db, 1);
}

/// Record a schema version in the version table.
fn recordVersion(db: *sqlite.Database, version: u32) sqlite.SqliteError!void {
    const timestamp = std.time.nanoTimestamp();
    var buf: [128]u8 = undefined;
    const sql = std.fmt.bufPrintZ(&buf, "INSERT INTO schema_version (version, applied_at) VALUES ({d}, {d});", .{ version, timestamp }) catch {
        return sqlite.SqliteError.OutOfMemory;
    };
    try db.execSql(sql);
}

// =============================================================================
// Tests
// =============================================================================

test "initSchema creates tables" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    try initSchema(&db);

    // Verify history table exists by inserting a row
    try db.execSql(
        \\INSERT INTO history (id, timestamp, duration, exit, command, cwd, session, hostname)
        \\VALUES ('test-id', 1234567890, 100, 0, 'ls -la', '/home/user', 'session-1', 'localhost');
    );
}

test "initSchema creates indexes" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    try initSchema(&db);

    // Verify indexes exist by checking sqlite_master
    // If the index doesn't exist, this query would fail
    try db.execSql("SELECT * FROM sqlite_master WHERE type='index' AND name='idx_history_timestamp';");
}

test "initSchema is idempotent" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    // Run init multiple times - should not fail
    try initSchema(&db);
    try initSchema(&db);
    try initSchema(&db);
}

test "schema version is tracked" {
    var db = try sqlite.initMemoryDb();
    defer db.close();

    try initSchema(&db);

    const version = try getSchemaVersion(&db);
    try std.testing.expectEqual(@as(u32, SCHEMA_VERSION), version);
}
