const std = @import("std");
const clipboard = @import("clipboard.zig");
const ui = @import("ui.zig");
const persistence = @import("persistence.zig");
const config = @import("config.zig");
const image_storage = @import("image_storage.zig");
const pasteboard = @import("pasteboard.zig");

pub const ClipboardManagerError = error{
    InvalidIndex,
};

pub const ClipboardEntry = struct {
    id: u64,
    content: []const u8,
    timestamp: i64,
    entry_type: clipboard.ClipboardType,
    pinned: bool = false,

    pub fn create(allocator: std.mem.Allocator, id: u64, content: []const u8, entry_type: clipboard.ClipboardType) !ClipboardEntry {
        const content_copy = try allocator.dupe(u8, content);
        return ClipboardEntry{
            .id = id,
            .content = content_copy,
            .timestamp = std.time.timestamp(),
            .entry_type = entry_type,
            .pinned = false,
        };
    }

    pub fn free(self: ClipboardEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const DisplayEntrySnapshot = struct {
    id: u64,
    content: []const u8,
    timestamp: i64,
    entry_type: clipboard.ClipboardType,
    pinned: bool,
    is_current: bool,

    pub fn free(self: DisplayEntrySnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

/// The OS boundary is replaceable so capture/restore behavior can be tested
/// without reading or changing the user's real clipboard.
pub const ClipboardAccess = struct {
    context: ?*anyopaque = null,
    revision: *const fn (?*anyopaque) ?i64 = systemRevision,
    read: *const fn (?*anyopaque, std.mem.Allocator, config.Config) anyerror!clipboard.ClipboardContent = systemRead,
    write: *const fn (?*anyopaque, std.mem.Allocator, []const u8, clipboard.ClipboardType) anyerror!void = systemWrite,

    fn systemRevision(_: ?*anyopaque) ?i64 {
        return pasteboard.getChangeCount();
    }

    fn systemRead(_: ?*anyopaque, allocator: std.mem.Allocator, cfg: config.Config) !clipboard.ClipboardContent {
        return clipboard.getContentWithConfig(allocator, cfg);
    }

    fn systemWrite(_: ?*anyopaque, allocator: std.mem.Allocator, content: []const u8, entry_type: clipboard.ClipboardType) !void {
        return clipboard.setContentWithType(allocator, content, entry_type);
    }
};

const CaptureState = struct {
    acknowledged_revision: ?i64 = null,
    failed_revision: ?i64 = null,
    failures: u32 = 0,
};

pub const ClipboardManager = struct {
    entries: std.ArrayList(ClipboardEntry),
    allocator: std.mem.Allocator,
    max_entries: usize,
    next_entry_id: u64,
    current_entry_id: ?u64 = null,
    clipboard_access: ClipboardAccess = .{},
    image_store: image_storage.ImageStore,
    // Image deletion must follow a successful save, never precede it.
    pending_image_deletions: std.ArrayList([]const u8) = .empty,
    pending_error: ?anyerror = null,
    state_mutex: std.Thread.Mutex = .{},
    monitor_thread: ?std.Thread = null,
    should_monitor: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    persistence: persistence.Persistence,
    // Batched persistence fields
    dirty_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_save_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_save_attempt: i64 = 0,
    // Configuration
    config: config.Config,
    // Callback for notifying when entries change (for JSON API)
    entries_changed_callback: ?*const fn (*ClipboardManager) void = null,
    error_callback: ?*const fn (*ClipboardManager, anyerror) void = null,
    capture_recovered_callback: ?*const fn (*ClipboardManager) void = null,
    // Mutex for thread-safe stdout writes (used in JSON API mode)
    stdout_mutex: std.Thread.Mutex = .{},

    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardManager {
        const pers = try persistence.Persistence.init(allocator);
        return initWithConfigAndPersistence(allocator, cfg, pers);
    }

    pub fn initWithPersistencePath(allocator: std.mem.Allocator, cfg: config.Config, persistence_path: []const u8) !ClipboardManager {
        const pers = try persistence.Persistence.initWithPath(persistence_path);
        return initWithConfigAndPersistence(allocator, cfg, pers);
    }

    fn initWithConfigAndPersistence(allocator: std.mem.Allocator, cfg: config.Config, pers: persistence.Persistence) !ClipboardManager {
        const image_root = try pers.imageRoot(allocator);
        errdefer allocator.free(image_root);
        var manager = ClipboardManager{
            .entries = .empty,
            .allocator = allocator,
            .max_entries = @max(1, cfg.max_entries),
            .next_entry_id = 1,
            .persistence = pers,
            .image_store = .{ .root = image_root },
            .config = cfg,
        };
        errdefer {
            for (manager.entries.items) |entry| entry.free(allocator);
            manager.entries.deinit(allocator);
            for (manager.pending_image_deletions.items) |path| allocator.free(path);
            manager.pending_image_deletions.deinit(allocator);
        }

        try manager.loadFromPersistence();

        return manager;
    }

    pub fn deinit(self: *ClipboardManager) void {
        self.stopMonitoring();

        // Force save any pending changes
        self.forceSavePersistence();

        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        for (self.entries.items) |entry| {
            entry.free(self.allocator);
        }
        self.entries.deinit(self.allocator);
        for (self.pending_image_deletions.items) |path| self.allocator.free(path);
        self.pending_image_deletions.deinit(self.allocator);
        self.allocator.free(self.image_store.root);
    }

    fn loadFromPersistence(self: *ClipboardManager) !void {
        var loaded_result = try self.persistence.loadEntries(self.allocator);
        defer {
            for (loaded_result.entries.items) |entry| {
                entry.free(self.allocator);
            }
            loaded_result.entries.deinit(self.allocator);
        }

        while (countUnpinned(loaded_result.entries.items) > self.max_entries) {
            const eviction_index = findOldestUnpinnedEntry(loaded_result.entries.items) orelse break;
            const removed = loaded_result.entries.orderedRemove(eviction_index);
            self.retireEntryLocked(removed);
            self.dirty_flag.store(true, .release);
        }

        for (loaded_result.entries.items) |entry| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
            errdefer self.allocator.free(content_copy);
            const new_entry = ClipboardEntry{
                .id = entry.id,
                .content = content_copy,
                .timestamp = entry.timestamp,
                .entry_type = entry.entry_type,
                .pinned = entry.pinned,
            };
            try self.entries.append(self.allocator, new_entry);
        }
        self.next_entry_id = loaded_result.next_entry_id;
        if (self.next_entry_id == 0) self.next_entry_id = 1;
        if (loaded_result.needs_save) self.dirty_flag.store(true, .release);
        if (loaded_result.recovered_corrupt_history) self.pending_error = error.CorruptHistoryRecovered;
    }

    fn saveToPersistenceLocked(self: *ClipboardManager) !void {
        try self.persistence.saveEntries(self.allocator, self.entries.items, self.next_entry_id);
        for (self.pending_image_deletions.items) |path| {
            var referenced = false;
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.content, path)) {
                    referenced = true;
                    break;
                }
            }
            if (!referenced) self.image_store.delete(path) catch {};
            self.allocator.free(path);
        }
        self.pending_image_deletions.clearRetainingCapacity();
    }

    fn retireEntryLocked(self: *ClipboardManager, entry: ClipboardEntry) void {
        if (entry.entry_type == .image and self.image_store.owns(entry.content)) {
            self.pending_image_deletions.append(self.allocator, entry.content) catch {
                // Prefer an orphaned asset over deleting a file still referenced on disk.
                entry.free(self.allocator);
            };
        } else {
            entry.free(self.allocator);
        }
    }

    pub fn addEntry(self: *ClipboardManager, clipboard_content: clipboard.ClipboardContent) !void {
        var entry_added = false;
        {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            entry_added = try self.addEntryLocked(clipboard_content);
        }

        if (entry_added) self.notifyEntriesChanged();
        self.notifyPendingError();
    }

    fn notifyEntriesChanged(self: *ClipboardManager) void {
        if (self.entries_changed_callback) |callback| {
            self.stdout_mutex.lock();
            defer self.stdout_mutex.unlock();
            callback(self);
        } else {
            // CLI mode only — don't pollute stdout in JSON API mode
            ui.printEntries(self);
            std.debug.print("> ", .{});
        }
    }

    fn addEntryLocked(self: *ClipboardManager, clipboard_content: clipboard.ClipboardContent) !bool {
        // Takes ownership on both success and failure.
        defer self.allocator.free(clipboard_content.content);
        // Check if content already exists in any entry
        for (self.entries.items, 0..) |existing_entry, index| {
            if (std.mem.eql(u8, existing_entry.content, clipboard_content.content) and
                existing_entry.entry_type == clipboard_content.type)
            {
                return self.promoteEntryLocked(index);
            }
        }

        // Special handling for images: check if we already have the same image
        // by comparing file contents (since file paths are always unique)
        if (clipboard_content.type == .image and self.image_store.owns(clipboard_content.content)) {
            for (self.entries.items, 0..) |existing_entry, index| {
                if (existing_entry.entry_type == .image and
                    self.image_store.owns(existing_entry.content))
                {
                    // Compare the image files to see if they're the same
                    if (image_storage.compareImageFiles(existing_entry.content, clipboard_content.content) catch false) {
                        // The new capture is not persisted, so it is safe to delete.
                        self.image_store.delete(clipboard_content.content) catch {};
                        return self.promoteEntryLocked(index);
                    }
                }
            }
        }

        const entry = try ClipboardEntry.create(self.allocator, self.next_entry_id, clipboard_content.content, clipboard_content.type);
        errdefer entry.free(self.allocator);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        self.next_entry_id +%= 1;
        if (self.next_entry_id == 0) self.next_entry_id = 1;

        // Pins are retained separately from the rolling unpinned history budget.
        while (countUnpinned(self.entries.items) >= self.max_entries) {
            const eviction_index = self.findOldestUnpinnedIndex() orelse break;
            const oldest = self.entries.orderedRemove(eviction_index);
            self.retireEntryLocked(oldest);
        }

        self.entries.appendAssumeCapacity(entry);
        self.current_entry_id = entry.id;

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistenceLocked();

        return true;
    }

    fn promoteEntryLocked(self: *ClipboardManager, index: usize) bool {
        const id = self.entries.items[index].id;
        if (self.current_entry_id == id and index == self.entries.items.len - 1) return false;
        var entry = self.entries.orderedRemove(index);
        entry.timestamp = std.time.timestamp();
        self.entries.appendAssumeCapacity(entry);
        self.current_entry_id = id;
        self.dirty_flag.store(true, .release);
        self.trySavePersistenceLocked();
        return true;
    }

    fn countUnpinned(entries: []const ClipboardEntry) usize {
        var count: usize = 0;
        for (entries) |entry| {
            if (!entry.pinned) count += 1;
        }
        return count;
    }

    pub fn takePendingError(self: *ClipboardManager) ?anyerror {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const err = self.pending_error;
        self.pending_error = null;
        return err;
    }

    fn reportError(self: *ClipboardManager, err: anyerror) void {
        if (self.error_callback) |callback| {
            self.stdout_mutex.lock();
            defer self.stdout_mutex.unlock();
            callback(self, err);
        } else {
            std.debug.print("Clipboard error: {s}\n", .{@errorName(err)});
        }
    }

    fn notifyPendingError(self: *ClipboardManager) void {
        if (self.takePendingError()) |err| self.reportError(err);
    }

    // Batched persistence - only save if dirty and enough time has passed
    fn trySavePersistenceLocked(self: *ClipboardManager) void {
        const now = std.time.timestamp();
        const last_save = @max(self.last_save_time.load(.acquire), self.last_save_attempt);

        // Save if dirty and enough time has passed (configurable interval)
        if (self.dirty_flag.load(.acquire) and (now - last_save >= self.config.batch_save_interval)) {
            self.last_save_attempt = now;
            self.saveToPersistenceLocked() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
                self.pending_error = error.HistorySaveFailed;
                return;
            };
            self.dirty_flag.store(false, .release);
            self.last_save_time.store(now, .release);
        }
    }

    fn trySavePersistence(self: *ClipboardManager) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.trySavePersistenceLocked();
    }

    // Force save (for shutdown)
    fn forceSavePersistenceLocked(self: *ClipboardManager) void {
        if (self.dirty_flag.load(.acquire)) {
            self.last_save_attempt = std.time.timestamp();
            self.saveToPersistenceLocked() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
                self.pending_error = error.HistorySaveFailed;
                return;
            };
            self.dirty_flag.store(false, .release);
            self.last_save_time.store(std.time.timestamp(), .release);
        }
    }

    fn forceSavePersistence(self: *ClipboardManager) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.forceSavePersistenceLocked();
    }

    /// A successful exit means pending history is durable. Callers can report
    /// failure rather than treating an unsuccessful save as a clean shutdown.
    pub fn shutdown(self: *ClipboardManager) !void {
        self.stopMonitoring();
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.forceSavePersistenceLocked();
        if (self.dirty_flag.load(.acquire)) return error.HistorySaveFailed;
    }

    pub fn snapshotDisplayEntries(self: *ClipboardManager, allocator: std.mem.Allocator) !std.ArrayList(DisplayEntrySnapshot) {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.snapshotDisplayEntriesLocked(allocator);
    }

    fn snapshotDisplayEntriesLocked(self: *ClipboardManager, allocator: std.mem.Allocator) !std.ArrayList(DisplayEntrySnapshot) {
        var snapshot = std.ArrayList(DisplayEntrySnapshot){};
        errdefer freeDisplayEntriesSnapshot(allocator, &snapshot);

        for (0..self.entries.items.len) |display_index| {
            const real_index = self.getRealIndexForDisplayPositionLocked(display_index) orelse continue;
            const entry = self.entries.items[real_index];
            const content_copy = try allocator.dupe(u8, entry.content);
            errdefer allocator.free(content_copy);

            try snapshot.append(allocator, .{
                .id = entry.id,
                .content = content_copy,
                .timestamp = entry.timestamp,
                .entry_type = entry.entry_type,
                .pinned = entry.pinned,
                .is_current = self.current_entry_id == entry.id,
            });
        }

        return snapshot;
    }

    pub fn freeDisplayEntriesSnapshot(allocator: std.mem.Allocator, snapshot: *std.ArrayList(DisplayEntrySnapshot)) void {
        for (snapshot.items) |entry| {
            entry.free(allocator);
        }
        snapshot.deinit(allocator);
    }

    fn getRealIndexForDisplayPositionLocked(self: *const ClipboardManager, display_index: usize) ?usize {
        if (display_index >= self.entries.items.len) return null;
        if (self.entries.items.len == 0) return null;

        const current_index = self.entries.items.len - 1;
        if (display_index == 0) return current_index;

        var display_cursor: usize = 1;
        var offset: usize = 1;
        while (offset <= current_index) : (offset += 1) {
            const real_index = current_index - offset;
            const entry = self.entries.items[real_index];
            if (entry.pinned) {
                if (display_cursor == display_index) return real_index;
                display_cursor += 1;
            }
        }

        offset = 1;
        while (offset <= current_index) : (offset += 1) {
            const real_index = current_index - offset;
            const entry = self.entries.items[real_index];
            if (!entry.pinned) {
                if (display_cursor == display_index) return real_index;
                display_cursor += 1;
            }
        }

        return null;
    }

    fn findOldestUnpinnedIndex(self: *const ClipboardManager) ?usize {
        return findOldestUnpinnedEntry(self.entries.items);
    }

    fn findOldestUnpinnedEntry(entries: []const ClipboardEntry) ?usize {
        for (entries, 0..) |entry, index| {
            if (!entry.pinned) {
                return index;
            }
        }
        return null;
    }

    fn findRealIndexByIdLocked(self: *ClipboardManager, entry_id: u64) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id == entry_id) {
                return index;
            }
        }
        return null;
    }

    fn clearCurrent(self: *ClipboardManager, revision: ?i64) bool {
        self.state_mutex.lock();
        const access = self.clipboard_access;
        if (access.revision(access.context) != revision) {
            self.state_mutex.unlock();
            return false;
        }
        const changed = self.current_entry_id != null;
        self.current_entry_id = null;
        self.state_mutex.unlock();
        if (changed) self.notifyEntriesChanged();
        return true;
    }

    /// One monitor iteration, also exercised by tests with a fake clipboard.
    /// No revision is acknowledged until capture completes successfully.
    fn captureOnce(self: *ClipboardManager, state: *CaptureState) !void {
        const access = self.clipboard_access;
        const revision = access.revision(access.context);
        if (revision != null and revision == state.acknowledged_revision) return;

        const content = access.read(access.context, self.allocator, self.config) catch |err| {
            if (!self.clearCurrent(revision)) return;
            if (err == error.NoClipboardContent) {
                state.acknowledged_revision = revision;
                state.failures = 0;
                return;
            }
            return err;
        };

        // Serialize the final revision check with selectEntry, which may have
        // changed the clipboard while this read was running.
        self.state_mutex.lock();
        if (access.revision(access.context) != revision) {
            self.state_mutex.unlock();
            if (content.type == .image and self.image_store.owns(content.content)) {
                self.image_store.delete(content.content) catch {};
            }
            self.allocator.free(content.content);
            return;
        }
        const changed = self.addEntryLocked(content) catch |err| {
            self.state_mutex.unlock();
            return err;
        };
        self.state_mutex.unlock();
        state.acknowledged_revision = revision;
        state.failures = 0;
        if (changed) self.notifyEntriesChanged();
    }

    fn monitorThread(self: *ClipboardManager) void {
        var state = CaptureState{};
        while (self.should_monitor.load(.acquire)) {
            const was_failing = state.failures != 0;
            self.captureOnce(&state) catch |err| {
                const revision = self.clipboard_access.revision(self.clipboard_access.context);
                if (state.failures == 0 or state.failed_revision != revision) {
                    self.reportError(err);
                    state.failures = 0;
                }
                state.failed_revision = revision;
                state.failures = @min(state.failures + 1, 20);
            };
            if (was_failing and state.failures == 0) {
                if (self.capture_recovered_callback) |callback| {
                    self.stdout_mutex.lock();
                    defer self.stdout_mutex.unlock();
                    callback(self);
                }
            }
            // Check the save deadline even when the clipboard is idle or failing.
            self.trySavePersistence();
            self.notifyPendingError();
            const delay_ms = @min(self.config.max_poll_interval, self.config.min_poll_interval + state.failures * 50);
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }

    pub fn startMonitoring(self: *ClipboardManager) !void {
        if (self.monitor_thread != null) return;

        self.should_monitor.store(true, .release);
        errdefer self.should_monitor.store(false, .release);
        self.monitor_thread = try std.Thread.spawn(.{}, monitorThread, .{self});
        std.debug.print("\nMonitoring clipboard in background...\n", .{});
        std.debug.print("> ", .{});
    }

    pub fn stopMonitoring(self: *ClipboardManager) void {
        if (self.monitor_thread) |thread| {
            std.debug.print("Signaling monitor thread to stop...\n", .{});
            self.should_monitor.store(false, .release);

            std.debug.print("Waiting for monitor thread to join...\n", .{});
            thread.join();
            self.monitor_thread = null;
            std.debug.print("Monitor thread stopped successfully.\n", .{});
        }
    }

    fn selectRealIndexLocked(self: *ClipboardManager, real_index: usize) !void {
        const entry = self.entries.items[real_index];
        const access = self.clipboard_access;
        try access.write(access.context, self.allocator, entry.content, entry.entry_type);
        _ = self.promoteEntryLocked(real_index);
    }

    pub fn selectEntry(self: *ClipboardManager, index: usize) !void {
        {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();

            if (index == 0 or index > self.entries.items.len) return error.InvalidIndex;

            const real_index = self.getRealIndexForDisplayPositionLocked(index - 1) orelse {
                return error.InvalidIndex;
            };
            try self.selectRealIndexLocked(real_index);
        }
        ui.printEntries(self);
    }

    pub fn selectEntryById(self: *ClipboardManager, entry_id: u64) !void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const real_index = self.findRealIndexByIdLocked(entry_id) orelse {
            return error.InvalidIndex;
        };
        try self.selectRealIndexLocked(real_index);
    }

    fn removeRealIndexLocked(self: *ClipboardManager, real_index: usize) void {
        const entry_to_remove = self.entries.orderedRemove(real_index);
        if (self.current_entry_id == entry_to_remove.id) self.current_entry_id = null;
        self.retireEntryLocked(entry_to_remove);

        // Force-save immediately for user-initiated deletions
        self.dirty_flag.store(true, .release);
        self.forceSavePersistenceLocked();
    }

    pub fn removeEntry(self: *ClipboardManager, index: usize) !void {
        {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();

            if (index == 0 or index > self.entries.items.len) return error.InvalidIndex;

            const real_index = self.getRealIndexForDisplayPositionLocked(index - 1) orelse {
                return error.InvalidIndex;
            };
            self.removeRealIndexLocked(real_index);
        }
        ui.printEntries(self);
    }

    pub fn removeEntryById(self: *ClipboardManager, entry_id: u64) !void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const real_index = self.findRealIndexByIdLocked(entry_id) orelse {
            return error.InvalidIndex;
        };
        self.removeRealIndexLocked(real_index);
    }

    fn togglePinnedRealIndexLocked(self: *ClipboardManager, real_index: usize) bool {
        self.entries.items[real_index].pinned = !self.entries.items[real_index].pinned;
        const pinned = self.entries.items[real_index].pinned;
        // Unpinning returns an item to the rolling history budget. Evict the
        // oldest unpinned item, but never the actual current clipboard entry.
        while (countUnpinned(self.entries.items) > self.max_entries) {
            var eviction_index: ?usize = null;
            for (self.entries.items, 0..) |entry, index| {
                if (!entry.pinned and self.current_entry_id != entry.id) {
                    eviction_index = index;
                    break;
                }
            }
            const index = eviction_index orelse break;
            self.retireEntryLocked(self.entries.orderedRemove(index));
        }

        self.dirty_flag.store(true, .release);
        self.forceSavePersistenceLocked();

        return pinned;
    }

    pub fn togglePinned(self: *ClipboardManager, index: usize) !bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        if (index == 0 or index > self.entries.items.len) {
            return error.InvalidIndex;
        }

        const real_index = self.getRealIndexForDisplayPositionLocked(index - 1) orelse {
            return error.InvalidIndex;
        };
        return self.togglePinnedRealIndexLocked(real_index);
    }

    pub fn togglePinnedById(self: *ClipboardManager, entry_id: u64) !bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        const real_index = self.findRealIndexByIdLocked(entry_id) orelse {
            return error.InvalidIndex;
        };
        return self.togglePinnedRealIndexLocked(real_index);
    }

    pub fn clearHistory(self: *ClipboardManager) !void {
        var removed_any = false;
        {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();

            // Keep the current clipboard entry and any pinned entries.
            if (self.entries.items.len == 0) return;

            var write_index: usize = 0;

            for (self.entries.items, 0..) |entry, read_index| {
                const should_keep = self.current_entry_id == entry.id or entry.pinned;
                if (should_keep) {
                    if (write_index != read_index) {
                        self.entries.items[write_index] = entry;
                    }
                    write_index += 1;
                    continue;
                }

                removed_any = true;
                self.retireEntryLocked(entry);
            }

            if (!removed_any) return;

            self.entries.items.len = write_index;

            // Force-save immediately for user-initiated clears
            self.dirty_flag.store(true, .release);
            self.forceSavePersistenceLocked();
        }

        ui.printEntries(self);
    }

    pub fn clean(self: *ClipboardManager) !void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        for (self.entries.items) |entry| {
            self.retireEntryLocked(entry);
        }

        self.entries.clearRetainingCapacity();
        self.current_entry_id = null;
        self.dirty_flag.store(true, .release);
        self.forceSavePersistenceLocked();
        if (self.dirty_flag.load(.acquire)) return error.HistorySaveFailed;
    }

    pub fn getPersistencePath(self: *const ClipboardManager) []const u8 {
        return self.persistence.getFilePath();
    }
};

