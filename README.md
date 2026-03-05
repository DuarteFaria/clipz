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

Clipz lives in the menu bar. Click the clipboard icon or press **Cmd+Alt++** to toggle the popover.

| Key           | Action                  |
| ------------- | ----------------------- |
| Arrow Up/Down | Navigate history        |
| Enter         | Copy entry to clipboard |
| Escape        | Close popover           |

## Features

- **Menu bar app** — lives in the status bar, no dock icon
- **Persistent history** — saved to `~/.clipz_history.json`
- **Image & file support** — detects content type automatically, shows inline previews
- **Deduplication** — identical entries (including images by content) are collapsed
- **Battery-efficient** — uses NSPasteboard change count to avoid polling when idle

## Build from Source

Requires [Zig](https://ziglang.org) and [Rust](https://rustup.rs).

```bash
zig build                     # build backend
cargo run -p clipz-gpui       # run frontend (starts backend automatically)
```

The frontend expects the backend binary at `zig-out/bin/clipz`.

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
