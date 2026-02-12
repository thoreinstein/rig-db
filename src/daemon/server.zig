const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fs = std.fs;
const protocol = @import("protocol.zig");
const queue = @import("queue.zig");

/// Errors that can occur during server operations
pub const ServerError = error{
    SocketCreationFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    SocketPathTooLong,
    RuntimeDirNotFound,
    PathError,
    OutOfMemory,
    RemoveSocketFailed,
    SetNonBlockingFailed,
};

/// Maximum path length for Unix domain sockets (typically 108 on Linux, 104 on macOS)
const SOCKET_PATH_MAX = 104;

/// The socket filename
const SOCKET_FILENAME = "rig.sock";

/// Unix Domain Socket Server for the rig-db daemon
pub const Server = struct {
    socket_path: []u8,
    socket_fd: posix.socket_t,
    allocator: mem.Allocator,
    running: bool,

    const Self = @This();

    /// Initialize a new server instance.
    /// Determines the socket path and prepares for binding.
    /// Call `start()` to begin accepting connections.
    pub fn init(allocator: mem.Allocator) ServerError!Self {
        const socket_path = try getSocketPath(allocator);
        errdefer allocator.free(socket_path);

        return Self{
            .socket_path = socket_path,
            .socket_fd = undefined,
            .allocator = allocator,
            .running = false,
        };
    }

    /// Start the server: create socket, bind, and listen.
    /// Removes any stale socket file before binding.
    pub fn start(self: *Self) ServerError!void {
        // Remove stale socket if it exists
        try self.removeStaleSocket();

        // Create Unix domain socket
        const socket_fd = posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM,
            0,
        ) catch {
            return ServerError.SocketCreationFailed;
        };
        errdefer posix.close(socket_fd);

        // Set up the socket address
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };

        // Copy socket path to address, ensuring null termination
        if (self.socket_path.len >= addr.path.len) {
            return ServerError.SocketPathTooLong;
        }
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        // Bind to the socket
        posix.bind(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
            return ServerError.BindFailed;
        };

        // Start listening (backlog of 16 pending connections)
        posix.listen(socket_fd, 16) catch {
            return ServerError.ListenFailed;
        };

        // Set socket to non-blocking mode
        setNonBlocking(socket_fd) catch {
            return ServerError.SetNonBlockingFailed;
        };

        self.socket_fd = socket_fd;
        self.running = true;
    }

    /// Accept a single connection (non-blocking).
    /// Returns null if no connection is pending (EAGAIN/EWOULDBLOCK).
    /// Returns the client file descriptor on success.
    pub fn acceptConnection(self: *Self) ?posix.socket_t {
        if (!self.running) return null;

        var client_addr: posix.sockaddr.un = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.un);

        const client_fd = posix.accept(self.socket_fd, @ptrCast(&client_addr), &addr_len, posix.SOCK.NONBLOCK) catch |err| {
            // EAGAIN/EWOULDBLOCK means no pending connections - this is normal
            if (err == error.WouldBlock) {
                return null;
            }
            // Other errors - log and return null
            return null;
        };

        return client_fd;
    }

    /// Handle a client connection: read length-prefixed JSON messages,
    /// parse them, enqueue to the write queue, and send responses.
    pub fn handleClient(self: *Self, client_fd: posix.socket_t, write_queue: *queue.WriteQueue, allocator: mem.Allocator) void {
        _ = self;
        defer posix.close(client_fd);

        var read_buffer = protocol.ReadBuffer.init(allocator, 8192) catch return;
        defer read_buffer.deinit();

        while (true) {
            const payload = protocol.readMessageFromBuffer(client_fd, &read_buffer) catch |err| {
                switch (err) {
                    protocol.ProtocolError.ConnectionClosed => break,
                    protocol.ProtocolError.WouldBlock => {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    },
                    else => {
                        protocol.writeResponse(client_fd, protocol.Response.failure("protocol error"), allocator) catch {};
                        break;
                    },
                }
            };

            // null means we need more data
            const msg_payload = payload orelse {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            };

            // Parse the JSON payload into a message (allocates owned strings)
            const msg = protocol.parseMessage(msg_payload, allocator) catch {
                protocol.writeResponse(client_fd, protocol.Response.failure("invalid message"), allocator) catch break;
                continue;
            };

            // Convert IncomingMessage to QueueItem (zero-copy ownership transfer)
            const item: queue.QueueItem = switch (msg) {
                .start => |s| .{ .start = s },
                .end => |e| .{ .end = e },
            };

            // Enqueue the item (transfers ownership to queue)
            write_queue.enqueue(item) catch {
                // Queue full - free the item's memory and send error
                var qi = item;
                write_queue.freeItem(&qi);
                protocol.writeResponse(client_fd, protocol.Response.failure("queue full"), allocator) catch break;
                continue;
            };

            // Send success response (message is already queued even if write fails)
            protocol.writeResponse(client_fd, protocol.Response.success(), allocator) catch break;
        }
    }

    /// Run a single iteration of the server loop.
    /// Accepts one pending connection if available.
    /// Returns true if a connection was handled, false otherwise.
    pub fn pollOnce(self: *Self, write_queue: *queue.WriteQueue, allocator: mem.Allocator) bool {
        if (self.acceptConnection()) |client_fd| {
            self.handleClient(client_fd, write_queue, allocator);
            return true;
        }
        return false;
    }

    /// Stop the server and clean up resources.
    pub fn stop(self: *Self) void {
        if (self.running) {
            self.running = false;
            posix.close(self.socket_fd);

            // Remove the socket file
            fs.cwd().deleteFile(self.socket_path) catch {};
        }
    }

    /// Clean up all resources.
    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.free(self.socket_path);
    }

    /// Remove a stale socket file if it exists from a previous crashed process.
    fn removeStaleSocket(self: *Self) ServerError!void {
        // Try to remove the socket file - ignore error if it doesn't exist
        fs.cwd().deleteFile(self.socket_path) catch |err| {
            switch (err) {
                error.FileNotFound => {}, // Socket doesn't exist, that's fine
                else => return ServerError.RemoveSocketFailed,
            }
        };
    }

    /// Get the path to the socket file.
    pub fn getPath(self: *const Self) []const u8 {
        return self.socket_path;
    }
};

