# 🔗 Clipz Integration Guide

This guide explains how to integrate Clipz with various workflows and applications. Clipz provides multiple interfaces to fit different use cases.

## Overview

Clipz is a powerful clipboard manager that can be integrated with other applications through its JSON API mode. This document describes the integration interface and new features.

## New Features (Image Support)

### 🖼️ Image Detection and Management

Clipz now automatically detects and manages both text and image clipboard content:

- **Automatic Type Detection**: Uses native macOS `osascript` to detect clipboard content type
- **Image Path Storage**: Stores file paths for images instead of copying files
- **Smart Fallback**: Handles images without file paths (screenshots, web images, etc.)
- **Duplicate Prevention**: Prevents duplicates based on both content and type

### 📡 API Changes

The JSON API has been enhanced to support image entries:

#### Entry Format
```json
{
  "id": 1,
  "content": "/path/to/image.png", // or "[Image Data - No File Path]"
  "timestamp": 1640995200000,
  "type": "image", // or "text"
  "isCurrent": true
}
```

#### Supported Types
- `"text"` - Text clipboard content
- `"image"` - Image clipboard content (with file path or data indicator)

### 🔧 Technical Implementation

#### Clipboard Detection
```applescript
-- Type detection
set theClipboard to the clipboard
try
    set imgData to the clipboard as picture
    return "image"
on error
    return "text"
end try

-- Path retrieval for images
try
    set imgPath to the clipboard as alias
    return POSIX path of imgPath
on error
    return "[Image Data - No File Path]"
end try
```

#### Data Storage
- **Version 2 Format**: Persistence files now include a `type` field
- **Backward Compatibility**: Existing entries are automatically upgraded
- **Efficient Storage**: Images store paths only, not file data

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