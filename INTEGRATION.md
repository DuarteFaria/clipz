# 🔗 Clipz Integration Guide

This guide explains how to integrate Clipz with various workflows and applications. Clipz provides multiple interfaces to fit different use cases.

## Integration Modes

### 1. CLI Integration

Perfect for shell scripts, automation, and terminal workflows.

```bash
# Basic clipboard access
./zig-out/bin/clipz

# Get specific entry
echo "get 1" | ./zig-out/bin/clipz --cli

# Clear clipboard history
echo "clean" | ./zig-out/bin/clipz --cli
```

### 2. Electron Frontend (Recommended)

Modern GUI with working global hotkeys and system tray integration.

```bash
cd electron-frontend
npm install
npm start
```

Features:
- ✅ Working global hotkeys (Cmd+Ctrl+1-9)
- ✅ System tray integration
- ✅ Real-time clipboard monitoring
- ✅ Modern, responsive UI

### 3. JSON API Integration

For building custom frontends or integrating with other applications.

```bash
./zig-out/bin/clipz --json-api
```

**API Commands:**
- `get-entries` - Retrieve all clipboard entries
- `select-entry:<index>` - Select specific entry  
- `clear` - Clear clipboard history
- `quit` - Exit API mode

**Response Format:**
```json
{
  "type": "entries", 
  "data": [
    {
      "id": 1,
      "content": "clipboard text",
      "timestamp": 1640995200000,
      "type": "text"
    }
  ]
}
```

## Available Integrations

### Shell Scripts

```bash
#!/bin/bash
# Get latest clipboard entry
latest=$(echo "get 1" | ./zig-out/bin/clipz --cli)
echo "Latest: $latest"
```

### System Service (macOS)

Create a Launch Agent plist for the Electron frontend:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.clipz</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/npm</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/path/to/clipz/electron-frontend</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

### Electron Frontend

The included Electron frontend demonstrates JSON API integration:

```javascript
const { spawn } = require('child_process');

const clipz = spawn('./zig-out/bin/clipz', ['--json-api']);

// Send command
clipz.stdin.write('get-entries\n');

// Handle response
clipz.stdout.on('data', (data) => {
  const response = JSON.parse(data.toString());
  console.log('Clipboard entries:', response.data);
});
```

## Platform Features

✅ **Core Features (All Platforms)**
- ✅ CLI interface
- ✅ Clipboard monitoring  
- ✅ Persistent storage
- ✅ Multiple run modes (CLI, json-api)
- ✅ JSON API for integrations

✅ **GUI Features (Electron Frontend)**
- ✅ Global hotkeys (all platforms)
- ✅ System tray integration
- ✅ Modern, responsive UI
- ✅ Real-time updates

## Configuration

### Environment Variables

- `CLIPZ_MAX_ENTRIES` - Maximum clipboard entries to store (default: 10)
- `CLIPZ_DATA_DIR` - Custom data directory for persistence

### Command Line Options

```
Usage: clipz [OPTION]

Options:
  -c, --cli       Run in CLI mode (default)
  -j, --json-api  Run in JSON API mode for Electron integration
  -h, --help      Show this help message

Note: For global hotkeys, use the Electron frontend with 'npm start'
```

## Example Integrations

### Alfred Workflow (macOS)

Create an Alfred script filter that queries Clipz:

```bash
#!/bin/bash
echo "get-entries" | /path/to/clipz --json-api | jq '.data[] | {title: .content, arg: .id}'
```

### Raycast Extension

Use the JSON API to build a Raycast extension for clipboard management.

### tmux Integration

Add to `.tmux.conf`:

```bash
bind-key p run-shell "echo 'get 1' | /path/to/clipz --cli | tmux load-buffer -"
```

## Best Practices

1. **Use Electron frontend** for daily use with global hotkeys
2. **Use JSON API** for building custom interfaces  
3. **Use CLI mode** for one-off operations and scripts
4. **Monitor memory usage** with large clipboard histories
5. **Set appropriate max entries** for your use case

## Troubleshooting

### Common Issues

**Global hotkeys not working:**
- Use the Electron frontend instead of trying to set up manual hotkeys
- Ensure the Electron app has necessary permissions

**JSON API not responding:**
- Check that process is running in JSON API mode
- Verify stdin/stdout are properly connected
- Test with simple commands first

### Debug Mode

Enable debug output:

```bash
CLIPZ_DEBUG=1 ./zig-out/bin/clipz --cli
```

## Contributing

Want to add new integrations? Please:

1. Test with existing JSON API first
2. Document the integration approach
3. Provide example configurations
4. Submit pull requests with clear descriptions

For questions or support, please open an issue in the repository. 