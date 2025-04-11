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

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) ClipboardManager {
        return .{
            .entries = std.ArrayList(ClipboardEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
            .last_content = null,
        };
    }

    pub fn deinit(self: *ClipboardManager) void {
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
    }

    pub fn getEntries(self: *const ClipboardManager) []const ClipboardEntry {
        return self.entries.items;
    }

    pub fn monitor(self: *ClipboardManager) !void {
        while (true) {
            const content = clipboard.getContent(self.allocator) catch |err| switch (err) {
                clipboard.ClipboardError.NoClipboardContent => continue,
                clipboard.ClipboardError.CommandFailed => continue,
                else => return err,
            };
            defer self.allocator.free(content);

            try self.addEntry(content);
            std.time.sleep(1 * std.time.ns_per_s); // Check every second
        }
    }

    pub fn getEntry(self: *const ClipboardManager, index: usize) ?*const ClipboardEntry {
        if (index == 0 or index > self.entries.items.len) return null;
        const real_index = self.entries.items.len - index;
        return &self.entries.items[real_index];
    }

    pub fn clean(self: *ClipboardManager) !void {
        if (self.last_content) |last| {
            self.allocator.free(last);
        }

        self.entries.clearRetainingCapacity();
        self.last_content = null;
    }
};
