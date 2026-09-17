const std = @import("std");
const manager = @import("manager.zig");
const clipboard = @import("clipboard.zig");
const image_storage = @import("image_storage.zig");

pub const LoadResult = struct {
    entries: std.ArrayList(manager.ClipboardEntry),
    next_entry_id: u64,
    recovered_corrupt_history: bool = false,
    needs_save: bool = false,
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
    production_images: bool = false,
    legacy_image_root: []const u8 = "/tmp/clipz_images",
    save_blocked: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Persistence {
        const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home_dir);

        var file_path: [256]u8 = undefined;
        const file_path_slice = try std.fmt.bufPrint(&file_path, "{s}/.clipz_history.json", .{home_dir});

        return Persistence{
            .file_path = file_path,
            .file_path_len = file_path_slice.len,
            .production_images = true,
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
        if (self.save_blocked) return error.HistoryRecoveryRequired;
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
                    0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
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

        const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp-{x}", .{ self.getFilePath(), std.crypto.random.int(u64) });
        defer allocator.free(temp_path);
        errdefer std.fs.cwd().deleteFile(temp_path) catch {};

        {
            const file = try std.fs.cwd().createFile(temp_path, .{ .exclusive = true, .mode = 0o600 });
            defer file.close();

            try std.posix.fchmod(file.handle, 0o600);

            try file.writeAll(json.items);
            try file.sync();
        }

        try std.posix.rename(temp_path, self.getFilePath());
        var parent = try std.fs.cwd().openDir(std.fs.path.dirname(self.getFilePath()) orelse ".", .{});
        defer parent.close();
        try std.posix.fsync(parent.fd);
    }

    fn quarantine(self: *Persistence, allocator: std.mem.Allocator) !LoadResult {
        const path = try std.fmt.allocPrint(allocator, "{s}.corrupt-{x}", .{ self.getFilePath(), std.crypto.random.int(u64) });
        defer allocator.free(path);
        try std.posix.rename(self.getFilePath(), path);
        var parent = try std.fs.cwd().openDir(std.fs.path.dirname(self.getFilePath()) orelse ".", .{});
        defer parent.close();
        try std.posix.fsync(parent.fd);
        std.debug.print("Clipz: corrupt history preserved at {s}; starting with empty history.\n", .{path});
        return .{ .entries = .{}, .next_entry_id = 1, .recovered_corrupt_history = true };
    }

    pub fn loadEntries(self: *Persistence, allocator: std.mem.Allocator) !LoadResult {
        // If loading fails, preserve the on-disk history even if a caller keeps running.
        errdefer self.save_blocked = true;
        var entries = std.ArrayList(manager.ClipboardEntry){};
        errdefer {
            for (entries.items) |entry| {
                entry.free(allocator);
            }
            entries.deinit(allocator);
        }
        var next_entry_id: u64 = 1;
        var needs_save = false;

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
            if (err == error.OutOfMemory) return err;
            std.debug.print("Failed to parse JSON file: {}\n", .{err});
            return try self.quarantine(allocator);
        };
        defer parsed.deinit();
        const root = parsed.value;

        if (root != .object) {
            return try self.quarantine(allocator);
        }

        const version = if (root.object.get("version")) |v| if (v == .integer) v.integer else 1 else 1;
        if (version < 1 or version > 4) return error.UnsupportedHistoryVersion;
        if (root.object.get("version")) |v| {
            if (v != .integer) return try self.quarantine(allocator);
        }
        const entries_array = root.object.get("entries") orelse return try self.quarantine(allocator);
        if (entries_array != .array) return try self.quarantine(allocator);
        // Validate before constructing entries; do not silently discard malformed records.
        for (entries_array.array.items) |item| {
            if (item != .object) return try self.quarantine(allocator);
            const c = item.object.get("content") orelse return try self.quarantine(allocator);
            const t = item.object.get("timestamp") orelse return try self.quarantine(allocator);
            if (c != .string or t != .integer) return try self.quarantine(allocator);
            if (item.object.get("type")) |entry_type| {
                if (entry_type != .string or std.meta.stringToEnum(clipboard.ClipboardType, entry_type.string) == null)
                    return try self.quarantine(allocator);
            }
            if (item.object.get("pinned")) |pinned| {
                if (pinned != .bool) return try self.quarantine(allocator);
            }
        }

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

            var content_copy = try allocator.dupe(u8, content_str);
            errdefer allocator.free(content_copy);
            if (entry_type == .image and (image_storage.ImageStore{ .root = self.legacy_image_root }).owns(content_str)) {
                const root_path = try self.imageRoot(allocator);
                defer allocator.free(root_path);
                const migrated = (image_storage.ImageStore{ .root = root_path }).migrateFrom(allocator, self.legacy_image_root, content_str) catch |err| blk: {
                    if (err == error.OutOfMemory) return err;
                    std.debug.print("Clipz: could not migrate image {s}: {}\n", .{ content_str, err });
                    break :blk null;
                };
                if (migrated) |path| {
                    allocator.free(content_copy);
                    content_copy = path;
                    needs_save = true;
                }
            }
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
            .needs_save = needs_save,
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

    pub fn imageRoot(self: *const Persistence, allocator: std.mem.Allocator) ![]u8 {
        return if (self.production_images)
            image_storage.imageDir(allocator)
        else
            std.fs.path.join(allocator, &.{ std.fs.path.dirname(self.getFilePath()) orelse ".", "images" });
    }
};

