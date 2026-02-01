const std = @import("std");
const mem = std.mem;
const protocol = @import("protocol.zig");

/// Errors that can occur during queue operations
pub const QueueError = error{
    /// Queue has reached maximum capacity
    QueueFull,
    /// Memory allocation failed
    OutOfMemory,
};

/// A queue item wrapping a protocol message with its associated memory.
/// The queue takes ownership of the message's allocated strings.
pub const QueueItem = union(protocol.MessageType) {
    start: protocol.StartMessage,
    end: protocol.EndMessage,
};

/// Thread-safe FIFO write queue for buffering protocol messages.
/// Uses a ring buffer backed by a fixed-size array for bounded memory usage.
pub const WriteQueue = struct {
    /// Ring buffer storage for queue items
    items: []QueueItem,
    /// Index of the next item to dequeue (head)
    head: usize,
    /// Index where the next item will be enqueued (tail)
    tail: usize,
    /// Current number of items in the queue
    count: usize,
    /// Maximum number of items the queue can hold
    max_size: usize,
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,
    /// Allocator used for the items array and freeing messages
    allocator: mem.Allocator,

    const Self = @This();

    /// Initialize a new write queue with the specified maximum size.
    /// The queue will reject new items once max_size is reached.
    pub fn init(allocator: mem.Allocator, max_size: usize) QueueError!Self {
        const items = allocator.alloc(QueueItem, max_size) catch {
            return QueueError.OutOfMemory;
        };

        return Self{
            .items = items,
            .head = 0,
            .tail = 0,
            .count = 0,
            .max_size = max_size,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    /// Add an item to the queue (non-blocking).
    /// Returns QueueError.QueueFull if the queue is at capacity.
    /// Takes ownership of the item's allocated strings.
    pub fn enqueue(self: *Self, item: QueueItem) QueueError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count >= self.max_size) {
            return QueueError.QueueFull;
        }

        self.items[self.tail] = item;
        self.tail = (self.tail + 1) % self.max_size;
        self.count += 1;
    }

    /// Get the next item from the queue (non-blocking).
    /// Returns null if the queue is empty.
    /// Caller takes ownership of the returned item's allocated strings
    /// and must free them using protocol.freeMessage when done.
    pub fn dequeue(self: *Self) ?QueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) {
            return null;
        }

        const item = self.items[self.head];
        self.head = (self.head + 1) % self.max_size;
        self.count -= 1;

        return item;
    }

    /// Get multiple items from the queue in a single operation.
    /// Returns up to batch_size items in FIFO order.
    /// Caller owns the returned slice and the items within it.
    /// The slice must be freed with allocator.free() when done.
    /// Each item's strings must also be freed using protocol.freeMessage.
    pub fn dequeueBatch(self: *Self, batch_size: usize) QueueError![]QueueItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        const actual_batch = @min(batch_size, self.count);
        if (actual_batch == 0) {
            // Return empty slice
            return self.allocator.alloc(QueueItem, 0) catch {
                return QueueError.OutOfMemory;
            };
        }

        const batch = self.allocator.alloc(QueueItem, actual_batch) catch {
            return QueueError.OutOfMemory;
        };

        for (0..actual_batch) |i| {
            batch[i] = self.items[self.head];
            self.head = (self.head + 1) % self.max_size;
        }
        self.count -= actual_batch;

        return batch;
    }

    /// Returns the current number of items in the queue.
    pub fn len(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.count;
    }

    /// Returns true if the queue is at maximum capacity.
    pub fn isFull(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.count >= self.max_size;
    }

    /// Returns true if the queue is empty.
    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.count == 0;
    }

    /// Free a queue item's allocated strings.
    /// Helper method that delegates to protocol.freeMessage.
    pub fn freeItem(self: *Self, item: *QueueItem) void {
        var msg = switch (item.*) {
            .start => |s| protocol.IncomingMessage{ .start = s },
            .end => |e| protocol.IncomingMessage{ .end = e },
        };
        protocol.freeMessage(&msg, self.allocator);
    }

    /// Clean up the queue and all items within it.
    /// Frees all remaining items' allocated strings.
    pub fn deinit(self: *Self) void {
        // Free any remaining items in the queue
        while (self.dequeue()) |item| {
            var mutable_item = item;
            self.freeItem(&mutable_item);
        }

        self.allocator.free(self.items);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "WriteQueue init and deinit" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(!queue.isFull());
    try std.testing.expect(queue.isEmpty());
}

