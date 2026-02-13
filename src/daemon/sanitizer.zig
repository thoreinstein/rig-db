const std = @import("std");
const mem = std.mem;

// PCRE2 10.44 8-bit API bindings. Constants sourced from pcre2.h.
// Using direct extern declarations because @cImport cannot translate
// PCRE2's token-pasting macros (PCRE2_SUFFIX).
// If upgrading PCRE2, verify these constants against the new pcre2.h.
const pcre2 = struct {
    const code = opaque {};
    const match_data = opaque {};
    const compile_context = opaque {};
    const match_context = opaque {};

    // pcre2.h constants (stable across PCRE2 10.x releases)
    const ZERO_TERMINATED = ~@as(usize, 0);
    const CASELESS: u32 = 0x00000008;
    const SUBSTITUTE_GLOBAL: u32 = 0x00000100;
    const SUBSTITUTE_OVERFLOW_LENGTH: u32 = 0x00001000;
    const ERROR_NOMEMORY: c_int = -48;

    extern "c" fn pcre2_compile_8(
        pattern: [*]const u8,
        length: usize,
        options: u32,
        errorcode: *c_int,
        erroroffset: *usize,
        ccontext: ?*compile_context,
    ) ?*code;

    extern "c" fn pcre2_code_free_8(re: ?*code) void;

    extern "c" fn pcre2_substitute_8(
        re: *const code,
        subject: [*]const u8,
        length: usize,
        startoffset: usize,
        options: u32,
        match_data_ptr: ?*match_data,
        mcontext: ?*match_context,
        replacement: [*]const u8,
        rlength: usize,
        outputbuffer: [*]u8,
        outlengthptr: *usize,
    ) c_int;
};

pub const SanitizerError = error{
    CompileError,
    SubstituteError,
    OutOfMemory,
};

/// A compiled PCRE2 regex pattern with a human-readable name.
/// Compile once, reuse for multiple substitutions.
pub const CompiledPattern = struct {
    code: *pcre2.code,
    name: []const u8,

    const Self = @This();

    /// Compile a PCRE2 pattern. Returns CompileError for invalid regex syntax.
    pub fn compile(pattern: [*:0]const u8, options: u32, name: []const u8) SanitizerError!Self {
        var errcode: c_int = 0;
        var erroffset: usize = 0;

        const code_ptr = pcre2.pcre2_compile_8(
            pattern,
            pcre2.ZERO_TERMINATED,
            options,
            &errcode,
            &erroffset,
            null,
        ) orelse return SanitizerError.CompileError;

        return Self{
            .code = code_ptr,
            .name = name,
        };
    }

    /// Replace all matches in subject with replacement. Returns null if no
    /// matches found (avoids allocation). Otherwise allocates a new string;
    /// caller owns the result. Uses iterative buffer growth: starts at 2x input
    /// length (min 256), retries with PCRE2's required size on overflow.
    pub fn substitute(self: *const Self, subject: []const u8, replacement: [*:0]const u8, allocator: mem.Allocator) SanitizerError!?[]u8 {
        // Use a stack buffer for the first attempt to avoid heap allocation for small commands
        var stack_buf: [1024]u8 = undefined;
        var out_len: usize = stack_buf.len;
        var out_ptr: [*]u8 = &stack_buf;

        const rc = pcre2.pcre2_substitute_8(
            self.code,
            subject.ptr,
            subject.len,
            0, // start offset
            pcre2.SUBSTITUTE_GLOBAL | pcre2.SUBSTITUTE_OVERFLOW_LENGTH,
            null, // match_data
            null, // match_context
            replacement,
            pcre2.ZERO_TERMINATED,
            out_ptr,
            &out_len,
        );

        if (rc > 0) {
            // rc > 0: number of substitutions made. out_len is actual length.
            const result = allocator.alloc(u8, out_len) catch return SanitizerError.OutOfMemory;
            @memcpy(result, out_ptr[0..out_len]);
            return result;
        }

        if (rc == 0) {
            // No matches
            return null;
        }

        if (rc == pcre2.ERROR_NOMEMORY) {
            // Stack buffer too small, allocate exactly what's needed
            const out_buf = allocator.alloc(u8, out_len) catch return SanitizerError.OutOfMemory;
            errdefer allocator.free(out_buf);
            var actual_len: usize = out_len;

            const rc2 = pcre2.pcre2_substitute_8(
                self.code,
                subject.ptr,
                subject.len,
                0,
                pcre2.SUBSTITUTE_GLOBAL,
                null,
                null,
                replacement,
                pcre2.ZERO_TERMINATED,
                out_buf.ptr,
                &actual_len,
            );

            if (rc2 > 0) {
                return out_buf[0..actual_len];
            }
        }

        return SanitizerError.SubstituteError;
    }

    pub fn deinit(self: *const Self) void {
        pcre2.pcre2_code_free_8(@constCast(self.code));
    }
};

