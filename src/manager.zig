const std = @import("std");
const clipboard = @import("clipboard.zig");
const ui = @import("ui.zig");

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

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) ClipboardManager {
        return .{
            .entries = std.ArrayList(ClipboardEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
            .last_content = null,
        };
    }

    pub fn deinit(self: *ClipboardManager) void {
        self.stopMonitoring();
        for (self.entries.items) |entry| {
            entry.free(self.allocator);
        }
        self.entries.deinit();
        if (self.last_content) |content| {
            self.allocator.free(content);
        }
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

        const allocator = self.allocator;
        try clipboard.setContent(allocator, entry.content);

        const oldEntry = self.entries.orderedRemove(real_index);

        std.debug.print("Removed entry: {s}\n", .{oldEntry.content});

        try self.addEntry(entry.content);
    }

    pub fn clean(self: *ClipboardManager) !void {
        if (self.last_content) |last| {
            self.allocator.free(last);
        }

        self.entries.clearRetainingCapacity();
        self.last_content = null;
    }
};