fn noopEntriesChanged(_: *ClipboardManager) void {}

fn addTextEntry(allocator: std.mem.Allocator, clipboard_manager: *ClipboardManager, value: []const u8) !void {
    const content = try allocator.dupe(u8, value);
    try clipboard_manager.addEntry(.{
        .content = content,
        .type = .text,
    });
}

fn findSnapshotEntryByContent(entries: []const DisplayEntrySnapshot, value: []const u8) ?DisplayEntrySnapshot {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.content, value)) return entry;
    }
    return null;
}

const WriterContext = struct {
    allocator: std.mem.Allocator,
    clipboard_manager: *ClipboardManager,
};

fn writerThread(ctx: *WriterContext) void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const text = std.fmt.allocPrint(ctx.allocator, "thread-entry-{d}", .{i}) catch continue;
        defer ctx.allocator.free(text);
        addTextEntry(ctx.allocator, ctx.clipboard_manager, text) catch continue;
    }
}

test "removeEntryById removes the same entry after list reorders" {
    const allocator = std.testing.allocator;
    const persistence_path = try std.fmt.allocPrint(allocator, "/tmp/clipz-test-remove-{d}.json", .{std.time.nanoTimestamp()});
    defer allocator.free(persistence_path);
    std.fs.deleteFileAbsolute(persistence_path) catch {};
    defer std.fs.deleteFileAbsolute(persistence_path) catch {};

    var cfg = config.Config.default();
    cfg.batch_save_interval = 3600;
    cfg.max_entries = 20;

    var clipboard_manager = try ClipboardManager.initWithPersistencePath(allocator, cfg, persistence_path);
    defer clipboard_manager.deinit();
    clipboard_manager.entries_changed_callback = noopEntriesChanged;

    try addTextEntry(allocator, &clipboard_manager, "a");
    try addTextEntry(allocator, &clipboard_manager, "b");
    try addTextEntry(allocator, &clipboard_manager, "c");

    var before = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &before);

    const b_entry = findSnapshotEntryByContent(before.items, "b") orelse {
        try std.testing.expect(false);
        return;
    };
    const c_entry = findSnapshotEntryByContent(before.items, "c") orelse {
        try std.testing.expect(false);
        return;
    };

    // Reorder display positions by adding a newer entry.
    try addTextEntry(allocator, &clipboard_manager, "d");

    try clipboard_manager.removeEntryById(b_entry.id);

    var after = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &after);

    try std.testing.expect(findSnapshotEntryByContent(after.items, "b") == null);
    try std.testing.expect(findSnapshotEntryByContent(after.items, "c") != null);
    try std.testing.expect(findSnapshotEntryByContent(after.items, "d") != null);

    // Existing IDs stay stable.
    const c_after = findSnapshotEntryByContent(after.items, "c") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(c_entry.id, c_after.id);
}