/// Set a file descriptor to non-blocking mode using fcntl.
fn setNonBlocking(fd: posix.socket_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const new_flags = flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"));
    _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
}

/// Determine the socket path based on environment.
/// Uses XDG_RUNTIME_DIR/rig.sock if available, otherwise /tmp/rig-{uid}.sock
fn getSocketPath(allocator: mem.Allocator) ServerError![]u8 {
    // First try XDG_RUNTIME_DIR
    if (posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            const path = fs.path.join(allocator, &[_][]const u8{ runtime_dir, SOCKET_FILENAME }) catch {
                return ServerError.OutOfMemory;
            };

            // Check path length
            if (path.len >= SOCKET_PATH_MAX) {
                allocator.free(path);
                return ServerError.SocketPathTooLong;
            }

            return path;
        }
    }

    // Fall back to /tmp/rig-{uid}.sock
    const uid = std.c.getuid();
    const path = std.fmt.allocPrint(allocator, "/tmp/rig-{d}.sock", .{uid}) catch {
        return ServerError.OutOfMemory;
    };

    // Check path length
    if (path.len >= SOCKET_PATH_MAX) {
        allocator.free(path);
        return ServerError.SocketPathTooLong;
    }

    return path;
}

// =============================================================================
// Tests
// =============================================================================

/// Helper to create a socket pair for testing
fn createSocketPair() ![2]posix.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    const result = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    if (result != 0) {
        return error.SocketPairFailed;
    }
    return .{ @intCast(fds[0]), @intCast(fds[1]) };
}

test "Server init and deinit" {
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    // Socket path should be set
    try std.testing.expect(server.socket_path.len > 0);

    // Should contain "rig" somewhere
    try std.testing.expect(mem.indexOf(u8, server.socket_path, "rig") != null);
}

test "Server start and stop" {
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    // Start the server
    try server.start();
    try std.testing.expect(server.running);

    // Verify socket file exists
    const stat = fs.cwd().statFile(server.socket_path) catch null;
    try std.testing.expect(stat != null);

    // Stop the server
    server.stop();
    try std.testing.expect(!server.running);

    // Verify socket file is removed
    const stat2 = fs.cwd().statFile(server.socket_path) catch null;
    try std.testing.expect(stat2 == null);
}

