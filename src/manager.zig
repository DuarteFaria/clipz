const std = @import("std");
const clipboard = @import("clipboard.zig");

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

    pub fn printEntries(self: *const ClipboardManager) void {
        std.debug.print("\nClipboard History ({d} entries):\n", .{self.entries.items.len});
        std.debug.print("----------------------------------------\n", .{});

        for (self.entries.items, 0..) |entry, i| {
            const reversed_index = self.entries.items.len - 1 - i;
            const timestamp = entry.timestamp;
            const now = std.time.timestamp();
            const age_secs = now - timestamp;

            std.debug.print("\nClip {d} (from {d}s ago):\n", .{ reversed_index + 1, age_secs });
            std.debug.print("{s}\n", .{entry.content});
        }
        std.debug.print("----------------------------------------\n", .{});
    }

    pub fn getEntry(self: *const ClipboardManager, index: usize) ?*const ClipboardEntry {
        if (index == 0 or index > self.entries.items.len) return null;
        const real_index = self.entries.items.len - index;
        return &self.entries.items[real_index];
    }

    pub fn interactive(self: *ClipboardManager) !void {
        const stdin = std.io.getStdIn();
        var buffer: [1024]u8 = undefined;

        std.debug.print("Clipboard Manager - Interactive Mode\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  get       - Show all clipboard entries\n", .{});
        std.debug.print("  get <n>   - Show specific clipboard entry\n", .{});
        std.debug.print("  monitor   - Start monitoring clipboard\n", .{});
        std.debug.print("  exit      - Exit the program\n\n", .{});

        while (true) {
            std.debug.print("> ", .{});
            if (try stdin.reader().readUntilDelimiterOrEof(buffer[0..], '\n')) |user_input| {
                const trimmed = std.mem.trim(u8, user_input, " \t\r\n");
                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit")) {
                    std.debug.print("Goodbye!\n", .{});
                    break;
                }

                if (std.mem.eql(u8, trimmed, "get")) {
                    self.printEntries();
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "monitor")) {
                    std.debug.print("\nStarting clipboard monitor (Ctrl+C to stop)...\n", .{});
                    try self.monitor();
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "get ")) {
                    const index_str = trimmed["get ".len..];
                    const index = std.fmt.parseInt(usize, index_str, 10) catch {
                        std.debug.print("Invalid index. Usage: get <number>\n", .{});
                        continue;
                    };

                    if (self.getEntry(index)) |entry| {
                        const now = std.time.timestamp();
                        const age_secs = now - entry.timestamp;
                        std.debug.print("\nClip {d} (from {d}s ago):\n", .{ index, age_secs });
                        std.debug.print("{s}\n", .{entry.content});
                    } else {
                        std.debug.print("No entry at index {d}\n", .{index});
                    }
                    continue;
                }

                std.debug.print("Unknown command. Available commands:\n", .{});
                std.debug.print("  get       - Show all clipboard entries\n", .{});
                std.debug.print("  get <n>   - Show specific clipboard entry\n", .{});
                std.debug.print("  monitor   - Start monitoring clipboard\n", .{});
                std.debug.print("  exit      - Exit the program\n", .{});
            }
        }
    }
};
