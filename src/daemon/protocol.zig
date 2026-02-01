const std = @import("std");
const mem = std.mem;
const posix = std.posix;

/// Protocol errors that can occur during message handling
pub const ProtocolError = error{
    /// Message length exceeds maximum allowed size
    MessageTooLarge,
    /// Failed to read complete message (connection closed early)
    IncompleteRead,
    /// Failed to write complete message
    IncompleteWrite,
    /// JSON parsing failed
    InvalidJson,
    /// Required field missing from message
    MissingRequiredField,
    /// Unknown message type
    UnknownMessageType,
    /// Connection closed by peer
    ConnectionClosed,
    /// Read operation would block (for non-blocking sockets)
    WouldBlock,
};

/// Maximum message size (1MB should be plenty for shell commands)
pub const MAX_MESSAGE_SIZE: u32 = 1024 * 1024;

/// Length prefix size in bytes (u32 little-endian)
pub const LENGTH_PREFIX_SIZE: usize = 4;

/// Message types for CLI-to-daemon communication
pub const MessageType = enum {
    start,
    end,
};

/// Start command message - sent when a shell command begins execution
pub const StartMessage = struct {
    type: []const u8 = "start",
    id: []const u8,
    cmd: []const u8,
    ts: i64,
    cwd: []const u8,
    session: []const u8,
    hostname: []const u8,
};

/// End command message - sent when a shell command completes
pub const EndMessage = struct {
    type: []const u8 = "end",
    id: []const u8,
    exit: i32,
    duration: i64,
};

/// Response message - sent from daemon to CLI
pub const Response = struct {
    ok: bool,
    @"error": ?[]const u8 = null,

    pub fn success() Response {
        return .{ .ok = true, .@"error" = null };
    }

    pub fn failure(message: []const u8) Response {
        return .{ .ok = false, .@"error" = message };
    }
};

/// Union type for incoming messages (start or end)
pub const IncomingMessage = union(MessageType) {
    start: StartMessage,
    end: EndMessage,
};

/// Buffer for handling partial reads
pub const ReadBuffer = struct {
    data: []u8,
    pos: usize,
    len: usize,
    allocator: mem.Allocator,

    const Self = @This();

    pub fn init(allocator: mem.Allocator, capacity: usize) !Self {
        const data = try allocator.alloc(u8, capacity);
        return Self{
            .data = data,
            .pos = 0,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
    }

    /// Returns the portion of the buffer containing unread data
    pub fn unread(self: *const Self) []const u8 {
        return self.data[self.pos..self.len];
    }

    /// Returns the available space for writing new data
    pub fn available(self: *Self) []u8 {
        return self.data[self.len..];
    }

    /// Advance the read position
    pub fn consume(self: *Self, count: usize) void {
        self.pos += count;
        // Compact buffer if we've consumed a lot
        if (self.pos > self.data.len / 2) {
            self.compact();
        }
    }

    /// Record that new data was written to the buffer
    pub fn extend(self: *Self, count: usize) void {
        self.len += count;
    }

    /// Move unread data to the beginning of the buffer
    fn compact(self: *Self) void {
        const unread_len = self.len - self.pos;
        if (unread_len > 0 and self.pos > 0) {
            std.mem.copyForwards(u8, self.data[0..unread_len], self.data[self.pos..self.len]);
        }
        self.len = unread_len;
        self.pos = 0;
    }

    /// Reset buffer to empty state
    pub fn reset(self: *Self) void {
        self.pos = 0;
        self.len = 0;
    }
};

/// Write a message with length prefix to a file descriptor.
/// Returns the number of bytes written (including length prefix).
pub fn writeMessage(fd: posix.socket_t, payload: []const u8) ProtocolError!usize {
    if (payload.len > MAX_MESSAGE_SIZE) {
        return ProtocolError.MessageTooLarge;
    }

    // Write length prefix (4 bytes, little-endian)
    const length: u32 = @intCast(payload.len);
    const length_bytes = mem.toBytes(length);

    var total_written: usize = 0;

    // Write length prefix
    while (total_written < LENGTH_PREFIX_SIZE) {
        const written = posix.write(fd, length_bytes[total_written..]) catch |err| {
            if (err == error.WouldBlock) {
                return ProtocolError.WouldBlock;
            }
            return ProtocolError.IncompleteWrite;
        };
        if (written == 0) {
            return ProtocolError.ConnectionClosed;
        }
        total_written += written;
    }

    // Write payload
    var payload_written: usize = 0;
    while (payload_written < payload.len) {
        const written = posix.write(fd, payload[payload_written..]) catch |err| {
            if (err == error.WouldBlock) {
                return ProtocolError.WouldBlock;
            }
            return ProtocolError.IncompleteWrite;
        };
        if (written == 0) {
            return ProtocolError.ConnectionClosed;
        }
        payload_written += written;
    }

    return LENGTH_PREFIX_SIZE + payload.len;
}

/// Serialize a value to JSON using an allocating writer
fn jsonStringify(value: anytype, allocator: mem.Allocator) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(value, .{}, &out.writer);

    return out.toOwnedSlice();
}

