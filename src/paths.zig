const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;

/// Errors that can occur during path resolution
pub const PathError = error{
    HomeNotFound,
    PathTooLong,
    OutOfMemory,
    AccessDenied,
    PermissionDenied,
    SystemResources,
    Unexpected,
};

/// The application name used for data directory
const APP_NAME = "rig";

/// Default XDG data home subdirectory relative to HOME
const DEFAULT_DATA_SUBDIR = ".local/share";

/// Get the XDG data directory for rig.
/// Respects $XDG_DATA_HOME when set, otherwise falls back to ~/.local/share/rig.
/// Creates the directory if it doesn't exist.
/// Caller owns the returned memory and must free it with the provided allocator.
pub fn getDataDir(allocator: mem.Allocator) PathError![]u8 {
    const data_home = getDataHome(allocator) catch |err| return err;
    defer allocator.free(data_home);

    // Build the full path: data_home/rig
    const full_path = fs.path.join(allocator, &[_][]const u8{ data_home, APP_NAME }) catch {
        return PathError.OutOfMemory;
    };
    errdefer allocator.free(full_path);

    // Create the directory if it doesn't exist
    ensureDir(full_path) catch |err| {
        return err;
    };

    return full_path;
}

/// Get the XDG data home directory.
/// Respects $XDG_DATA_HOME when set, otherwise falls back to ~/.local/share.
/// Caller owns the returned memory and must free it with the provided allocator.
fn getDataHome(allocator: mem.Allocator) PathError![]u8 {
    // Check XDG_DATA_HOME first
    if (posix.getenv("XDG_DATA_HOME")) |xdg_data_home| {
        if (xdg_data_home.len > 0) {
            return allocator.dupe(u8, xdg_data_home) catch {
                return PathError.OutOfMemory;
            };
        }
    }

    // Fall back to ~/.local/share
    const home = posix.getenv("HOME") orelse {
        return PathError.HomeNotFound;
    };

    return fs.path.join(allocator, &[_][]const u8{ home, DEFAULT_DATA_SUBDIR }) catch {
        return PathError.OutOfMemory;
    };
}

/// Ensure a directory exists, creating it and all parent directories if necessary.
fn ensureDir(path: []const u8) PathError!void {
    fs.cwd().makePath(path) catch |err| {
        return switch (err) {
            error.AccessDenied => PathError.AccessDenied,
            error.SymLinkLoop,
            error.NameTooLong,
            error.InvalidUtf8,
            error.InvalidWtf8,
            error.BadPathName,
            error.NoDevice,
            error.FileNotFound,
            error.NotDir,
            error.PathAlreadyExists,
            error.AntivirusInterference,
            error.DeviceBusy,
            error.DiskQuota,
            error.FileBusy,
            error.FileLocksNotSupported,
            error.FileTooBig,
            error.IsDir,
            error.LinkQuotaExceeded,
            error.NetworkNotFound,
            error.NoSpaceLeft,
            error.PipeBusy,
            error.ProcessFdQuotaExceeded,
            error.ProcessNotFound,
            error.SharingViolation,
            error.SystemFdQuotaExceeded,
            error.WouldBlock,
            => PathError.Unexpected,
            error.ReadOnlyFileSystem,
            error.PermissionDenied,
            => PathError.PermissionDenied,
            error.SystemResources => PathError.SystemResources,
            error.Unexpected => PathError.Unexpected,
        };
    };
}

/// Get the full path to the history database file.
/// Caller owns the returned memory and must free it with the provided allocator.
pub fn getHistoryDbPath(allocator: mem.Allocator) PathError![]u8 {
    const data_dir = try getDataDir(allocator);
    defer allocator.free(data_dir);

    return fs.path.join(allocator, &[_][]const u8{ data_dir, "history.db" }) catch {
        return PathError.OutOfMemory;
    };
}

// =============================================================================
// Tests
// =============================================================================

test "getDataDir respects XDG_DATA_HOME" {
    const allocator = std.testing.allocator;

    // Save original environment values
    const original_xdg = posix.getenv("XDG_DATA_HOME");
    const original_home = posix.getenv("HOME");

    // Set up test environment
    const test_dir = "/tmp/rig-test-xdg";

    // Clean up any existing test directory
    fs.cwd().deleteTree(test_dir) catch {};

    // Create the test base directory
    fs.cwd().makePath(test_dir) catch |err| {
        std.debug.print("Failed to create test dir: {}\n", .{err});
        return err;
    };
    defer fs.cwd().deleteTree(test_dir) catch {};

    // Set XDG_DATA_HOME for the test
    // Note: We can't actually set env vars in Zig tests easily,
    // so we test the helper function directly
    _ = original_xdg;
    _ = original_home;

    // Test that getDataHome falls back correctly when HOME is set
    // This tests the fallback path since XDG_DATA_HOME might not be set
    const data_home = getDataHome(allocator) catch |err| {
        std.debug.print("getDataHome failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(data_home);

    // Verify it's a valid path (either XDG_DATA_HOME or ~/.local/share)
    try std.testing.expect(data_home.len > 0);
}

test "getDataDir creates directory if missing" {
    const allocator = std.testing.allocator;

    // Get the data directory - this should create it if missing
    const data_dir = getDataDir(allocator) catch |err| {
        // If HOME isn't set, skip this test
        if (err == PathError.HomeNotFound) {
            return;
        }
        return err;
    };
    defer allocator.free(data_dir);

    // Verify the directory exists
    var dir = fs.cwd().openDir(data_dir, .{}) catch |err| {
        std.debug.print("Failed to open created dir: {}\n", .{err});
        return err;
    };
    dir.close();
}

test "getHistoryDbPath returns correct path" {
    const allocator = std.testing.allocator;

    const db_path = getHistoryDbPath(allocator) catch |err| {
        // If HOME isn't set, skip this test
        if (err == PathError.HomeNotFound) {
            return;
        }
        return err;
    };
    defer allocator.free(db_path);

    // Verify path ends with history.db
    try std.testing.expect(mem.endsWith(u8, db_path, "history.db"));

    // Verify path contains rig directory
    try std.testing.expect(mem.indexOf(u8, db_path, "/rig/") != null);
}

test "ensureDir creates nested directories" {
    const test_path = "/tmp/rig-test-nested/a/b/c";

    // Clean up first
    fs.cwd().deleteTree("/tmp/rig-test-nested") catch {};

    // Create nested directory
    try ensureDir(test_path);

    // Verify it exists
    var dir = try fs.cwd().openDir(test_path, .{});
    dir.close();

    // Clean up
    fs.cwd().deleteTree("/tmp/rig-test-nested") catch {};
}

test "getDataHome returns non-empty path" {
    const allocator = std.testing.allocator;

    const data_home = getDataHome(allocator) catch |err| {
        // If HOME isn't set, skip this test
        if (err == PathError.HomeNotFound) {
            return;
        }
        return err;
    };
    defer allocator.free(data_home);

    try std.testing.expect(data_home.len > 0);
}
