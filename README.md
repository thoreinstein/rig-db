# rigdb

Local shell history with interactive search. Records commands to a SQLite database via a background daemon, with PII sanitization and offline buffering.

## Quick Start

```bash
# Build
zig build

# Add to your shell config (~/.zshrc or ~/.bashrc)
eval "$(rigdb init zsh)"    # or: eval "$(rigdb init bash)"
```

Once installed, rigdb automatically records commands and provides interactive search via **Ctrl+R**.

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.15+
- C compiler (libc required for SQLite and PCRE2, both built from source in `deps/`)

## Commands

```
rigdb init <shell>                  Generate shell integration (zsh, bash)
rigdb history start -- <command>    Record command start (called by shell hook)
rigdb history end --id <uuid> --exit <n>  Record command end (called by shell hook)
rigdb history list [-n N] [-p PAT] [--cwd DIR]  List recent history
rigdb search                        Interactive history search (Ctrl+R)
rigdb daemon                        Run background daemon (auto-managed)
```

## How It Works

Shell hooks capture each command before and after execution. The CLI sends events to a background daemon over a Unix socket. The daemon batches writes to SQLite with PII sanitization (API keys, tokens, passwords are redacted). If the daemon is unavailable, events buffer to a JSONL file and recover on next startup.

The daemon auto-starts on first command and idles out after 5 minutes of inactivity.

## Testing

```bash
zig build test
```

## Data Locations

| Path | Purpose |
|------|---------|
| `$XDG_DATA_HOME/rig/history.db` | SQLite database |
| `$XDG_DATA_HOME/rig/pending.jsonl` | Offline buffer |
| `$XDG_CONFIG_HOME/rig/sanitize.json` | PII sanitization config |
| `$XDG_RUNTIME_DIR/rig.sock` | Daemon socket |
