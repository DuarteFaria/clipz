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
zig build test --summary all     # Run module tests through src/tests.zig
python3 scripts/test-json-api.py # Protocol tests; build the backend first
```

Dependencies: Zig 0.15.2, macOS AppKit, and Xcode Command Line Tools. No SDL dependency.

### Rust gpui frontend
```bash
cargo run -p clipz-gpui          # Run the gpui frontend (auto-starts the Zig backend)
cargo build -p clipz-gpui        # Build only
cargo test --locked -p clipz-gpui # Run tests
```

The gpui frontend expects the backend binary at `zig-out/bin/clipz` (dev) or `Resources/bin/clipz` (packaged). Always build the Zig backend first before running the Rust frontend.

## Architecture

### Communication Protocol (JSON API)
The gpui frontend spawns `clipz --json-api --low-power` and communicates over stdin/stdout with newline-delimited JSON:

**Commands (frontend → backend, plain text):**
- `get-entries` — request current clipboard history
- `select-entry-id:<id>` — restore the entry to the clipboard and promote it
- `remove-entry-id:<id>` — delete an entry
- `toggle-pin-id:<id>` — toggle pinning
- `select-entry:<index>`, `remove-entry:<index>`, `toggle-pin:<index>` — legacy 1-based display-position commands
- `clear` — remove history except the actual current entry and pinned entries
- `quit` — stop monitoring, flush pending history, and exit

**Messages (backend → frontend, JSON):**
- `{"type":"ready","supportsIdCommands":true}` — first frame, before monitoring starts
- `{"type":"entries","data":[...]}` — full entry list (sent on change and after commands)
- `{"type":"select-success","id":N}` / `{"type":"remove-success","id":N}`
- `{"type":"pin-toggled","id":N,"pinned":true}`
- Legacy command responses use `index` instead of `id`.
- `{"type":"success","message":"..."}` / `{"type":"error","message":"..."}`
- Capture, restore, persistence, and recovery errors also include `source`.
- `{"type":"error-resolved","source":"capture"}` — a failed capture recovered;
  clear only the corresponding capture warning. `select-success` resolves a
  restore warning, not unrelated persistence/recovery errors.

IDs are stable across promotion, pinning, and reload. `isCurrent` is explicit and
is not inferred from the ID or display position. It is unknown until startup
capture and can be absent when the clipboard is empty or unreadable. The UI hides
removal for the current entry; the backend can remove any entry by ID.

Error frames also report capture, persistence, and recovery problems, so they are
not necessarily replies to the last command. Writes are serialized with the
stdout mutex. Diagnostics belong on stderr, never on the protocol stream.

### Zig Backend Modules
- `main.zig` — arg parsing, CLI mode entry, JSON API event loop
- `manager.zig` (`ClipboardManager`) — history identity/recency, pins, capture retries, batched persistence, deferred image deletion, background monitor
- `clipboard.zig` — typed macOS capture/restore; AppleScript for text/images and native file restoration, with no fake labels or successful text fallbacks
- `pasteboard.zig` — native NSPasteboard change count and file URL restoration
- `config.zig` — polling intervals and limits for three profiles (default/balanced, lowPower, responsive)
- `persistence.zig` — JSON v4 history, atomic saves, legacy loading/migration, corrupt-history quarantine
- `image_storage.zig` — private durable images, complete byte comparison, safely scoped deletion
- `ui.zig` — terminal display for CLI mode
- `command.zig` — CLI command parsing

### Clipboard Type Handling
Capture inspects advertised clipboard representations: file URL or AppleScript
alias (including legacy Clipz-restored files), PNG/JPEG/TIFF,
then text (classified further as URL/color). Images are copied to durable storage.
The stored type is authoritative during restoration. Failed asset reads and
oversized content are errors, not placeholder entries.
File restoration writes an `NSURL` with `NSPasteboard.writeObjects`, advertising
`public.file-url` for Finder-compatible paste; never write a filename or alias
as a substitute for a file URL.

### Rust Frontend (`gpui-app/src/main.rs`)
- `BackendHandle` — owns the child process, pumps commands and messages on separate threads via `mpsc` channels
- `BackendClient` — shared replaceable connection and visible error/restart/quit state
- `AppState` — polls messages/events every 100 ms; restarts and quits on a worker thread with a bounded graceful shutdown
- `MenuBarPopover` — history rendering, controls, and persistent error banner
- `FileSystemAssets` — passes absolute image paths directly to gpui's `img()` for preview thumbnails
- Keyboard navigation: arrow keys change `focused_index`, Enter selects the focused entry

### Data Flow
1. `ClipboardManager::monitorThread` captures on startup, then reads only changed pasteboard revisions; failed reads retry without acknowledgment
2. `addEntry` promotes duplicates, enforces `max_entries` for unpinned history (default 10), schedules a save, and notifies
3. `entries_changed_callback` in JSON API mode serialises and writes entries to stdout
4. The frontend updates shared entries and calls `cx.notify()` to re-render;
   capture/restore errors clear when that operation recovers. Other errors remain
   visible until dismissed or restarted.

### Persistence
History uses `~/.clipz_history.json` v4 (`version`, `next_id`, `entries[]` with
`id`, `content`, `timestamp` in seconds, `type`, `pinned`). The API reports
timestamps in milliseconds. Versions 1–3 are accepted; future versions are
preserved rather than overwritten. Malformed history is renamed to a `.corrupt-*`
backup before starting an empty history.

Images live in `~/Library/Application Support/Clipz/images`. Legacy `/tmp` images
are copied on load, with source files retained for recovery. Missing assets stay
in history. Image deletion follows a successful history save; failed saves keep
the dirty flag and pending deletions. Shutdown flushes changes before exiting.

Tests must not use the real clipboard or HOME history. Use `ClipboardAccess`,
`initWithPersistencePath`, and `ImageStore.root` with temporary directories. The
JSON API integration harness substitutes `osascript`. Native pasteboard I/O and
event-driven frontend dispatch are mostly deferred to milestone 3. File URL
restoration is already native for correctness, with tests on unique pasteboards
that never modify the general clipboard.
