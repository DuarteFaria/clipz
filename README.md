# Clipz

A native macOS clipboard manager. Keeps a persistent history of text, images, and files with a snappy GUI and minimal resource usage.

## Install

### Homebrew (recommended)

```bash
brew tap DuarteFaria/clipz
brew install --cask clipz
```

### Download DMG

Grab `Clipz.dmg` from the [latest release](https://github.com/DuarteFaria/clipz/releases/latest), open it, and drag Clipz to Applications.

> If macOS blocks the app on first launch, run `xattr -cr /Applications/Clipz.app` or go to **System Settings > Privacy & Security** and click **Open Anyway**.

## Usage

Clipz lives in the menu bar. Click the clipboard icon or press **Command+Option+=**
(the Equal key) to toggle the popover.

| Key           | Action                  |
| ------------- | ----------------------- |
| Arrow Up/Down | Navigate history        |
| Enter         | Copy entry to clipboard |
| Escape        | Close popover           |

## Features

- **Menu bar app** — lives in the status bar, no dock icon
- **Persistent history** — saved to `~/.clipz_history.json`
- **Pins** — retained separately from the rolling history of 10 unpinned entries
- **Image & file support** — detects content type automatically, shows inline previews
- **Deduplication** — recopying an entry promotes it while retaining its ID and pin; images are compared byte-for-byte
- **Battery-efficient capture** — uses NSPasteboard change count to skip unchanged clipboard reads

### History, images, and recovery

- The existing clipboard is captured on startup. If a clipboard read fails, Clipz
  retries with capped backoff rather than treating that change as captured.
- Captured PNG, JPEG, and TIFF images live in
  `~/Library/Application Support/Clipz/images`, not temporary storage. The image
  directory is private (`0700`); new images and history files are `0600`.
- Older `/tmp/clipz_images` captures are copied into durable storage on load.
  Legacy files are deliberately left intact for recovery; missing assets remain
  in history and produce an error when selected.
- History saves are atomic and batched (30 seconds in the frontend's low-power
  profile). Failed saves remain pending and retry. Removed images are deleted
  only after the updated history has been saved.
- Damaged history is preserved as `~/.clipz_history.json.corrupt-<suffix>` and a
  warning is shown. Unknown future history versions are left untouched and stop
  backend startup. Back up the files before attempting manual recovery.
- Backend startup, connection, and command errors appear in the popover.
  **Dismiss** clears the message; **Restart backend** reconnects after stopping
  the previous process. For save failures, resolve disk-space/permission problems
  before restarting so pending changes can be flushed.
- **Quit** requests a final save and waits for backend exit. An unresponsive
  backend is forcibly terminated after two seconds; this last-resort timeout can
  lose changes that have not yet been saved.

History is local but **not encrypted**. Do not treat clipboard history as a secure
store for passwords or tokens. Files copied from Finder remain references to the
original file; Clipz does not back up those files.

## Build from Source

Requires macOS, [Zig 0.15.2](https://ziglang.org), [Rust](https://rustup.rs),
and the Xcode Command Line Tools. The backend links AppKit; SDL is not required.

```bash
zig build                     # build backend
cargo run -p clipz-gpui       # run frontend (starts backend automatically)
```

The frontend expects the backend binary at `zig-out/bin/clipz`.

### Tests

```bash
zig build test --summary all
zig build
python3 scripts/test-json-api.py
cargo test --locked -p clipz-gpui
```

`src/tests.zig` explicitly discovers the backend module tests. Manager tests use
an injected clipboard and temporary history/image directories. The JSON API
tests run the real backend with isolated `HOME` and fake `osascript`; they never
read or change the user's clipboard contents. Frontend lifecycle tests use fake
child processes. Pull-request CI runs these tests and builds both components.

### CLI mode

```bash
zig build run                          # balanced (default)
zig build run -- --low-power           # slower polling, better for battery
zig build run -- --responsive          # faster polling
zig build run -- --json-api            # JSON API over stdin/stdout
```

### Packaging

```bash
./scripts/build-app.sh
open Clipz.dmg
```

## Releasing

1. Tag and push:
   ```bash
   git tag -a v1.x.x -m "Description"
   git push --tags
   ```
2. GitHub Actions builds `Clipz.dmg` and publishes it as a release
3. Update `version` in [`homebrew-clipz/Casks/clipz.rb`](https://github.com/DuarteFaria/homebrew-clipz)

## Project Structure

```
clipz/
├── src/            # Zig backend (clipboard monitoring, persistence, JSON API)
├── gpui-app/       # Rust frontend (gpui, menu bar, popover)
├── scripts/        # Build/packaging scripts
└── build.zig
```

## License

MIT — see [LICENSE](LICENSE).
