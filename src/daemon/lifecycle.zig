const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fs = std.fs;
const c = std.c;

/// Default idle timeout in nanoseconds (5 minutes)
pub const DEFAULT_IDLE_TIMEOUT_NS: u64 = 5 * 60 * std.time.ns_per_s;

/// Maximum time to wait for daemon socket to become ready (5 seconds)
const SOCKET_READY_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;

/// Polling interval when waiting for socket (50ms)
const SOCKET_POLL_INTERVAL_NS: u64 = 50 * std.time.ns_per_ms;

/// PID file name
const PID_FILENAME = "rig.pid";

/// Socket file name (must match server.zig)
const SOCKET_FILENAME = "rig.sock";

/// Errors that can occur during lifecycle operations
pub const LifecycleError = error{
    RuntimeDirNotFound,
    OutOfMemory,
    PidFileWriteFailed,
    PidFileReadFailed,
    DaemonSpawnFailed,
    SocketNotReady,
    ForkFailed,
    SetsidFailed,
    PathTooLong,
    ExecFailed,
};

/// Get the runtime directory for PID and socket files.
/// Uses XDG_RUNTIME_DIR if available, otherwise /tmp.
fn getRuntimeDir(allocator: mem.Allocator) LifecycleError![]u8 {
    // First try XDG_RUNTIME_DIR
    if (posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            return allocator.dupe(u8, runtime_dir) catch {
                return LifecycleError.OutOfMemory;
            };
        }
    }

    // Fall back to /tmp
    return allocator.dupe(u8, "/tmp") catch {
        return LifecycleError.OutOfMemory;
    };
}

/// Get the path to the PID file.
/// Uses $XDG_RUNTIME_DIR/rig.pid or /tmp/rig-{uid}.pid
/// Caller owns the returned memory.
pub fn getPidFilePath(allocator: mem.Allocator) LifecycleError![]u8 {
    // First try XDG_RUNTIME_DIR
    if (posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            return fs.path.join(allocator, &[_][]const u8{ runtime_dir, PID_FILENAME }) catch {
                return LifecycleError.OutOfMemory;
            };
        }
    }

    // Fall back to /tmp/rig-{uid}.pid
    const uid = c.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/rig-{d}.pid", .{uid}) catch {
        return LifecycleError.OutOfMemory;
    };
}

/// Get the path to the socket file.
/// Must match server.zig's getSocketPath function.
fn getSocketPath(allocator: mem.Allocator) LifecycleError![]u8 {
    // First try XDG_RUNTIME_DIR
    if (posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            return fs.path.join(allocator, &[_][]const u8{ runtime_dir, SOCKET_FILENAME }) catch {
                return LifecycleError.OutOfMemory;
            };
        }
    }

    // Fall back to /tmp/rig-{uid}.sock
    const uid = c.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/rig-{d}.sock", .{uid}) catch {
        return LifecycleError.OutOfMemory;
    };
}

/// Read the PID from the PID file.
/// Returns null if the file doesn't exist or can't be read.
fn readPidFile(allocator: mem.Allocator) ?posix.pid_t {
    const pid_path = getPidFilePath(allocator) catch return null;
    defer allocator.free(pid_path);

    const file = fs.cwd().openFile(pid_path, .{}) catch return null;
    defer file.close();

    var buffer: [32]u8 = undefined;
    const bytes_read = file.readAll(&buffer) catch return null;

    if (bytes_read == 0) return null;

    // Trim whitespace and parse
    const content = mem.trim(u8, buffer[0..bytes_read], &std.ascii.whitespace);
    return std.fmt.parseInt(posix.pid_t, content, 10) catch null;
}

/// Check if a process with the given PID is running.
fn isProcessRunning(pid: posix.pid_t) bool {
    // Use kill with signal 0 to check if process exists
    // This doesn't actually send a signal, just checks if the process is valid
    posix.kill(pid, 0) catch |err| {
        // If kill fails with ProcessNotFound, process doesn't exist
        // If kill fails with PermissionDenied, process exists but we don't have permission
        return err != error.ProcessNotFound;
    };

    // If kill succeeds, process exists
    return true;
}