/// Serialize and write a Response message
pub fn writeResponse(fd: posix.socket_t, response: Response, allocator: mem.Allocator) !void {
    const json = try jsonStringify(response, allocator);
    defer allocator.free(json);

    _ = try writeMessage(fd, json);
}

/// Read a complete message from a file descriptor using a buffer.
/// Returns the JSON payload as a slice, or null if more data is needed.
/// The returned slice is only valid until the next read operation.
pub fn readMessageFromBuffer(fd: posix.socket_t, buffer: *ReadBuffer) ProtocolError!?[]const u8 {
    // Try to read more data into buffer
    const avail = buffer.available();
    if (avail.len > 0) {
        const bytes_read = posix.read(fd, avail) catch |err| {
            if (err == error.WouldBlock) {
                // Check if we have enough data in buffer already
                return tryParseMessage(buffer);
            }
            return ProtocolError.IncompleteRead;
        };
        if (bytes_read == 0) {
            if (buffer.unread().len > 0) {
                return ProtocolError.IncompleteRead;
            }
            return ProtocolError.ConnectionClosed;
        }
        buffer.extend(bytes_read);
    }

    return tryParseMessage(buffer);
}

/// Try to parse a complete message from the buffer without reading more data
fn tryParseMessage(buffer: *ReadBuffer) ProtocolError!?[]const u8 {
    const unread_data = buffer.unread();

    // Need at least length prefix
    if (unread_data.len < LENGTH_PREFIX_SIZE) {
        return null;
    }

    // Parse length prefix (little-endian u32)
    const length = mem.readInt(u32, unread_data[0..LENGTH_PREFIX_SIZE], .little);

    if (length > MAX_MESSAGE_SIZE) {
        return ProtocolError.MessageTooLarge;
    }

    const total_message_size = LENGTH_PREFIX_SIZE + length;

    // Check if we have the complete message
    if (unread_data.len < total_message_size) {
        return null;
    }

    // Extract payload (don't consume yet - caller will do that after processing)
    const payload = unread_data[LENGTH_PREFIX_SIZE..total_message_size];

    // Consume the message from buffer
    buffer.consume(total_message_size);

    return payload;
}

/// Read a complete message synchronously (blocking until complete).
/// Allocates and returns the JSON payload. Caller owns the returned memory.
pub fn readMessage(fd: posix.socket_t, allocator: mem.Allocator) ![]u8 {
    // Read length prefix
    var length_bytes: [LENGTH_PREFIX_SIZE]u8 = undefined;
    var length_read: usize = 0;

    while (length_read < LENGTH_PREFIX_SIZE) {
        const bytes = posix.read(fd, length_bytes[length_read..]) catch |err| {
            if (err == error.WouldBlock) {
                continue;
            }
            return ProtocolError.IncompleteRead;
        };
        if (bytes == 0) {
            if (length_read == 0) {
                return ProtocolError.ConnectionClosed;
            }
            return ProtocolError.IncompleteRead;
        }
        length_read += bytes;
    }

    const length = mem.readInt(u32, &length_bytes, .little);

    if (length > MAX_MESSAGE_SIZE) {
        return ProtocolError.MessageTooLarge;
    }

    // Allocate buffer for payload
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);

    // Read payload
    var payload_read: usize = 0;
    while (payload_read < length) {
        const bytes = posix.read(fd, payload[payload_read..]) catch |err| {
            if (err == error.WouldBlock) {
                continue;
            }
            return ProtocolError.IncompleteRead;
        };
        if (bytes == 0) {
            return ProtocolError.IncompleteRead;
        }
        payload_read += bytes;
    }

    return payload;
}

