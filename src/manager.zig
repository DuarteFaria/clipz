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
    content: []const u8,
    timestamp: i64,
    entry_type: clipboard.ClipboardType,
    pinned: bool = false,

    pub fn create(allocator: std.mem.Allocator, content: []const u8, entry_type: clipboard.ClipboardType) !ClipboardEntry {
        const content_copy = try allocator.dupe(u8, content);
        return ClipboardEntry{
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

pub const ClipboardManager = struct {
    entries: std.ArrayList(ClipboardEntry),
    allocator: std.mem.Allocator,
    max_entries: usize,
    last_content: ?[]const u8,
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

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) !ClipboardManager {
        var cfg = config.Config.default();
        cfg.max_entries = max_entries;
        return initWithConfig(allocator, cfg);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardManager {
        const pers = try persistence.Persistence.init(allocator);

        var manager = ClipboardManager{
            .entries = .empty,
            .allocator = allocator,
            .max_entries = cfg.max_entries,
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
        var loaded_entries = try self.persistence.loadEntries(self.allocator);
        defer loaded_entries.deinit(self.allocator);

        while (loaded_entries.items.len > self.max_entries) {
            const eviction_index = findOldestUnpinnedEntry(loaded_entries.items) orelse 0;
            const removed = loaded_entries.orderedRemove(eviction_index);
            self.allocator.free(removed.content);
        }

        for (loaded_entries.items) |entry| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
            const new_entry = ClipboardEntry{
                .content = content_copy,
                .timestamp = entry.timestamp,
                .entry_type = entry.entry_type,
                .pinned = entry.pinned,
            };
            try self.entries.append(self.allocator, new_entry);
        }
    }

    fn saveToPersistence(self: *ClipboardManager) !void {
        try self.persistence.saveEntries(self.allocator, self.entries.items);
    }

    pub fn addEntry(self: *ClipboardManager, clipboard_content: clipboard.ClipboardContent) !void {
        // Check if content already exists in any entry
        for (self.entries.items) |existing_entry| {
            if (std.mem.eql(u8, existing_entry.content, clipboard_content.content) and
                existing_entry.entry_type == clipboard_content.type)
            {
                // Free the clipboard content since we're not using it
                self.allocator.free(clipboard_content.content);
                return; // Don't add duplicate content
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
                        return; // Don't add duplicate image
                    }
                }
            }
        }

        const entry = try ClipboardEntry.create(self.allocator, clipboard_content.content, clipboard_content.type);
        // Free the original clipboard content since we made a copy
        self.allocator.free(clipboard_content.content);

        if (self.entries.items.len >= self.max_entries) {
            const eviction_index = self.findOldestUnpinnedIndex() orelse {
                // All entries are pinned, so we ignore the new clipboard item.
                if (entry.entry_type == .image and image_storage.isTempImagePath(entry.content)) {
                    image_storage.deleteImageFile(entry.content) catch {};
                }
                entry.free(self.allocator);
                return;
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
        self.trySavePersistence();

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

    // Batched persistence - only save if dirty and enough time has passed
    fn trySavePersistence(self: *ClipboardManager) void {
        const now = std.time.timestamp();
        const last_save = self.last_save_time.load(.acquire);

        // Save if dirty and enough time has passed (configurable interval)
        if (self.dirty_flag.load(.acquire) and (now - last_save >= self.config.batch_save_interval)) {
            self.saveToPersistence() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
                return;
            };
            self.dirty_flag.store(false, .release);
            self.last_save_time.store(now, .release);
        }
    }

    // Force save (for shutdown)
    fn forceSavePersistence(self: *ClipboardManager) void {
        if (self.dirty_flag.load(.acquire)) {
            self.saveToPersistence() catch |err| {
                std.debug.print("Failed to save clipboard history: {}\n", .{err});
            };
            self.dirty_flag.store(false, .release);
            self.last_save_time.store(std.time.timestamp(), .release);
        }
    }

    pub fn getEntries(self: *const ClipboardManager) []const ClipboardEntry {
        return self.entries.items;
    }

    pub fn getDisplayEntry(self: *const ClipboardManager, display_index: usize) ?ClipboardEntry {
        const real_index = self.getRealIndexForDisplayPosition(display_index) orelse return null;
        return self.entries.items[real_index];
    }

    pub fn getDisplayCount(self: *const ClipboardManager) usize {
        return self.entries.items.len;
    }

    fn getRealIndexForDisplayPosition(self: *const ClipboardManager, display_index: usize) ?usize {
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

            if (self.last_content) |last| {
                if (std.mem.eql(u8, last, clipboard_content.content)) {
                    self.allocator.free(clipboard_content.content);
                    consecutive_failures = 0;
                    std.Thread.sleep(self.config.min_poll_interval * std.time.ns_per_ms);
                    continue;
                }

                // For images saved to temp files, paths are always unique so compare file contents
                if (clipboard_content.type == .image and
                    image_storage.isTempImagePath(clipboard_content.content) and
                    image_storage.isTempImagePath(last))
                {
                    if (image_storage.compareImageFiles(last, clipboard_content.content) catch false) {
                        image_storage.deleteImageFile(clipboard_content.content) catch {};
                        self.allocator.free(clipboard_content.content);
                        consecutive_failures = 0;
                        std.Thread.sleep(self.config.min_poll_interval * std.time.ns_per_ms);
                        continue;
                    }
                }
            }

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

    pub fn selectEntry(self: *ClipboardManager, index: usize) !void {
        if (index == 0 or index > self.entries.items.len) {
            return error.InvalidIndex;
        }

        const real_index = self.getRealIndexForDisplayPosition(index - 1) orelse {
            return error.InvalidIndex;
        };
        const entry = self.entries.items[real_index];

        try clipboard.setContentWithType(self.allocator, entry.content, entry.entry_type);

        const selected_entry = self.entries.orderedRemove(real_index);
        try self.entries.append(self.allocator, selected_entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, entry.content);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistence();

        ui.printEntries(self);
    }

    pub fn removeEntry(self: *ClipboardManager, index: usize) !void {
        if (index == 0 or index > self.entries.items.len) {
            return error.InvalidIndex;
        }

        const real_index = self.getRealIndexForDisplayPosition(index - 1) orelse {
            return error.InvalidIndex;
        };
        const entry_to_remove = self.entries.orderedRemove(real_index);

        // Clean up image file if it's a temp image path
        if (entry_to_remove.entry_type == .image and image_storage.isTempImagePath(entry_to_remove.content)) {
            image_storage.deleteImageFile(entry_to_remove.content) catch {};
        }

        entry_to_remove.free(self.allocator);

        // Force-save immediately for user-initiated deletions
        self.dirty_flag.store(true, .release);
        self.forceSavePersistence();

        ui.printEntries(self);
    }

    pub fn togglePinned(self: *ClipboardManager, index: usize) !bool {
        if (index == 0 or index > self.entries.items.len) {
            return error.InvalidIndex;
        }

        const real_index = self.getRealIndexForDisplayPosition(index - 1) orelse {
            return error.InvalidIndex;
        };
        self.entries.items[real_index].pinned = !self.entries.items[real_index].pinned;

        self.dirty_flag.store(true, .release);
        self.forceSavePersistence();

        return self.entries.items[real_index].pinned;
    }

    pub fn clearHistory(self: *ClipboardManager) !void {
        // Keep the current clipboard entry and any pinned entries.
        if (self.entries.items.len == 0) return;

        const current_index = self.entries.items.len - 1;
        var write_index: usize = 0;
        var removed_any = false;

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
        self.forceSavePersistence();

        ui.printEntries(self);
    }

    pub fn clean(self: *ClipboardManager) !void {
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
