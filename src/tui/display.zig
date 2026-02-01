const std = @import("std");
const terminal_mod = @import("terminal.zig");
const history = @import("../db/history.zig");

const Terminal = terminal_mod.Terminal;
const Key = terminal_mod.Key;

/// A result entry for display purposes, decoupled from database records.
/// This allows the display module to work with any data that can provide
/// these fields, not just HistoryRecord.
pub const DisplayRecord = struct {
    command: []const u8,
    timestamp: i128,
};

/// Search state managing the current query, results, and selection.
pub const SearchState = struct {
    /// The current search query entered by user
    query: []const u8,
    /// Results from the search (references external data)
    results: []const DisplayRecord,
    /// Index of currently selected item (0-based)
    selected_index: usize,
    /// Scroll offset for the visible window
    scroll_offset: usize,
    /// Number of visible rows for results (calculated from terminal height)
    visible_rows: usize,
    /// Whether the search was cancelled
    cancelled: bool,

    const Self = @This();

    /// Initialize a new search state.
    pub fn init() Self {
        return Self{
            .query = "",
            .results = &[_]DisplayRecord{},
            .selected_index = 0,
            .scroll_offset = 0,
            .visible_rows = 10, // Default, will be updated based on terminal size
            .cancelled = false,
        };
    }

    /// Update the results and reset selection to first item.
    pub fn setResults(self: *Self, results: []const DisplayRecord) void {
        self.results = results;
        self.selected_index = 0;
        self.scroll_offset = 0;
    }

    /// Update the query string.
    pub fn setQuery(self: *Self, query: []const u8) void {
        self.query = query;
    }

    /// Move selection up by one.
    pub fn moveUp(self: *Self) void {
        if (self.results.len == 0) return;

        if (self.selected_index > 0) {
            self.selected_index -= 1;

            // Adjust scroll offset if selection is above visible window
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    /// Move selection down by one.
    pub fn moveDown(self: *Self) void {
        if (self.results.len == 0) return;

        if (self.selected_index < self.results.len - 1) {
            self.selected_index += 1;

            // Adjust scroll offset if selection is below visible window
            const visible_end = self.scroll_offset + self.visible_rows;
            if (self.selected_index >= visible_end) {
                self.scroll_offset = self.selected_index - self.visible_rows + 1;
            }
        }
    }

    /// Move selection up by a page.
    pub fn pageUp(self: *Self) void {
        if (self.results.len == 0) return;

        if (self.selected_index >= self.visible_rows) {
            self.selected_index -= self.visible_rows;
            if (self.selected_index < self.scroll_offset) {
                self.scroll_offset = self.selected_index;
            }
        } else {
            self.selected_index = 0;
            self.scroll_offset = 0;
        }
    }

    /// Move selection down by a page.
    pub fn pageDown(self: *Self) void {
        if (self.results.len == 0) return;

        const new_index = self.selected_index + self.visible_rows;
        if (new_index < self.results.len) {
            self.selected_index = new_index;
        } else {
            self.selected_index = self.results.len - 1;
        }

        // Adjust scroll offset
        const visible_end = self.scroll_offset + self.visible_rows;
        if (self.selected_index >= visible_end) {
            self.scroll_offset = self.selected_index - self.visible_rows + 1;
        }
    }

    /// Get the currently selected command, or null if no results.
    pub fn getSelectedCommand(self: *const Self) ?[]const u8 {
        if (self.results.len == 0) return null;
        if (self.selected_index >= self.results.len) return null;
        return self.results[self.selected_index].command;
    }

    /// Get the currently selected record, or null if no results.
    pub fn getSelectedRecord(self: *const Self) ?DisplayRecord {
        if (self.results.len == 0) return null;
        if (self.selected_index >= self.results.len) return null;
        return self.results[self.selected_index];
    }

    /// Update the number of visible rows based on terminal size.
    /// Reserves space for: prompt (1), separator (1), status bar (1).
    pub fn setVisibleRows(self: *Self, terminal_rows: u16) void {
        // Reserve 3 rows for prompt, separator, and status bar
        const reserved_rows: u16 = 3;
        if (terminal_rows > reserved_rows) {
            self.visible_rows = terminal_rows - reserved_rows;
        } else {
            self.visible_rows = 1; // Minimum 1 visible row
        }
    }

    /// Mark the search as cancelled.
    pub fn cancel(self: *Self) void {
        self.cancelled = true;
    }
};

/// Display renderer for the TUI search interface.
pub const Display = struct {
    terminal: *Terminal,
    /// Buffer for building output strings
    output_buffer: [4096]u8 = undefined,

    const Self = @This();

    // ANSI escape codes
    const ESC = "\x1b";
    const CSI = ESC ++ "[";

    // Cursor and screen control
    const CLEAR_SCREEN = CSI ++ "2J";
    const CLEAR_LINE = CSI ++ "2K";
    const CURSOR_HOME = CSI ++ "H";
    const CURSOR_HIDE = CSI ++ "?25l";
    const CURSOR_SHOW = CSI ++ "?25h";

    // Text styling
    const RESET = CSI ++ "0m";
    const BOLD = CSI ++ "1m";
    const DIM = CSI ++ "2m";
    const REVERSE = CSI ++ "7m";
    const UNDERLINE = CSI ++ "4m";

    // Colors (foreground)
    const FG_GREEN = CSI ++ "32m";
    const FG_YELLOW = CSI ++ "33m";
    const FG_BLUE = CSI ++ "34m";
    const FG_CYAN = CSI ++ "36m";
    const FG_WHITE = CSI ++ "37m";
    const FG_BRIGHT_BLACK = CSI ++ "90m"; // Gray

    /// Initialize the display with a terminal reference.
    pub fn init(term: *Terminal) Self {
        return Self{
            .terminal = term,
        };
    }

    /// Write directly to stdout.
    fn write(self: *Self, data: []const u8) !void {
        _ = self;
        const stdout = std.io.getStdOut();
        try stdout.writeAll(data);
    }

    /// Format and write using the internal buffer.
    fn writeFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const slice = std.fmt.bufPrint(&self.output_buffer, fmt, args) catch |err| {
            return switch (err) {
                error.NoSpaceLeft => error.NoSpaceLeft,
            };
        };
        try self.write(slice);
    }

    /// Clear the entire screen.
    pub fn clear(self: *Self) !void {
        try self.write(CLEAR_SCREEN);
        try self.write(CURSOR_HOME);
    }

    /// Move cursor to specific position (1-based row, col).
    pub fn moveCursor(self: *Self, row: u16, col: u16) !void {
        try self.writeFmt(CSI ++ "{d};{d}H", .{ row, col });
    }

    /// Hide the cursor.
    pub fn hideCursor(self: *Self) !void {
        try self.write(CURSOR_HIDE);
    }

    /// Show the cursor.
    pub fn showCursor(self: *Self) !void {
        try self.write(CURSOR_SHOW);
    }

    /// Clear the current line.
    pub fn clearLine(self: *Self) !void {
        try self.write(CLEAR_LINE);
    }

    /// Render the full search UI.
    pub fn render(self: *Self, state: *SearchState) !void {
        const size = self.terminal.getSize();
        state.setVisibleRows(size.rows);

        // Start rendering
        try self.hideCursor();
        try self.moveCursor(1, 1);

        // Render prompt line
        try self.renderPrompt(state.query, size.cols);

        // Render separator
        try self.moveCursor(2, 1);
        try self.renderSeparator(size.cols);

        // Render results
        try self.renderResults(state, size.cols, size.rows);

        // Render status bar at bottom
        try self.moveCursor(size.rows, 1);
        try self.renderStatusBar(state, size.cols);

        // Position cursor at end of query
        try self.moveCursor(1, @intCast(state.query.len + 3)); // "> " + query
        try self.showCursor();
    }

    /// Render the search prompt line.
    fn renderPrompt(self: *Self, query: []const u8, width: u16) !void {
        try self.clearLine();
        try self.write(FG_GREEN ++ BOLD ++ "> " ++ RESET);

        // Truncate query if too long
        const max_query_len = if (width > 4) width - 4 else 1;
        if (query.len > max_query_len) {
            try self.write(query[0..max_query_len]);
        } else {
            try self.write(query);
        }
        try self.write("_");
    }

    /// Render the separator line.
    fn renderSeparator(self: *Self, width: u16) !void {
        try self.clearLine();
        try self.write(FG_BRIGHT_BLACK);
        var i: u16 = 0;
        while (i < width) : (i += 1) {
            try self.write("\xe2\x94\x80"); // Unicode box-drawing: horizontal line
        }
        try self.write(RESET);
    }

    /// Render the results list.
    fn renderResults(self: *Self, state: *SearchState, width: u16, height: u16) !void {
        const start_row: u16 = 3; // After prompt and separator
        const end_row = if (height > 1) height - 1 else height; // Leave room for status bar

        if (state.results.len == 0) {
            try self.moveCursor(start_row, 1);
            try self.clearLine();
            try self.write(DIM ++ "  No results found" ++ RESET);
            return;
        }

        // Calculate visible range
        const visible_count = @min(state.visible_rows, state.results.len - state.scroll_offset);

        var row: u16 = start_row;
        var i: usize = 0;
        while (i < visible_count and row < end_row) : (i += 1) {
            const result_idx = state.scroll_offset + i;
            if (result_idx >= state.results.len) break;

            try self.moveCursor(row, 1);
            try self.clearLine();

            const is_selected = result_idx == state.selected_index;
            try self.renderResultRow(state.results[result_idx], is_selected, width);

            row += 1;
        }

        // Clear remaining rows
        while (row < end_row) : (row += 1) {
            try self.moveCursor(row, 1);
            try self.clearLine();
        }
    }

    /// Render a single result row.
    fn renderResultRow(self: *Self, record: DisplayRecord, selected: bool, width: u16) !void {
        // Calculate space for timestamp (max ~15 chars like "12 months ago")
        const timestamp_width: u16 = 16;
        const prefix_width: u16 = 2; // "  " or "> "
        const padding: u16 = 2; // Space between command and timestamp

        const available_for_command = if (width > prefix_width + timestamp_width + padding)
            width - prefix_width - timestamp_width - padding
        else
            10; // Minimum

        if (selected) {
            try self.write(REVERSE);
        }

        // Selection indicator
        if (selected) {
            try self.write(FG_GREEN ++ "> " ++ RESET ++ REVERSE);
        } else {
            try self.write("  ");
        }

        // Command (truncated if needed)
        var cmd_buf: [256]u8 = undefined;
        const truncated_cmd = truncateText(record.command, available_for_command, &cmd_buf);
        try self.write(truncated_cmd);

        // Padding to align timestamp
        const cmd_display_len = truncated_cmd.len;
        const pad_needed = if (available_for_command > cmd_display_len)
            available_for_command - @as(u16, @intCast(cmd_display_len))
        else
            0;
        var pad_i: u16 = 0;
        while (pad_i < pad_needed) : (pad_i += 1) {
            try self.write(" ");
        }

        // Relative time
        var time_buf: [32]u8 = undefined;
        const relative_time = formatRelativeTime(record.timestamp, &time_buf);

        if (selected) {
            try self.write(RESET ++ REVERSE ++ FG_BRIGHT_BLACK);
        } else {
            try self.write(FG_BRIGHT_BLACK);
        }
        try self.write("  ");
        try self.write(relative_time);
        try self.write(RESET);
    }

    /// Render the status bar with keybinding hints.
    fn renderStatusBar(self: *Self, state: *SearchState, width: u16) !void {
        _ = width;
        try self.clearLine();
        try self.write(FG_BRIGHT_BLACK);

        // Show result count and position
        if (state.results.len > 0) {
            try self.writeFmt("[{d}/{d}] ", .{ state.selected_index + 1, state.results.len });
        }

        try self.write("[");
        try self.write(FG_CYAN ++ "\xe2\x86\x91\xe2\x86\x93" ++ FG_BRIGHT_BLACK); // Up/down arrows
        try self.write(" navigate] [");
        try self.write(FG_CYAN ++ "Enter" ++ FG_BRIGHT_BLACK);
        try self.write(" select] [");
        try self.write(FG_CYAN ++ "Esc" ++ FG_BRIGHT_BLACK);
        try self.write(" cancel]");
        try self.write(RESET);
    }

    /// Cleanup display state (show cursor, clear screen if needed).
    pub fn cleanup(self: *Self) !void {
        try self.showCursor();
        try self.write(RESET);
    }
};

/// Format a timestamp as relative time (e.g., "2 min ago", "1 hour ago").
pub fn formatRelativeTime(timestamp: i128, buffer: []u8) []const u8 {
    const now = std.time.nanoTimestamp();
    const diff_ns = now - timestamp;

    // Convert to seconds
    const diff_secs: i64 = @intCast(@divTrunc(diff_ns, std.time.ns_per_s));

    if (diff_secs < 0) {
        return "just now";
    }

    const diff: u64 = @intCast(diff_secs);

    if (diff < 60) {
        return "just now";
    } else if (diff < 120) {
        return "1 min ago";
    } else if (diff < 3600) {
        const mins = diff / 60;
        return std.fmt.bufPrint(buffer, "{d} min ago", .{mins}) catch "? min ago";
    } else if (diff < 7200) {
        return "1 hour ago";
    } else if (diff < 86400) {
        const hours = diff / 3600;
        return std.fmt.bufPrint(buffer, "{d} hours ago", .{hours}) catch "? hours ago";
    } else if (diff < 172800) {
        return "yesterday";
    } else if (diff < 604800) {
        const days = diff / 86400;
        return std.fmt.bufPrint(buffer, "{d} days ago", .{days}) catch "? days ago";
    } else if (diff < 1209600) {
        return "1 week ago";
    } else if (diff < 2592000) {
        const weeks = diff / 604800;
        return std.fmt.bufPrint(buffer, "{d} weeks ago", .{weeks}) catch "? weeks ago";
    } else if (diff < 5184000) {
        return "1 month ago";
    } else if (diff < 31536000) {
        const months = diff / 2592000;
        return std.fmt.bufPrint(buffer, "{d} months ago", .{months}) catch "? months ago";
    } else if (diff < 63072000) {
        return "1 year ago";
    } else {
        const years = diff / 31536000;
        return std.fmt.bufPrint(buffer, "{d} years ago", .{years}) catch "? years ago";
    }
}

/// Truncate text to fit within max_width, adding "..." if truncated.
/// Returns a slice into the provided buffer or the original text if no truncation needed.
pub fn truncateText(text: []const u8, max_width: u16, buffer: []u8) []const u8 {
    if (max_width < 4) {
        // Not enough space for truncation indicator
        if (max_width == 0) return "";
        const len = @min(text.len, max_width);
        return text[0..len];
    }

    if (text.len <= max_width) {
        return text;
    }

    // Need to truncate
    const truncated_len = max_width - 3; // Space for "..."
    if (truncated_len > buffer.len - 3) {
        // Buffer too small
        return text[0..@min(text.len, max_width)];
    }

    @memcpy(buffer[0..truncated_len], text[0..truncated_len]);
    buffer[truncated_len] = '.';
    buffer[truncated_len + 1] = '.';
    buffer[truncated_len + 2] = '.';

    return buffer[0 .. truncated_len + 3];
}

/// Convert a HistoryRecord to a DisplayRecord.
pub fn historyToDisplay(record: history.HistoryRecord) DisplayRecord {
    return DisplayRecord{
        .command = record.command,
        .timestamp = record.timestamp,
    };
}

/// Convert a slice of HistoryRecords to DisplayRecords.
/// Note: This creates a new array but references the original strings.
pub fn historySliceToDisplay(allocator: std.mem.Allocator, records: []const history.HistoryRecord) ![]DisplayRecord {
    const display_records = try allocator.alloc(DisplayRecord, records.len);
    for (records, 0..) |record, i| {
        display_records[i] = historyToDisplay(record);
    }
    return display_records;
}

// =============================================================================
// Tests
// =============================================================================

test "formatRelativeTime - just now" {
    var buffer: [32]u8 = undefined;

    // Use a timestamp very close to now
    const now = std.time.nanoTimestamp();
    const result = formatRelativeTime(now - 30 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("just now", result);
}

test "formatRelativeTime - minutes" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // 1 minute ago
    const one_min = formatRelativeTime(now - 90 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("1 min ago", one_min);

    // Multiple minutes
    const five_min = formatRelativeTime(now - 300 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("5 min ago", five_min);
}

test "formatRelativeTime - hours" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // 1 hour ago
    const one_hour = formatRelativeTime(now - 3700 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("1 hour ago", one_hour);

    // Multiple hours
    const five_hours = formatRelativeTime(now - 18000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("5 hours ago", five_hours);
}

test "formatRelativeTime - days" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // Yesterday
    const yesterday = formatRelativeTime(now - 100000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("yesterday", yesterday);

    // Multiple days
    const three_days = formatRelativeTime(now - 259200 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("3 days ago", three_days);
}

test "formatRelativeTime - weeks" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // 1 week ago
    const one_week = formatRelativeTime(now - 700000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("1 week ago", one_week);

    // Multiple weeks
    const three_weeks = formatRelativeTime(now - 2000000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("3 weeks ago", three_weeks);
}

test "formatRelativeTime - months" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // 1 month ago
    const one_month = formatRelativeTime(now - 3000000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("1 month ago", one_month);

    // Multiple months
    const six_months = formatRelativeTime(now - 15552000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("6 months ago", six_months);
}

test "formatRelativeTime - years" {
    var buffer: [32]u8 = undefined;

    const now = std.time.nanoTimestamp();

    // 1 year ago
    const one_year = formatRelativeTime(now - 40000000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("1 year ago", one_year);

    // Multiple years
    const three_years = formatRelativeTime(now - 100000000 * std.time.ns_per_s, &buffer);
    try std.testing.expectEqualStrings("3 years ago", three_years);
}

test "truncateText - no truncation needed" {
    var buffer: [256]u8 = undefined;

    const short = "hello";
    const result = truncateText(short, 10, &buffer);
    try std.testing.expectEqualStrings("hello", result);
}

test "truncateText - exact fit" {
    var buffer: [256]u8 = undefined;

    const exact = "hello";
    const result = truncateText(exact, 5, &buffer);
    try std.testing.expectEqualStrings("hello", result);
}

test "truncateText - needs truncation" {
    var buffer: [256]u8 = undefined;

    const long_text = "this is a very long command that needs truncation";
    const result = truncateText(long_text, 20, &buffer);
    try std.testing.expectEqualStrings("this is a very lo...", result);
    try std.testing.expectEqual(@as(usize, 20), result.len);
}

test "truncateText - minimum width" {
    var buffer: [256]u8 = undefined;

    const text = "hello world";
    const result = truncateText(text, 4, &buffer);
    try std.testing.expectEqualStrings("h...", result);
}

test "truncateText - very small width" {
    var buffer: [256]u8 = undefined;

    const text = "hello";
    const result = truncateText(text, 2, &buffer);
    try std.testing.expectEqualStrings("he", result);
}

test "truncateText - zero width" {
    var buffer: [256]u8 = undefined;

    const text = "hello";
    const result = truncateText(text, 0, &buffer);
    try std.testing.expectEqualStrings("", result);
}

test "SearchState - init" {
    const state = SearchState.init();
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);
    try std.testing.expectEqualStrings("", state.query);
    try std.testing.expectEqual(@as(usize, 0), state.results.len);
    try std.testing.expect(!state.cancelled);
}

test "SearchState - moveUp/moveDown" {
    var state = SearchState.init();

    const test_records = [_]DisplayRecord{
        .{ .command = "cmd1", .timestamp = 1000 },
        .{ .command = "cmd2", .timestamp = 2000 },
        .{ .command = "cmd3", .timestamp = 3000 },
    };

    state.setResults(&test_records);

    try std.testing.expectEqual(@as(usize, 0), state.selected_index);

    state.moveDown();
    try std.testing.expectEqual(@as(usize, 1), state.selected_index);

    state.moveDown();
    try std.testing.expectEqual(@as(usize, 2), state.selected_index);

    // Can't go past last item
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 2), state.selected_index);

    state.moveUp();
    try std.testing.expectEqual(@as(usize, 1), state.selected_index);

    state.moveUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);

    // Can't go before first item
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
}

test "SearchState - getSelectedCommand" {
    var state = SearchState.init();

    // No results
    try std.testing.expect(state.getSelectedCommand() == null);

    const test_records = [_]DisplayRecord{
        .{ .command = "ls -la", .timestamp = 1000 },
        .{ .command = "git status", .timestamp = 2000 },
    };

    state.setResults(&test_records);

    const cmd = state.getSelectedCommand();
    try std.testing.expect(cmd != null);
    try std.testing.expectEqualStrings("ls -la", cmd.?);

    state.moveDown();
    const cmd2 = state.getSelectedCommand();
    try std.testing.expectEqualStrings("git status", cmd2.?);
}

test "SearchState - scrolling" {
    var state = SearchState.init();
    state.visible_rows = 3;

    // Create more records than visible rows
    const test_records = [_]DisplayRecord{
        .{ .command = "cmd0", .timestamp = 0 },
        .{ .command = "cmd1", .timestamp = 1 },
        .{ .command = "cmd2", .timestamp = 2 },
        .{ .command = "cmd3", .timestamp = 3 },
        .{ .command = "cmd4", .timestamp = 4 },
        .{ .command = "cmd5", .timestamp = 5 },
    };

    state.setResults(&test_records);

    // Initially at top
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);

    // Move down within visible window
    state.moveDown();
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 2), state.selected_index);
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);

    // Move down should trigger scroll
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 3), state.selected_index);
    try std.testing.expectEqual(@as(usize, 1), state.scroll_offset);

    // Continue scrolling
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 4), state.selected_index);
    try std.testing.expectEqual(@as(usize, 2), state.scroll_offset);

    // Move up should scroll back
    state.moveUp();
    state.moveUp();
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 1), state.selected_index);
    try std.testing.expectEqual(@as(usize, 1), state.scroll_offset);
}