test "WriteQueue enqueue and dequeue single item" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    // Create a test item - allocate strings as the queue expects owned memory
    const id = try allocator.dupe(u8, "test-id-1");
    errdefer allocator.free(id);

    const item = QueueItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = 0,
            .duration = 1000,
        },
    };

    // Enqueue
    try queue.enqueue(item);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    try std.testing.expect(!queue.isEmpty());

    // Dequeue
    var dequeued = queue.dequeue();
    try std.testing.expect(dequeued != null);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(queue.isEmpty());

    // Verify content
    try std.testing.expect(dequeued.? == .end);
    try std.testing.expectEqualStrings("test-id-1", dequeued.?.end.id);
    try std.testing.expectEqual(@as(i32, 0), dequeued.?.end.exit);

    // Free the item's strings
    queue.freeItem(&dequeued.?);
}

test "WriteQueue FIFO order" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    // Enqueue items in order
    for (0..5) |i| {
        const id = try std.fmt.allocPrint(allocator, "id-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = @intCast(i),
                .duration = @intCast(i * 100),
            },
        };
        try queue.enqueue(item);
    }

    try std.testing.expectEqual(@as(usize, 5), queue.len());

    // Dequeue and verify FIFO order
    for (0..5) |i| {
        var dequeued = queue.dequeue();
        try std.testing.expect(dequeued != null);

        const expected_id = try std.fmt.allocPrint(allocator, "id-{d}", .{i});
        defer allocator.free(expected_id);

        try std.testing.expectEqualStrings(expected_id, dequeued.?.end.id);
        try std.testing.expectEqual(@as(i32, @intCast(i)), dequeued.?.end.exit);

        queue.freeItem(&dequeued.?);
    }

    try std.testing.expect(queue.isEmpty());
}

test "WriteQueue handles full queue" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 3);
    defer queue.deinit();

    // Fill the queue
    for (0..3) |i| {
        const id = try std.fmt.allocPrint(allocator, "id-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = 0,
                .duration = 0,
            },
        };
        try queue.enqueue(item);
    }

    try std.testing.expect(queue.isFull());

    // Try to add one more - should fail
    const overflow_id = try allocator.dupe(u8, "overflow");
    const overflow_item = QueueItem{
        .end = protocol.EndMessage{
            .id = overflow_id,
            .exit = 0,
            .duration = 0,
        },
    };

    const result = queue.enqueue(overflow_item);
    try std.testing.expectError(QueueError.QueueFull, result);

    // Free the rejected item's memory ourselves
    allocator.free(overflow_id);
}

test "WriteQueue dequeueBatch returns correct items" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    // Enqueue 5 items
    for (0..5) |i| {
        const id = try std.fmt.allocPrint(allocator, "batch-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = @intCast(i),
                .duration = 0,
            },
        };
        try queue.enqueue(item);
    }

    // Dequeue batch of 3
    const batch = try queue.dequeueBatch(3);
    defer allocator.free(batch);

    try std.testing.expectEqual(@as(usize, 3), batch.len);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    // Verify FIFO order in batch
    for (0..3) |i| {
        const expected_id = try std.fmt.allocPrint(allocator, "batch-{d}", .{i});
        defer allocator.free(expected_id);

        try std.testing.expectEqualStrings(expected_id, batch[i].end.id);

        var item = batch[i];
        queue.freeItem(&item);
    }

    // Dequeue remaining items
    const remaining = try queue.dequeueBatch(10);
    defer allocator.free(remaining);

    try std.testing.expectEqual(@as(usize, 2), remaining.len);
    try std.testing.expect(queue.isEmpty());

    for (remaining) |item| {
        var mutable_item = item;
        queue.freeItem(&mutable_item);
    }
}