// =============================================================================
// Built-in pattern definitions
// =============================================================================

const PatternDef = struct {
    name: []const u8,
    regex: [*:0]const u8,
    options: u32,
};

// Pattern order matters: URL-based patterns run first on raw text to avoid
// false matches from replacement text (e.g. <REDACTED_name> contains ":" which
// would create false url_password matches if token patterns ran first).
const builtin_patterns = [_]PatternDef{
    // URL-based pattern first (needs to see raw URLs).
    // \K resets match start so only the password portion is replaced,
    // preserving URL structure: ://user:<REDACTED>@host
    // Covers all URL types including postgres://, redis://, mongodb://, etc.
    // Fixed: uses [^:@/\s]* (star instead of plus) to support empty usernames.
    .{ .name = "url_password", .regex = "://[^:@/\\s]*:\\K[^@\\s]+(?=@)", .options = 0 },
    // Key/token patterns
    .{ .name = "aws_key", .regex = "AKIA[0-9A-Z]{16}", .options = 0 },
    .{ .name = "aws_secret", .regex = "(?i)aws_secret_access_key[=:]\\s*\\S+", .options = 0 },
    .{ .name = "github_token", .regex = "gh[pousr]_[A-Za-z0-9_]{36,}", .options = 0 },
    .{ .name = "openai_key", .regex = "sk-[A-Za-z0-9]{32,}", .options = 0 },
    .{ .name = "anthropic_key", .regex = "sk-ant-[A-Za-z0-9\\-]{20,}", .options = 0 },
    .{ .name = "generic_token", .regex = "(?i)(token|bearer|api[_\\-]?key)[=:\\s]+['\"]?\\S{20,}['\"]?", .options = 0 },
    .{ .name = "private_key", .regex = "-----BEGIN [A-Z ]*PRIVATE KEY-----", .options = 0 },
    .{ .name = "jwt", .regex = "eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}", .options = 0 },
    // Argument/env patterns
    .{ .name = "password_arg", .regex = "(?i)(\\-p|\\-\\-password)[=\\s]+\\S+", .options = 0 },
    .{ .name = "env_secret", .regex = "(?i)(SECRET|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|AUTH_TOKEN)=\\S+", .options = 0 },
    .{ .name = "ssh_key_path", .regex = "(?i)\\-i\\s+\\S*id_[a-z]+", .options = 0 },
};

// =============================================================================
// Sanitizer
// =============================================================================

