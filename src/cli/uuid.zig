const std = @import("std");

/// UUID v7 implementation per RFC 9562.
/// UUID v7 embeds a Unix timestamp in milliseconds for natural time-ordering,
/// making it ideal for database record IDs where chronological ordering matters.
pub const Uuid7 = struct {
    bytes: [16]u8,

    /// Thread-local state for monotonic counter within same millisecond.
    /// This ensures uniqueness even when called rapidly within the same ms.
    threadlocal var last_timestamp_ms: i64 = 0;
    threadlocal var counter: u12 = 0;

    /// Generate a new UUID v7.
    /// Uses the current system time for the timestamp portion and
    /// cryptographically secure random bytes for the random portion.
    /// Implements a monotonic counter to ensure uniqueness when called
    /// rapidly within the same millisecond.
    pub fn generate() Uuid7 {
        var uuid: Uuid7 = undefined;

        // Get current timestamp in milliseconds since Unix epoch
        const timestamp_ms = std.time.milliTimestamp();

        // Handle monotonic counter for same-millisecond generation
        var rand_a: u12 = undefined;
        if (timestamp_ms == last_timestamp_ms) {
            // Same millisecond - increment counter
            counter +%= 1;
            rand_a = counter;
        } else {
            // New millisecond - reset counter with random value
            last_timestamp_ms = timestamp_ms;
            var rand_bytes: [2]u8 = undefined;
            std.crypto.random.bytes(&rand_bytes);
            counter = @as(u12, @truncate(std.mem.readInt(u16, &rand_bytes, .big)));
            rand_a = counter;
        }

        // Bytes 0-5: 48-bit Unix timestamp in milliseconds (big-endian)
        const ts_u48: u48 = @intCast(@as(u64, @bitCast(timestamp_ms)) & 0xFFFFFFFFFFFF);
        uuid.bytes[0] = @truncate(ts_u48 >> 40);
        uuid.bytes[1] = @truncate(ts_u48 >> 32);
        uuid.bytes[2] = @truncate(ts_u48 >> 24);
        uuid.bytes[3] = @truncate(ts_u48 >> 16);
        uuid.bytes[4] = @truncate(ts_u48 >> 8);
        uuid.bytes[5] = @truncate(ts_u48);

        // Bytes 6-7: version (0111) and rand_a (12 bits)
        // High 4 bits of byte 6 = version 7 (0111)
        // Low 4 bits of byte 6 + high 8 bits of byte 7 = rand_a
        uuid.bytes[6] = 0x70 | @as(u8, @truncate(rand_a >> 8));
        uuid.bytes[7] = @truncate(rand_a);

        // Bytes 8-15: variant (10) and rand_b (62 bits)
        // Generate 8 random bytes
        std.crypto.random.bytes(uuid.bytes[8..16]);

        // Set variant bits in byte 8 to 10xxxxxx
        uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;

        return uuid;
    }

    /// Format the UUID as a 36-character string in the standard format:
    /// xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    pub fn toString(self: Uuid7, buf: *[36]u8) void {
        const hex_chars = "0123456789abcdef";

        var out_idx: usize = 0;
        for (self.bytes, 0..) |byte, i| {
            // Insert hyphens at positions 4, 6, 8, 10 (after bytes 3, 5, 7, 9)
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                buf[out_idx] = '-';
                out_idx += 1;
            }

            buf[out_idx] = hex_chars[byte >> 4];
            buf[out_idx + 1] = hex_chars[byte & 0x0F];
            out_idx += 2;
        }
    }

    /// Extract the Unix timestamp in milliseconds from the UUID.
    /// Returns the 48-bit timestamp as an i64.
    pub fn getTimestamp(self: Uuid7) i64 {
        const ts: u48 =
            (@as(u48, self.bytes[0]) << 40) |
            (@as(u48, self.bytes[1]) << 32) |
            (@as(u48, self.bytes[2]) << 24) |
            (@as(u48, self.bytes[3]) << 16) |
            (@as(u48, self.bytes[4]) << 8) |
            @as(u48, self.bytes[5]);

        return @intCast(ts);
    }

    /// Parse a UUID from a 36-character string.
    /// Accepts standard format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    /// Returns error.InvalidFormat if the string is malformed.
    pub fn fromString(str: []const u8) !Uuid7 {
        if (str.len != 36) {
            return error.InvalidFormat;
        }

        // Validate hyphen positions
        if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
            return error.InvalidFormat;
        }

        var uuid: Uuid7 = undefined;
        var byte_idx: usize = 0;
        var i: usize = 0;

        while (i < 36) : (i += 1) {
            // Skip hyphens
            if (str[i] == '-') {
                continue;
            }

            // Need two hex chars for one byte
            if (i + 1 >= 36 or str[i + 1] == '-') {
                return error.InvalidFormat;
            }

            const high = hexCharToNibble(str[i]) orelse return error.InvalidFormat;
            const low = hexCharToNibble(str[i + 1]) orelse return error.InvalidFormat;

            uuid.bytes[byte_idx] = (@as(u8, high) << 4) | low;
            byte_idx += 1;
            i += 1; // Skip the second hex char (loop will increment again)
        }

        if (byte_idx != 16) {
            return error.InvalidFormat;
        }

        // Validate version (should be 7)
        const version = (uuid.bytes[6] >> 4);
        if (version != 7) {
            return error.InvalidVersion;
        }

        // Validate variant (should be 10xx xxxx)
        const variant = (uuid.bytes[8] >> 6);
        if (variant != 0b10) {
            return error.InvalidVariant;
        }

        return uuid;
    }

    /// Compare two UUIDs for ordering.
    /// Returns negative if self < other, positive if self > other, zero if equal.
    /// Time-ordered by design: earlier UUIDs sort before later ones.
    pub fn compare(self: Uuid7, other: Uuid7) i32 {
        for (self.bytes, other.bytes) |a, b| {
            if (a < b) return -1;
            if (a > b) return 1;
        }
        return 0;
    }

    /// Check if two UUIDs are equal.
    pub fn eql(self: Uuid7, other: Uuid7) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

