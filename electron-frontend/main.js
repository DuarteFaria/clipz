const { app, BrowserWindow, ipcMain, globalShortcut, Tray, Menu } = require('electron');
const { spawn } = require('child_process');
const path = require('path');

let mainWindow;
let zigBackend;
// Global hotkeys are handled by Electron's globalShortcut API
let tray = null;

// Create the main window
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    minWidth: 600,
    minHeight: 400,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    },
    titleBarStyle: 'hiddenInset', // macOS style
    backgroundColor: '#f8f8f8',
    show: false // Don't show until ready
  });

  mainWindow.loadFile('index.html');

  // Show window when ready to prevent visual flash
  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  // Handle window closed - give user choice between minimize to tray or quit
  mainWindow.on('close', (event) => {
    if (!app.isQuiting) {
      // On macOS, check if user wants to minimize to tray or quit completely
      if (process.platform === 'darwin') {
        const choice = require('electron').dialog.showMessageBoxSync(mainWindow, {
          type: 'question',
          buttons: ['Minimize to Tray', 'Quit Completely'],
          defaultId: 0,
          cancelId: 0,
          title: 'Close Clipz',
          message: 'How would you like to close Clipz?',
          detail: 'Minimize to tray keeps global hotkeys active.\nQuit completely stops all processes.'
        });

        if (choice === 0) {
          // Minimize to tray
          event.preventDefault();
          mainWindow.hide();
          app.dock.hide();
        } else {
          // Quit completely
          app.isQuiting = true;
          globalShortcut.unregisterAll();
          stopZigBackend();
          if (tray) {
            tray.destroy();
          }
          app.quit();
        }
      } else {
        // On other platforms, minimize to tray by default (can still quit from tray menu)
        event.preventDefault();
        mainWindow.hide();
      }
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// Start the Zig backend process in JSON API mode
function startZigBackend() {
  const zigPath = path.join(__dirname, '..', 'zig-out', 'bin', 'clipz');

  // Use low-power mode for better battery life
  zigBackend = spawn(zigPath, ['--json-api', '--low-power'], {
    stdio: ['pipe', 'pipe', 'pipe']
  });

  // Handle JSON responses from Zig backend
  let buffer = '';
  zigBackend.stdout.on('data', (data) => {
    buffer += data.toString();
    const lines = buffer.split('\n');
    buffer = lines.pop(); // Keep incomplete line in buffer

    lines.forEach(line => {
      if (line.trim()) {
        try {
          const message = JSON.parse(line);
          handleZigMessage(message);
        } catch (err) {
          console.error('Failed to parse JSON from Zig:', line, err);
        }
      }
    });
  });

  zigBackend.stderr.on('data', (data) => {
    console.error(`Zig backend error: ${data.toString()}`);
  });

  zigBackend.on('error', (err) => {
    console.error('Failed to start Zig backend:', err);
  });
}

// Send command to Zig backend
function sendZigCommand(command) {
  if (zigBackend && zigBackend.stdin) {
    zigBackend.stdin.write(command + '\n');
  }
}

// Optimized hotkey handler - combines selection and UI update
function handleHotkeyPress(index) {
  // 1. Immediate UI feedback (fastest - no backend required)
  if (mainWindow) {
    mainWindow.webContents.send('hotkey-used', index);
  }

  // 2. Backend operation - select and refresh in quick succession
  sendZigCommand(`select-entry:${index}`);
  // Use setImmediate for next tick execution (faster than setTimeout)
  setImmediate(() => {
    sendZigCommand('get-entries');
  });
}

// Stop the Zig backend process
function stopZigBackend() {
  if (zigBackend) {
    sendZigCommand('quit');
    setTimeout(() => {
      if (zigBackend) {
        zigBackend.kill('SIGTERM');
        zigBackend = null;
      }
    }, 1000);
  }
}

// Note: Global hotkeys are now handled directly by Electron's globalShortcut API
// No separate daemon process needed

// Create system tray
function createTray() {
  const { nativeImage } = require('electron');

  // Create a simple programmatic icon (16x16 clipboard-like icon)
  const iconBuffer = Buffer.from([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x91, 0x68, 0x36, 0x00, 0x00, 0x00,
    0x09, 0x70, 0x48, 0x59, 0x73, 0x00, 0x00, 0x0B, 0x13, 0x00, 0x00, 0x0B,
    0x13, 0x01, 0x00, 0x9A, 0x9C, 0x18, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49,
    0x4D, 0x45, 0x07, 0xE0, 0x06, 0x16, 0x12, 0x2B, 0x5D, 0x1B, 0x5A, 0x91,
    0x01, 0x00, 0x00, 0x00, 0x19, 0x74, 0x45, 0x58, 0x74, 0x43, 0x6F, 0x6D,
    0x6D, 0x65, 0x6E, 0x74, 0x00, 0x43, 0x72, 0x65, 0x61, 0x74, 0x65, 0x64,
    0x20, 0x77, 0x69, 0x74, 0x68, 0x20, 0x47, 0x49, 0x4D, 0x50, 0x57, 0x81,
    0x0E, 0x17, 0x00, 0x00, 0x00, 0x2E, 0x49, 0x44, 0x41, 0x54, 0x28, 0x91,
    0x63, 0x60, 0x40, 0x02, 0xFF, 0x81, 0x01, 0x02, 0x30, 0x20, 0xC0, 0x24,
    0x40, 0x69, 0x20, 0x32, 0x20, 0x1C, 0x0C, 0x20, 0x85, 0x04, 0x48, 0x01,
    0x99, 0x81, 0xC8, 0x80, 0x70, 0x30, 0x80, 0x14, 0x12, 0x20, 0x05, 0x64,
    0x06, 0x22, 0x03, 0x00, 0x80, 0x65, 0x07, 0x6C, 0x2C, 0x65, 0x5C, 0x1A,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
  ]);

  const icon = nativeImage.createFromBuffer(iconBuffer);
  tray = new Tray(icon);

  const contextMenu = Menu.buildFromTemplate([
    {
      label: '📋 Show Clipz Window',
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          if (process.platform === 'darwin') {
            app.dock.show();
          }
        } else {
          createWindow();
        }
      }
    },
    { type: 'separator' },
    {
      label: '⚡ Global Hotkeys',
      submenu: [
        {
          label: '✅ Active (Cmd+Ctrl+1-9)',
          enabled: false
        },
        {
          label: 'Built into Electron frontend',
          enabled: false
        }
      ]
    },
    { type: 'separator' },
    {
      label: '❌ Quit & Stop All Processes',
      click: () => {
        app.isQuiting = true;
        globalShortcut.unregisterAll();
        stopZigBackend();
        if (tray) {
          tray.destroy();
        }
        app.quit();
      }
    }
  ]);

  tray.setToolTip('Clipz - Clipboard Manager');
  tray.setContextMenu(contextMenu);

  // Double-click to show main window
  tray.on('double-click', () => {
    if (mainWindow) {
      mainWindow.show();
      if (process.platform === 'darwin') {
        app.dock.show();
      }
    } else {
      createWindow();
    }
  });
}

// Global hotkeys are now handled by Electron's globalShortcut API

// App event handlers
app.whenReady().then(() => {
  createWindow();
  startZigBackend();
  createTray(); // Create system tray

  // Register global shortcuts for clipboard access (Cmd+Ctrl+1-0)
  for (let i = 1; i <= 9; i++) {
    globalShortcut.register(`CommandOrControl+Control+${i}`, () => handleHotkeyPress(i));
  }
  // Register Cmd+Ctrl+0 for entry 10
  globalShortcut.register('CommandOrControl+Control+0', () => handleHotkeyPress(10));

  // Register Cmd+Ctrl+Q to quit completely (global shortcut)
  globalShortcut.register('CommandOrControl+Control+Q', () => {
    app.isQuiting = true;
    globalShortcut.unregisterAll();
    stopZigBackend();
    if (tray) {
      tray.destroy();
    }
    app.quit();
  });

  // macOS: Re-create window when dock icon is clicked
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

// Quit when all windows are closed (except on macOS)
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    stopZigBackend();
    app.quit();
  }
});

app.on('will-quit', () => {
  // Unregister all shortcuts
  globalShortcut.unregisterAll();
  stopZigBackend();
});

// Store latest clipboard entries
let latestEntries = [];

// IPC handlers for communication with renderer process
ipcMain.handle('get-clipboard-entries', async () => {
  // Request fresh entries from Zig backend
  sendZigCommand('get-entries');

  // Return cached entries immediately (they'll be updated via real-time updates)
  return latestEntries;
});

ipcMain.handle('select-entry', async (event, index) => {
  sendZigCommand(`select-entry:${index}`);
  return { success: true };
});

ipcMain.handle('clear-clipboard', async () => {
  sendZigCommand('clear');
  return { success: true };
});

// Update handler for Zig messages
function handleZigMessage(message) {
  if (message.type === 'entries') {
    latestEntries = message.data;
    // Send real-time updates to renderer
    if (mainWindow) {
      mainWindow.webContents.send('clipboard-entries-updated', message.data);
    }
  } else if (message.type === 'ready') {
    // Request initial entries
    sendZigCommand('get-entries');
  }
} 