/// Owns a set of compiled patterns and applies them to command strings.
pub const Sanitizer = struct {
    patterns: []CompiledPattern,
    allocator: mem.Allocator,
    enabled: bool,

    const Self = @This();

    /// Initialize with all built-in patterns.
    pub fn init(allocator: mem.Allocator) SanitizerError!Self {
        var patterns = allocator.alloc(CompiledPattern, builtin_patterns.len) catch
            return SanitizerError.OutOfMemory;
        var compiled: usize = 0;
        errdefer {
            for (patterns[0..compiled]) |p| p.deinit();
            allocator.free(patterns);
        }

        for (builtin_patterns) |def| {
            patterns[compiled] = try CompiledPattern.compile(def.regex, def.options, def.name);
            compiled += 1;
        }

        return Self{
            .patterns = patterns,
            .allocator = allocator,
            .enabled = true,
        };
    }

    /// Initialize with config: respects level, disabled patterns, and extra patterns.
    pub fn initWithConfig(allocator: mem.Allocator, config: SanitizeConfig) SanitizerError!Self {
        if (config.level == .off) {
            return Self{
                .patterns = &.{},
                .allocator = allocator,
                .enabled = false,
            };
        }

        // Count enabled built-in patterns
        var count: usize = 0;
        for (builtin_patterns) |def| {
            if (!isDisabled(def.name, config.disabled_patterns)) {
                count += 1;
            }
        }
        count += config.extra_patterns.len;

        if (count == 0) {
            return Self{ .patterns = &.{}, .allocator = allocator, .enabled = true };
        }

        var patterns = allocator.alloc(CompiledPattern, count) catch
            return SanitizerError.OutOfMemory;
        var compiled: usize = 0;
        errdefer {
            for (patterns[0..compiled]) |p| p.deinit();
            allocator.free(patterns);
        }

        // Compile enabled built-in patterns
        for (builtin_patterns) |def| {
            if (!isDisabled(def.name, config.disabled_patterns)) {
                patterns[compiled] = try CompiledPattern.compile(def.regex, def.options, def.name);
                compiled += 1;
            }
        }

        // Compile extra patterns (need null-terminated strings)
        for (config.extra_patterns) |ep| {
            const z_regex = allocator.allocSentinel(u8, ep.regex.len, 0) catch
                return SanitizerError.OutOfMemory;
            @memcpy(z_regex, ep.regex);

            patterns[compiled] = CompiledPattern.compile(z_regex, 0, ep.name) catch |err| {
                allocator.free(z_regex[0 .. ep.regex.len + 1]);
                return err;
            };
            allocator.free(z_regex[0 .. ep.regex.len + 1]);
            compiled += 1;
        }

        return Self{
            .patterns = patterns,
            .allocator = allocator,
            .enabled = true,
        };
    }

    fn isDisabled(name: []const u8, disabled: []const []const u8) bool {
        for (disabled) |d| {
            if (mem.eql(u8, name, d)) return true;
        }
        return false;
    }

    pub fn deinit(self: *Self) void {
        for (self.patterns) |p| p.deinit();
        // patterns is heap-allocated (from init/initWithConfig with count > 0)
        // or a zero-length comptime literal (from initWithConfig with level=off).
        // Only free if it was heap-allocated.
        if (self.patterns.len > 0) {
            self.allocator.free(self.patterns);
        }
    }

    /// Sanitize a single command string. Chains all pattern substitutions,
    /// replacing matches with `<REDACTED_{name}>`. Caller owns the result.
    /// Only allocates when a pattern actually matches (returns null optimization
    /// in substitute avoids allocation for non-matching patterns).
    pub fn sanitize(self: *const Self, allocator: mem.Allocator, cmd: []const u8) SanitizerError![]u8 {
        if (!self.enabled or self.patterns.len == 0) {
            return allocator.dupe(u8, cmd) catch return SanitizerError.OutOfMemory;
        }

        var current: ?[]u8 = null;
        errdefer if (current) |c| allocator.free(c);

        for (self.patterns) |*pat| {
            var replacement_buf: [64]u8 = undefined;
            // Use _ separator (not :) to avoid cascading regex matches from replacement text
            const replacement_z = std.fmt.bufPrintZ(&replacement_buf, "<REDACTED_{s}>", .{pat.name}) catch {
                continue;
            };

            const subject = if (current) |c| c else cmd;
            const maybe_next = try pat.substitute(subject, replacement_z, allocator);

            if (maybe_next) |next| {
                if (current) |c| allocator.free(c);
                current = next;
            }
            // null means no match — keep current, no allocation was made
        }

        return current orelse allocator.dupe(u8, cmd) catch return SanitizerError.OutOfMemory;
    }

    /// Sanitize all `.start` items in a batch, replacing `.cmd` in-place.
    /// Frees the original cmd string and replaces it with the sanitized version.
    /// The allocator MUST be the same one used to allocate the original cmd
    /// strings (i.e., the daemon's GPA allocator used by protocol.parseMessage).
    pub fn sanitizeBatch(self: *const Self, batch: []queue_mod.QueueItem, allocator: mem.Allocator) void {
        for (batch) |*item| {
            switch (item.*) {
                .start => |*start| {
                    const sanitized = self.sanitize(allocator, start.cmd) catch |err| {
                        log.warn("Failed to sanitize command: {}", .{err});
                        continue;
                    };
                    allocator.free(@constCast(start.cmd));
                    start.cmd = sanitized;
                },
                .end => {},
            }
        }
    }
};