/// Check if the daemon is currently running.
/// Returns true if a valid PID file exists and the process is alive.
pub fn isDaemonRunning(allocator: mem.Allocator) bool {
    const pid = readPidFile(allocator) orelse return false;
    return isProcessRunning(pid);
}

/// Write the current process PID to the PID file.
/// Called by the daemon on startup.
pub fn writePidFile(allocator: mem.Allocator) LifecycleError!void {
    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    const file = fs.cwd().createFile(pid_path, .{
        .mode = 0o644, // rw-r--r--
    }) catch {
        return LifecycleError.PidFileWriteFailed;
    };
    defer file.close();

    const pid = c.getpid();
    var buffer: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buffer, "{d}\n", .{pid}) catch {
        return LifecycleError.PidFileWriteFailed;
    };

    file.writeAll(pid_str) catch {
        return LifecycleError.PidFileWriteFailed;
    };
}

/// Remove the PID file.
/// Called by the daemon on shutdown.
pub fn removePidFile(allocator: mem.Allocator) void {
    const pid_path = getPidFilePath(allocator) catch return;
    defer allocator.free(pid_path);

    fs.cwd().deleteFile(pid_path) catch {};
}

/// Check if the socket file exists and is accessible.
fn isSocketReady(allocator: mem.Allocator) bool {
    const socket_path = getSocketPath(allocator) catch return false;
    defer allocator.free(socket_path);

    // Try to stat the socket file
    const stat = fs.cwd().statFile(socket_path) catch return false;

    // Check if it's a socket
    return stat.kind == .unix_domain_socket;
}

/// Wait for the daemon socket to become ready.
/// Returns error if socket doesn't become available within timeout.
fn waitForSocket(allocator: mem.Allocator) LifecycleError!void {
    var elapsed: u64 = 0;

    while (elapsed < SOCKET_READY_TIMEOUT_NS) {
        if (isSocketReady(allocator)) {
            return; // Socket is ready
        }

        // Sleep for poll interval
        std.Thread.sleep(SOCKET_POLL_INTERVAL_NS);
        elapsed += SOCKET_POLL_INTERVAL_NS;
    }

    return LifecycleError.SocketNotReady;
}

/// Get the path to the daemon executable.
/// For now, assumes the daemon is the same executable with a "daemon" subcommand.
fn getDaemonExePath(allocator: mem.Allocator) LifecycleError![]u8 {
    // Get the path to the current executable
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const exe_path = fs.selfExePath(&path_buf) catch {
        return LifecycleError.DaemonSpawnFailed;
    };

    return allocator.dupe(u8, exe_path) catch {
        return LifecycleError.OutOfMemory;
    };
}

/// Spawn the daemon process if not already running.
/// The daemon is launched as a detached background process.
/// Waits for the socket to become ready before returning.
pub fn ensureDaemonRunning(allocator: mem.Allocator) LifecycleError!void {
    // Check if daemon is already running
    if (isDaemonRunning(allocator)) {
        // Daemon is running, but make sure socket is ready
        if (isSocketReady(allocator)) {
            return; // All good
        }
        // Daemon running but socket not ready - wait for it
        return waitForSocket(allocator);
    }

    // Need to spawn the daemon
    try spawnDaemon(allocator);

    // Wait for socket to become ready
    return waitForSocket(allocator);
}