test "Server handleClient processes protocol message and enqueues" {
    const allocator = std.testing.allocator;

    var write_queue = try queue.WriteQueue.init(allocator, 10);
    defer write_queue.deinit();

    // Create a socket pair for testing
    const pair = try createSocketPair();

    // Send a start message on the client end
    const start_msg = protocol.StartMessage{
        .id = "test-uuid-svr",
        .cmd = "ls -la",
        .ts = 1234567890,
        .cwd = "/home/user",
        .session = "session-svr",
        .hostname = "localhost",
    };

    const json = try protocol.serializeStartMessage(start_msg, allocator);
    defer allocator.free(json);

    _ = try protocol.writeMessage(pair[0], json);

    // Close client end to signal EOF (handleClient will read message, then see disconnect)
    posix.close(pair[0]);

    // Handle client on the server end
    var server = try Server.init(allocator);
    defer server.deinit();
    server.handleClient(pair[1], &write_queue, allocator);
    // pair[1] is closed by handleClient

    // Verify the message was enqueued
    var item = write_queue.dequeue();
    try std.testing.expect(item != null);
    try std.testing.expect(item.? == .start);
    try std.testing.expectEqualStrings("test-uuid-svr", item.?.start.id);
    try std.testing.expectEqualStrings("ls -la", item.?.start.cmd);
    try std.testing.expectEqual(@as(i64, 1234567890), item.?.start.ts);
    write_queue.freeItem(&item.?);
}

test "Server cleans up stale socket" {
    const allocator = std.testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    // Create a fake stale socket file
    const file = fs.cwd().createFile(server.socket_path, .{}) catch {
        return error.SkipZigTest;
    };
    file.close();

    // Verify the file exists
    const stat = fs.cwd().statFile(server.socket_path) catch null;
    try std.testing.expect(stat != null);

    // Start should remove the stale socket and bind successfully
    try server.start();
    try std.testing.expect(server.running);

    server.stop();
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

    // Path should be within socket path limits
    try std.testing.expect(path.len < SOCKET_PATH_MAX);
}

test "Server handles client disconnect gracefully" {
    const allocator = std.testing.allocator;

    var write_queue = try queue.WriteQueue.init(allocator, 10);
    defer write_queue.deinit();

    var server = try Server.init(allocator);
    defer server.deinit();

    try server.start();

    // Create and connect a client
    const client_fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        return error.SkipZigTest;
    };

    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..server.socket_path.len], server.socket_path);

    posix.connect(client_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        return error.SkipZigTest;
    };

    // Immediately disconnect
    posix.close(client_fd);

    // Server should handle the disconnected client without crashing
    if (server.acceptConnection()) |accepted_fd| {
        server.handleClient(accepted_fd, &write_queue, allocator);
        // If we get here without crashing, test passes
    }
}

test "Server handleClient rejects queue-full" {
    const allocator = std.testing.allocator;

    // Create a queue with capacity 1
    var write_queue = try queue.WriteQueue.init(allocator, 1);
    defer write_queue.deinit();

    // Fill the queue with a dummy item
    const dummy_id = try allocator.dupe(u8, "dummy");
    try write_queue.enqueue(queue.QueueItem{
        .end = protocol.EndMessage{ .id = dummy_id, .exit = 0, .duration = 0 },
    });

    // Create a socket pair
    const pair = try createSocketPair();

    // Send a start message
    const start_msg = protocol.StartMessage{
        .id = "overflow-uuid",
        .cmd = "echo overflow",
        .ts = 9999,
        .cwd = "/tmp",
        .session = "s",
        .hostname = "h",
    };
    const json = try protocol.serializeStartMessage(start_msg, allocator);
    defer allocator.free(json);
    _ = try protocol.writeMessage(pair[0], json);
    posix.close(pair[0]);

    // Handle client - queue is full, item should be rejected
    var server = try Server.init(allocator);
    defer server.deinit();
    server.handleClient(pair[1], &write_queue, allocator);

    // Queue should still have only the original dummy item
    try std.testing.expectEqual(@as(usize, 1), write_queue.len());
}
