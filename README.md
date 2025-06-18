# Clipz

A powerful, lightweight clipboard manager written in Zig with CLI and Electron frontend interfaces.

## Features

- 📋 **CLI Mode**: Simple command-line interface for clipboard management
- 🖥️ **Electron Frontend**: Modern GUI with global hotkey support
- 🔄 **Automatic Monitoring**: Tracks clipboard changes automatically  
- 💾 **Persistent Storage**: Saves clipboard history across sessions
- ⌨️ **Global Hotkeys**: Quick access via Cmd+Ctrl+1-9 (Electron frontend)
- 🧹 **Smart Cleanup**: Manages memory efficiently
- 🎯 **JSON API**: Integration support for external applications

## Quick Start

### Electron Frontend (Recommended)

```bash
cd electron-frontend
npm install
npm start
```

Features working global hotkeys (cross-platform) and system tray integration.

### CLI Mode

```bash
./zig-out/bin/clipz
```

**CLI Commands:**
- `get` - Show all clipboard entries
- `get <n>` - Copy entry n to clipboard  
- `clean` - Clear all entries
- `exit` - Quit

### JSON API Mode (For Integration)

```bash  
./zig-out/bin/clipz --json-api
```

Provides JSON interface for external applications like the Electron frontend.

## Build Instructions

Make sure you have Zig installed (0.13.0 or later):

```bash
# Clone the repository
git clone <repository-url>
cd clipz

# Build the project
zig build

# Run in CLI mode
./zig-out/bin/clipz

# Or use the Electron frontend
cd electron-frontend && npm start
```

## Usage

### Command Line Arguments

```
Usage: clipz [OPTION]

Options:
  -c, --cli       Run in CLI mode (default)
  -j, --json-api  Run in JSON API mode for Electron integration
  -h, --help      Show this help message

Note: For global hotkeys (cross-platform), use the Electron frontend with 'npm start'
```

### Global Hotkeys (Electron Frontend)

The Electron frontend provides working global hotkeys:

- `Cmd+Ctrl+1` through `Cmd+Ctrl+9` (macOS) / `Ctrl+Alt+1-9` (Windows/Linux) - Quick access to clipboard entries 1-9
- `Cmd+Ctrl+0` (macOS) / `Ctrl+Alt+0` (Windows/Linux) - Access clipboard entry 10
- `Cmd+Ctrl+Q` (macOS) / `Ctrl+Alt+Q` (Windows/Linux) - Quit application completely

## Project Structure

```
clipz/
├── src/
│   ├── main.zig          # Main entry point
│   ├── manager.zig       # Clipboard management logic
│   ├── clipboard.zig     # Platform clipboard interface
│   ├── ui.zig           # CLI interface
│   ├── persistence.zig   # Data persistence
│   └── command.zig      # Command parsing
├── electron-frontend/    # Electron GUI application
│   ├── main.js          # Electron main process
│   ├── renderer.js      # Frontend UI logic
│   ├── preload.js       # Secure IPC bridge
│   ├── index.html       # UI markup
│   ├── styles.css       # UI styling
│   └── package.json     # Node.js dependencies
├── build.zig            # Zig build configuration
└── README.md
```

## Integration

See `INTEGRATION.md` for detailed integration examples including:
- Shell script integration
- JSON API usage
- Custom frontend development

**Recommended approach**: Use the Electron frontend for daily use, CLI for automation and scripts.

## Contributing

Contributions welcome! The codebase is now simplified with two main interfaces:
1. **CLI mode** - for terminal and automation use
2. **Electron frontend** - for GUI and global hotkeys

## License

See LICENSE file for details.