/// Parse a JSON payload into a message type.
/// Returns the parsed message. Caller must manage memory lifecycle.
pub fn parseMessage(json_payload: []const u8, allocator: mem.Allocator) !IncomingMessage {
    // First, parse to determine message type
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch {
        return ProtocolError.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return ProtocolError.InvalidJson;
    }

    const obj = root.object;

    // Get message type
    const type_value = obj.get("type") orelse return ProtocolError.MissingRequiredField;
    if (type_value != .string) {
        return ProtocolError.InvalidJson;
    }
    const msg_type = type_value.string;

    if (mem.eql(u8, msg_type, "start")) {
        return parseStartMessage(obj, allocator);
    } else if (mem.eql(u8, msg_type, "end")) {
        return parseEndMessage(obj, allocator);
    } else {
        return ProtocolError.UnknownMessageType;
    }
}

/// Parse a StartMessage from a JSON object
fn parseStartMessage(obj: std.json.ObjectMap, allocator: mem.Allocator) !IncomingMessage {
    // Extract and validate required fields
    const id_val = obj.get("id") orelse return ProtocolError.MissingRequiredField;
    const cmd_val = obj.get("cmd") orelse return ProtocolError.MissingRequiredField;
    const ts_val = obj.get("ts") orelse return ProtocolError.MissingRequiredField;
    const cwd_val = obj.get("cwd") orelse return ProtocolError.MissingRequiredField;
    const session_val = obj.get("session") orelse return ProtocolError.MissingRequiredField;
    const hostname_val = obj.get("hostname") orelse return ProtocolError.MissingRequiredField;

    if (id_val != .string or cmd_val != .string or cwd_val != .string or
        session_val != .string or hostname_val != .string)
    {
        return ProtocolError.InvalidJson;
    }

    const ts: i64 = switch (ts_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return ProtocolError.InvalidJson,
    };

    // Duplicate strings for ownership
    const id = try allocator.dupe(u8, id_val.string);
    errdefer allocator.free(id);

    const cmd = try allocator.dupe(u8, cmd_val.string);
    errdefer allocator.free(cmd);

    const cwd = try allocator.dupe(u8, cwd_val.string);
    errdefer allocator.free(cwd);

    const session = try allocator.dupe(u8, session_val.string);
    errdefer allocator.free(session);

    const hostname = try allocator.dupe(u8, hostname_val.string);

    return IncomingMessage{
        .start = StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = ts,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };
}

/// Parse an EndMessage from a JSON object
fn parseEndMessage(obj: std.json.ObjectMap, allocator: mem.Allocator) !IncomingMessage {
    const id_val = obj.get("id") orelse return ProtocolError.MissingRequiredField;
    const exit_val = obj.get("exit") orelse return ProtocolError.MissingRequiredField;
    const duration_val = obj.get("duration") orelse return ProtocolError.MissingRequiredField;

    if (id_val != .string) {
        return ProtocolError.InvalidJson;
    }

    const exit: i32 = switch (exit_val) {
        .integer => |i| @intCast(i),
        else => return ProtocolError.InvalidJson,
    };

    const duration: i64 = switch (duration_val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return ProtocolError.InvalidJson,
    };

    const id = try allocator.dupe(u8, id_val.string);

    return IncomingMessage{
        .end = EndMessage{
            .id = id,
            .exit = exit,
            .duration = duration,
        },
    };
}

/// Free memory allocated by parseMessage
pub fn freeMessage(msg: *IncomingMessage, allocator: mem.Allocator) void {
    switch (msg.*) {
        .start => |*start| {
            allocator.free(start.id);
            allocator.free(start.cmd);
            allocator.free(start.cwd);
            allocator.free(start.session);
            allocator.free(start.hostname);
        },
        .end => |*end| {
            allocator.free(end.id);
        },
    }
}

