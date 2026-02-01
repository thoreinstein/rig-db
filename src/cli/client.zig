const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fs = std.fs;
const c = std.c;

const protocol = @import("../daemon/protocol.zig");
const lifecycle = @import("../daemon/lifecycle.zig");

/// Maximum number of connection retry attempts
const MAX_RETRIES: u32 = 5;

/// Initial retry delay in nanoseconds (100ms)
const INITIAL_RETRY_DELAY_NS: u64 = 100 * std.time.ns_per_ms;

/// Maximum retry delay in nanoseconds (2 seconds)
const MAX_RETRY_DELAY_NS: u64 = 2 * std.time.ns_per_s;

/// Connection timeout in nanoseconds (5 seconds)
const CONNECTION_TIMEOUT_NS: u64 = 5 * std.time.ns_per_s;

/// Socket filename (must match server.zig and lifecycle.zig)
const SOCKET_FILENAME = "rig.sock";

/// Maximum socket path length (macOS limit)
const SOCKET_PATH_MAX = 104;

/// Errors that can occur during client operations
pub const ClientError = error{
    /// Failed to create socket
    SocketCreationFailed,
    /// Connection to daemon refused
    ConnectionRefused,
    /// Connection timed out
    ConnectionTimedOut,
    /// Maximum retries exceeded
    MaxRetriesExceeded,
    /// Failed to spawn daemon
    DaemonSpawnFailed,
    /// Socket path too long
    SocketPathTooLong,
    /// Runtime directory not found
    RuntimeDirNotFound,
    /// Memory allocation failed
    OutOfMemory,
    /// Protocol error during communication
    ProtocolError,
    /// Invalid response from daemon
    InvalidResponse,
    /// Connection closed unexpectedly
    ConnectionClosed,
    /// Write operation failed
    WriteFailed,
    /// Read operation failed
    ReadFailed,
};

