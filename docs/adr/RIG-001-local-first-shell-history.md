# RIG-001: Local-First Shell History Architecture

## Status
Proposed

## Context
The user desires a shell history tool similar to `atuin` but strictly local, removing all server, synchronization, and account management features. The goal is to capture, store, and retrieve shell history efficiently and reliably across sessions with a "local-first" philosophy.

The current `atuin` architecture is a split model:
1.  **CLI:** Captures hooks (pre/post-exec) and provides the UI.
2.  **Daemon:** (Optional but recommended) Handles writes to the database to avoid blocking the shell.
3.  **Server:** (Excluded for Rig) Handles sync.

We need to define the architecture for `rig-db` that preserves the performance and reliability of `atuin` while stripping the sync complexity and optimizing for local resource usage.

## Decision
We will build `rig-db` using **Zig**.

### Language Rationale: Zig
*   **Startup Speed:** Zig binaries have near-zero startup time, which is critical for a tool that executes on *every single shell prompt*. Saving 10-20ms per command adds up.
*   **Binary Size:** Zig produces extremely small, static binaries. This fits the philosophy of a lightweight, "do one thing well" Unix tool.
*   **Cross-Compilation:** `zig build` offers effortless cross-compilation (e.g., building for Linux/ARM from macOS/x86), ensuring the tool is easily portable.
*   **C Interoperability:** Zig can import SQLite's C headers directly (`@cImport`). This removes the need for complex FFI wrappers and provides raw performance access to the database engine.
*   **Control:** Zig gives manual control over memory allocation, allowing us to optimize the daemon's footprint to be negligible.

### Architecture

#### 1. Components
*   **`rig` (CLI):** The main entry point.
    *   **Hooks:** Generates shell scripts (`rig init zsh`, etc.) and handles `start`/`end` events.
    *   **TUI:** Provides the search interface. Uses `zig-clap` for argument parsing.
    *   **Read Path:** connects directly to SQLite (ReadOnly mode) for instant search results, bypassing the daemon IPC for queries to reduce latency.
*   **`rig-daemon`:** A lightweight background process.
    *   **Write Path:** Owns the exclusive **write** lock to the SQLite database.
    *   **IPC:** Listens on a Unix Domain Socket (macOS/Linux) or Named Pipe (Windows).
    *   **Queue:** Buffers write requests in memory to ensure the CLI (and thus the shell) never blocks on disk I/O.
    *   **Lifecycle:** Launched on demand by the CLI if not running (socket activation pattern).

#### 2. Data Storage
*   **Engine:** SQLite (WAL mode).
*   **Location:** Follows XDG Base Directory spec (e.g., `~/.local/share/rig/history.db`).
*   **Schema:**
    ```sql
    CREATE TABLE history (
        id TEXT PRIMARY KEY,        -- UUID v7 (time-ordered)
        timestamp INTEGER NOT NULL, -- Nanoseconds since epoch
        duration INTEGER NOT NULL,  -- Nanoseconds
        exit INTEGER NOT NULL,      -- Exit code
        command TEXT NOT NULL,      -- The command string
        cwd TEXT NOT NULL,          -- Working directory
        session TEXT NOT NULL,      -- Session UUID
        hostname TEXT NOT NULL,     -- Hostname
        deleted_at INTEGER          -- Soft delete timestamp
    );
    ```

#### 3. Inter-Process Communication (IPC)
*   **Transport:** Unix Domain Sockets (`AF_UNIX`).
*   **Protocol:** **TigerBeetle/Zap-style binary protocol** or simple **Length-Prefixed JSON**.
    *   *Decision:* We will use **Length-Prefixed JSON** initially.
    *   *Rationale:* Zig's standard library `std.json` is fast enough for this volume. Debugging binary protocols during development is painful. JSON allows us to `cat` the socket to see what's happening.
    *   *Structure:* `<u32 length><json payload>`

### Workflow
1.  **Shell Hook (Start):**
    *   User types `ls -la`.
    *   Shell pre-exec hook runs `rig history start -- "ls -la"`.
    *   `rig` generates a UUID v7 locally.
    *   `rig` connects to the daemon socket and sends `{ "type": "start", "id": "...", "cmd": "ls -la", "ts": ... }`.
    *   If daemon is unreachable, `rig` spawns it and retries, or falls back to a temporary write-ahead log file.
    *   `rig` prints the UUID.
2.  **Command Execution:**
    *   `ls -la` runs.
3.  **Shell Hook (End):**
    *   Shell post-exec hook runs `rig history end --id <UUID> --exit <CODE>`.
    *   `rig` sends `{ "type": "end", "id": "...", "exit": 0, "duration": 15000000 }` to daemon.
    *   Daemon updates the record in memory and commits to SQLite.

## Consequences
*   **Pros:**
    *   **Performance:** Unbeatable startup time and minimal resource usage.
    *   **Portability:** Single binary, no dependencies.
    *   **Simplicity:** Codebase will be explicit and "boring" (no hidden allocations or complex async runtimes).
*   **Cons:**
    *   **Ecosystem:** We lose `sqlx`'s compile-time SQL verification. We must write tests to verify schema matching.
    *   **Manual Memory Management:** Higher cognitive load to ensure no leaks in the daemon (though Zig's `GeneralPurposeAllocator` helps detect them).
    *   **Async:** Zig's async story is currently in flux; we may need to use threads or a library like `libxev` for the daemon's event loop.

## Implementation Plan
1.  **Scaffold:** `zig init`
2.  **SQLite:** Set up `build.zig` to link `sqlite3`.
3.  **Daemon:** Implement a basic UDS server using `std.net`.
4.  **CLI:** Implement `start`/`end` commands sending JSON to the socket.
5.  **Hooks:** Port the Zsh/Bash scripts from `atuin`.
6.  **TUI:** Implement the search UI (consider `vaxis` or raw termios handling).