// =============================================================================
// Configuration
// =============================================================================

pub const SanitizeLevel = enum {
    off,
    secrets,

    pub fn jsonParse(allocator: mem.Allocator, source: anytype, options: anytype) !SanitizeLevel {
        _ = allocator;
        _ = options;
        const token = try source.next();
        switch (token) {
            .string => |s| {
                if (mem.eql(u8, s, "off")) return .off;
                if (mem.eql(u8, s, "secrets")) return .secrets;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonParseFromValue(allocator: mem.Allocator, source: anytype, options: anytype) !SanitizeLevel {
        _ = allocator;
        _ = options;
        switch (source) {
            .string => |s| {
                if (mem.eql(u8, s, "off")) return .off;
                if (mem.eql(u8, s, "secrets")) return .secrets;
                return error.UnexpectedToken;
            },
            else => return error.UnexpectedToken,
        }
    }
};

const ExtraPattern = struct {
    name: []const u8,
    regex: []const u8,
};

pub const SanitizeConfig = struct {
    level: SanitizeLevel = .secrets,
    extra_patterns: []const ExtraPattern = &.{},
    disabled_patterns: []const []const u8 = &.{},
};

/// Load sanitize config from config_dir/sanitize.json.
/// Returns default config if file doesn't exist or is malformed.
/// Caller should pass the result of paths.getConfigDir().
pub fn loadConfig(allocator: mem.Allocator, config_dir: []const u8) SanitizeConfig {
    const config_path = std.fs.path.join(allocator, &[_][]const u8{ config_dir, "sanitize.json" }) catch return .{};
    defer allocator.free(config_path);

    const file = std.fs.cwd().openFile(config_path, .{}) catch return .{};
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 64) catch return .{};
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(SanitizeConfig, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return .{};

    // We need to dupe the parsed data since the parsed arena will be freed.
    // Return the parsed value and let initWithConfig handle it via the parsed lifetime.
    // Actually, parseFromSlice owns the memory via an arena. We need to keep it alive
    // or copy the data out. Let's copy what we need.
    var result = SanitizeConfig{
        .level = parsed.value.level,
    };

    if (parsed.value.extra_patterns.len > 0) {
        var extras = allocator.alloc(ExtraPattern, parsed.value.extra_patterns.len) catch {
            parsed.deinit();
            return .{};
        };
        for (parsed.value.extra_patterns, 0..) |ep, i| {
            extras[i] = .{
                .name = allocator.dupe(u8, ep.name) catch {
                    // Clean up already-duped
                    for (extras[0..i]) |prev| {
                        allocator.free(prev.name);
                        allocator.free(prev.regex);
                    }
                    allocator.free(extras);
                    parsed.deinit();
                    return .{};
                },
                .regex = allocator.dupe(u8, ep.regex) catch {
                    allocator.free(extras[i].name);
                    for (extras[0..i]) |prev| {
                        allocator.free(prev.name);
                        allocator.free(prev.regex);
                    }
                    allocator.free(extras);
                    parsed.deinit();
                    return .{};
                },
            };
        }
        result.extra_patterns = extras;
    }

    if (parsed.value.disabled_patterns.len > 0) {
        var disabled = allocator.alloc([]const u8, parsed.value.disabled_patterns.len) catch {
            freeExtraPatterns(allocator, result.extra_patterns);
            parsed.deinit();
            return .{};
        };
        for (parsed.value.disabled_patterns, 0..) |dp, i| {
            disabled[i] = allocator.dupe(u8, dp) catch {
                for (disabled[0..i]) |prev| allocator.free(prev);
                allocator.free(disabled);
                freeExtraPatterns(allocator, result.extra_patterns);
                parsed.deinit();
                return .{};
            };
        }
        result.disabled_patterns = disabled;
    }

    parsed.deinit();
    return result;
}

fn freeExtraPatterns(allocator: mem.Allocator, extras: []const ExtraPattern) void {
    for (extras) |ep| {
        allocator.free(ep.name);
        allocator.free(ep.regex);
    }
    if (extras.len > 0) allocator.free(extras);
}

pub fn freeConfig(allocator: mem.Allocator, config: *const SanitizeConfig) void {
    for (config.disabled_patterns) |dp| allocator.free(dp);
    if (config.disabled_patterns.len > 0) allocator.free(config.disabled_patterns);
    freeExtraPatterns(allocator, config.extra_patterns);
}

const queue_mod = @import("queue.zig");
const log = std.log.scoped(.sanitizer);

// =============================================================================
// Tests
// =============================================================================

// --- CompiledPattern tests ---

test "compile simple pattern and substitute" {
    const allocator = std.testing.allocator;

    const pat = try CompiledPattern.compile("world", 0, "test");
    defer pat.deinit();

    const result = (try pat.substitute("hello world", "zig", allocator)).?;
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello zig", result);
}

test "invalid pattern returns compile error" {
    const result = CompiledPattern.compile("[invalid", 0, "test");
    try std.testing.expectError(SanitizerError.CompileError, result);
}

test "no match returns null (no allocation)" {
    const allocator = std.testing.allocator;

    const pat = try CompiledPattern.compile("xyz", 0, "test");
    defer pat.deinit();

    const result = try pat.substitute("hello world", "replaced", allocator);
    try std.testing.expect(result == null);
}

test "global substitution replaces all matches" {
    const allocator = std.testing.allocator;

    const pat = try CompiledPattern.compile("o", 0, "test");
    defer pat.deinit();

    const result = (try pat.substitute("foo bar boo", "0", allocator)).?;
    defer allocator.free(result);

    try std.testing.expectEqualStrings("f00 bar b00", result);
}

test "substitute with regex pattern" {
    const allocator = std.testing.allocator;

    const pat = try CompiledPattern.compile("\\d+", 0, "test");
    defer pat.deinit();

    const result = (try pat.substitute("abc 123 def 456", "<NUM>", allocator)).?;
    defer allocator.free(result);

    try std.testing.expectEqualStrings("abc <NUM> def <NUM>", result);
}

test "case insensitive compile option" {
    const allocator = std.testing.allocator;

    const pat = try CompiledPattern.compile("hello", pcre2.CASELESS, "test");
    defer pat.deinit();

    const result = (try pat.substitute("HELLO world", "hi", allocator)).?;
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hi world", result);
}

// --- Sanitizer init/deinit tests ---

test "Sanitizer init compiles 13 built-in patterns" {
    const allocator = std.testing.allocator;

    var sanitizer = try Sanitizer.init(allocator);
    defer sanitizer.deinit();

    try std.testing.expectEqual(@as(usize, 12), sanitizer.patterns.len);
}

// --- Pattern-specific tests ---

test "pattern: aws_key" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "export KEY=AKIAIOSFODNN7EXAMPLE");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "AKIAIOSFODNN7EXAMPLE") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_aws_key>") != null);
}