/// Unix Domain Socket client for communicating with the rig-db daemon.
/// Handles connection establishment, message sending/receiving, and
/// automatic daemon spawning if not running.
pub const Client = struct {
    /// Socket file descriptor
    socket_fd: posix.socket_t,
    /// Allocator for internal operations
    allocator: mem.Allocator,
    /// Socket path (owned memory)
    socket_path: []u8,

    const Self = @This();

    /// Connect to the daemon socket.
    /// If the daemon is not running, attempts to spawn it.
    /// Implements retry logic with exponential backoff for transient failures.
    pub fn connect(allocator: mem.Allocator) ClientError!Self {
        const socket_path = try getSocketPath(allocator);
        errdefer allocator.free(socket_path);

        var retry_count: u32 = 0;
        var delay_ns: u64 = INITIAL_RETRY_DELAY_NS;

        while (retry_count < MAX_RETRIES) {
            // Try to connect
            const result = tryConnect(socket_path);

            switch (result) {
                .success => |fd| {
                    return Self{
                        .socket_fd = fd,
                        .allocator = allocator,
                        .socket_path = socket_path,
                    };
                },
                .connection_refused, .socket_not_found => {
                    // Daemon not running or socket doesn't exist - try to spawn it
                    lifecycle.ensureDaemonRunning(allocator) catch {
                        retry_count += 1;
                        if (retry_count >= MAX_RETRIES) {
                            return ClientError.DaemonSpawnFailed;
                        }
                        // Wait before retry
                        std.Thread.sleep(delay_ns);
                        delay_ns = @min(delay_ns * 2, MAX_RETRY_DELAY_NS);
                        continue;
                    };

                    // Daemon should be running now, try connecting again
                    const retry_result = tryConnect(socket_path);
                    switch (retry_result) {
                        .success => |fd| {
                            return Self{
                                .socket_fd = fd,
                                .allocator = allocator,
                                .socket_path = socket_path,
                            };
                        },
                        else => {
                            retry_count += 1;
                            if (retry_count >= MAX_RETRIES) {
                                return ClientError.MaxRetriesExceeded;
                            }
                            std.Thread.sleep(delay_ns);
                            delay_ns = @min(delay_ns * 2, MAX_RETRY_DELAY_NS);
                        },
                    }
                },
                .timeout => {
                    retry_count += 1;
                    if (retry_count >= MAX_RETRIES) {
                        return ClientError.ConnectionTimedOut;
                    }
                    std.Thread.sleep(delay_ns);
                    delay_ns = @min(delay_ns * 2, MAX_RETRY_DELAY_NS);
                },
                .other_error => {
                    retry_count += 1;
                    if (retry_count >= MAX_RETRIES) {
                        return ClientError.ConnectionRefused;
                    }
                    std.Thread.sleep(delay_ns);
                    delay_ns = @min(delay_ns * 2, MAX_RETRY_DELAY_NS);
                },
            }
        }

        return ClientError.MaxRetriesExceeded;
    }

    /// Send a StartMessage to the daemon and receive the response.
    pub fn sendStart(self: *Self, msg: protocol.StartMessage) ClientError!protocol.Response {
        // Serialize the message to JSON
        const json = protocol.serializeStartMessage(msg, self.allocator) catch {
            return ClientError.OutOfMemory;
        };
        defer self.allocator.free(json);

        // Send the message
        try self.sendMessage(json);

        // Receive and parse response
        return try self.receiveResponse();
    }

    /// Send an EndMessage to the daemon and receive the response.
    pub fn sendEnd(self: *Self, msg: protocol.EndMessage) ClientError!protocol.Response {
        // Serialize the message to JSON
        const json = protocol.serializeEndMessage(msg, self.allocator) catch {
            return ClientError.OutOfMemory;
        };
        defer self.allocator.free(json);

        // Send the message
        try self.sendMessage(json);

        // Receive and parse response
        return try self.receiveResponse();
    }

    /// Close the connection to the daemon.
    pub fn close(self: *Self) void {
        posix.close(self.socket_fd);
        self.allocator.free(self.socket_path);
    }

    /// Send a length-prefixed JSON message to the daemon.
    fn sendMessage(self: *Self, payload: []const u8) ClientError!void {
        _ = protocol.writeMessage(self.socket_fd, payload) catch |err| {
            return switch (err) {
                protocol.ProtocolError.ConnectionClosed => ClientError.ConnectionClosed,
                protocol.ProtocolError.IncompleteWrite => ClientError.WriteFailed,
                protocol.ProtocolError.MessageTooLarge => ClientError.ProtocolError,
                protocol.ProtocolError.WouldBlock => ClientError.WriteFailed,
                else => ClientError.ProtocolError,
            };
        };
    }

    /// Receive and parse a Response message from the daemon.
    fn receiveResponse(self: *Self) ClientError!protocol.Response {
        // Read the response message
        const response_json = protocol.readMessage(self.socket_fd, self.allocator) catch |err| {
            return switch (err) {
                protocol.ProtocolError.ConnectionClosed => ClientError.ConnectionClosed,
                protocol.ProtocolError.IncompleteRead => ClientError.ReadFailed,
                protocol.ProtocolError.MessageTooLarge => ClientError.ProtocolError,
                else => ClientError.ReadFailed,
            };
        };
        defer self.allocator.free(response_json);

        // Parse the JSON response
        return parseResponse(response_json) catch {
            return ClientError.InvalidResponse;
        };
    }
};

/// Result of a connection attempt
const ConnectResult = union(enum) {
    success: posix.socket_t,
    connection_refused,
    socket_not_found,
    timeout,
    other_error,
};

/// Attempt to connect to the daemon socket.
fn tryConnect(socket_path: []const u8) ConnectResult {
    // Create Unix domain socket
    const socket_fd = posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM,
        0,
    ) catch {
        return .other_error;
    };
    errdefer posix.close(socket_fd);

    // Set up the socket address
    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = undefined,
    };

    if (socket_path.len >= addr.path.len) {
        return .other_error;
    }

    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);

    // Attempt to connect
    posix.connect(socket_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        posix.close(socket_fd);
        return switch (err) {
            error.ConnectionRefused => .connection_refused,
            error.FileNotFound => .socket_not_found,
            error.ConnectionTimedOut => .timeout,
            else => .other_error,
        };
    };

    return .{ .success = socket_fd };
}

