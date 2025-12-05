const std = @import("std");
const clipboard = @import("clipboard.zig");
const ui = @import("ui.zig");
const persistence = @import("persistence.zig");
const config = @import("config.zig");
const image_storage = @import("image_storage.zig");

pub const ClipboardManagerError = error{
    InvalidIndex,
};

pub const ClipboardEntry = struct {
    content: []const u8,
    timestamp: i64,
    entry_type: clipboard.ClipboardType,

    pub fn create(allocator: std.mem.Allocator, content: []const u8, entry_type: clipboard.ClipboardType) !ClipboardEntry {
        const content_copy = try allocator.dupe(u8, content);
        return ClipboardEntry{
            .content = content_copy,
            .timestamp = std.time.timestamp(),
            .entry_type = entry_type,
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

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) !ClipboardManager {
        var cfg = config.Config.default();
        cfg.max_entries = max_entries;
        return initWithConfig(allocator, cfg);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardManager {
        const pers = try persistence.Persistence.init(allocator);

        var manager = ClipboardManager{
            .entries = std.ArrayList(ClipboardEntry).init(allocator),
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
        std.time.sleep(100 * std.time.ns_per_ms);

        // Force save any pending changes
        self.forceSavePersistence();

        for (self.entries.items) |entry| {
            entry.free(self.allocator);
        }
        self.entries.deinit();
        if (self.last_content) |content| {
            self.allocator.free(content);
            self.last_content = null;
        }
    }

    fn loadFromPersistence(self: *ClipboardManager) !void {
        const loaded_entries = try self.persistence.loadEntries(self.allocator);
        defer loaded_entries.deinit();

        const start_index = if (loaded_entries.items.len > self.max_entries)
            loaded_entries.items.len - self.max_entries
        else
            0;

        for (loaded_entries.items[start_index..]) |entry| {
            const content_copy = try self.allocator.dupe(u8, entry.content);
            const new_entry = ClipboardEntry{
                .content = content_copy,
                .timestamp = entry.timestamp,
                .entry_type = entry.entry_type,
            };
            try self.entries.append(new_entry);
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
            const now = std.time.timestamp();
            // Check recent image entries (within last 30 seconds)
            for (self.entries.items) |existing_entry| {
                if (existing_entry.entry_type == .image and
                    image_storage.isTempImagePath(existing_entry.content) and
                    (now - existing_entry.timestamp) < 30)
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
            const oldest = self.entries.orderedRemove(0);
            oldest.free(self.allocator);
        }

        try self.entries.append(entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, entry.content);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistence();

        ui.printEntries(self);
        std.debug.print("> ", .{});
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

    fn monitorThread(self: *ClipboardManager) !void {
        var consecutive_failures: u32 = 0;
        var last_change_time: i64 = std.time.timestamp();
        var save_counter: u32 = 0;
        var last_image_add_time: i64 = 0;

        while (self.should_monitor.load(.acquire)) {
            const clipboard_content = clipboard.getContent(self.allocator) catch |err| switch (err) {
                clipboard.ClipboardError.NoClipboardContent => {
                    consecutive_failures += 1;
                    // Adaptive backoff: increase delay for consecutive failures
                    const delay_ms: u64 = @min(self.config.max_poll_interval, self.config.min_poll_interval + (consecutive_failures * 50));
                    std.time.sleep(delay_ms * std.time.ns_per_ms);
                    continue;
                },
                clipboard.ClipboardError.CommandFailed => {
                    consecutive_failures += 1;
                    const delay_ms: u64 = @min(self.config.max_poll_interval, self.config.min_poll_interval + (consecutive_failures * 50));
                    std.time.sleep(delay_ms * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            // Check if clipboard content has actually changed
            const now = std.time.timestamp();

            // For text: check if content matches last_content
            if (self.last_content) |last| {
                if (clipboard_content.type == .text and std.mem.eql(u8, last, clipboard_content.content)) {
                    // Same text content, skip
                    self.allocator.free(clipboard_content.content);
                    consecutive_failures = 0;
                    std.time.sleep(self.config.min_poll_interval * std.time.ns_per_ms);
                    continue;
                }
            }

            // For images: check if we just added an image very recently (within 5 seconds)
            // This prevents rapid-fire processing, but we'll still do content comparison in addEntry
            if (clipboard_content.type == .image) {
                if ((now - last_image_add_time) < 5) {
                    // Very recent image add, likely the same image still in clipboard
                    // But we'll still process it and let addEntry do the file comparison
                    // This ensures we catch it even if the cooldown expires
                }
            }

            try self.addEntry(clipboard_content);

            // Track when we last added an image
            if (clipboard_content.type == .image) {
                last_image_add_time = now;
            }
            consecutive_failures = 0; // Reset on success
            last_change_time = std.time.timestamp();

            // Adaptive sleep: longer delays when inactive (configurable)
            const time_since_change = std.time.timestamp() - last_change_time;
            const base_delay: u64 = if (time_since_change > self.config.inactive_threshold)
                self.config.max_poll_interval
            else
                self.config.min_poll_interval;

            // Split sleep for responsiveness and periodic saves
            var sleep_count: u32 = 0;
            const chunks = base_delay / 50;
            while (sleep_count < chunks and self.should_monitor.load(.acquire)) {
                std.time.sleep(50 * std.time.ns_per_ms);
                sleep_count += 1;
                save_counter += 1;

                // Attempt periodic save (configurable frequency)
                if (save_counter >= self.config.force_save_cycles) {
                    self.trySavePersistence();
                    save_counter = 0;
                }
            }
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
            std.time.sleep(100 * std.time.ns_per_ms);

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

        const real_index = self.entries.items.len - index;
        const entry = self.entries.items[real_index];

        try clipboard.setContent(self.allocator, entry.content);

        const selected_entry = self.entries.orderedRemove(real_index);
        try self.entries.append(selected_entry);

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

        const real_index = self.entries.items.len - index;
        const entry_to_remove = self.entries.orderedRemove(real_index);

        // Clean up image file if it's a temp image path
        if (entry_to_remove.entry_type == .image and image_storage.isTempImagePath(entry_to_remove.content)) {
            image_storage.deleteImageFile(entry_to_remove.content) catch {};
        }

        entry_to_remove.free(self.allocator);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistence();

        ui.printEntries(self);
    }

    pub fn clearHistory(self: *ClipboardManager) !void {
        // Keep only the most recent entry (current clipboard)
        if (self.entries.items.len <= 1) return; // Nothing to clear

        // Free all entries except the last one (most recent)
        for (self.entries.items[0 .. self.entries.items.len - 1]) |entry| {
            // Clean up image file if it's a temp image path
            if (entry.entry_type == .image and image_storage.isTempImagePath(entry.content)) {
                image_storage.deleteImageFile(entry.content) catch {};
            }
            entry.free(self.allocator);
        }

        // Keep only the last entry
        const current_entry = self.entries.items[self.entries.items.len - 1];
        self.entries.clearRetainingCapacity();
        try self.entries.append(current_entry);

        // Mark as dirty for batched persistence
        self.dirty_flag.store(true, .release);
        self.trySavePersistence();

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