test "stable IDs survive pinning and new entries" {
    const allocator = std.testing.allocator;
    const persistence_path = try std.fmt.allocPrint(allocator, "/tmp/clipz-test-id-stability-{d}.json", .{std.time.nanoTimestamp()});
    defer allocator.free(persistence_path);
    std.fs.deleteFileAbsolute(persistence_path) catch {};
    defer std.fs.deleteFileAbsolute(persistence_path) catch {};

    var cfg = config.Config.default();
    cfg.batch_save_interval = 3600;
    cfg.max_entries = 20;

    var clipboard_manager = try ClipboardManager.initWithPersistencePath(allocator, cfg, persistence_path);
    defer clipboard_manager.deinit();
    clipboard_manager.entries_changed_callback = noopEntriesChanged;

    try addTextEntry(allocator, &clipboard_manager, "a");
    try addTextEntry(allocator, &clipboard_manager, "b");
    try addTextEntry(allocator, &clipboard_manager, "c");

    var before = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &before);

    const a_before = findSnapshotEntryByContent(before.items, "a") orelse {
        try std.testing.expect(false);
        return;
    };
    const b_before = findSnapshotEntryByContent(before.items, "b") orelse {
        try std.testing.expect(false);
        return;
    };
    const c_before = findSnapshotEntryByContent(before.items, "c") orelse {
        try std.testing.expect(false);
        return;
    };

    const pinned = try clipboard_manager.togglePinnedById(a_before.id);
    try std.testing.expect(pinned);

    try addTextEntry(allocator, &clipboard_manager, "d");

    var after = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &after);

    const a_after = findSnapshotEntryByContent(after.items, "a") orelse {
        try std.testing.expect(false);
        return;
    };
    const b_after = findSnapshotEntryByContent(after.items, "b") orelse {
        try std.testing.expect(false);
        return;
    };
    const c_after = findSnapshotEntryByContent(after.items, "c") orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expect(a_after.pinned);
    try std.testing.expectEqual(a_before.id, a_after.id);
    try std.testing.expectEqual(b_before.id, b_after.id);
    try std.testing.expectEqual(c_before.id, c_after.id);
}

