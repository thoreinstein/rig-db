# CLAUDE.md — rig-db

## Build / Test / Run

```bash
zig build              # Build the rig-db executable
zig build test         # Run all tests (inline unit tests via refAllDecls)
zig build run          # Build and run
zig build run -- <args>  # Run with arguments (e.g., zig build run -- history start -- ls)
```

The build compiles SQLite and PCRE2 from C source in `deps/`. Both are statically linked. libc is required.

## What This Project Is

A local shell history system. A lightweight CLI records commands to a background daemon, which writes them to a SQLite database. If the daemon is unavailable, commands buffer to a JSONL fallback file and recover on next daemon startup.

## Architecture

```
Shell Hook (preexec/precmd)
  → CLI: rig history start -- "command"
    → Generate UUID v7, capture context (cwd, hostname, session)
    → Try daemon connection (Unix socket, length-prefixed JSON)
      ├─ Success: enqueue to WriteQueue → Writer thread → SQLite
      └─ Fail: append to ~/.local/share/rig/pending.jsonl
    → Print UUID to stdout
  → (command runs)
  → CLI: rig history end --id <uuid> --exit <code>
    → Same daemon-or-fallback path
```

### Module Layout

```
src/
├── main.zig                 # Entry point, CLI arg parsing, refAllDecls for tests
├── paths.zig                # XDG path resolution (data, config, runtime dirs)
├── db/
│   ├── sqlite.zig           # SQLite wrapper (Database struct, open/exec/pragma)
│   ├── schema.zig           # Schema v1 init + migration system
│   └── history.zig          # insertStart, updateEnd, query operations
├── daemon/
│   ├── daemon.zig           # Orchestrator: startup, signal handling, idle timeout, shutdown
│   ├── server.zig           # Non-blocking Unix socket server (backlog 16)
│   ├── protocol.zig         # Length-prefixed JSON framing (4-byte LE u32 + payload)
│   ├── queue.zig            # Thread-safe bounded ring buffer (mutex, FIFO)
│   ├── writer.zig           # DB writer thread: batch transactions, SQLITE_BUSY retry
│   ├── sanitizer.zig        # PCRE2-based PII redaction (12 built-in patterns)
│   └── lifecycle.zig        # PID file, socket path, daemon spawn (double-fork)
├── cli/
│   ├── uuid.zig             # UUID v7 (RFC 9562) with monotonic counter
│   ├── client.zig           # Socket client with retry + auto-spawn daemon
│   ├── fallback.zig         # JSONL offline buffer (append-only, atomic)
│   └── commands/
│       ├── start.zig        # rig history start -- <cmd>
│       ├── end.zig          # rig history end --id <uuid> --exit <n>
│       ├── list.zig         # rig history list (query/filter history)
│       └── init.zig         # rig init <shell> (zsh/bash hook scripts)
└── tui/                     # Interactive search UI
    ├── app.zig              # TUI application loop and state machine
    ├── terminal.zig
    ├── reader.zig
    ├── search.zig
    └── display.zig
```

## Key Patterns

### IPC Protocol (`daemon/protocol.zig`)
- **Framing**: 4-byte little-endian length prefix + JSON body
- **Messages**: `StartMessage` (id, cmd, ts, cwd, session, hostname) and `EndMessage` (id, exit, duration)
- **Response**: `{ok: bool, error?: string}`
- **Max message size**: 1MB
- **Socket path**: `$XDG_RUNTIME_DIR/rig.sock` or `/tmp/rig-{uid}.sock`

### Write Queue (`daemon/queue.zig`)
- Bounded ring buffer with mutex, capacity 10,000
- `enqueue()` / `dequeue()` / `dequeueBatch()` — returns `QueueError.QueueFull` when at capacity
- Writer thread processes batches in transactions (`BEGIN IMMEDIATE` / `COMMIT` / `ROLLBACK`)