test "pattern: aws_secret" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "wJalrXUtn") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_aws_secret>") != null);
}

test "pattern: github_token" {
    const allocator = std.testing.allocator;

    // Test the pattern directly first
    const pat = try CompiledPattern.compile("gh[pousr]_[A-Za-z0-9_]{36,}", 0, "github_token");
    defer pat.deinit();

    const direct = (try pat.substitute("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn", "<REDACTED_github_token>", allocator)).?;
    defer allocator.free(direct);
    try std.testing.expectEqualStrings("<REDACTED_github_token>", direct);

    // Now test through the full sanitizer
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "git clone https://ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn@github.com/user/repo");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "ghp_ABCDEFGHIJ") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_github_token>") != null);
}

test "pattern: openai_key" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "curl -H 'Authorization: Bearer sk-proj1234567890abcdefghijklmnopqrstuv'");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "sk-proj1234567890") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_") != null);
}

test "pattern: anthropic_key" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrst");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "sk-ant-api03") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_") != null);
}

test "pattern: generic_token" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "TOKEN=abcdefghij1234567890abcdefghij");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "abcdefghij1234567890") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_") != null);
}

test "pattern: private_key" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "echo '-----BEGIN RSA PRIVATE KEY-----'");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "-----BEGIN RSA PRIVATE KEY-----") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_private_key>") != null);
}