test "entry IDs are not reused after remove and re-add" {
    const allocator = std.testing.allocator;
    const persistence_path = try std.fmt.allocPrint(allocator, "/tmp/clipz-test-id-reuse-{d}.json", .{std.time.nanoTimestamp()});
    defer allocator.free(persistence_path);
    std.fs.deleteFileAbsolute(persistence_path) catch {};
    defer std.fs.deleteFileAbsolute(persistence_path) catch {};

    var cfg = config.Config.default();
    cfg.batch_save_interval = 3600;
    cfg.max_entries = 20;

    var clipboard_manager = try ClipboardManager.initWithPersistencePath(allocator, cfg, persistence_path);
    defer clipboard_manager.deinit();
    clipboard_manager.entries_changed_callback = noopEntriesChanged;

    try addTextEntry(allocator, &clipboard_manager, "same-content");

    var before = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &before);
    try std.testing.expectEqual(@as(usize, 1), before.items.len);
    const original_id = before.items[0].id;

    try clipboard_manager.removeEntryById(original_id);
    try addTextEntry(allocator, &clipboard_manager, "same-content");

    var after = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &after);
    try std.testing.expectEqual(@as(usize, 1), after.items.len);
    try std.testing.expect(after.items[0].id != original_id);
}

test "concurrent addEntry and snapshotDisplayEntries stay consistent" {
    const allocator = std.testing.allocator;
    const persistence_path = try std.fmt.allocPrint(allocator, "/tmp/clipz-test-concurrency-{d}.json", .{std.time.nanoTimestamp()});
    defer allocator.free(persistence_path);
    std.fs.deleteFileAbsolute(persistence_path) catch {};
    defer std.fs.deleteFileAbsolute(persistence_path) catch {};

    var cfg = config.Config.default();
    cfg.batch_save_interval = 3600;
    cfg.max_entries = 50;

    var clipboard_manager = try ClipboardManager.initWithPersistencePath(allocator, cfg, persistence_path);
    defer clipboard_manager.deinit();
    clipboard_manager.entries_changed_callback = noopEntriesChanged;

    var writer_ctx = WriterContext{
        .allocator = allocator,
        .clipboard_manager = &clipboard_manager,
    };
    const thread = try std.Thread.spawn(.{}, writerThread, .{&writer_ctx});

    var reads: usize = 0;
    while (reads < 120) : (reads += 1) {
        var snapshot = try clipboard_manager.snapshotDisplayEntries(allocator);
        ClipboardManager.freeDisplayEntriesSnapshot(allocator, &snapshot);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    thread.join();

    var final_snapshot = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(allocator, &final_snapshot);
    try std.testing.expect(final_snapshot.items.len <= cfg.max_entries);
    try std.testing.expect(final_snapshot.items.len > 0);
}

const TestHistory = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    manager: ClipboardManager,

    fn init(max_entries: usize) !TestHistory {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realpathAlloc(allocator, ".");
        defer allocator.free(dir);
        const path = try std.fs.path.join(allocator, &.{ dir, "history.json" });
        errdefer allocator.free(path);
        var cfg = config.Config.default();
        cfg.max_entries = max_entries;
        cfg.batch_save_interval = 3600;
        var history = try ClipboardManager.initWithPersistencePath(allocator, cfg, path);
        history.entries_changed_callback = noopEntriesChanged;
        return .{ .tmp = tmp, .path = path, .manager = history };
    }

    fn deinit(self: *TestHistory) void {
        self.manager.deinit();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn add(self: *TestHistory, content: []const u8) !void {
        try addTextEntry(std.testing.allocator, &self.manager, content);
    }
};

const FakeClipboard = struct {
    revision_value: i64 = 1,
    content: ?[]const u8 = "startup",
    fail_read: bool = false,
    fail_write: bool = false,
    change_during_read: bool = false,
    reads: usize = 0,

    fn access(self: *FakeClipboard) ClipboardAccess {
        return .{ .context = self, .revision = revision, .read = read, .write = write };
    }

    fn from(context: ?*anyopaque) *FakeClipboard {
        return @ptrCast(@alignCast(context.?));
    }

    fn revision(context: ?*anyopaque) ?i64 {
        return from(context).revision_value;
    }

    fn read(context: ?*anyopaque, allocator: std.mem.Allocator, _: config.Config) !clipboard.ClipboardContent {
        const self = from(context);
        self.reads += 1;
        if (self.fail_read) return error.CommandFailed;
        const content = self.content orelse return error.NoClipboardContent;
        if (self.change_during_read) self.revision_value += 1;
        return .{ .content = try allocator.dupe(u8, content), .type = .text };
    }

    fn write(context: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: clipboard.ClipboardType) !void {
        if (from(context).fail_write) return error.CommandFailed;
        from(context).revision_value += 1;
    }
};

test "recopy promotes an existing pinned entry without changing its identity" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    try history.add("a");
    const id = history.manager.current_entry_id.?;
    _ = try history.manager.togglePinnedById(id);
    try history.add("b");
    try history.add("a");

    var snapshot = try history.manager.snapshotDisplayEntries(std.testing.allocator);
    defer ClipboardManager.freeDisplayEntriesSnapshot(std.testing.allocator, &snapshot);
    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(id, snapshot.items[0].id);
    try std.testing.expect(snapshot.items[0].is_current);
    try std.testing.expect(snapshot.items[0].pinned);
    try std.testing.expect(!snapshot.items[1].is_current);
}