test "SearchState - pageUp/pageDown" {
    var state = SearchState.init();
    state.visible_rows = 3;

    const test_records = [_]DisplayRecord{
        .{ .command = "cmd0", .timestamp = 0 },
        .{ .command = "cmd1", .timestamp = 1 },
        .{ .command = "cmd2", .timestamp = 2 },
        .{ .command = "cmd3", .timestamp = 3 },
        .{ .command = "cmd4", .timestamp = 4 },
        .{ .command = "cmd5", .timestamp = 5 },
        .{ .command = "cmd6", .timestamp = 6 },
        .{ .command = "cmd7", .timestamp = 7 },
        .{ .command = "cmd8", .timestamp = 8 },
    };

    state.setResults(&test_records);

    // Page down
    state.pageDown();
    try std.testing.expectEqual(@as(usize, 3), state.selected_index);

    state.pageDown();
    try std.testing.expectEqual(@as(usize, 6), state.selected_index);

    // Page down near end
    state.pageDown();
    try std.testing.expectEqual(@as(usize, 8), state.selected_index);

    // Page up
    state.pageUp();
    try std.testing.expectEqual(@as(usize, 5), state.selected_index);

    state.pageUp();
    try std.testing.expectEqual(@as(usize, 2), state.selected_index);

    state.pageUp();
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
}

