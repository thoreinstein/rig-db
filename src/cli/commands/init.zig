const std = @import("std");
const mem = std.mem;

/// Errors specific to the init command
pub const InitError = error{
    /// Unknown shell type
    UnknownShell,
    /// Failed to write to stdout
    WriteFailed,
};

/// Run the 'rig init <shell>' command.
/// Outputs shell initialization script to stdout.
///
/// Supported shells: zsh, bash
pub fn run(args: []const []const u8, writer: anytype) !void {
    if (args.len == 0) {
        try printUsage(writer);
        return;
    }

    const shell = args[0];

    if (mem.eql(u8, shell, "zsh")) {
        try outputZshScript(writer);
    } else if (mem.eql(u8, shell, "bash")) {
        try outputBashScript(writer);
    } else if (mem.eql(u8, shell, "help") or mem.eql(u8, shell, "--help") or mem.eql(u8, shell, "-h")) {
        try printUsage(writer);
    } else {
        return InitError.UnknownShell;
    }
}

fn printUsage(writer: anytype) !void {
    _ = try writer.write(
        \\rig init - Generate shell integration script
        \\
        \\Usage:
        \\  rig init <shell>
        \\
        \\Supported shells:
        \\  zsh     Generate Zsh integration (add to ~/.zshrc)
        \\  bash    Generate Bash integration (add to ~/.bashrc)
        \\
        \\Examples:
        \\  # Add to ~/.zshrc:
        \\  eval "$(rig init zsh)"
        \\
        \\  # Add to ~/.bashrc:
        \\  eval "$(rig init bash)"
        \\
    );
}

/// Output Zsh integration script.
/// Uses preexec/precmd hooks for command tracking.
fn outputZshScript(writer: anytype) !void {
    _ = try writer.write(
        \\# rig shell integration for Zsh
        \\# Add to ~/.zshrc: eval "$(rig init zsh)"
        \\
        \\# Initialize session UUID (persists for shell lifetime)
        \\if [[ -z "${RIG_SESSION}" ]]; then
        \\    export RIG_SESSION="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown-$$-$RANDOM")"
        \\fi
        \\
        \\# State variables
        \\typeset -g _rig_cmd_id=""
        \\typeset -g _rig_preexec_done=0
        \\
        \\# Pre-execution hook: called before each command runs
        \\_rig_preexec() {
        \\    # Skip if we already ran for this command (handles multiline)
        \\    [[ "$_rig_preexec_done" == "1" ]] && return
        \\    _rig_preexec_done=1
        \\
        \\    # $1 is the command line as typed
        \\    local cmd="$1"
        \\
        \\    # Skip empty commands
        \\    [[ -z "${cmd// }" ]] && return
        \\
        \\    # Skip rig's own commands to avoid recursion
        \\    [[ "$cmd" == rig\ * ]] && return
        \\
        \\    # Record command start, capture UUID
        \\    _rig_cmd_id="$(rig history start -- "$cmd" 2>/dev/null)"
        \\}
        \\
        \\# Pre-prompt hook: called before each prompt is displayed
        \\_rig_precmd() {
        \\    local exit_code=$?
        \\
        \\    # Reset preexec flag for next command
        \\    _rig_preexec_done=0
        \\
        \\    # If we have a command ID, record its completion
        \\    if [[ -n "$_rig_cmd_id" ]]; then
        \\        rig history end --id "$_rig_cmd_id" --exit "$exit_code" 2>/dev/null &!
        \\        _rig_cmd_id=""
        \\    fi
        \\}
        \\
        \\# Install hooks (append to arrays to preserve existing hooks)
        \\autoload -Uz add-zsh-hook
        \\add-zsh-hook preexec _rig_preexec
        \\add-zsh-hook precmd _rig_precmd
        \\
        \\# TODO: Ctrl+R keybinding for rig search (when TUI is ready)
        \\# bindkey '^R' _rig_search
        \\
    );
}