test "startup capture reads the existing clipboard and idle capture is skipped" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    var fake = FakeClipboard{};
    history.manager.clipboard_access = fake.access();
    var state = CaptureState{};
    try history.manager.captureOnce(&state);
    try history.manager.captureOnce(&state);
    try std.testing.expectEqual(@as(usize, 1), fake.reads);
    try std.testing.expectEqualStrings("startup", history.manager.entries.items[0].content);
    try std.testing.expectEqual(@as(?i64, 1), state.acknowledged_revision);
}

test "failed capture retries the same revision and empty clipboard clears current" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    var fake = FakeClipboard{ .fail_read = true };
    history.manager.clipboard_access = fake.access();
    var state = CaptureState{};
    try std.testing.expectError(error.CommandFailed, history.manager.captureOnce(&state));
    try std.testing.expectEqual(@as(?i64, null), state.acknowledged_revision);
    fake.fail_read = false;
    try history.manager.captureOnce(&state);
    try std.testing.expectEqual(@as(usize, 2), fake.reads);
    try std.testing.expect(history.manager.current_entry_id != null);

    fake.content = null;
    fake.revision_value += 1;
    try history.manager.captureOnce(&state);
    try std.testing.expectEqual(@as(?u64, null), history.manager.current_entry_id);
    try std.testing.expectEqual(@as(usize, 1), history.manager.entries.items.len);
}