/// Spawn the daemon as a detached background process.
fn spawnDaemon(allocator: mem.Allocator) LifecycleError!void {
    const exe_path = try getDaemonExePath(allocator);
    defer allocator.free(exe_path);

    // Build argv: [exe_path, "daemon", null]
    const argv = [_:null]?[*:0]const u8{
        @ptrCast(exe_path.ptr),
        "daemon",
    };

    // Fork the process
    const child_pid = posix.fork() catch {
        return LifecycleError.ForkFailed;
    };

    if (child_pid == 0) {
        // Child process - will become the daemon

        // Create new session (detach from terminal)
        const setsid_result = std.c.setsid();
        if (setsid_result == -1) {
            // Can't call std.process.exit in fork child reliably
            // Just _exit directly
            _ = std.c._exit(1);
        }

        // Fork again to prevent reacquiring a terminal
        const grandchild_pid = posix.fork() catch {
            _ = std.c._exit(1);
        };

        if (grandchild_pid == 0) {
            // Grandchild - the actual daemon

            // Redirect stdio to /dev/null
            const dev_null = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
                _ = std.c._exit(1);
            };
            defer posix.close(dev_null);

            // Redirect stdin, stdout, stderr to /dev/null
            posix.dup2(dev_null, posix.STDIN_FILENO) catch {};
            posix.dup2(dev_null, posix.STDOUT_FILENO) catch {};
            posix.dup2(dev_null, posix.STDERR_FILENO) catch {};

            // Change to root directory to avoid holding onto mount points
            _ = posix.chdir("/") catch {};

            // Execute the daemon
            // execveZ only returns on error, so we exit on error
            _ = posix.execveZ(
                @ptrCast(exe_path.ptr),
                &argv,
                @ptrCast(std.c.environ),
            ) catch {};

            // If execve returns, it failed
            _ = std.c._exit(1);
        } else {
            // First child - exit immediately
            // The grandchild continues as the daemon
            _ = std.c._exit(0);
        }
    } else {
        // Parent process - wait for child to exit
        // (Child will exit immediately, grandchild becomes daemon)
        _ = posix.waitpid(child_pid, 0);
    }
}

