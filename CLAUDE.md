# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Clipz is a macOS clipboard manager with two components:
- **Zig backend** (`src/`) — monitors the clipboard, persists history, and exposes a JSON API over stdin/stdout
- **Rust gpui frontend** (`gpui-app/`) — native GUI using Zed's gpui framework, spawns the Zig backend as a subprocess

## Commands

### Zig backend
```bash
zig build                        # Build backend binary to zig-out/bin/clipz
zig build run                    # Build and run in CLI mode
zig build run -- --json-api      # Run in JSON API mode
zig build run -- --low-power     # Run with low-power polling config
zig build run -- --responsive    # Run with faster polling config
zig build test                   # Run unit tests
```

Dependencies: SDL2 and SDL2_ttf from Homebrew (hardcoded to `/opt/homebrew/include`).

### Rust gpui frontend
```bash
cargo run -p clipz-gpui          # Run the gpui frontend (auto-starts the Zig backend)
cargo build -p clipz-gpui        # Build only
cargo test -p clipz-gpui         # Run tests
```

The gpui frontend expects the backend binary at `zig-out/bin/clipz` (dev) or `Resources/bin/clipz` (packaged). Always build the Zig backend first before running the Rust frontend.

## Architecture

### Communication Protocol (JSON API)
The gpui frontend spawns `clipz --json-api --low-power` and communicates over stdin/stdout with newline-delimited JSON:

**Commands (frontend → backend, plain text):**
- `get-entries` — request current clipboard history
- `select-entry:<index>` — copy entry at index back to clipboard and promote it to current
- `remove-entry:<index>` — delete entry at index
- `clear` — remove all entries except the current clipboard
- `quit` — shut down the backend

**Messages (backend → frontend, JSON):**
- `{"type":"ready"}` — backend started
- `{"type":"entries","data":[...]}` — full entry list (sent on change and after commands)
- `{"type":"select-success","index":N}`
- `{"type":"remove-success","index":N}`
- `{"type":"success","message":"..."}` / `{"type":"error","message":"..."}`

Entry IDs are transient: id=1 is always the current clipboard item and cannot be removed.

### Zig Backend Modules
- `main.zig` — arg parsing, CLI mode entry, JSON API event loop
- `manager.zig` (`ClipboardManager`) — the core: in-memory entry list, dedup, batched persistence, background monitor thread
- `clipboard.zig` — macOS clipboard access via `osascript`; handles text, image, and file types
- `config.zig` — polling intervals and limits for three profiles (default/balanced, lowPower, responsive)
- `persistence.zig` — JSON v2 format, saves to `~/.clipz_history.json`
- `image_storage.zig` — saves raw clipboard image data to temp files, compares files to avoid duplicates
- `ui.zig` — terminal display for CLI mode
- `command.zig` — CLI command parsing

### Clipboard Type Handling
Content type detection uses osascript in sequence: image check → file URL check → text fallback. Images are stored as file paths when available; otherwise saved to a temp file via `image_storage`. The `entry_type` field (`text`/`image`/`file`) flows from `ClipboardType` (clipboard.zig) through `ClipboardEntry` (manager.zig) into the JSON API and persistence layer.

### Rust Frontend (`gpui-app/src/main.rs`)
- `BackendHandle` — owns the child process, pumps commands and messages on separate threads via `mpsc` channels
- `ClipzApp` — gpui `Render` impl; calls `poll_backend()` on every render frame to drain the message channel; applies optimistic UI updates before backend confirms
- `FileSystemAssets` — passes absolute image paths directly to gpui's `img()` for preview thumbnails
- Keyboard navigation: arrow keys change `focused_index`, Enter selects the focused entry

### Data Flow
1. `ClipboardManager::monitorThread` polls osascript, calls `addEntry` on change
2. `addEntry` deduplicates, enforces `max_entries` (default 10), schedules batched save, fires `entries_changed_callback`
3. `entries_changed_callback` in JSON API mode serialises and writes entries to stdout
4. gpui frontend receives the JSON, updates `ClipzApp::entries`, calls `cx.notify()` to re-render

### Persistence
History is saved to `~/.clipz_history.json` (v2 JSON format with `version`, `entries[]`, `content`, `timestamp`, `type`). Saves are batched: dirty flag + minimum interval (`batch_save_interval` seconds). Force-save on shutdown.