test "WriteQueue dequeueBatch handles empty queue" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    const batch = try queue.dequeueBatch(5);
    defer allocator.free(batch);

    try std.testing.expectEqual(@as(usize, 0), batch.len);
}

test "WriteQueue dequeue returns null on empty queue" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    const result = queue.dequeue();
    try std.testing.expect(result == null);
}

test "WriteQueue ring buffer wraps correctly" {
    const allocator = std.testing.allocator;

    // Small queue to force wrapping
    var queue = try WriteQueue.init(allocator, 3);
    defer queue.deinit();

    // Add 2, remove 2, add 3 more (forces wrap)
    for (0..2) |i| {
        const id = try std.fmt.allocPrint(allocator, "first-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = @intCast(i),
                .duration = 0,
            },
        };
        try queue.enqueue(item);
    }

    for (0..2) |_| {
        var dequeued = queue.dequeue();
        queue.freeItem(&dequeued.?);
    }

    // Now head=2, tail=2, count=0
    // Add 3 more items - this will wrap tail around
    for (0..3) |i| {
        const id = try std.fmt.allocPrint(allocator, "wrap-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = @intCast(i + 10),
                .duration = 0,
            },
        };
        try queue.enqueue(item);
    }

    try std.testing.expectEqual(@as(usize, 3), queue.len());
    try std.testing.expect(queue.isFull());

    // Verify items are in correct order
    for (0..3) |i| {
        var dequeued = queue.dequeue();
        try std.testing.expect(dequeued != null);

        const expected_id = try std.fmt.allocPrint(allocator, "wrap-{d}", .{i});
        defer allocator.free(expected_id);

        try std.testing.expectEqualStrings(expected_id, dequeued.?.end.id);
        try std.testing.expectEqual(@as(i32, @intCast(i + 10)), dequeued.?.end.exit);

        queue.freeItem(&dequeued.?);
    }
}

test "WriteQueue handles StartMessage items" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);
    defer queue.deinit();

    // Create a StartMessage item with all allocated fields
    const id = try allocator.dupe(u8, "start-id-1");
    errdefer allocator.free(id);
    const cmd = try allocator.dupe(u8, "ls -la");
    errdefer allocator.free(cmd);
    const cwd = try allocator.dupe(u8, "/home/user");
    errdefer allocator.free(cwd);
    const session = try allocator.dupe(u8, "session-123");
    errdefer allocator.free(session);
    const hostname = try allocator.dupe(u8, "localhost");
    errdefer allocator.free(hostname);

    const item = QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 1234567890,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    try queue.enqueue(item);

    var dequeued = queue.dequeue();
    try std.testing.expect(dequeued != null);
    try std.testing.expect(dequeued.? == .start);
    try std.testing.expectEqualStrings("start-id-1", dequeued.?.start.id);
    try std.testing.expectEqualStrings("ls -la", dequeued.?.start.cmd);
    try std.testing.expectEqual(@as(i64, 1234567890), dequeued.?.start.ts);
    try std.testing.expectEqualStrings("/home/user", dequeued.?.start.cwd);
    try std.testing.expectEqualStrings("session-123", dequeued.?.start.session);
    try std.testing.expectEqualStrings("localhost", dequeued.?.start.hostname);

    queue.freeItem(&dequeued.?);
}

test "WriteQueue deinit frees remaining items" {
    const allocator = std.testing.allocator;

    var queue = try WriteQueue.init(allocator, 10);

    // Add some items without removing them
    for (0..3) |i| {
        const id = try std.fmt.allocPrint(allocator, "orphan-{d}", .{i});
        const item = QueueItem{
            .end = protocol.EndMessage{
                .id = id,
                .exit = 0,
                .duration = 0,
            },
        };
        try queue.enqueue(item);
    }

    // deinit should free all remaining items
    queue.deinit();

    // If we get here without memory leaks, test passes
    // (testing.allocator will catch leaks)
}