test "a clipboard changing during capture is not acknowledged or stored" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    var fake = FakeClipboard{ .change_during_read = true };
    history.manager.clipboard_access = fake.access();
    var state = CaptureState{};
    try history.manager.captureOnce(&state);
    try std.testing.expectEqual(@as(usize, 0), history.manager.entries.items.len);
    try std.testing.expectEqual(@as(?i64, null), state.acknowledged_revision);
    fake.change_during_read = false;
    try history.manager.captureOnce(&state);
    try std.testing.expectEqual(@as(usize, 1), history.manager.entries.items.len);
}

test "pins do not consume the rolling history budget and survive reload" {
    var history = try TestHistory.init(2);
    defer history.deinit();
    try history.add("pinned-a");
    _ = try history.manager.togglePinnedById(history.manager.current_entry_id.?);
    try history.add("pinned-b");
    _ = try history.manager.togglePinnedById(history.manager.current_entry_id.?);
    try history.add("c");
    try history.add("d");
    try history.add("e");
    try history.manager.shutdown();

    var reloaded = try ClipboardManager.initWithPersistencePath(std.testing.allocator, history.manager.config, history.path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 4), reloaded.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), ClipboardManager.countUnpinned(reloaded.entries.items));
    // Persisted order is not proof of the current OS clipboard after a restart.
    try std.testing.expectEqual(@as(?u64, null), reloaded.current_entry_id);
    try std.testing.expectEqualStrings("e", reloaded.entries.items[3].content);
}