/// Serialize a StartMessage to JSON
pub fn serializeStartMessage(msg: StartMessage, allocator: mem.Allocator) ![]u8 {
    return jsonStringify(msg, allocator);
}

/// Serialize an EndMessage to JSON
pub fn serializeEndMessage(msg: EndMessage, allocator: mem.Allocator) ![]u8 {
    return jsonStringify(msg, allocator);
}

/// Serialize a Response to JSON
pub fn serializeResponse(response: Response, allocator: mem.Allocator) ![]u8 {
    return jsonStringify(response, allocator);
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

test "writeMessage encodes length prefix correctly" {
    // Create a socket pair for testing
    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const payload = "hello";
    _ = try writeMessage(pair[0], payload);

    // Read and verify
    var buffer: [32]u8 = undefined;
    const bytes_read = try posix.read(pair[1], &buffer);

    try std.testing.expectEqual(@as(usize, LENGTH_PREFIX_SIZE + payload.len), bytes_read);

    // Check length prefix (little-endian)
    const length = mem.readInt(u32, buffer[0..4], .little);
    try std.testing.expectEqual(@as(u32, 5), length);

    // Check payload
    try std.testing.expectEqualStrings(payload, buffer[4..9]);
}

test "readMessage decodes length-prefixed message" {
    const allocator = std.testing.allocator;

    // Create socket pair
    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Write a message
    const payload = "test message";
    _ = try writeMessage(pair[0], payload);

    // Read it back
    const received = try readMessage(pair[1], allocator);
    defer allocator.free(received);

    try std.testing.expectEqualStrings(payload, received);
}

test "encode decode round trip for StartMessage" {
    const allocator = std.testing.allocator;

    const original = StartMessage{
        .id = "test-uuid-123",
        .cmd = "ls -la",
        .ts = 1234567890,
        .cwd = "/home/user",
        .session = "session-456",
        .hostname = "localhost",
    };

    // Serialize
    const json = try serializeStartMessage(original, allocator);
    defer allocator.free(json);

    // Parse back
    var parsed = try parseMessage(json, allocator);
    defer freeMessage(&parsed, allocator);

    try std.testing.expect(parsed == .start);
    const start = parsed.start;

    try std.testing.expectEqualStrings(original.id, start.id);
    try std.testing.expectEqualStrings(original.cmd, start.cmd);
    try std.testing.expectEqual(original.ts, start.ts);
    try std.testing.expectEqualStrings(original.cwd, start.cwd);
    try std.testing.expectEqualStrings(original.session, start.session);
    try std.testing.expectEqualStrings(original.hostname, start.hostname);
}

test "encode decode round trip for EndMessage" {
    const allocator = std.testing.allocator;

    const original = EndMessage{
        .id = "test-uuid-456",
        .exit = 0,
        .duration = 15000000,
    };

    // Serialize
    const json = try serializeEndMessage(original, allocator);
    defer allocator.free(json);

    // Parse back
    var parsed = try parseMessage(json, allocator);
    defer freeMessage(&parsed, allocator);

    try std.testing.expect(parsed == .end);
    const end = parsed.end;

    try std.testing.expectEqualStrings(original.id, end.id);
    try std.testing.expectEqual(original.exit, end.exit);
    try std.testing.expectEqual(original.duration, end.duration);
}

test "encode decode round trip for Response" {
    const allocator = std.testing.allocator;

    // Test success response
    const success_resp = Response.success();
    const success_json = try serializeResponse(success_resp, allocator);
    defer allocator.free(success_json);

    try std.testing.expect(std.mem.indexOf(u8, success_json, "\"ok\":true") != null);

    // Test failure response
    const failure_resp = Response.failure("something went wrong");
    const failure_json = try serializeResponse(failure_resp, allocator);
    defer allocator.free(failure_json);

    try std.testing.expect(std.mem.indexOf(u8, failure_json, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_json, "something went wrong") != null);
}

test "parseMessage rejects invalid JSON" {
    const allocator = std.testing.allocator;

    const result = parseMessage("not valid json", allocator);
    try std.testing.expectError(ProtocolError.InvalidJson, result);
}

test "parseMessage rejects missing type field" {
    const allocator = std.testing.allocator;

    const result = parseMessage("{\"id\": \"test\"}", allocator);
    try std.testing.expectError(ProtocolError.MissingRequiredField, result);
}

test "parseMessage rejects unknown message type" {
    const allocator = std.testing.allocator;

    const result = parseMessage("{\"type\": \"unknown\"}", allocator);
    try std.testing.expectError(ProtocolError.UnknownMessageType, result);
}

test "parseMessage rejects start message with missing fields" {
    const allocator = std.testing.allocator;

    // Missing cmd field
    const result = parseMessage(
        \\{"type": "start", "id": "test", "ts": 123, "cwd": "/", "session": "s", "hostname": "h"}
    , allocator);
    try std.testing.expectError(ProtocolError.MissingRequiredField, result);
}

test "parseMessage rejects end message with missing fields" {
    const allocator = std.testing.allocator;

    // Missing duration field
    const result = parseMessage(
        \\{"type": "end", "id": "test", "exit": 0}
    , allocator);
    try std.testing.expectError(ProtocolError.MissingRequiredField, result);
}

test "ReadBuffer handles partial messages" {
    const allocator = std.testing.allocator;

    var buffer = try ReadBuffer.init(allocator, 1024);
    defer buffer.deinit();

    // Write partial length prefix (only 2 bytes)
    buffer.data[0] = 0x05;
    buffer.data[1] = 0x00;
    buffer.len = 2;

    // Should return null (not enough data)
    const result1 = try tryParseMessage(&buffer);
    try std.testing.expect(result1 == null);

    // Add remaining length prefix bytes
    buffer.data[2] = 0x00;
    buffer.data[3] = 0x00;
    buffer.len = 4;

    // Should still return null (have length but no payload)
    const result2 = try tryParseMessage(&buffer);
    try std.testing.expect(result2 == null);

    // Add payload "hello"
    @memcpy(buffer.data[4..9], "hello");
    buffer.len = 9;

    // Should now return the message
    const result3 = try tryParseMessage(&buffer);
    try std.testing.expect(result3 != null);
    try std.testing.expectEqualStrings("hello", result3.?);
}

test "ReadBuffer compact works correctly" {
    const allocator = std.testing.allocator;

    // Use a small buffer (16 bytes) so compaction triggers at pos > 8
    var buffer = try ReadBuffer.init(allocator, 16);
    defer buffer.deinit();

    // Fill buffer with data
    @memcpy(buffer.data[0..10], "0123456789");
    buffer.len = 10;

    // Consume 9 bytes - this triggers compaction since 9 > 16/2=8
    buffer.consume(9);

    // After compaction, pos should be 0 and data should be compacted
    try std.testing.expectEqualStrings("9", buffer.unread());
    try std.testing.expectEqual(@as(usize, 0), buffer.pos);
    try std.testing.expectEqual(@as(usize, 1), buffer.len);
}

test "writeMessage rejects oversized messages" {
    // Create socket pair
    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Try to write a message larger than MAX_MESSAGE_SIZE
    var large_buffer: [MAX_MESSAGE_SIZE + 1]u8 = undefined;
    @memset(&large_buffer, 'x');

    const result = writeMessage(pair[0], &large_buffer);
    try std.testing.expectError(ProtocolError.MessageTooLarge, result);
}

test "full protocol round trip over socket pair" {
    const allocator = std.testing.allocator;

    // Create socket pair
    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Send a start message
    const start_msg = StartMessage{
        .id = "uuid-123",
        .cmd = "git status",
        .ts = 1704067200,
        .cwd = "/home/user/project",
        .session = "session-abc",
        .hostname = "workstation",
    };

    const json = try serializeStartMessage(start_msg, allocator);
    defer allocator.free(json);

    _ = try writeMessage(pair[0], json);

    // Read and parse on the other end
    const received_json = try readMessage(pair[1], allocator);
    defer allocator.free(received_json);

    var parsed = try parseMessage(received_json, allocator);
    defer freeMessage(&parsed, allocator);

    try std.testing.expect(parsed == .start);

    // Send response back
    const response = Response.success();
    try writeResponse(pair[1], response, allocator);

    // Read response
    const response_json = try readMessage(pair[0], allocator);
    defer allocator.free(response_json);

    try std.testing.expect(std.mem.indexOf(u8, response_json, "\"ok\":true") != null);
}