/// Convert a hex character to its 4-bit value.
fn hexCharToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "generate creates valid UUID v7" {
    const uuid = Uuid7.generate();

    // Check version (bits 48-51 should be 0111 = 7)
    const version = uuid.bytes[6] >> 4;
    try std.testing.expectEqual(@as(u8, 7), version);

    // Check variant (bits 64-65 should be 10)
    const variant = uuid.bytes[8] >> 6;
    try std.testing.expectEqual(@as(u8, 0b10), variant);
}

test "generate creates unique UUIDs" {
    const uuid1 = Uuid7.generate();
    const uuid2 = Uuid7.generate();

    try std.testing.expect(!uuid1.eql(uuid2));
}

test "generate creates time-ordered UUIDs" {
    const uuid1 = Uuid7.generate();

    // Small delay to ensure different timestamp
    std.Thread.sleep(1_000_000); // 1ms

    const uuid2 = Uuid7.generate();

    // uuid2 should be greater than uuid1 (later time sorts after)
    try std.testing.expect(uuid1.compare(uuid2) < 0);
}

test "rapid generation produces unique UUIDs" {
    var uuids: [100]Uuid7 = undefined;

    // Generate many UUIDs rapidly
    for (&uuids) |*uuid| {
        uuid.* = Uuid7.generate();
    }

    // Check all are unique
    for (uuids, 0..) |uuid1, i| {
        for (uuids[i + 1 ..]) |uuid2| {
            try std.testing.expect(!uuid1.eql(uuid2));
        }
    }
}

test "rapid generation maintains ordering" {
    var uuids: [100]Uuid7 = undefined;

    // Generate many UUIDs rapidly
    for (&uuids) |*uuid| {
        uuid.* = Uuid7.generate();
    }

    // Check ordering is maintained (each UUID <= next)
    for (0..uuids.len - 1) |i| {
        try std.testing.expect(uuids[i].compare(uuids[i + 1]) <= 0);
    }
}

test "toString formats correctly" {
    var uuid: Uuid7 = undefined;
    // Set known bytes for predictable output
    uuid.bytes = .{ 0x01, 0x89, 0x4c, 0x77, 0x7b, 0x1c, 0x72, 0x34, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 };

    var buf: [36]u8 = undefined;
    uuid.toString(&buf);

    try std.testing.expectEqualStrings("01894c77-7b1c-7234-89ab-cdef01234567", &buf);
}