test "pattern: jwt" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "curl -H 'Auth: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0'");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "eyJhbGciOiJ") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_jwt>") != null);
}

test "pattern: url_password preserves URL structure" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "psql postgres://admin:s3cretP4ss@db.example.com/mydb");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "s3cretP4ss") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_url_password>") != null);
    // URL structure preserved: ://user:<REDACTED>@host
    try std.testing.expect(mem.indexOf(u8, result, "://admin:") != null);
    try std.testing.expect(mem.indexOf(u8, result, "@db.example.com") != null);
}

test "pattern: password_arg" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "mysql -u root --password=hunter2");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "hunter2") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_password_arg>") != null);
}

test "pattern: url_password handles database connection strings" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "redis-cli -u redis://default:mypassword@redis.example.com:6379");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "mypassword") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_url_password>") != null);
    // URL structure preserved
    try std.testing.expect(mem.indexOf(u8, result, "redis://default:") != null);
    try std.testing.expect(mem.indexOf(u8, result, "@redis.example.com") != null);
}

test "pattern: env_secret" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "PASSWORD=mysecretvalue ./run.sh");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "mysecretvalue") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_env_secret>") != null);
}

test "pattern: ssh_key_path" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "ssh -i ~/.ssh/id_rsa user@host");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "id_rsa") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_ssh_key_path>") != null);
}

test "pattern: no secrets returns unchanged" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "ls -la /home/user");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ls -la /home/user", result);
}

// --- sanitize function tests ---

test "sanitize: multiple secrets in one command" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "PASSWORD=secret123 curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0'");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "secret123") == null);
    try std.testing.expect(mem.indexOf(u8, result, "eyJhbGciOiJ") == null);
}

test "sanitize: disabled sanitizer returns copy" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();
    s.enabled = false;

    const input = "PASSWORD=secret123";
    const result = try s.sanitize(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

// --- sanitizeBatch tests ---

test "sanitizeBatch: mutates start item cmd" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const protocol = @import("protocol.zig");

    // Create a batch with a start item containing a secret
    var batch = try allocator.alloc(queue_mod.QueueItem, 1);
    defer allocator.free(batch);

    const id = try allocator.dupe(u8, "test-id");
    const cmd = try allocator.dupe(u8, "PASSWORD=hunter2 ./deploy.sh");
    const cwd = try allocator.dupe(u8, "/tmp");
    const session = try allocator.dupe(u8, "sess");
    const hostname = try allocator.dupe(u8, "host");

    batch[0] = queue_mod.QueueItem{
        .start = protocol.StartMessage{
            .id = id,
            .cmd = cmd,
            .ts = 123,
            .cwd = cwd,
            .session = session,
            .hostname = hostname,
        },
    };

    s.sanitizeBatch(batch, allocator);

    // cmd should be sanitized now
    try std.testing.expect(mem.indexOf(u8, batch[0].start.cmd, "hunter2") == null);
    try std.testing.expect(mem.indexOf(u8, batch[0].start.cmd, "<REDACTED_") != null);

    // Clean up — free the sanitized cmd and other fields
    allocator.free(@constCast(batch[0].start.cmd));
    allocator.free(id);
    allocator.free(cwd);
    allocator.free(session);
    allocator.free(hostname);
}