test "control bytes round trip and atomic history is private" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "history.json" });
    defer a.free(path);
    var p = try Persistence.initWithPath(path);
    var controls: [32]u8 = undefined;
    for (&controls, 0..) |*c, i| c.* = @intCast(i);
    const entries = [_]manager.ClipboardEntry{.{
        .id = 42,
        .content = &controls,
        .timestamp = 1234,
        .entry_type = .text,
        .pinned = true,
    }};
    try p.saveEntries(a, &entries, 43);
    var loaded = try p.loadEntries(a);
    defer {
        for (loaded.entries.items) |e| e.free(a);
        loaded.entries.deinit(a);
    }
    try std.testing.expectEqualSlices(u8, &controls, loaded.entries.items[0].content);
    try std.testing.expectEqual(@as(u64, 42), loaded.entries.items[0].id);
    const stat = try tmp.dir.statFile("history.json");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
}

test "corrupt history is quarantined and missing images retained" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "history.json" });
    defer a.free(path);
    var p = try Persistence.initWithPath(path);
    try tmp.dir.writeFile(.{ .sub_path = "history.json", .data = "{broken" });
    var recovered = try p.loadEntries(a);
    defer recovered.entries.deinit(a);
    try std.testing.expect(recovered.recovered_corrupt_history);
    var iterator = tmp.dir.iterate();
    var found = false;
    while (try iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "history.json.corrupt-")) {
            const content = try tmp.dir.readFileAlloc(a, entry.name, 100);
            defer a.free(content);
            try std.testing.expectEqualStrings("{broken", content);
            found = true;
        }
    }
    try std.testing.expect(found);
    const valid_history =
        \\{"version":4,"entries":[{"id":1,"content":"/missing/image.png","timestamp":1,"type":"image"}]}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "history.json", .data = valid_history });
    var loaded = try p.loadEntries(a);
    defer {
        for (loaded.entries.items) |e| e.free(a);
        loaded.entries.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("/missing/image.png", loaded.entries.items[0].content);
}

test "legacy migration copies bytes retains source and persists durable path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    try tmp.dir.makeDir("legacy");
    const legacy = try std.fs.path.join(a, &.{ root, "legacy" });
    defer a.free(legacy);
    const source = try std.fs.path.join(a, &.{ legacy, "clipz_123_ab.png" });
    defer a.free(source);
    try tmp.dir.writeFile(.{ .sub_path = "legacy/clipz_123_ab.png", .data = "image bytes" });
    const history = try std.fs.path.join(a, &.{ root, "history.json" });
    defer a.free(history);
    var p = try Persistence.initWithPath(history);
    p.legacy_image_root = legacy;
    const entries = [_]manager.ClipboardEntry{.{
        .id = 1,
        .content = source,
        .timestamp = 1,
        .entry_type = .image,
    }};
    try p.saveEntries(a, &entries, 2);
    var loaded = try p.loadEntries(a);
    defer {
        for (loaded.entries.items) |e| e.free(a);
        loaded.entries.deinit(a);
    }
    try std.testing.expect(loaded.needs_save);
    try std.testing.expect(try image_storage.compareImageFiles(source, loaded.entries.items[0].content));
    try tmp.dir.access("legacy/clipz_123_ab.png", .{});
    try p.saveEntries(a, loaded.entries.items, loaded.next_entry_id);
    var reloaded = try p.loadEntries(a);
    defer {
        for (reloaded.entries.items) |e| e.free(a);
        reloaded.entries.deinit(a);
    }
    try std.testing.expect(!reloaded.needs_save);
    try std.testing.expectEqualStrings(loaded.entries.items[0].content, reloaded.entries.items[0].content);
}

test "failed history load blocks saves rather than overwriting recovery data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "history.json" });
    defer a.free(path);
    const future = "{\"version\":99,\"entries\":[]}";
    try tmp.dir.writeFile(.{ .sub_path = "history.json", .data = future });
    var p = try Persistence.initWithPath(path);
    try std.testing.expectError(error.UnsupportedHistoryVersion, p.loadEntries(a));
    try std.testing.expectError(error.HistoryRecoveryRequired, p.saveEntries(a, &.{}, 1));
    const unchanged = try tmp.dir.readFileAlloc(a, "history.json", 1024);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(future, unchanged);
}

test "missing legacy images remain in history without marking migration complete" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const source = try std.fs.path.join(a, &.{ root, "clipz_123_ab.png" });
    defer a.free(source);
    const path = try std.fs.path.join(a, &.{ root, "history.json" });
    defer a.free(path);
    var p = try Persistence.initWithPath(path);
    p.legacy_image_root = root;
    const entries = [_]manager.ClipboardEntry{.{ .id = 1, .content = source, .timestamp = 1, .entry_type = .image }};
    try p.saveEntries(a, &entries, 2);
    var loaded = try p.loadEntries(a);
    defer {
        for (loaded.entries.items) |e| e.free(a);
        loaded.entries.deinit(a);
    }
    try std.testing.expect(!loaded.needs_save);
    try std.testing.expectEqualStrings(source, loaded.entries.items[0].content);
}
