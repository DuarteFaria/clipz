const { contextBridge, ipcRenderer } = require('electron');

// Expose protected methods that allow the renderer process to use
// the ipcRenderer without exposing the entire object
contextBridge.exposeInMainWorld('electronAPI', {
  // Get clipboard entries from the backend
  getClipboardEntries: () => ipcRenderer.invoke('get-clipboard-entries'),

  // Select a clipboard entry
  selectEntry: (index) => ipcRenderer.invoke('select-entry', index),

  // Clear clipboard
  clearClipboard: () => ipcRenderer.invoke('clear-clipboard'),

  // Listen for events from main process
  onSelectEntry: (callback) => {
    ipcRenderer.on('select-entry', callback);
  },

  // Listen for real-time clipboard updates from Zig backend
  onClipboardEntriesUpdated: (callback) => {
    ipcRenderer.on('clipboard-entries-updated', (event, entries) => callback(entries));
  },

  // Listen for hotkey used events
  onHotkeyUsed: (callback) => {
    ipcRenderer.on('hotkey-used', callback);
  },

  // Remove listeners
  removeAllListeners: (channel) => {
    ipcRenderer.removeAllListeners(channel);
  }
}); 