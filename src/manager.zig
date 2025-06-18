const std = @import("std");
const clipboard = @import("clipboard.zig");
const ui = @import("ui.zig");
const persistence = @import("persistence.zig");

pub const ClipboardEntry = struct {
    content: []const u8,
    timestamp: i64,

    pub fn create(allocator: std.mem.Allocator, content: []const u8) !ClipboardEntry {
        const content_copy = try allocator.dupe(u8, content);
        return ClipboardEntry{
            .content = content_copy,
            .timestamp = std.time.timestamp(),
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

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) !ClipboardManager {
        const pers = try persistence.Persistence.init(allocator);

        var manager = ClipboardManager{
            .entries = std.ArrayList(ClipboardEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
            .last_content = null,
            .persistence = pers,
        };

        try manager.loadFromPersistence();

        return manager;
    }

    pub fn deinit(self: *ClipboardManager) void {
        self.stopMonitoring();
        std.time.sleep(100 * std.time.ns_per_ms);

        self.saveToPersistence() catch |err| {
            std.debug.print("Failed to save clipboard history: {}\n", .{err});
        };

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
        const loaded_entries = try self.persistence.loadEntries();
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
            };
            try self.entries.append(new_entry);
        }
    }

    fn saveToPersistence(self: *ClipboardManager) !void {
        try self.persistence.saveEntries(self.entries.items);
    }

    pub fn addEntry(self: *ClipboardManager, content: []const u8) !void {
        if (self.last_content) |last| {
            if (std.mem.eql(u8, last, content)) {
                return;
            }
        }

        const entry = try ClipboardEntry.create(self.allocator, content);

        if (self.entries.items.len >= self.max_entries) {
            const oldest = self.entries.orderedRemove(0);
            oldest.free(self.allocator);
        }

        try self.entries.append(entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, content);

        self.saveToPersistence() catch |err| {
            std.debug.print("Failed to save clipboard history: {}\n", .{err});
        };

        ui.printEntries(self);
        std.debug.print("> ", .{});
    }

    pub fn getEntries(self: *const ClipboardManager) []const ClipboardEntry {
        return self.entries.items;
    }

    fn monitorThread(self: *ClipboardManager) !void {
        while (self.should_monitor.load(.acquire)) {
            const content = clipboard.getContent(self.allocator) catch |err| switch (err) {
                clipboard.ClipboardError.NoClipboardContent => continue,
                clipboard.ClipboardError.CommandFailed => continue,
                else => return err,
            };
            defer self.allocator.free(content);

            try self.addEntry(content);
            std.time.sleep(1000 * std.time.ns_per_ms);
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
            self.should_monitor.store(false, .release);
            thread.join();
            self.monitor_thread = null;
            std.debug.print("> ", .{});
            std.debug.print("\nStopped monitoring clipboard.\n", .{});
        }
    }

    pub fn selectEntry(self: *ClipboardManager, index: usize) !void {
        if (index == 0 or index > self.entries.items.len) return;

        const real_index = self.entries.items.len - index;
        const entry = self.entries.items[real_index];

        try clipboard.setContent(entry.content);

        const selected_entry = self.entries.orderedRemove(real_index);
        try self.entries.append(selected_entry);

        if (self.last_content) |last| {
            self.allocator.free(last);
        }
        self.last_content = try self.allocator.dupe(u8, entry.content);

        self.saveToPersistence() catch |err| {
            std.debug.print("Failed to save clipboard history: {}\n", .{err});
        };

        ui.printEntries(self);
    }

    pub fn clean(self: *ClipboardManager) !void {
        if (self.last_content) |last| {
            self.allocator.free(last);
        }

        self.entries.clearRetainingCapacity();
        self.last_content = null;

        self.saveToPersistence() catch |err| {
            std.debug.print("Failed to save clipboard history: {}\n", .{err});
        };
    }

    pub fn getPersistencePath(self: *const ClipboardManager) []const u8 {
        return self.persistence.getFilePath();
    }
};
