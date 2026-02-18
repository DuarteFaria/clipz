# Clipz

Clipz is a lightweight clipboard manager with a Zig backend and a native gpui (Rust) frontend. It keeps a small, persistent clipboard history with fast search and macOS-friendly performance.

## Features

- Zig backend with adaptive polling and persistence
- gpui frontend (macOS) with Zed-inspired layout, search, filtering, select/remove/clear actions
- Image and file clipboard detection with basic previews
- JSON API for integrations
- CLI mode for quick control
- Configurable performance modes (balanced, low-power, responsive)

## Quick Start

### gpui frontend (macOS)
```bash
cargo run -p clipz-gpui
```
The frontend will launch the Zig backend in JSON API mode automatically.

### CLI
```bash
zig build
./zig-out/bin/clipz           # balanced (default)
./zig-out/bin/clipz --low-power
./zig-out/bin/clipz --responsive
```

### JSON API (for integrations)
```bash
./zig-out/bin/clipz --json-api
```

## Project Structure
```
clipz/
├── src/            # Zig backend
├── gpui-app/       # gpui frontend (Rust)
├── build.zig
└── README.md
```

## Keyboard

- Command palette/search: cmd+f (planned binding in gpui)
- Entry selection: number bindings forwarded to the backend (handled in gpui)

## Image Support

Images are stored as paths where possible; previews work best for files saved on disk (screenshots, Finder copies).

## Integration

See `INTEGRATION.md` for JSON API examples, shell integration, and performance tuning.

## License

See `LICENSE` for details.
