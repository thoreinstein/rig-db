const std = @import("std");
const terminal_mod = @import("terminal.zig");
const reader_mod = @import("reader.zig");
const search_mod = @import("search.zig");
const display_mod = @import("display.zig");

const Terminal = terminal_mod.Terminal;
const RawModeGuard = terminal_mod.RawModeGuard;
const Display = display_mod.Display;
const SearchState = display_mod.SearchState;
const HistoryReader = reader_mod.HistoryReader;

// Alternate screen buffer escape sequences
const ALT_SCREEN_ON = "\x1b[?1049h";
const ALT_SCREEN_OFF = "\x1b[?1049l";

/// Run the interactive search TUI.
/// Renders to stderr (so stdout can be captured by shell for Ctrl+R).
/// Returns the selected command (caller must free), or null if cancelled.
pub fn run(allocator: std.mem.Allocator) !?[]u8 {
    // Open database read-only
    var reader = HistoryReader.open(allocator) catch |err| {
        switch (err) {
            reader_mod.ReaderError.DatabaseNotFound => {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("No history recorded yet. Run some commands first.\n") catch {};
                return null;
            },
            else => return null,
        }
    };
    defer reader.close();

    // Setup terminal (raw mode for key-by-key input)
    var term = Terminal.init();
    const guard = try RawModeGuard.init(&term);
    defer guard.deinit();

    // Write TUI to stderr so stdout can be captured by $()
    const output = std.fs.File.stderr();

    // Switch to alternate screen buffer (preserves user's terminal content)
    output.writeAll(ALT_SCREEN_ON) catch {};
    defer output.writeAll(ALT_SCREEN_OFF) catch {};

    var display = Display.initWithOutput(&term, output);
    var state = SearchState.init();

    // Query buffer
    var query_buf: [256]u8 = undefined;
    var query_len: usize = 0;

    // Track current search results for cleanup
    var current_results: ?[]search_mod.SearchResult = null;
    var current_display: ?[]display_mod.DisplayRecord = null;
    defer {
        if (current_display) |d| allocator.free(d);
        if (current_results) |r| search_mod.freeResults(allocator, r);
    }

    // Initial search (empty query = all recent commands)
    doSearch(&reader, allocator, &state, &current_results, &current_display, "");

    // Render initial state
    display.clear() catch {};
    display.render(&state) catch {};

    // Event loop
    while (true) {
        if (term.readKey() catch null) |key| {
            var needs_search = false;

            switch (key) {
                .escape, .ctrl_c, .ctrl_d => {
                    state.cancel();
                    break;
                },
                .enter => break,
                .backspace => {
                    if (query_len > 0) {
                        query_len -= 1;
                        needs_search = true;
                    }
                },
                .arrow_up => state.moveUp(),
                .arrow_down => state.moveDown(),
                .page_up => state.pageUp(),
                .page_down => state.pageDown(),
                .char => |c| {
                    if (c >= 0x20 and c < 0x7f and query_len < query_buf.len) {
                        query_buf[query_len] = c;
                        query_len += 1;
                        needs_search = true;
                    }
                },
                else => {},
            }

            if (needs_search) {
                state.setQuery(query_buf[0..query_len]);
                doSearch(&reader, allocator, &state, &current_results, &current_display, query_buf[0..query_len]);
            }

            display.render(&state) catch {};
        }
    }

    display.cleanup() catch {};

    // Return selected command (caller prints to stdout)
    if (!state.cancelled) {
        if (state.getSelectedCommand()) |cmd| {
            return allocator.dupe(u8, cmd) catch return null;
        }
    }
    return null;
}

/// Run a search and update state with results.
fn doSearch(
    reader: *HistoryReader,
    allocator: std.mem.Allocator,
    state: *SearchState,
    current_results: *?[]search_mod.SearchResult,
    current_display: *?[]display_mod.DisplayRecord,
    query: []const u8,
) void {
    // Free old results
    if (current_display.*) |d| allocator.free(d);
    current_display.* = null;
    if (current_results.*) |r| search_mod.freeResults(allocator, r);
    current_results.* = null;

    // Run search
    const results = search_mod.search(reader, allocator, .{
        .query = query,
        .substring_match = true,
        .unique = true,
        .limit = 100,
    }) catch {
        state.setResults(&.{});
        return;
    };

    // Convert to display records
    const display_records = display_mod.historySliceToDisplay(allocator, results) catch {
        search_mod.freeResults(allocator, results);
        state.setResults(&.{});
        return;
    };

    current_results.* = results;
    current_display.* = display_records;
    state.setResults(display_records);
}

// =============================================================================
// Tests
// =============================================================================

test "doSearch with no database does not crash" {
    // This is a compilation test - the interactive TUI can't be unit tested
    _ = &doSearch;
}