test "failed restore leaves current entry and order unchanged" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    try history.add("a");
    const a_id = history.manager.current_entry_id.?;
    try history.add("b");
    const b_id = history.manager.current_entry_id.?;
    var fake = FakeClipboard{ .fail_write = true };
    history.manager.clipboard_access = fake.access();
    try std.testing.expectError(error.CommandFailed, history.manager.selectEntryById(a_id));
    try std.testing.expectEqual(b_id, history.manager.current_entry_id.?);
    try std.testing.expectEqualStrings("b", history.manager.entries.items[1].content);
    fake.fail_write = false;
    try history.manager.selectEntryById(a_id);
    try std.testing.expectEqual(a_id, history.manager.current_entry_id.?);
}

test "failed save remains pending and successful shutdown persists the latest history" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    try history.add("a");
    try history.add("b");
    try std.testing.expect(history.manager.dirty_flag.load(.acquire));
    const working_persistence = history.manager.persistence;
    // A missing parent guarantees failure even when tests run with broad privileges.
    const broken_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/history.json", .{history.path});
    defer std.testing.allocator.free(broken_path);
    history.manager.persistence = try persistence.Persistence.initWithPath(broken_path);
    try std.testing.expectError(error.HistorySaveFailed, history.manager.shutdown());
    try std.testing.expect(history.manager.dirty_flag.load(.acquire));
    try std.testing.expectEqual(error.HistorySaveFailed, history.manager.takePendingError().?);
    history.manager.persistence = working_persistence;
    try history.manager.shutdown();
    try std.testing.expect(!history.manager.dirty_flag.load(.acquire));

    var reloaded = try ClipboardManager.initWithPersistencePath(std.testing.allocator, history.manager.config, history.path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.entries.items.len);
    try std.testing.expectEqualStrings("b", reloaded.entries.items[1].content);
}