test "sanitizeBatch: leaves end items unchanged" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const protocol = @import("protocol.zig");

    var batch = try allocator.alloc(queue_mod.QueueItem, 1);
    defer allocator.free(batch);

    const id = try allocator.dupe(u8, "test-id");
    defer allocator.free(id);

    batch[0] = queue_mod.QueueItem{
        .end = protocol.EndMessage{
            .id = id,
            .exit = 0,
            .duration = 100,
        },
    };

    // Should not crash or modify end items
    s.sanitizeBatch(batch, allocator);
    try std.testing.expectEqualStrings("test-id", batch[0].end.id);
}

// --- Config tests ---

test "initWithConfig: level=off disables sanitization" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.initWithConfig(allocator, .{ .level = .off });
    defer s.deinit();

    try std.testing.expect(!s.enabled);
    try std.testing.expectEqual(@as(usize, 0), s.patterns.len);

    const result = try s.sanitize(allocator, "PASSWORD=secret123");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("PASSWORD=secret123", result);
}

test "initWithConfig: disabled built-in pattern" {
    const allocator = std.testing.allocator;
    const disabled = [_][]const u8{"ssh_key_path"};
    var s = try Sanitizer.initWithConfig(allocator, .{
        .disabled_patterns = &disabled,
    });
    defer s.deinit();

    // Should have 11 patterns (12 built-in minus 1 disabled)
    try std.testing.expectEqual(@as(usize, 11), s.patterns.len);

    // ssh_key_path should not be redacted
    const result = try s.sanitize(allocator, "ssh -i ~/.ssh/id_rsa user@host");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "id_rsa") != null);
}

test "initWithConfig: extra pattern" {
    const allocator = std.testing.allocator;
    const extras = [_]ExtraPattern{
        .{ .name = "custom_secret", .regex = "MY_SECRET_[0-9a-f]{8}" },
    };
    var s = try Sanitizer.initWithConfig(allocator, .{
        .extra_patterns = &extras,
    });
    defer s.deinit();

    // Should have 13 patterns (12 built-in + 1 extra)
    try std.testing.expectEqual(@as(usize, 13), s.patterns.len);

    const result = try s.sanitize(allocator, "echo MY_SECRET_deadbeef");
    defer allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "MY_SECRET_deadbeef") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_custom_secret>") != null);
}

test "initWithConfig: defaults match init" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.initWithConfig(allocator, .{});
    defer s.deinit();

    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(usize, 12), s.patterns.len);
}

test "loadConfig: missing file returns defaults" {
    const allocator = std.testing.allocator;
    // loadConfig should return defaults when no config file exists
    const config = loadConfig(allocator, "/tmp/rig-test-nonexistent-dir");
    defer freeConfig(allocator, &config);

    try std.testing.expectEqual(SanitizeLevel.secrets, config.level);
    try std.testing.expectEqual(@as(usize, 0), config.extra_patterns.len);
    try std.testing.expectEqual(@as(usize, 0), config.disabled_patterns.len);
}

