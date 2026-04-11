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

pub const ClipboardManager = struct {
    entries: std.ArrayList(ClipboardEntry),
    allocator: std.mem.Allocator,
    max_entries: usize,
    next_entry_id: u64,
    last_content: ?[]const u8,
    state_mutex: std.Thread.Mutex = .{},
    monitor_thread: ?std.Thread = null,
    should_monitor: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    persistence: persistence.Persistence,
    // Batched persistence fields
    dirty_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_save_time: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // Configuration
    config: config.Config,
    // Callback for notifying when entries change (for JSON API)
    entries_changed_callback: ?*const fn (*ClipboardManager) void = null,
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
        var manager = ClipboardManager{
            .entries = .empty,
            .allocator = allocator,
            .max_entries = cfg.max_entries,
            .next_entry_id = 1,
            .last_content = null,
            .persistence = pers,
            .config = cfg,
        };

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
        if (self.last_content) |content| {
            self.allocator.free(content);
            self.last_content = null;
        }
    }

    fn loadFromPersistence(self: *ClipboardManager) !void {
        var loaded_result = try self.persistence.loadEntries(self.allocator);
        defer {
            for (loaded_result.entries.items) |entry| {
                entry.free(self.allocator);
            }
            loaded_result.entries.deinit(self.allocator);
        }

        while (loaded_result.entries.items.len > self.max_entries) {
            const eviction_index = findOldestUnpinnedEntry(loaded_result.entries.items) orelse 0;
            const removed = loaded_result.entries.orderedRemove(eviction_index);
            self.allocator.free(removed.content);
        }

        for (loaded_result.entries.items) |entry| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
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
    }

    fn saveToPersistenceLocked(self: *ClipboardManager) !void {
        try self.persistence.saveEntries(self.allocator, self.entries.items, self.next_entry_id);
    }

    pub fn addEntry(self: *ClipboardManager, clipboard_content: clipboard.ClipboardContent) !void {
        var entry_added = false;
        {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            entry_added = try self.addEntryLocked(clipboard_content);
        }

        if (!entry_added) return;

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
        // Check if content already exists in any entry
        for (self.entries.items) |existing_entry| {
            if (std.mem.eql(u8, existing_entry.content, clipboard_content.content) and
                existing_entry.entry_type == clipboard_content.type)
            {
                // Free the clipboard content since we're not using it
                self.allocator.free(clipboard_content.content);
                return false; // Don't add duplicate content
            }
        }

        // Special handling for images: check if we already have the same image
        // by comparing file contents (since file paths are always unique)
        if (clipboard_content.type == .image and image_storage.isTempImagePath(clipboard_content.content)) {
            for (self.entries.items) |existing_entry| {
                if (existing_entry.entry_type == .image and
                    image_storage.isTempImagePath(existing_entry.content))
                {
                    // Compare the image files to see if they're the same
                    if (image_storage.compareImageFiles(existing_entry.content, clipboard_content.content) catch false) {
                        // Same image, delete the new file and skip adding
                        image_storage.deleteImageFile(clipboard_content.content) catch {};
                        self.allocator.free(clipboard_content.content);
                        return false; // Don't add duplicate image
                    }
                }
            }
        }

        const entry = try ClipboardEntry.create(self.allocator, self.next_entry_id, clipboard_content.content, clipboard_content.type);
        // Free the original clipboard content since we made a copy
        self.allocator.free(clipboard_content.content);
        self.next_entry_id +%= 1;
        if (self.next_entry_id == 0) self.next_entry_id = 1;

        if (self.entries.items.len >= self.max_entries) {
            const eviction_index = self.findOldestUnpinnedIndex() orelse {
                // All entries are pinned, so we ignore the new clipboard item.
                if (entry.entry_type == .image and image_storage.isTempImagePath(entry.content)) {
                    image_storage.deleteImageFile(entry.content) catch {};
                }
                entry.free(self.allocator);
                return false;
            };

            const oldest = self.entries.orderedRemove(eviction_index);
            if (oldest.entry_type == .image and image_storage.isTempImagePath(oldest.content)) {
                image_storage.deleteImageFile(oldest.content) catch {};
            }
            oldest.free(self.allocator);
        }

        try self.entries.append(self.allocator, entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, entry.content);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistenceLocked();

        return true;
    }

    // Batched persistence - only save if dirty and enough time has passed
    fn trySavePersistenceLocked(self: *ClipboardManager) void {
        const now = std.time.timestamp();
        const last_save = self.last_save_time.load(.acquire);

        // Save if dirty and enough time has passed (configurable interval)
        if (self.dirty_flag.load(.acquire) and (now - last_save >= self.config.batch_save_interval)) {
            self.saveToPersistenceLocked() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
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
            self.saveToPersistenceLocked() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
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

            try snapshot.append(allocator, .{
                .id = entry.id,
                .content = content_copy,
                .timestamp = entry.timestamp,
                .entry_type = entry.entry_type,
                .pinned = entry.pinned,
                .is_current = display_index == 0,
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

    fn monitorThread(self: *ClipboardManager) !void {
        var consecutive_failures: u32 = 0;
        var save_counter: u32 = 0;
        var last_change_count: i64 = pasteboard.getChangeCount() orelse -1;

        while (self.should_monitor.load(.acquire)) {
            const current_change_count = pasteboard.getChangeCount() orelse -1;
            if (current_change_count == last_change_count and current_change_count != -1) {
                std.Thread.sleep(self.config.min_poll_interval * std.time.ns_per_ms);
                save_counter += 1;
                if (save_counter >= self.config.force_save_cycles) {
                    self.trySavePersistence();
                    save_counter = 0;
                }
                continue;
            }
            last_change_count = current_change_count;

            const clipboard_content = clipboard.getContent(self.allocator) catch |err| switch (err) {
                clipboard.ClipboardError.NoClipboardContent => {
                    consecutive_failures += 1;
                    const delay_ms: u64 = @min(self.config.max_poll_interval, self.config.min_poll_interval + (consecutive_failures * 50));
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    continue;
                },
                clipboard.ClipboardError.CommandFailed => {
                    consecutive_failures += 1;
                    const delay_ms: u64 = @min(self.config.max_poll_interval, self.config.min_poll_interval + (consecutive_failures * 50));
                    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            try self.addEntry(clipboard_content);
            consecutive_failures = 0;
            std.Thread.sleep(self.config.min_poll_interval * std.time.ns_per_ms);
        }
    }

    pub fn startMonitoring(self: *ClipboardManager) !void {
        if (self.monitor_thread != null) return;

        self.should_monitor.store(true, .release);
        self.monitor_thread = try std.Thread.spawn(.{}, monitorThread, .{self});
        std.debug.print("\nMonitoring clipboard in background...\n", .{});
        std.debug.print("> ", .{});
    }

    pub fn stopMonitoring(self: *ClipboardManager) void {
        if (self.monitor_thread) |thread| {
            std.debug.print("Signaling monitor thread to stop...\n", .{});
            self.should_monitor.store(false, .release);

            // Give the thread a moment to notice the signal
            std.Thread.sleep(100 * std.time.ns_per_ms);

            std.debug.print("Waiting for monitor thread to join...\n", .{});
            thread.join();
            self.monitor_thread = null;
            std.debug.print("Monitor thread stopped successfully.\n", .{});
        }
    }

    fn selectRealIndexLocked(self: *ClipboardManager, real_index: usize) !void {
        const entry = self.entries.items[real_index];
        try clipboard.setContentWithType(self.allocator, entry.content, entry.entry_type);

        const selected_entry = self.entries.orderedRemove(real_index);
        try self.entries.append(self.allocator, selected_entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, selected_entry.content);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistenceLocked();
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

        // Clean up image file if it is a temp image path
        if (entry_to_remove.entry_type == .image and image_storage.isTempImagePath(entry_to_remove.content)) {
            image_storage.deleteImageFile(entry_to_remove.content) catch {};
        }
        entry_to_remove.free(self.allocator);

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

        self.dirty_flag.store(true, .release);
        self.forceSavePersistenceLocked();

        return self.entries.items[real_index].pinned;
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

            const current_index = self.entries.items.len - 1;
            var write_index: usize = 0;

            for (self.entries.items, 0..) |entry, read_index| {
                const should_keep = read_index == current_index or entry.pinned;
                if (should_keep) {
                    if (write_index != read_index) {
                        self.entries.items[write_index] = entry;
                    }
                    write_index += 1;
                    continue;
                }

                removed_any = true;

                // Clean up image file if it's a temp image path
                if (entry.entry_type == .image and image_storage.isTempImagePath(entry.content)) {
                    image_storage.deleteImageFile(entry.content) catch {};
                }
                entry.free(self.allocator);
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

        if (self.last_content) |last| {
            self.allocator.free(last);
        }

        // Free memory for all entries and clean up image files
        for (self.entries.items) |entry| {
            // Clean up image file if it's a temp image path
            if (entry.entry_type == .image and image_storage.isTempImagePath(entry.content)) {
                image_storage.deleteImageFile(entry.content) catch {};
            }
            entry.free(self.allocator);
        }

        self.entries.clearRetainingCapacity();
        self.last_content = null;

        // Clear the persistence file completely
        self.persistence.clearPersistence() catch |err| {
            std.debug.print("Failed to clear persistence file: {}\n", .{err});
        };
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