test "removed images stay available until the history deletion is durable" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    var dir = try history.manager.image_store.open();
    defer dir.close();
    const filename = "clipz_123_ab.png";
    try dir.writeFile(.{ .sub_path = filename, .data = "retained image" });
    const path = try std.fs.path.join(std.testing.allocator, &.{ history.manager.image_store.root, filename });
    defer std.testing.allocator.free(path);
    try history.manager.addEntry(.{
        .content = try std.testing.allocator.dupe(u8, path),
        .type = .image,
    });
    const id = history.manager.current_entry_id.?;
    const working_persistence = history.manager.persistence;
    const broken_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/history.json", .{history.path});
    defer std.testing.allocator.free(broken_path);
    history.manager.persistence = try persistence.Persistence.initWithPath(broken_path);
    try history.manager.removeEntryById(id);
    try dir.access(filename, .{});
    try std.testing.expect(history.manager.dirty_flag.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), history.manager.pending_image_deletions.items.len);

    history.manager.persistence = working_persistence;
    try history.manager.shutdown();
    try std.testing.expectError(error.FileNotFound, dir.access(filename, .{}));
    var reloaded = try ClipboardManager.initWithPersistencePath(std.testing.allocator, history.manager.config, history.path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), reloaded.entries.items.len);
}

test "image dedup preserves distinct suffixes and promotes true duplicates" {
    var history = try TestHistory.init(10);
    defer history.deinit();
    var dir = try history.manager.image_store.open();
    defer dir.close();
    var bytes = [_]u8{42} ** 4096;
    const names = [_][]const u8{ "clipz_123_aa.png", "clipz_123_bb.png", "clipz_123_cc.png" };
    var first_id: u64 = 0;
    for (names, 0..) |name, index| {
        bytes[4095] = if (index == 1) 43 else 42;
        try dir.writeFile(.{ .sub_path = name, .data = &bytes });
        try history.manager.addEntry(.{
            .content = try std.fs.path.join(std.testing.allocator, &.{ history.manager.image_store.root, name }),
            .type = .image,
        });
        if (index == 0) first_id = history.manager.current_entry_id.?;
    }
    try std.testing.expectEqual(@as(usize, 2), history.manager.entries.items.len);
    try std.testing.expectEqual(first_id, history.manager.current_entry_id.?);
    try dir.access(names[0], .{});
    try dir.access(names[1], .{});
    try std.testing.expectError(error.FileNotFound, dir.access(names[2], .{}));
    try history.manager.shutdown();
    var reloaded = try ClipboardManager.initWithPersistencePath(std.testing.allocator, history.manager.config, history.path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.entries.items.len);
}
