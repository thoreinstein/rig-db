const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const server_mod = @import("server.zig");
const queue_mod = @import("queue.zig");
const writer_mod = @import("writer.zig");
const lifecycle = @import("lifecycle.zig");
const sanitizer_mod = @import("sanitizer.zig");
const paths = @import("../paths.zig");

const log = std.log.scoped(.daemon);

/// Global shutdown flag, accessed by signal handler
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Signal handler for SIGTERM/SIGINT
fn signalHandler(_: c_int) callconv(.c) void {
    shutdown_flag.store(true, .release);
}

/// Main daemon entry point. Orchestrates all components:
/// Writer (fallback recovery + DB writes), WriteQueue, Server, and worker thread.
pub fn daemonMain(allocator: mem.Allocator) !void {
    // Reset shutdown flag (important for tests or restart scenarios)
    shutdown_flag.store(false, .release);

    // 1. Init Writer and recover any fallback items
    var writer = try writer_mod.Writer.init(allocator);
    defer writer.deinit();

    const fallback_count = writer.processFallback() catch |err| blk: {
        log.warn("Failed to process fallback: {}", .{err});
        break :blk @as(usize, 0);
    };
    if (fallback_count > 0) {
        log.info("Recovered {} fallback items", .{fallback_count});
    }

    // 2. Init Sanitizer (loads config from ~/.config/rig/sanitize.json)
    const config_dir = paths.getConfigDir(allocator) catch null;
    const config = if (config_dir) |dir| blk: {
        defer allocator.free(dir);
        break :blk sanitizer_mod.loadConfig(allocator, dir);
    } else sanitizer_mod.SanitizeConfig{};
    defer sanitizer_mod.freeConfig(allocator, &config);

    var sanitizer = sanitizer_mod.Sanitizer.initWithConfig(allocator, config) catch |err| {
        log.err("Failed to init sanitizer: {}", .{err});
        return err;
    };
    defer sanitizer.deinit();

    // 3. Init WriteQueue (capacity 10,000)
    var write_queue = try queue_mod.WriteQueue.init(allocator, 10_000);
    defer write_queue.deinit();

    // 4. Init Server and start listening
    var server = try server_mod.Server.init(allocator);
    defer server.deinit();
    try server.start();

    // 5. Write PID file
    lifecycle.writePidFile(allocator) catch |err| {
        log.warn("Failed to write PID file: {}", .{err});
    };
    defer lifecycle.removePidFile(allocator);

    // 6. Register signal handlers
    installSignalHandlers();

    // 7. Spawn writer worker thread
    const worker_thread = std.Thread.spawn(.{}, writerThreadFn, .{ &write_queue, &writer, &sanitizer, allocator }) catch |err| {
        log.err("Failed to spawn writer thread: {}", .{err});
        return err;
    };

    // 8. Main loop: accept connections + idle timeout
    var idle_timer = lifecycle.IdleTimer.initDefault();

    log.info("Daemon started, listening on {s}", .{server.getPath()});

    while (!shutdown_flag.load(.acquire)) {
        const handled = server.pollOnce(&write_queue, allocator);
        if (handled) {
            idle_timer.resetTimer();
        }

        if (idle_timer.isExpired()) {
            log.info("Idle timeout expired, shutting down", .{});
            break;
        }

        if (!handled) {
            // No connection pending, sleep briefly to avoid busy-wait
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    // 9. Shutdown: signal worker, join, cleanup
    shutdown_flag.store(true, .release);
    worker_thread.join();

    log.info("Daemon stopped", .{});
}

/// Writer worker thread function. Dequeues batches from the write queue,
/// sanitizes PII, and processes them through the Writer (SQLite INSERT/UPDATE).
fn writerThreadFn(write_queue: *queue_mod.WriteQueue, writer: *writer_mod.Writer, sanitizer: *const sanitizer_mod.Sanitizer, allocator: mem.Allocator) void {
    while (!shutdown_flag.load(.acquire)) {
        const batch = write_queue.dequeueBatch(100) catch |err| {
            log.err("Failed to dequeue batch: {}", .{err});
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };

        if (batch.len == 0) {
            allocator.free(batch);
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        sanitizer.sanitizeBatch(batch, allocator);

        writer.processBatch(batch) catch |err| {
            log.err("Failed to process batch of {} items: {}", .{ batch.len, err });
        };

        for (batch) |item| {
            var mutable_item = item;
            write_queue.freeItem(&mutable_item);
        }
        allocator.free(batch);
    }

    // Drain remaining items on shutdown
    drainQueue(write_queue, writer, sanitizer, allocator);
}

/// Drain any remaining items from the queue during shutdown.
fn drainQueue(write_queue: *queue_mod.WriteQueue, writer: *writer_mod.Writer, sanitizer: *const sanitizer_mod.Sanitizer, allocator: mem.Allocator) void {
    while (true) {
        const batch = write_queue.dequeueBatch(100) catch break;
        if (batch.len == 0) {
            allocator.free(batch);
            break;
        }

        sanitizer.sanitizeBatch(batch, allocator);

        writer.processBatch(batch) catch |err| {
            log.err("Failed to process final batch: {}", .{err});
        };

        for (batch) |item| {
            var mutable_item = item;
            write_queue.freeItem(&mutable_item);
        }
        allocator.free(batch);
    }
}

/// Install SIGTERM and SIGINT handlers to trigger graceful shutdown.
fn installSignalHandlers() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);
}

// =============================================================================
// Tests
// =============================================================================

test "shutdown flag starts false" {
    shutdown_flag.store(false, .release);
    try std.testing.expect(!shutdown_flag.load(.acquire));
}

test "signal handler sets shutdown flag" {
    shutdown_flag.store(false, .release);
    signalHandler(posix.SIG.TERM);
    try std.testing.expect(shutdown_flag.load(.acquire));
    // Reset for other tests
    shutdown_flag.store(false, .release);
}

test "drainQueue processes remaining items" {
    const allocator = std.testing.allocator;

    var write_queue = try queue_mod.WriteQueue.init(allocator, 10);
    defer write_queue.deinit();

    var writer = try writer_mod.Writer.initWithConfig(allocator, .{ .use_memory_db = true });
    defer writer.deinit();

    // Enqueue a start message
    const id = try allocator.dupe(u8, "drain-test-id");
    errdefer allocator.free(id);
    const cmd = try allocator.dupe(u8, "echo drain");
    errdefer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/tmp");
    errdefer allocator.free(cwd);
    const session = try allocator.dupe(u8, "session-drain");
    errdefer allocator.free(session);
    const hostname = try allocator.dupe(u8, "testhost");
    errdefer allocator.free(hostname);

    const protocol = @import("protocol.zig");
    const item = queue_mod.QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 1234567890,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };
    try write_queue.enqueue(item);

    // Init sanitizer for drain test
    var sanitizer = try sanitizer_mod.Sanitizer.init(allocator);
    defer sanitizer.deinit();

    // Drain should process it
    drainQueue(&write_queue, &writer, &sanitizer, allocator);

    // Queue should be empty
    try std.testing.expect(write_queue.isEmpty());
}
