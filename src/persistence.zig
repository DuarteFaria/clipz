const std = @import("std");
const manager = @import("manager.zig");

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

    pub fn saveEntries(self: *Persistence, entries: []const manager.ClipboardEntry) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var json = std.ArrayList(u8).init(arena_allocator);
        var writer = json.writer();

        try writer.writeAll("{\n");
        try writer.print("  \"version\": 1,\n", .{});
        try writer.print("  \"entries\": [\n", .{});

        for (entries, 0..) |entry, i| {
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"content\": ");
            try std.json.encodeJsonString(entry.content, .{}, writer);
            try writer.writeAll(",\n");
            try writer.print("      \"timestamp\": {d}\n", .{entry.timestamp});

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

    pub fn loadEntries(self: *Persistence) !std.ArrayList(manager.ClipboardEntry) {
        var entries = std.ArrayList(manager.ClipboardEntry).init(std.heap.page_allocator);

        const file = std.fs.cwd().openFile(self.getFilePath(), .{}) catch |err| switch (err) {
            error.FileNotFound => return entries,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(std.heap.page_allocator, std.math.maxInt(usize));
        defer std.heap.page_allocator.free(content);

        // Try to parse JSON, but if it fails, return empty entries instead of crashing
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, content, .{}) catch |err| {
            std.debug.print("Failed to parse JSON file: {}\n", .{err});
            return entries;
        };
        defer parsed.deinit();
        const root = parsed.value;

        const entries_array = root.object.get("entries") orelse return entries;
        if (entries_array != .array) return error.InvalidFormat;

        for (entries_array.array.items) |item| {
            if (item != .object) continue;
            const content_field = item.object.get("content") orelse continue;
            const timestamp_field = item.object.get("timestamp") orelse continue;
            if (content_field != .string or timestamp_field != .integer) continue;
            const content_str = content_field.string;
            const timestamp = timestamp_field.integer;
            const content_copy = try std.heap.page_allocator.dupe(u8, content_str);
            const entry = manager.ClipboardEntry{
                .content = content_copy,
                .timestamp = timestamp,
            };
            try entries.append(entry);
        }

        return entries;
    }

    pub fn getFilePath(self: *const Persistence) []const u8 {
        return self.file_path[0..self.file_path_len];
    }
};