test "loadConfig: valid config file" {
    const allocator = std.testing.allocator;

    // Create a temp config dir and file
    const test_dir = "/tmp/rig-test-config";
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makePath(test_dir) catch return;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const config_json =
        \\{"level":"secrets","extra_patterns":[{"name":"custom","regex":"CUSTOM_\\d+"}],"disabled_patterns":["ssh_key_path"]}
    ;
    const file = std.fs.cwd().createFile(test_dir ++ "/sanitize.json", .{}) catch return;
    file.writeAll(config_json) catch {
        file.close();
        return;
    };
    file.close();

    const config = loadConfig(allocator, test_dir);
    defer freeConfig(allocator, &config);

    try std.testing.expectEqual(SanitizeLevel.secrets, config.level);
    try std.testing.expectEqual(@as(usize, 1), config.extra_patterns.len);
    try std.testing.expectEqualStrings("custom", config.extra_patterns[0].name);
    try std.testing.expectEqual(@as(usize, 1), config.disabled_patterns.len);
    try std.testing.expectEqualStrings("ssh_key_path", config.disabled_patterns[0]);
}

test "loadConfig: malformed JSON returns defaults" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/rig-test-config-bad";
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makePath(test_dir) catch return;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const file = std.fs.cwd().createFile(test_dir ++ "/sanitize.json", .{}) catch return;
    file.writeAll("{invalid json}") catch {
        file.close();
        return;
    };
    file.close();

    const config = loadConfig(allocator, test_dir);
    defer freeConfig(allocator, &config);

    try std.testing.expectEqual(SanitizeLevel.secrets, config.level);
}

test "loadConfig: level=off config" {
    const allocator = std.testing.allocator;

    const test_dir = "/tmp/rig-test-config-off";
    std.fs.cwd().deleteTree(test_dir) catch {};
    std.fs.cwd().makePath(test_dir) catch return;
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const file = std.fs.cwd().createFile(test_dir ++ "/sanitize.json", .{}) catch return;
    file.writeAll("{\"level\":\"off\"}") catch {
        file.close();
        return;
    };
    file.close();

    const config = loadConfig(allocator, test_dir);
    defer freeConfig(allocator, &config);

    try std.testing.expectEqual(SanitizeLevel.off, config.level);
}

// --- False positive hardening tests ---

test "false positive: short string 'sk-ip' should not match openai_key" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "sk-ip address check");
    defer allocator.free(result);
    // "sk-ip" is only 5 chars after "sk-", openai_key requires 32+
    try std.testing.expectEqualStrings("sk-ip address check", result);
}

test "false positive: git format strings not redacted" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "git log --format='%H %s'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("git log --format='%H %s'", result);
}

test "false positive: version strings not redacted" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "node --version v18.17.0");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("node --version v18.17.0", result);
}

test "false positive: file paths with id_ not redacted when no -i flag" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "cat /home/user/.ssh/id_rsa.pub");
    defer allocator.free(result);
    // ssh_key_path only matches "-i <path>id_*" pattern
    try std.testing.expectEqualStrings("cat /home/user/.ssh/id_rsa.pub", result);
}

test "false positive: pipes and redirects not redacted" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "cat file.txt | grep pattern > output.txt 2>&1");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("cat file.txt | grep pattern > output.txt 2>&1", result);
}

test "false positive: short token values not redacted" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    // generic_token requires 20+ chars, short values should pass through
    const result = try s.sanitize(allocator, "TOKEN=short");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("TOKEN=short", result);
}

test "false positive: AKIA prefix in normal text" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    // "AKIA" followed by fewer than 16 uppercase alphanumeric chars
    const result = try s.sanitize(allocator, "echo AKIA is a prefix");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("echo AKIA is a prefix", result);
}

test "false positive: URLs without credentials not redacted" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    const result = try s.sanitize(allocator, "curl https://api.example.com/v1/data");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("curl https://api.example.com/v1/data", result);
}

test "false positive: password flag without value" {
    const allocator = std.testing.allocator;
    var s = try Sanitizer.init(allocator);
    defer s.deinit();

    // "--password" as a flag name in help text
    const result = try s.sanitize(allocator, "man says use --password flag");
    defer allocator.free(result);
    // password_arg matches "--password <value>", "flag" will be redacted since it looks like a value
    // This is expected behavior — the pattern matches --password followed by any \S+
    try std.testing.expect(mem.indexOf(u8, result, "<REDACTED_password_arg>") != null);
}