test "fromString parses valid UUID" {
    const uuid = try Uuid7.fromString("01894c77-7b1c-7234-89ab-cdef01234567");

    try std.testing.expectEqual(@as(u8, 0x01), uuid.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x89), uuid.bytes[1]);
    try std.testing.expectEqual(@as(u8, 0x4c), uuid.bytes[2]);
    try std.testing.expectEqual(@as(u8, 0x77), uuid.bytes[3]);
    try std.testing.expectEqual(@as(u8, 0x7b), uuid.bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x1c), uuid.bytes[5]);
    try std.testing.expectEqual(@as(u8, 0x72), uuid.bytes[6]);
    try std.testing.expectEqual(@as(u8, 0x34), uuid.bytes[7]);
    try std.testing.expectEqual(@as(u8, 0x89), uuid.bytes[8]);
    try std.testing.expectEqual(@as(u8, 0xab), uuid.bytes[9]);
}

test "fromString accepts uppercase" {
    const uuid = try Uuid7.fromString("01894C77-7B1C-7234-89AB-CDEF01234567");

    try std.testing.expectEqual(@as(u8, 0x01), uuid.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xcd), uuid.bytes[10]);
}

test "fromString rejects invalid length" {
    try std.testing.expectError(error.InvalidFormat, Uuid7.fromString("01894c77-7b1c-7234-89ab-cdef0123456"));
    try std.testing.expectError(error.InvalidFormat, Uuid7.fromString("01894c77-7b1c-7234-89ab-cdef012345678"));
}

test "fromString rejects missing hyphens" {
    try std.testing.expectError(error.InvalidFormat, Uuid7.fromString("01894c777b1c-7234-89ab-cdef01234567"));
}

test "fromString rejects invalid version" {
    // Version 4 UUID (not version 7)
    try std.testing.expectError(error.InvalidVersion, Uuid7.fromString("01894c77-7b1c-4234-89ab-cdef01234567"));
}

test "fromString rejects invalid variant" {
    // Variant bits are 11 instead of 10
    try std.testing.expectError(error.InvalidVariant, Uuid7.fromString("01894c77-7b1c-7234-c9ab-cdef01234567"));
}

test "roundtrip toString and fromString" {
    const original = Uuid7.generate();

    var buf: [36]u8 = undefined;
    original.toString(&buf);

    const parsed = try Uuid7.fromString(&buf);

    try std.testing.expect(original.eql(parsed));
}

test "getTimestamp extracts correct timestamp" {
    // Create a UUID with a known timestamp
    var uuid: Uuid7 = undefined;
    // Timestamp: 0x01894c777b1c (1700000000028 ms = ~2023-11-14)
    uuid.bytes = .{ 0x01, 0x89, 0x4c, 0x77, 0x7b, 0x1c, 0x72, 0x34, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 };

    const timestamp = uuid.getTimestamp();

    try std.testing.expectEqual(@as(i64, 0x01894c777b1c), timestamp);
}

test "getTimestamp matches generation time" {
    const before = std.time.milliTimestamp();
    const uuid = Uuid7.generate();
    const after = std.time.milliTimestamp();

    const uuid_ts = uuid.getTimestamp();

    // UUID timestamp should be between before and after
    try std.testing.expect(uuid_ts >= before);
    try std.testing.expect(uuid_ts <= after);
}

test "compare orders correctly" {
    var uuid1: Uuid7 = undefined;
    var uuid2: Uuid7 = undefined;

    // uuid1 has earlier timestamp
    uuid1.bytes = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x70, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    uuid2.bytes = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x70, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    try std.testing.expect(uuid1.compare(uuid2) < 0);
    try std.testing.expect(uuid2.compare(uuid1) > 0);
    try std.testing.expect(uuid1.compare(uuid1) == 0);
}

test "performance: generation under 1 microsecond" {
    const iterations = 10000;

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = Uuid7.generate();
    }
    const end = std.time.nanoTimestamp();

    const total_ns = end - start;
    const avg_ns = @divFloor(total_ns, iterations);

    // Should be under 1000ns (1 microsecond) per generation
    try std.testing.expect(avg_ns < 1000);
}
