// Renderer process - handles UI interactions
class ClipboardApp {
  constructor() {
    this.entries = [];
    this.selectedIndex = -1;
    this.filteredEntries = [];
    this.zoomLevel = 100;
    this.searchQuery = '';

    this.initializeElements();
    this.attachEventListeners();
    this.setupRealTimeUpdates();
    this.loadClipboardEntries();

    // Auto-refresh every 30 seconds as backup
    setInterval(() => this.loadClipboardEntries(), 30000);
  }

  initializeElements() {
    this.entryCountEl = document.getElementById('entryCount');
    this.clipboardListEl = document.getElementById('clipboardList');
    this.emptyStateEl = document.getElementById('emptyState');
    this.searchInputEl = document.getElementById('searchInput');
    this.searchClearEl = document.getElementById('searchClear');
    this.clearBtnEl = document.getElementById('clearBtn');
    this.zoomLevelEl = document.getElementById('zoomLevel');
    this.zoomInBtnEl = document.getElementById('zoomInBtn');
    this.zoomOutBtnEl = document.getElementById('zoomOutBtn');
    this.statusEl = document.getElementById('status');
    this.loadingOverlayEl = document.getElementById('loadingOverlay');
  }

  attachEventListeners() {
    // Search functionality
    this.searchInputEl.addEventListener('input', (e) => {
      this.searchQuery = e.target.value;
      this.filterEntries();
      this.updateSearchClearButton();
    });

    this.searchClearEl.addEventListener('click', () => {
      this.searchInputEl.value = '';
      this.searchQuery = '';
      this.filterEntries();
      this.updateSearchClearButton();
      this.searchInputEl.focus();
    });

    // Clear clipboard
    this.clearBtnEl.addEventListener('click', () => {
      this.clearClipboard();
    });

    // Zoom controls
    this.zoomInBtnEl.addEventListener('click', () => {
      this.adjustZoom(10);
    });

    this.zoomOutBtnEl.addEventListener('click', () => {
      this.adjustZoom(-10);
    });

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
      this.handleKeyboard(e);
    });

    // Listen for global shortcut events from main process
    window.electronAPI.onSelectEntry((event, index) => {
      this.selectEntry(index);
    });

    // Listen for hotkey usage notifications
    window.electronAPI.onHotkeyUsed((event, index) => {
      this.showHotkeyFeedback(index);
    });
  }

  setupRealTimeUpdates() {
    // Listen for real-time clipboard updates from Zig backend
    window.electronAPI.onClipboardEntriesUpdated((entries) => {
      // Check if entries order changed (someone used hotkey or added new entry)
      const entriesChanged = this.hasEntriesChanged(this.entries, entries);

      this.entries = entries;
      this.filterEntries();
      this.updateEntryCount();

      // If entries changed significantly, show visual feedback
      if (entriesChanged) {
        this.showListUpdateFeedback();
      }
    });
  }

  async loadClipboardEntries() {
    try {
      this.entries = await window.electronAPI.getClipboardEntries();
      this.filterEntries();
      this.updateEntryCount();
      this.hideLoading();
    } catch (error) {
      console.error('Failed to load clipboard entries:', error);
      this.updateStatus('Error loading entries', 'error');
    }
  }

  filterEntries() {
    if (!this.searchQuery.trim()) {
      this.filteredEntries = [...this.entries];
    } else {
      const query = this.searchQuery.toLowerCase();
      this.filteredEntries = this.entries.filter(entry =>
        entry.content.toLowerCase().includes(query)
      );
    }
    this.renderEntries();
  }

  renderEntries() {
    if (this.filteredEntries.length === 0) {
      this.showEmptyState();
      return;
    }

    this.hideEmptyState();

    this.clipboardListEl.innerHTML = this.filteredEntries.map((entry, index) => {
      const isSelected = index === this.selectedIndex;
      const timeAgo = this.formatTimeAgo(entry.timestamp);
      const isCurrent = entry.isCurrent || false;
      const entryClasses = [
        'clipboard-entry',
        isSelected ? 'selected' : '',
        isCurrent ? 'current-clipboard' : 'history-entry'
      ].filter(Boolean).join(' ');

      return `
                <div class="${entryClasses}" 
                     data-index="${index}" 
                     onclick="app.selectEntryByElement(this)">
                    <div class="entry-header">
                        <div class="entry-index">
                            ${entry.id}
                        </div>
                        <div class="entry-meta">
                            <span class="entry-time">${timeAgo}</span>
                        </div>
                    </div>
                    <div class="entry-content">${this.escapeHtml(entry.content)}</div>
                </div>
            `;
    }).join('');
  }

  selectEntryByElement(element) {
    const index = parseInt(element.dataset.index);
    const entryId = this.filteredEntries[index].id;
    this.selectEntry(entryId);
  }

  highlightEntry(index) {
    // Remove previous selection
    document.querySelectorAll('.clipboard-entry').forEach(el => {
      el.classList.remove('selected');
    });

    // Add selection to current entry
    const entryElement = document.querySelector(`[data-index="${index}"]`);
    if (entryElement) {
      entryElement.classList.add('selected');
      entryElement.scrollIntoView({ behavior: 'smooth', block: 'nearest' });

      // Remove selection after 2 seconds
      setTimeout(() => {
        entryElement.classList.remove('selected');
      }, 2000);
    }
  }

  async clearClipboard() {
    try {
      const result = await window.electronAPI.clearClipboard();
      if (result.success) {
        this.updateStatus('Clipboard cleared', 'success');
        this.loadClipboardEntries();
      }
    } catch (error) {
      console.error('Failed to clear clipboard:', error);
      this.updateStatus('Failed to clear clipboard', 'error');
    }
  }

  adjustZoom(delta) {
    this.zoomLevel = Math.max(50, Math.min(200, this.zoomLevel + delta));
    this.updateZoom();
  }

  updateZoom() {
    document.body.style.zoom = `${this.zoomLevel}%`;
    this.zoomLevelEl.textContent = `${this.zoomLevel}%`;
  }

  handleKeyboard(e) {
    // Search shortcut
    if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
      e.preventDefault();
      this.searchInputEl.focus();
      return;
    }

    // Clear shortcut
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      this.clearClipboard();
      return;
    }

    // Zoom shortcuts
    if (e.metaKey || e.ctrlKey) {
      if (e.key === '=' || e.key === '+') {
        e.preventDefault();
        this.adjustZoom(10);
        return;
      }
      if (e.key === '-') {
        e.preventDefault();
        this.adjustZoom(-10);
        return;
      }
      if (e.key === '0') {
        e.preventDefault();
        this.zoomLevel = 100;
        this.updateZoom();
        return;
      }
    }

    // Number shortcuts for quick access (Cmd+Ctrl+1-0)
    if (e.metaKey && e.ctrlKey) {
      const num = parseInt(e.key);
      if (num >= 1 && num <= 9) {
        e.preventDefault();
        this.selectEntry(num);
        return;
      }
      if (e.key === '0') {
        e.preventDefault();
        this.selectEntry(10);
        return;
      }
    }

    // Arrow navigation
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      this.navigateEntries(e.key === 'ArrowDown' ? 1 : -1);
    }

    // Enter to select
    if (e.key === 'Enter' && this.selectedIndex >= 0) {
      e.preventDefault();
      const entryId = this.filteredEntries[this.selectedIndex].id;
      this.selectEntry(entryId);
    }

    // Escape to clear search
    if (e.key === 'Escape') {
      if (this.searchQuery) {
        this.searchInputEl.value = '';
        this.searchQuery = '';
        this.filterEntries();
        this.updateSearchClearButton();
      }
    }
  }

  navigateEntries(direction) {
    if (this.filteredEntries.length === 0) return;

    this.selectedIndex = Math.max(0, Math.min(
      this.filteredEntries.length - 1,
      this.selectedIndex + direction
    ));

    this.renderEntries();
  }

  updateSearchClearButton() {
    this.searchClearEl.style.display = this.searchQuery ? 'flex' : 'none';
  }

  updateEntryCount() {
    const count = this.entries.length;
    this.entryCountEl.textContent = count === 1 ? '1 entry' : `${count} entries`;
  }

  showEmptyState() {
    this.clipboardListEl.style.display = 'none';
    this.emptyStateEl.style.display = 'flex';
  }

  hideEmptyState() {
    this.clipboardListEl.style.display = 'block';
    this.emptyStateEl.style.display = 'none';
  }

  showLoading() {
    this.loadingOverlayEl.style.display = 'flex';
  }

  hideLoading() {
    this.loadingOverlayEl.style.display = 'none';
  }

  updateStatus(message, type = 'info') {
    this.statusEl.textContent = message;
    this.statusEl.className = `status ${type}`;

    // Clear status after 3 seconds
    setTimeout(() => {
      this.statusEl.textContent = 'Ready';
      this.statusEl.className = 'status';
    }, 3000);
  }

  formatTimeAgo(timestamp) {
    const now = Date.now();
    const diff = now - timestamp;
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) return `${days}d ago`;
    if (hours > 0) return `${hours}h ago`;
    if (minutes > 0) return `${minutes}m ago`;
    return `${seconds}s ago`;
  }

  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  showHotkeyFeedback(index) {
    // Ultra-fast visual feedback - no delays
    this.updateStatus(`⚡ Entry ${index} → Clipboard`, 'success');

    // Instant pulsing effect
    document.body.classList.add('hotkey-active');
    // Remove effect quickly to avoid visual lag
    setTimeout(() => {
      document.body.classList.remove('hotkey-active');
    }, 200);

    // Optimistic UI update - immediately move entry to top visually
    this.optimisticMoveToTop(index);
  }

  optimisticMoveToTop(index) {
    // Find the entry with this ID and move it to top immediately (before backend confirms)
    const entryToMove = this.entries.find(entry => entry.id === index);
    if (entryToMove) {
      // First, add instant visual feedback to the selected entry
      const entryElements = document.querySelectorAll('.clipboard-entry');
      entryElements.forEach(el => {
        const entryIndex = parseInt(el.dataset.index);
        const entry = this.filteredEntries[entryIndex];
        if (entry && entry.id === index) {
          el.classList.add('instant-select');
          // Remove the class after a brief moment
          setTimeout(() => el.classList.remove('instant-select'), 400);
        }
      });

      // Remove from current position
      this.entries = this.entries.filter(entry => entry.id !== index);
      // Add to beginning with current flag
      this.entries.unshift({ ...entryToMove, isCurrent: true });

      // Update other entries to not be current
      this.entries.forEach((entry, i) => {
        if (i > 0) entry.isCurrent = false;
      });

      // Immediately re-render for instant feedback
      this.filterEntries();
    }
  }

  showListUpdateFeedback() {
    // Visual feedback when list order changes
    this.clipboardListEl.classList.add('list-updating');
    setTimeout(() => {
      this.clipboardListEl.classList.remove('list-updating');
    }, 300);
  }

  hasEntriesChanged(oldEntries, newEntries) {
    if (!oldEntries || oldEntries.length !== newEntries.length) {
      return true;
    }

    // Check if the first entry (most recent) changed
    if (oldEntries.length > 0 && newEntries.length > 0) {
      const oldFirst = oldEntries[0];
      const newFirst = newEntries[0];
      return oldFirst.id !== newFirst.id || oldFirst.content !== newFirst.content;
    }

    return false;
  }

  async selectEntry(index) {
    try {
      // Show immediate feedback
      this.updateStatus(`⚡ Selecting entry ${index}...`, 'info');

      const result = await window.electronAPI.selectEntry(index);
      if (result.success) {
        this.updateStatus(`✓ Entry ${index} selected and moved to top`, 'success');

        // Force immediate refresh to show new order
        setTimeout(() => {
          this.loadClipboardEntries();
        }, 100);
      }
    } catch (error) {
      console.error('Failed to select entry:', error);
      this.updateStatus('Failed to select entry', 'error');
    }
  }
}

// Initialize the app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  window.app = new ClipboardApp();
}); 