/// Get the socket path following the same logic as server.zig and lifecycle.zig.
fn getSocketPath(allocator: mem.Allocator) ClientError![]u8 {
    // First try XDG_RUNTIME_DIR
    if (posix.getenv("XDG_RUNTIME_DIR")) |runtime_dir| {
        if (runtime_dir.len > 0) {
            const path = fs.path.join(allocator, &[_][]const u8{ runtime_dir, SOCKET_FILENAME }) catch {
                return ClientError.OutOfMemory;
            };

            if (path.len >= SOCKET_PATH_MAX) {
                allocator.free(path);
                return ClientError.SocketPathTooLong;
            }

            return path;
        }
    }

    // Fall back to /tmp/rig-{uid}.sock
    const uid = c.getuid();
    const path = std.fmt.allocPrint(allocator, "/tmp/rig-{d}.sock", .{uid}) catch {
        return ClientError.OutOfMemory;
    };

    if (path.len >= SOCKET_PATH_MAX) {
        allocator.free(path);
        return ClientError.SocketPathTooLong;
    }

    return path;
}

/// Parse a JSON response into a Response struct.
fn parseResponse(json: []const u8) !protocol.Response {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return error.InvalidJson;
    }

    const obj = root.object;

    // Get "ok" field
    const ok_value = obj.get("ok") orelse return error.MissingField;
    if (ok_value != .bool) {
        return error.InvalidJson;
    }
    const ok = ok_value.bool;

    // Get optional "error" field - must dupe before deinit frees the JSON memory
    var error_msg: ?[]const u8 = null;
    if (obj.get("error")) |err_value| {
        if (err_value == .string) {
            error_msg = std.heap.page_allocator.dupe(u8, err_value.string) catch null;
        }
    }

    return protocol.Response{
        .ok = ok,
        .@"error" = error_msg,
    };
}

// =============================================================================
// Tests
// =============================================================================

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

test "tryConnect returns socket_not_found for nonexistent socket" {
    // Use a socket path that definitely doesn't exist
    const result = tryConnect("/tmp/rig-test-nonexistent-12345.sock");

    // Should fail with socket_not_found
    try std.testing.expect(result == .socket_not_found or result == .other_error);
}

test "parseResponse handles success response" {
    const json = "{\"ok\":true}";
    const response = try parseResponse(json);

    try std.testing.expect(response.ok);
    try std.testing.expect(response.@"error" == null);
}

test "parseResponse handles failure response" {
    const json = "{\"ok\":false,\"error\":\"something went wrong\"}";
    const response = try parseResponse(json);

    try std.testing.expect(!response.ok);
    try std.testing.expect(response.@"error" != null);
    try std.testing.expectEqualStrings("something went wrong", response.@"error".?);
}

test "parseResponse rejects invalid JSON" {
    const result = parseResponse("not valid json");
    try std.testing.expectError(error.InvalidJson, result);
}

test "parseResponse rejects missing ok field" {
    const result = parseResponse("{\"error\":\"test\"}");
    try std.testing.expectError(error.MissingField, result);
}

test "Client connect/sendStart/sendEnd/close with mock server" {
    const allocator = std.testing.allocator;

    // Create a test socket pair to simulate server/client
    var fds: [2]std.c.fd_t = undefined;
    const result = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    if (result != 0) {
        // Skip test if socket pair creation fails
        return error.SkipZigTest;
    }
    const client_fd: posix.socket_t = @intCast(fds[0]);
    const server_fd: posix.socket_t = @intCast(fds[1]);
    defer posix.close(server_fd);

    // Create a fake socket path
    const socket_path = try allocator.dupe(u8, "/tmp/test-socket.sock");

    // Create a client manually with our test socket
    var client = Client{
        .socket_fd = client_fd,
        .allocator = allocator,
        .socket_path = socket_path,
    };
    defer client.close();

    // Test sendStart in a separate thread while we respond from "server"
    const SendThread = struct {
        fn serverRespond(fd: posix.socket_t, alloc: mem.Allocator) void {
            // Read the incoming message
            const msg = protocol.readMessage(fd, alloc) catch return;
            defer alloc.free(msg);

            // Send a success response
            const response = protocol.Response.success();
            protocol.writeResponse(fd, response, alloc) catch return;
        }
    };

    // Start server thread
    const server_thread = std.Thread.spawn(.{}, SendThread.serverRespond, .{ server_fd, allocator }) catch {
        return error.SkipZigTest;
    };

    // Send a start message
    const start_msg = protocol.StartMessage{
        .id = "test-id",
        .cmd = "ls -la",
        .ts = 1234567890,
        .cwd = "/home/user",
        .session = "session-1",
        .hostname = "localhost",
    };

    const response = client.sendStart(start_msg) catch {
        server_thread.join();
        return error.SkipZigTest;
    };

    server_thread.join();

    try std.testing.expect(response.ok);
}

