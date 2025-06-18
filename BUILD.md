# Clipz Production Build Guide

This guide explains how to create production-ready apps from your Clipz codebase.

## 🚀 Quick Start

### Prerequisites

1. **Zig** (0.13.0 or later) - for building the backend
2. **Node.js** (16+ recommended) - for the Electron frontend
3. **npm** - for dependency management

### Building Production Apps

```bash
cd electron-frontend

# Install dependencies (first time only)
npm install

# Build for your current platform
npm run build

# Or build for specific platforms:
npm run build:mac    # macOS DMG and ZIP
npm run build:win    # Windows installer and portable
npm run build:linux  # Linux AppImage and DEB
```

## 📦 Production Artifacts

After building, you'll find these files in `electron-frontend/dist/`:

### macOS
- `Clipz-1.0.0.dmg` - Intel Mac installer (drag & drop)
- `Clipz-1.0.0-arm64.dmg` - Apple Silicon installer 
- `Clipz-1.0.0-mac.zip` - Intel Mac portable
- `Clipz-1.0.0-arm64-mac.zip` - Apple Silicon portable

### Windows
- `Clipz Setup 1.0.0.exe` - Windows installer
- `Clipz 1.0.0.exe` - Portable executable

### Linux
- `Clipz-1.0.0.AppImage` - Universal Linux app
- `clipz_1.0.0_amd64.deb` - Debian/Ubuntu package

## 🔧 Build Scripts

- `npm run build` - Build for current platform
- `npm run build:mac` - macOS DMG + ZIP (includes Zig backend)
- `npm run build:win` - Windows installer + portable
- `npm run build:linux` - Linux AppImage + DEB
- `npm run pack` - Create app folder (no installer)
- `npm run dist` - Build all platforms

**✅ Fixed**: The Zig backend is now properly included and accessible in production builds!

## ⚙️ Build Configuration

The build is configured in `package.json` under the `"build"` section:

- **App ID**: `com.yourname.clipz`
- **Product Name**: `Clipz`
- **Icons**: Located in `assets/`
- **Code Signing**: Disabled for development builds

## 📋 What's Included

Each production app includes:

1. **Zig Backend** (`clipz` binary) - compiled for optimal performance
2. **Electron Frontend** - modern GUI with global hotkeys
3. **Auto-updater ready** - configured for future updates
4. **Platform integration** - system tray, global shortcuts

## 🚨 Distribution Notes

### macOS
- Apps are **unsigned** by default (for development)
- Users may need to right-click → "Open" on first launch
- For App Store distribution, you'll need Apple Developer certificates

### Windows
- **SmartScreen** may warn about unsigned apps
- For production, consider code signing certificates
- Portable version doesn't require installation

### Linux
- **AppImage** works on most distributions
- **DEB** package for Debian/Ubuntu systems
- May need to mark as executable: `chmod +x Clipz-1.0.0.AppImage`

## 🔒 Code Signing (Optional)

For production distribution, you may want to sign your apps:

### macOS
```bash
# Add to package.json build config:
"mac": {
  "identity": "Developer ID Application: Your Name"
}
```

### Windows
```bash
# Add to package.json build config:
"win": {
  "certificateFile": "path/to/certificate.pfx",
  "certificatePassword": "password"
}
```

## 🧪 Testing Your Build

1. **Install the DMG/installer** on a clean system
2. **Test global hotkeys**: Cmd+Ctrl+1-9 (macOS) / Ctrl+Alt+1-9 (Windows/Linux)
3. **Verify clipboard monitoring** works correctly
4. **Check system tray integration**

## 📝 Customizing the Build

Edit `electron-frontend/package.json` to customize:

- App name and description
- Icons (place in `assets/` folder)
- Build targets and architectures
- Installer options

## 🆘 Troubleshooting

### Build Fails
- Ensure Zig is installed and in PATH
- Check Node.js version (16+ recommended)
- Clean and rebuild: `rm -rf node_modules && npm install`

### App Won't Start
- Check if Zig backend was built correctly: `../zig-out/bin/clipz --help`
- Look for errors in Console.app (macOS) or Event Viewer (Windows)

### Global Hotkeys Don't Work
- App needs accessibility permissions (macOS)
- Try running as administrator (Windows)
- Check for conflicting applications

## 🎯 Next Steps

Your production app is ready to use! You can:

1. **Distribute the DMG/installer** to users
2. **Set up auto-updates** with electron-updater
3. **Submit to app stores** (with proper code signing)
4. **Create a landing page** for downloads

---

**Congratulations! You now have a fully functional production app.** 🎉 