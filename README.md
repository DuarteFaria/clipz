# Clipz

Clipz is a native macOS clipboard manager. It maintains a persistent history of text, images, and files you've copied, with a snappy gpui interface and minimal resource usage.

## Features

- **Native GUI** — built with Zed's gpui framework for speed and simplicity
- **Persistent history** — clipboard entries saved to `~/.clipz_history.json`
- **Image & file support** — automatically detects what you copy
- **Low overhead** — adaptive polling with balanced/responsive/low-power modes
- **JSON API** — integrate with scripts and other tools
- **CLI mode** — quick access from the terminal

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

## Keyboard Shortcuts

- **Arrow Up/Down** — navigate clipboard history
- **Enter** — select and copy entry to clipboard
- **Delete** — remove entry from history
- **Cmd+K** — clear all history

## Image & File Support

The app detects and stores images and files from the clipboard. Image previews display inline in the history; file paths show as entries. Both are automatically deduplicated to avoid clutter.

## Integration

See `INTEGRATION.md` for JSON API examples, shell integration, and performance tuning.

## License

See `LICENSE` for details.