### Fallback (`cli/fallback.zig`)
- When daemon is unreachable, commands append to `~/.local/share/rig/pending.jsonl`
- O_APPEND + fsync for durability
- On daemon startup, `writer.processFallback()` reads, processes, and deletes the file

### PII Sanitization (`daemon/sanitizer.zig`)
- 12 built-in PCRE2 patterns: url_password, aws_key, aws_secret, github_token, openai_key, anthropic_key, generic_token, private_key, jwt, password_arg, env_secret, ssh_key_path
- Replacement format: `<REDACTED_{pattern_name}>`
- Applied in writer thread before database insert, in-place mutation of command strings
- Config: `~/.config/rig/sanitize.json` — levels: `off`, `secrets`; supports `extra_patterns` and `disabled_patterns`

### UUID v7 (`cli/uuid.zig`)
- RFC 9562: 48-bit ms timestamp + 12-bit monotonic counter + 62-bit random
- Thread-local state prevents collisions within same millisecond
- Used as primary key for all history records; naturally time-ordered

## C Dependencies (`deps/`)

**SQLite** (`deps/sqlite/`): Single-file amalgamation. Build flags: `SQLITE_THREADSAFE=0`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0`. DB pragmas: WAL journal, synchronous=NORMAL, foreign_keys=ON, busy_timeout=5000.

**PCRE2** (`deps/pcre2/src/`): 26 source files, 8-bit UTF-8 mode. Build flags: `PCRE2_CODE_UNIT_WIDTH=8`, `PCRE2_STATIC`, `SUPPORT_UNICODE`. Note: `pcre2_ucptables.c` is `#include`d by `pcre2_tables.c`, not compiled separately.

## Testing

All tests are inline (`test "description" { ... }`) within each module. `main.zig` uses `std.testing.refAllDecls(@This())` to pull tests from all imported modules. Additional test steps in `build.zig` compile tests for `paths.zig`, `daemon/server.zig`, `daemon/protocol.zig`, `daemon/queue.zig`, and `daemon/sanitizer.zig`.

All tests use `std.testing.allocator` for leak detection.

## Conventions

- **XDG compliance**: Data in `$XDG_DATA_HOME/rig`, config in `$XDG_CONFIG_HOME/rig`, runtime files in `$XDG_RUNTIME_DIR` (fallback `/tmp/rig-{uid}.*`)
- **Error handling**: Each module defines its own error enum. Errors propagate with `!` and `try`. Resources cleaned up with `defer`/`errdefer`
- **Memory**: GeneralPurposeAllocator in production, `std.testing.allocator` in tests. Allocator passed as first parameter. Caller owns returned memory
- **C interop**: Sentinel-terminated strings `[:0]const u8` for C API boundaries. `@cImport` for SQLite and PCRE2 headers
- **Daemon lifecycle**: Double-fork daemonization, PID file, signal handlers (SIGTERM/SIGINT) with `std.atomic.Value(bool)` for shutdown flag, 5-minute idle timeout

## Zig + SQLite Gotchas

- **SQLITE_STATIC buffer lifetime**: Stack buffers bound with `SQLITE_STATIC` must outlive `sqlite3_step()`. Declare at function scope, not inside conditional blocks.
- **LIKE pattern for subdirectory matching**: Use `(cwd = ? OR cwd LIKE ? ESCAPE '\')` with escaped `%`, `_`, `\` chars. Strip trailing slashes before appending `/%`.
- **Bounds-check stack buffers for C APIs**: When building strings char-by-char with escape expansion, guard capacity before every write (escaped chars can double buffer usage).

## TUI Notes

- **Cursor column math**: For formatted labels like `[mode] > query`, visible chars = `label.len + 3` (bracket + label + bracket + space), not `+ 4`.
- Filter mode cycling: global → directory → session, triggered by Ctrl+R (0x12).

## Shell Hook Integration

- `RIG_SESSION` prefers tmux session name (`tmux display-message -p '#S'`), falls back to UUID.
- Shell scripts are generated by `src/cli/commands/init.zig` — both zsh and bash variants.