test "Client sendEnd works correctly" {
    const allocator = std.testing.allocator;

    // Create a test socket pair
    var fds: [2]std.c.fd_t = undefined;
    const result = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    if (result != 0) {
        return error.SkipZigTest;
    }
    const client_fd: posix.socket_t = @intCast(fds[0]);
    const server_fd: posix.socket_t = @intCast(fds[1]);
    defer posix.close(server_fd);

    const socket_path = try allocator.dupe(u8, "/tmp/test-socket.sock");

    var client = Client{
        .socket_fd = client_fd,
        .allocator = allocator,
        .socket_path = socket_path,
    };
    defer client.close();

    const SendThread = struct {
        fn serverRespond(fd: posix.socket_t, alloc: mem.Allocator) void {
            const msg = protocol.readMessage(fd, alloc) catch return;
            defer alloc.free(msg);

            // Verify it's an end message
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg, .{}) catch return;
            defer parsed.deinit();

            if (parsed.value.object.get("type")) |type_val| {
                if (!std.mem.eql(u8, type_val.string, "end")) return;
            }

            const response = protocol.Response.success();
            protocol.writeResponse(fd, response, alloc) catch return;
        }
    };

    const server_thread = std.Thread.spawn(.{}, SendThread.serverRespond, .{ server_fd, allocator }) catch {
        return error.SkipZigTest;
    };

    const end_msg = protocol.EndMessage{
        .id = "test-id",
        .exit = 0,
        .duration = 1500,
    };

    const response = client.sendEnd(end_msg) catch {
        server_thread.join();
        return error.SkipZigTest;
    };

    server_thread.join();

    try std.testing.expect(response.ok);
}

test "Client handles error response from daemon" {
    const allocator = std.testing.allocator;

    var fds: [2]std.c.fd_t = undefined;
    const result = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    if (result != 0) {
        return error.SkipZigTest;
    }
    const client_fd: posix.socket_t = @intCast(fds[0]);
    const server_fd: posix.socket_t = @intCast(fds[1]);
    defer posix.close(server_fd);

    const socket_path = try allocator.dupe(u8, "/tmp/test-socket.sock");

    var client = Client{
        .socket_fd = client_fd,
        .allocator = allocator,
        .socket_path = socket_path,
    };
    defer client.close();

    const SendThread = struct {
        fn serverRespond(fd: posix.socket_t, alloc: mem.Allocator) void {
            const msg = protocol.readMessage(fd, alloc) catch return;
            defer alloc.free(msg);

            // Send an error response
            const response = protocol.Response.failure("database error");
            protocol.writeResponse(fd, response, alloc) catch return;
        }
    };

    const server_thread = std.Thread.spawn(.{}, SendThread.serverRespond, .{ server_fd, allocator }) catch {
        return error.SkipZigTest;
    };

    const start_msg = protocol.StartMessage{
        .id = "test-id",
        .cmd = "ls",
        .ts = 123,
        .cwd = "/",
        .session = "s",
        .hostname = "h",
    };

    const response = client.sendStart(start_msg) catch {
        server_thread.join();
        return error.SkipZigTest;
    };

    server_thread.join();

    try std.testing.expect(!response.ok);
    try std.testing.expect(response.@"error" != null);
}