/// Output Bash integration script.
/// Uses DEBUG trap for pre-exec and PROMPT_COMMAND for post-exec.
fn outputBashScript(writer: anytype) !void {
    _ = try writer.write(
        \\# rig shell integration for Bash
        \\# Add to ~/.bashrc: eval "$(rig init bash)"
        \\
        \\# Initialize session UUID (persists for shell lifetime)
        \\if [[ -z "${RIG_SESSION}" ]]; then
        \\    export RIG_SESSION="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "unknown-$$-$RANDOM")"
        \\fi
        \\
        \\# State variables
        \\_rig_cmd_id=""
        \\_rig_preexec_done=0
        \\_rig_last_hist_line=""
        \\
        \\# Pre-execution hook via DEBUG trap
        \\_rig_preexec() {
        \\    # Only run once per command
        \\    [[ "$_rig_preexec_done" == "1" ]] && return
        \\
        \\    # Get the current command from history
        \\    # This is more reliable than BASH_COMMAND for complex commands
        \\    local hist_line
        \\    hist_line="$(HISTTIMEFORMAT= history 1)"
        \\
        \\    # Skip if same history line (handles DEBUG trap running multiple times)
        \\    [[ "$hist_line" == "$_rig_last_hist_line" ]] && return
        \\    _rig_last_hist_line="$hist_line"
        \\
        \\    # Extract command (remove history number prefix)
        \\    local cmd="${hist_line#*[0-9]  }"
        \\
        \\    # Skip empty commands
        \\    [[ -z "${cmd// }" ]] && return
        \\
        \\    # Skip rig's own commands and PROMPT_COMMAND to avoid recursion
        \\    [[ "$cmd" == rig\ * ]] && return
        \\    [[ "$BASH_COMMAND" == _rig_* ]] && return
        \\    [[ "$BASH_COMMAND" == "__rig_"* ]] && return
        \\
        \\    _rig_preexec_done=1
        \\
        \\    # Record command start, capture UUID
        \\    _rig_cmd_id="$(rig history start -- "$cmd" 2>/dev/null)"
        \\}
        \\
        \\# Post-execution hook via PROMPT_COMMAND
        \\_rig_precmd() {
        \\    local exit_code=$?
        \\
        \\    # Reset flag for next command
        \\    _rig_preexec_done=0
        \\
        \\    # If we have a command ID, record its completion
        \\    if [[ -n "$_rig_cmd_id" ]]; then
        \\        # Run in background to avoid blocking prompt
        \\        (rig history end --id "$_rig_cmd_id" --exit "$exit_code" 2>/dev/null &)
        \\        _rig_cmd_id=""
        \\    fi
        \\
        \\    # Return original exit code so $? is preserved
        \\    return $exit_code
        \\}
        \\
        \\# Install DEBUG trap for pre-exec (preserve existing traps)
        \\__rig_install_debug_trap() {
        \\    local existing_trap
        \\    existing_trap="$(trap -p DEBUG | sed "s/trap -- '\\(.*\\)' DEBUG/\\1/")"
        \\
        \\    if [[ -n "$existing_trap" && "$existing_trap" != "_rig_preexec" ]]; then
        \\        # Chain with existing trap
        \\        trap "_rig_preexec; $existing_trap" DEBUG
        \\    else
        \\        trap '_rig_preexec' DEBUG
        \\    fi
        \\}
        \\__rig_install_debug_trap
        \\
        \\# Install PROMPT_COMMAND (preserve existing)
        \\if [[ -z "$PROMPT_COMMAND" ]]; then
        \\    PROMPT_COMMAND="_rig_precmd"
        \\elif [[ "$PROMPT_COMMAND" != *"_rig_precmd"* ]]; then
        \\    PROMPT_COMMAND="_rig_precmd; $PROMPT_COMMAND"
        \\fi
        \\
        \\# TODO: Ctrl+R keybinding for rig search (when TUI is ready)
        \\# bind -x '"\C-r": _rig_search'
        \\
    );
}

// =============================================================================
// Tests
// =============================================================================

test "run outputs zsh script" {
    var buffer: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"zsh"};
    try run(&args, writer);

    const output = fbs.getWritten();
    try std.testing.expect(mem.indexOf(u8, output, "preexec") != null);
    try std.testing.expect(mem.indexOf(u8, output, "precmd") != null);
    try std.testing.expect(mem.indexOf(u8, output, "RIG_SESSION") != null);
    try std.testing.expect(mem.indexOf(u8, output, "rig history start") != null);
    try std.testing.expect(mem.indexOf(u8, output, "rig history end") != null);
}

test "run outputs bash script" {
    var buffer: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"bash"};
    try run(&args, writer);

    const output = fbs.getWritten();
    try std.testing.expect(mem.indexOf(u8, output, "DEBUG") != null);
    try std.testing.expect(mem.indexOf(u8, output, "PROMPT_COMMAND") != null);
    try std.testing.expect(mem.indexOf(u8, output, "RIG_SESSION") != null);
    try std.testing.expect(mem.indexOf(u8, output, "rig history start") != null);
    try std.testing.expect(mem.indexOf(u8, output, "rig history end") != null);
}

test "run shows usage for help" {
    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"help"};
    try run(&args, writer);

    const output = fbs.getWritten();
    try std.testing.expect(mem.indexOf(u8, output, "Usage:") != null);
    try std.testing.expect(mem.indexOf(u8, output, "zsh") != null);
    try std.testing.expect(mem.indexOf(u8, output, "bash") != null);
}

test "run returns error for unknown shell" {
    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"fish"};
    const result = run(&args, writer);
    try std.testing.expectError(InitError.UnknownShell, result);
}

test "run shows usage for empty args" {
    var buffer: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{};
    try run(&args, writer);

    const output = fbs.getWritten();
    try std.testing.expect(mem.indexOf(u8, output, "Usage:") != null);
}

test "zsh script has valid syntax markers" {
    var buffer: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"zsh"};
    try run(&args, writer);

    const output = fbs.getWritten();
    // Check for zsh-specific syntax
    try std.testing.expect(mem.indexOf(u8, output, "typeset -g") != null);
    try std.testing.expect(mem.indexOf(u8, output, "add-zsh-hook") != null);
    try std.testing.expect(mem.indexOf(u8, output, "&!") != null); // zsh background disown
}

test "bash script has valid syntax markers" {
    var buffer: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();

    const args = [_][]const u8{"bash"};
    try run(&args, writer);

    const output = fbs.getWritten();
    // Check for bash-specific syntax
    try std.testing.expect(mem.indexOf(u8, output, "trap") != null);
    try std.testing.expect(mem.indexOf(u8, output, "PROMPT_COMMAND") != null);
    try std.testing.expect(mem.indexOf(u8, output, "history 1") != null);
}
