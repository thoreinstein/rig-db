const std = @import("std");
const posix = std.posix;

/// Key represents a parsed keyboard input.
pub const Key = union(enum) {
    /// Regular character input
    char: u8,
    /// Arrow key directions
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    /// Special keys
    enter,
    escape,
    backspace,
    delete,
    home,
    end,
    page_up,
    page_down,
    /// Control sequences
    ctrl_c,
    ctrl_d,
    ctrl_z,
    /// Unknown or unhandled input
    unknown,

    /// Returns true if this is a printable character.
    pub fn isPrintable(self: Key) bool {
        return switch (self) {
            .char => |c| c >= 0x20 and c < 0x7f,
            else => false,
        };
    }
};

/// Terminal state for raw mode operations.
pub const Terminal = struct {
    const Self = @This();

    /// Original termios settings to restore on exit.
    original_termios: ?posix.termios = null,
    /// File descriptor for the terminal (stdin).
    fd: posix.fd_t,
    /// Flag indicating if raw mode is currently active.
    is_raw: bool = false,
    /// Current terminal size (columns, rows).
    size: Size = .{ .cols = 80, .rows = 24 },
    /// Callback for window resize events.
    resize_callback: ?*const fn (*Self) void = null,

    pub const Size = struct {
        cols: u16,
        rows: u16,
    };

    /// Global terminal instance for signal handler access.
    /// This is necessary because signal handlers cannot capture state.
    var global_instance: ?*Self = null;

    /// Initialize the terminal handler.
    pub fn init() Self {
        return Self{
            .fd = posix.STDIN_FILENO,
        };
    }

    /// Enter raw mode for the terminal.
    /// Disables canonical mode, echo, and signal processing.
    /// Returns error if terminal settings cannot be changed.
    pub fn enableRawMode(self: *Self) !void {
        if (self.is_raw) return;

        // Get current terminal attributes
        self.original_termios = try posix.tcgetattr(self.fd);

        var raw = self.original_termios.?;

        // Input flags: disable break signal, CR to NL, parity check, strip bit, XON/XOFF
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output flags: disable post-processing
        raw.oflag.OPOST = false;

        // Control flags: set character size to 8 bits
        raw.cflag.CSIZE = .CS8;

        // Local flags: disable echo, canonical mode, extended input, signals
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Control characters: read returns immediately with 0 or more bytes
        // VMIN = 0: return immediately even if no input
        // VTIME = 1: timeout after 100ms (1 decisecond)
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        // Apply the new settings
        try posix.tcsetattr(self.fd, .FLUSH, raw);

        // Register this instance for signal handling
        global_instance = self;

        // Register SIGWINCH handler for window resize
        try self.registerSignalHandler();

        // Get initial terminal size
        self.updateSize();

        self.is_raw = true;
    }

    /// Exit raw mode and restore original terminal settings.
    pub fn disableRawMode(self: *Self) void {
        if (!self.is_raw) return;
        if (self.original_termios) |original| {
            posix.tcsetattr(self.fd, .FLUSH, original) catch {};
        }
        self.is_raw = false;
        global_instance = null;
    }

    /// Register signal handlers for cleanup and resize.
    fn registerSignalHandler(self: *Self) !void {
        _ = self;
        // Register SIGWINCH handler
        const sigwinch_action = posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        try posix.sigaction(posix.SIG.WINCH, &sigwinch_action, null);
    }

    /// Signal handler for SIGWINCH (window resize).
    fn handleSigwinch(_: c_int) callconv(.C) void {
        if (global_instance) |instance| {
            instance.updateSize();
            if (instance.resize_callback) |callback| {
                callback(instance);
            }
        }
    }

    /// Update the terminal size from the kernel.
    pub fn updateSize(self: *Self) void {
        var ws: posix.winsize = undefined;
        const result = posix.system.ioctl(self.fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            self.size.cols = ws.col;
            self.size.rows = ws.row;
        }
    }

    /// Get the current terminal size.
    pub fn getSize(self: *Self) Size {
        return self.size;
    }

    /// Set a callback for window resize events.
    pub fn setResizeCallback(self: *Self, callback: ?*const fn (*Self) void) void {
        self.resize_callback = callback;
    }

    /// Read a single key from the terminal.
    /// Returns null if no input is available (non-blocking).
    pub fn readKey(self: *Self) !?Key {
        var buf: [8]u8 = undefined;

        const n = posix.read(self.fd, &buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        if (n == 0) return null;

        return parseKey(buf[0..n]);
    }

    /// Read a key with blocking behavior.
    /// Waits until a key is pressed.
    pub fn readKeyBlocking(self: *Self) !Key {
        while (true) {
            if (try self.readKey()) |key| {
                return key;
            }
        }
    }
};

/// Parse raw input bytes into a Key value.
pub fn parseKey(bytes: []const u8) Key {
    if (bytes.len == 0) return .unknown;

    // Single byte sequences
    if (bytes.len == 1) {
        return switch (bytes[0]) {
            0x03 => .ctrl_c, // Ctrl+C
            0x04 => .ctrl_d, // Ctrl+D (EOF)
            0x1a => .ctrl_z, // Ctrl+Z
            0x1b => .escape, // Escape (alone)
            0x7f => .backspace, // Backspace (DEL)
            0x08 => .backspace, // Backspace (BS)
            '\r', '\n' => .enter, // Enter
            else => |c| if (c >= 0x20 and c < 0x7f)
                Key{ .char = c }
            else
                .unknown,
        };
    }

    // Escape sequences
    if (bytes[0] == 0x1b) {
        // CSI sequences: ESC [
        if (bytes.len >= 3 and bytes[1] == '[') {
            // Arrow keys: ESC [ A/B/C/D
            if (bytes.len == 3) {
                return switch (bytes[2]) {
                    'A' => .arrow_up,
                    'B' => .arrow_down,
                    'C' => .arrow_right,
                    'D' => .arrow_left,
                    'H' => .home,
                    'F' => .end,
                    else => .unknown,
                };
            }

            // Extended sequences: ESC [ n ~
            if (bytes.len == 4 and bytes[3] == '~') {
                return switch (bytes[2]) {
                    '1' => .home,
                    '3' => .delete,
                    '4' => .end,
                    '5' => .page_up,
                    '6' => .page_down,
                    '7' => .home,
                    '8' => .end,
                    else => .unknown,
                };
            }
        }

        // SS3 sequences: ESC O
        if (bytes.len >= 3 and bytes[1] == 'O') {
            return switch (bytes[2]) {
                'A' => .arrow_up,
                'B' => .arrow_down,
                'C' => .arrow_right,
                'D' => .arrow_left,
                'H' => .home,
                'F' => .end,
                else => .unknown,
            };
        }
    }

    return .unknown;
}

/// RAII wrapper for raw mode that ensures cleanup on scope exit.
pub const RawModeGuard = struct {
    terminal: *Terminal,

    const Self = @This();

    pub fn init(terminal: *Terminal) !Self {
        try terminal.enableRawMode();
        return Self{ .terminal = terminal };
    }

    pub fn deinit(self: Self) void {
        self.terminal.disableRawMode();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parseKey - single characters" {
    const testing = std.testing;

    // Printable characters
    try testing.expectEqual(Key{ .char = 'a' }, parseKey("a"));
    try testing.expectEqual(Key{ .char = 'Z' }, parseKey("Z"));
    try testing.expectEqual(Key{ .char = '0' }, parseKey("0"));
    try testing.expectEqual(Key{ .char = ' ' }, parseKey(" "));
}

test "parseKey - control characters" {
    const testing = std.testing;

    try testing.expectEqual(Key.ctrl_c, parseKey(&[_]u8{0x03}));
    try testing.expectEqual(Key.ctrl_d, parseKey(&[_]u8{0x04}));
    try testing.expectEqual(Key.ctrl_z, parseKey(&[_]u8{0x1a}));
}

test "parseKey - special keys" {
    const testing = std.testing;

    try testing.expectEqual(Key.enter, parseKey(&[_]u8{'\r'}));
    try testing.expectEqual(Key.enter, parseKey(&[_]u8{'\n'}));
    try testing.expectEqual(Key.backspace, parseKey(&[_]u8{0x7f}));
    try testing.expectEqual(Key.backspace, parseKey(&[_]u8{0x08}));
    try testing.expectEqual(Key.escape, parseKey(&[_]u8{0x1b}));
}

test "parseKey - arrow keys CSI" {
    const testing = std.testing;

    try testing.expectEqual(Key.arrow_up, parseKey("\x1b[A"));
    try testing.expectEqual(Key.arrow_down, parseKey("\x1b[B"));
    try testing.expectEqual(Key.arrow_right, parseKey("\x1b[C"));
    try testing.expectEqual(Key.arrow_left, parseKey("\x1b[D"));
}

test "parseKey - arrow keys SS3" {
    const testing = std.testing;

    try testing.expectEqual(Key.arrow_up, parseKey("\x1bOA"));
    try testing.expectEqual(Key.arrow_down, parseKey("\x1bOB"));
    try testing.expectEqual(Key.arrow_right, parseKey("\x1bOC"));
    try testing.expectEqual(Key.arrow_left, parseKey("\x1bOD"));
}

test "parseKey - navigation keys" {
    const testing = std.testing;

    // CSI sequences
    try testing.expectEqual(Key.home, parseKey("\x1b[H"));
    try testing.expectEqual(Key.end, parseKey("\x1b[F"));

    // VT sequences
    try testing.expectEqual(Key.delete, parseKey("\x1b[3~"));
    try testing.expectEqual(Key.page_up, parseKey("\x1b[5~"));
    try testing.expectEqual(Key.page_down, parseKey("\x1b[6~"));
}

test "parseKey - empty input" {
    const testing = std.testing;
    try testing.expectEqual(Key.unknown, parseKey(""));
}

test "Key.isPrintable" {
    const testing = std.testing;

    try testing.expect(Key.isPrintable(.{ .char = 'a' }));
    try testing.expect(Key.isPrintable(.{ .char = ' ' }));
    try testing.expect(!Key.isPrintable(.{ .char = 0x01 })); // Ctrl+A
    try testing.expect(!Key.isPrintable(.enter));
    try testing.expect(!Key.isPrintable(.arrow_up));
}

test "Terminal.init" {
    const term = Terminal.init();
    try std.testing.expectEqual(posix.STDIN_FILENO, term.fd);
    try std.testing.expect(!term.is_raw);
    try std.testing.expect(term.original_termios == null);
}

test "RawModeGuard type exists" {
    // Just verify the type compiles correctly
    _ = RawModeGuard;
}
