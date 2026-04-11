const std = @import("std");
const manager = @import("manager.zig");
const clipboard = @import("clipboard.zig");

pub const LoadResult = struct {
    entries: std.ArrayList(manager.ClipboardEntry),
    next_entry_id: u64,
};

fn hasEntryId(entries: []const manager.ClipboardEntry, entry_id: u64) bool {
    for (entries) |entry| {
        if (entry.id == entry_id) return true;
    }
    return false;
}

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

    pub fn initWithPath(path: []const u8) !Persistence {
        if (path.len > 256) return error.PathTooLong;

        var file_path: [256]u8 = undefined;
        std.mem.copyForwards(u8, file_path[0..path.len], path);

        return Persistence{
            .file_path = file_path,
            .file_path_len = path.len,
        };
    }

    pub fn saveEntries(self: *Persistence, allocator: std.mem.Allocator, entries: []const manager.ClipboardEntry, next_entry_id: u64) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var json = std.ArrayList(u8){};
        var writer = json.writer(arena_allocator);

        try writer.writeAll("{\n");
        try writer.print("  \"version\": 4,\n", .{});
        try writer.print("  \"next_id\": {d},\n", .{next_entry_id});
        try writer.print("  \"entries\": [\n", .{});

        for (entries, 0..) |entry, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"id\": {d},\n", .{entry.id});
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
            try writer.print("      \"type\": \"{s}\",\n", .{@tagName(entry.entry_type)});
            try writer.print("      \"pinned\": {s}\n", .{if (entry.pinned) "true" else "false"});

            if (i < entries.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }

        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");

        const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{self.getFilePath()});
        defer allocator.free(temp_path);
        errdefer std.fs.cwd().deleteFile(temp_path) catch {};

        {
            const file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true, .read = true });
            defer file.close();

            std.posix.fchmod(file.handle, 0o600) catch {};

            try file.writeAll(json.items);
            try file.sync();
        }

        try std.posix.rename(temp_path, self.getFilePath());
    }

    pub fn loadEntries(self: *Persistence, allocator: std.mem.Allocator) !LoadResult {
        var entries = std.ArrayList(manager.ClipboardEntry){};
        errdefer {
            for (entries.items) |entry| {
                entry.free(allocator);
            }
            entries.deinit(allocator);
        }
        var next_entry_id: u64 = 1;

        const file = std.fs.cwd().openFile(self.getFilePath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return .{ .entries = entries, .next_entry_id = next_entry_id },
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
            return .{ .entries = entries, .next_entry_id = next_entry_id };
        };
        defer parsed.deinit();
        const root = parsed.value;

        if (root != .object) {
            return .{ .entries = entries, .next_entry_id = next_entry_id };
        }

        const version = if (root.object.get("version")) |v| if (v == .integer) v.integer else 1 else 1;
        const entries_array = root.object.get("entries") orelse return .{ .entries = entries, .next_entry_id = next_entry_id };
        if (entries_array != .array) return .{ .entries = entries, .next_entry_id = next_entry_id };

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

            var pinned = false;
            if (version >= 3) {
                if (item.object.get("pinned")) |pinned_field| {
                    if (pinned_field == .bool) {
                        pinned = pinned_field.bool;
                    }
                }
            }

            var entry_id = next_entry_id;
            if (version >= 4) {
                if (item.object.get("id")) |id_field| {
                    if (id_field == .integer and id_field.integer > 0) {
                        entry_id = std.math.cast(u64, id_field.integer) orelse next_entry_id;
                    }
                }
            }
            if (entry_id == 0) entry_id = next_entry_id;
            while (hasEntryId(entries.items, entry_id)) {
                entry_id = next_entry_id;
                next_entry_id +%= 1;
                if (next_entry_id == 0) next_entry_id = 1;
            }

            const content_copy = try allocator.dupe(u8, content_str);
            const entry = manager.ClipboardEntry{
                .id = entry_id,
                .content = content_copy,
                .timestamp = timestamp,
                .entry_type = entry_type,
                .pinned = pinned,
            };
            try entries.append(allocator, entry);

            if (entry_id >= next_entry_id) {
                next_entry_id = entry_id +% 1;
                if (next_entry_id == 0) next_entry_id = 1;
            }
        }

        if (version >= 4) {
            if (root.object.get("next_id")) |next_id_field| {
                if (next_id_field == .integer and next_id_field.integer > 0) {
                    const parsed_next_id = std.math.cast(u64, next_id_field.integer) orelse next_entry_id;
                    if (parsed_next_id > next_entry_id) {
                        next_entry_id = parsed_next_id;
                    }
                }
            }
        }

        return .{
            .entries = entries,
            .next_entry_id = next_entry_id,
        };
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
