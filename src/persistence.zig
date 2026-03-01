const std = @import("std");
const manager = @import("manager.zig");
const clipboard = @import("clipboard.zig");

pub const Persistence = struct {
    file_path: [256]u8,
    file_path_len: usize,

    pub fn init(allocator: std.mem.Allocator) !Persistence {
        const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home_dir);

        var file_path: [256]u8 = undefined;
        const file_path_slice = try std.fmt.bufPrint(&file_path, "{s}/.clipz_history.json", .{home_dir});

        return Persistence{
            .file_path = file_path,
            .file_path_len = file_path_slice.len,
        };
    }

    pub fn saveEntries(self: *Persistence, allocator: std.mem.Allocator, entries: []const manager.ClipboardEntry) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var json = std.ArrayList(u8){};
        var writer = json.writer(arena_allocator);

        try writer.writeAll("{\n");
        try writer.print("  \"version\": 2,\n", .{});
        try writer.print("  \"entries\": [\n", .{});

        for (entries, 0..) |entry, i| {
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"content\": \"");
            for (entry.content) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{0:0>4}", .{c}),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("\",\n");
            try writer.print("      \"timestamp\": {d},\n", .{entry.timestamp});
            try writer.print("      \"type\": \"{s}\"\n", .{@tagName(entry.entry_type)});

            if (i < entries.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }

        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");

        const file = try std.fs.cwd().createFile(self.getFilePath(), .{});
        defer file.close();

        try file.writeAll(json.items);
    }

    pub fn loadEntries(self: *Persistence, allocator: std.mem.Allocator) !std.ArrayList(manager.ClipboardEntry) {
        var entries = std.ArrayList(manager.ClipboardEntry){};

        const file = std.fs.cwd().openFile(self.getFilePath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return entries,
            else => return err,
        };
        defer file.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const content = try file.readToEndAlloc(arena_allocator, 10 * 1024 * 1024);

        // Try to parse JSON, but if it fails, return empty entries instead of crashing
        var parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, content, .{}) catch |err| {
            std.debug.print("Failed to parse JSON file: {}\n", .{err});
            return entries;
        };
        defer parsed.deinit();
        const root = parsed.value;

        const version = if (root.object.get("version")) |v| if (v == .integer) v.integer else 1 else 1;
        const entries_array = root.object.get("entries") orelse return entries;
        if (entries_array != .array) return error.InvalidFormat;

        for (entries_array.array.items) |item| {
            if (item != .object) continue;
            const content_field = item.object.get("content") orelse continue;
            const timestamp_field = item.object.get("timestamp") orelse continue;
            if (content_field != .string or timestamp_field != .integer) continue;

            const content_str = content_field.string;
            const timestamp = timestamp_field.integer;

            // Handle entry type - default to text for backward compatibility
            var entry_type: clipboard.ClipboardType = .text;
            if (version >= 2) {
                if (item.object.get("type")) |type_field| {
                    if (type_field == .string) {
                        const type_str = type_field.string;
                        if (std.mem.eql(u8, type_str, "image")) {
                            entry_type = .image;
                        } else if (std.mem.eql(u8, type_str, "file")) {
                            entry_type = .file;
                        } else if (std.mem.eql(u8, type_str, "url")) {
                            entry_type = .url;
                        } else if (std.mem.eql(u8, type_str, "color")) {
                            entry_type = .color;
                        } else {
                            entry_type = .text;
                        }
                    }
                }
            }

            const content_copy = try allocator.dupe(u8, content_str);
            const entry = manager.ClipboardEntry{
                .content = content_copy,
                .timestamp = timestamp,
                .entry_type = entry_type,
            };
            try entries.append(allocator, entry);
        }

        return entries;
    }

    pub fn clearPersistence(self: *Persistence) !void {
        // Delete the persistence file completely
        std.fs.cwd().deleteFile(self.getFilePath()) catch |err| switch (err) {
            error.FileNotFound => {}, // File doesn't exist, that's fine
            else => return err,
        };
    }

    pub fn getFilePath(self: *const Persistence) []const u8 {
        return self.file_path[0..self.file_path_len];
    }
};