/// Idle timeout manager for the daemon.
/// Tracks last activity time and triggers shutdown when idle.
pub const IdleTimer = struct {
    last_activity_ns: i128,
    timeout_ns: u64,

    const Self = @This();

    /// Create a new idle timer with the given timeout.
    pub fn init(timeout_ns: u64) Self {
        return Self{
            .last_activity_ns = std.time.nanoTimestamp(),
            .timeout_ns = timeout_ns,
        };
    }

    /// Create a new idle timer with default timeout (5 minutes).
    pub fn initDefault() Self {
        return init(DEFAULT_IDLE_TIMEOUT_NS);
    }

    /// Reset the idle timer (called on each connection/activity).
    pub fn resetTimer(self: *Self) void {
        self.last_activity_ns = std.time.nanoTimestamp();
    }

    /// Check if the idle timeout has expired.
    pub fn isExpired(self: *const Self) bool {
        const now = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(now - self.last_activity_ns);
        return elapsed >= self.timeout_ns;
    }

    /// Get remaining time until expiration in nanoseconds.
    /// Returns 0 if already expired.
    pub fn remainingNs(self: *const Self) u64 {
        const now = std.time.nanoTimestamp();
        const elapsed: u64 = @intCast(now - self.last_activity_ns);
        if (elapsed >= self.timeout_ns) {
            return 0;
        }
        return self.timeout_ns - elapsed;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "getPidFilePath returns valid path" {
    const allocator = std.testing.allocator;

    const path = try getPidFilePath(allocator);
    defer allocator.free(path);

    // Path should be non-empty
    try std.testing.expect(path.len > 0);

    // Path should contain "rig"
    try std.testing.expect(mem.indexOf(u8, path, "rig") != null);

    // Path should end with .pid
    try std.testing.expect(mem.endsWith(u8, path, ".pid"));
}

test "getSocketPath returns valid path" {
    const allocator = std.testing.allocator;

    const path = try getSocketPath(allocator);
    defer allocator.free(path);

    // Path should be non-empty
    try std.testing.expect(path.len > 0);

    // Path should contain "rig"
    try std.testing.expect(mem.indexOf(u8, path, "rig") != null);

    // Path should end with .sock
    try std.testing.expect(mem.endsWith(u8, path, ".sock"));
}

test "isDaemonRunning returns false when no PID file" {
    const allocator = std.testing.allocator;

    // Clean up any existing PID file first
    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);
    fs.cwd().deleteFile(pid_path) catch {};

    // Should return false when no daemon is running
    try std.testing.expect(!isDaemonRunning(allocator));
}

test "writePidFile creates valid PID file" {
    const allocator = std.testing.allocator;

    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    // Clean up first
    fs.cwd().deleteFile(pid_path) catch {};

    // Write PID file
    try writePidFile(allocator);
    defer removePidFile(allocator);

    // Verify file exists
    const stat = fs.cwd().statFile(pid_path) catch null;
    try std.testing.expect(stat != null);

    // Read back the PID
    const read_pid = readPidFile(allocator);
    try std.testing.expect(read_pid != null);
    try std.testing.expectEqual(c.getpid(), read_pid.?);
}

test "removePidFile removes the file" {
    const allocator = std.testing.allocator;

    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    // Create a PID file
    try writePidFile(allocator);

    // Verify it exists
    const stat1 = fs.cwd().statFile(pid_path) catch null;
    try std.testing.expect(stat1 != null);

    // Remove it
    removePidFile(allocator);

    // Verify it's gone
    const stat2 = fs.cwd().statFile(pid_path) catch null;
    try std.testing.expect(stat2 == null);
}

test "isProcessRunning returns true for current process" {
    const pid = c.getpid();
    try std.testing.expect(isProcessRunning(pid));
}

test "isProcessRunning returns false for invalid PID" {
    // Use a very high PID that's unlikely to exist
    // PID 999999 should not exist on most systems
    try std.testing.expect(!isProcessRunning(999999));
}

test "IdleTimer init sets correct timeout" {
    const timer = IdleTimer.init(1000);
    try std.testing.expectEqual(@as(u64, 1000), timer.timeout_ns);
}

test "IdleTimer initDefault sets 5 minute timeout" {
    const timer = IdleTimer.initDefault();
    try std.testing.expectEqual(DEFAULT_IDLE_TIMEOUT_NS, timer.timeout_ns);
}

test "IdleTimer isExpired returns false immediately after init" {
    const timer = IdleTimer.initDefault();
    try std.testing.expect(!timer.isExpired());
}

test "IdleTimer isExpired returns true after timeout" {
    // Use a very short timeout (1 nanosecond)
    var timer = IdleTimer.init(1);

    // Sleep a bit to ensure timeout
    std.Thread.sleep(1000);

    try std.testing.expect(timer.isExpired());
}

test "IdleTimer resetTimer resets expiration" {
    // Use a short timeout
    var timer = IdleTimer.init(std.time.ns_per_ms * 100);

    // Wait a bit
    std.Thread.sleep(std.time.ns_per_ms * 50);

    // Reset
    timer.resetTimer();

    // Should not be expired
    try std.testing.expect(!timer.isExpired());
}

test "IdleTimer remainingNs returns correct value" {
    const timeout = std.time.ns_per_s; // 1 second
    const timer = IdleTimer.init(timeout);

    // Remaining should be close to timeout
    const remaining = timer.remainingNs();
    try std.testing.expect(remaining > 0);
    try std.testing.expect(remaining <= timeout);
}

test "IdleTimer remainingNs returns 0 when expired" {
    var timer = IdleTimer.init(1); // 1 nanosecond timeout
    std.Thread.sleep(1000);

    try std.testing.expectEqual(@as(u64, 0), timer.remainingNs());
}

test "getRuntimeDir returns valid path" {
    const allocator = std.testing.allocator;

    const path = try getRuntimeDir(allocator);
    defer allocator.free(path);

    // Path should be non-empty
    try std.testing.expect(path.len > 0);

    // Should be either XDG_RUNTIME_DIR or /tmp
    try std.testing.expect(mem.startsWith(u8, path, "/"));
}

test "isDaemonRunning with stale PID file" {
    const allocator = std.testing.allocator;

    const pid_path = try getPidFilePath(allocator);
    defer allocator.free(pid_path);

    // Clean up first
    fs.cwd().deleteFile(pid_path) catch {};

    // Create a stale PID file with a non-existent PID
    const file = try fs.cwd().createFile(pid_path, .{});
    defer fs.cwd().deleteFile(pid_path) catch {};
    try file.writeAll("999999\n");
    file.close();

    // Should return false because the process doesn't exist
    try std.testing.expect(!isDaemonRunning(allocator));
}
