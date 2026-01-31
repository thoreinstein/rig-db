# rig-db

A database CLI tool written in Zig.

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.11.0 or later)

## Building

To build the project:

```bash
zig build
```

The executable will be placed in `zig-out/bin/rig-db`.

## Running

To run the application directly:

```bash
zig build run
```

Or run the built executable:

```bash
./zig-out/bin/rig-db
```

### Available Commands

- `rig-db help` - Show help message
- `rig-db version` - Show version information

### Examples

```bash
# Show help
zig build run -- help

# Show version
zig build run -- version
```

## Testing

Run the test suite:

```bash
zig build test
```

## Development

The project structure:

```
rig-db/
├── build.zig        # Build configuration
├── src/
│   └── main.zig     # Main entry point
└── README.md        # This file
```