test "SearchState - setVisibleRows" {
    var state = SearchState.init();

    // Normal terminal
    state.setVisibleRows(24);
    try std.testing.expectEqual(@as(usize, 21), state.visible_rows);

    // Small terminal
    state.setVisibleRows(5);
    try std.testing.expectEqual(@as(usize, 2), state.visible_rows);

    // Very small terminal (edge case)
    state.setVisibleRows(3);
    try std.testing.expectEqual(@as(usize, 1), state.visible_rows);

    // Smaller than reserved
    state.setVisibleRows(2);
    try std.testing.expectEqual(@as(usize, 1), state.visible_rows);
}

test "SearchState - cancel" {
    var state = SearchState.init();
    try std.testing.expect(!state.cancelled);

    state.cancel();
    try std.testing.expect(state.cancelled);
}

test "SearchState - setQuery" {
    var state = SearchState.init();
    try std.testing.expectEqualStrings("", state.query);

    state.setQuery("git");
    try std.testing.expectEqualStrings("git", state.query);

    state.setQuery("git status");
    try std.testing.expectEqualStrings("git status", state.query);
}

test "SearchState - setResults resets selection" {
    var state = SearchState.init();

    const records1 = [_]DisplayRecord{
        .{ .command = "cmd1", .timestamp = 1 },
        .{ .command = "cmd2", .timestamp = 2 },
    };

    state.setResults(&records1);
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 1), state.selected_index);

    // New results should reset selection
    const records2 = [_]DisplayRecord{
        .{ .command = "new1", .timestamp = 10 },
        .{ .command = "new2", .timestamp = 20 },
        .{ .command = "new3", .timestamp = 30 },
    };

    state.setResults(&records2);
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    try std.testing.expectEqual(@as(usize, 0), state.scroll_offset);
}

test "Display.init" {
    var term = Terminal.init();
    const display = Display.init(&term);
    try std.testing.expectEqual(&term, display.terminal);
}

test "historyToDisplay" {
    const record = history.HistoryRecord{
        .id = "test-id",
        .timestamp = 12345,
        .duration = 100,
        .exit_code = 0,
        .command = "ls -la",
        .cwd = "/home",
        .session = "sess",
        .hostname = "host",
        .deleted_at = null,
    };

    const display_record = historyToDisplay(record);
    try std.testing.expectEqualStrings("ls -la", display_record.command);
    try std.testing.expectEqual(@as(i128, 12345), display_record.timestamp);
}
