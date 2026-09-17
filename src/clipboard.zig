const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const image_storage = @import("image_storage.zig");

pub const ClipboardError = error{
    CommandFailed,
    NoClipboardContent,
    ContentTooLarge,
    InvalidPath,
    UnsupportedImageFormat,
    UnsupportedPlatform,
};

pub const ClipboardType = enum { text, image, file, url, color };

pub const ClipboardContent = struct {
    content: []const u8,
    type: ClipboardType,
};

// osascript appends one newline. Other whitespace belongs to the value.
fn scriptValue(output: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, output, "\n")) output[0 .. output.len - 1] else output;
}

fn checkExit(term: std.process.Child.Term) ClipboardError!void {
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn checkRestoreResult(term: std.process.Child.Term, output: []const u8) ClipboardError!void {
    try checkExit(term);
    if (!std.mem.eql(u8, scriptValue(output), "success")) return error.CommandFailed;
}

fn runScript(allocator: std.mem.Allocator, script: []const u8, max_output_bytes: usize) ![]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", script },
        .max_output_bytes = max_output_bytes,
    }) catch |err| switch (err) {
        error.StdoutStreamTooLong => return error.ContentTooLarge,
        else => return err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    try checkExit(result.term);
    return result.stdout;
}

pub fn getContent(allocator: std.mem.Allocator) !ClipboardContent {
    return getContentWithConfig(allocator, config.Config.default());
}

pub fn getContentWithConfig(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardContent {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    // Inspect advertised representations instead of coercing arbitrary text to
    // a file URL. Failed reads of an advertised type must remain capture errors.
    const type_output = try runScript(allocator,
        \\if (clipboard info) is {} then return "empty"
        \\if (clipboard info for «class furl») is not {} then return "file"
        \\if (clipboard info for «class PNGf») is not {} then return "PNG"
        \\if (clipboard info for JPEG picture) is not {} then return "JPEG"
        \\if (clipboard info for TIFF picture) is not {} then return "TIFF"
        \\return "text"
    , cfg.max_fetch_size);
    defer allocator.free(type_output);
    const format = scriptValue(type_output);
    if (std.mem.eql(u8, format, "empty")) return error.NoClipboardContent;
    if (std.mem.eql(u8, format, "file")) {
        const file_output = try runScript(allocator, "return POSIX path of (get the clipboard as «class furl»)", cfg.max_fetch_size);
        defer allocator.free(file_output);
        const path = scriptValue(file_output);
        if (path.len > cfg.max_content_size) return error.ContentTooLarge;
        try validateAsset(path, .file);
        return .{ .content = try allocator.dupe(u8, path), .type = .file };
    }

    if (!std.mem.eql(u8, format, "text")) {
        if (!std.mem.eql(u8, format, "PNG") and !std.mem.eql(u8, format, "JPEG") and
            !std.mem.eql(u8, format, "TIFF")) return error.UnsupportedImageFormat;
        // Never substitute labels or associated text for an image save failure.
        const saved_path = try image_storage.saveImageFromClipboard(allocator, format);
        errdefer allocator.free(saved_path);
        try validateAsset(saved_path, .image);
        if (saved_path.len > cfg.max_content_size) return error.ContentTooLarge;
        return .{ .content = saved_path, .type = .image };
    }

    const text_output = try runScript(allocator, "get the clipboard as text", cfg.max_fetch_size);
    defer allocator.free(text_output);
    return capturedText(allocator, text_output, cfg.max_content_size);
}

fn capturedText(allocator: std.mem.Allocator, output: []const u8, max_content_size: usize) !ClipboardContent {
    const content = scriptValue(output);
    if (content.len == 0) return error.NoClipboardContent;
    if (content.len > max_content_size) return error.ContentTooLarge;
    return .{
        .content = try allocator.dupe(u8, content),
        .type = if (isUrl(content)) .url else if (isColorValue(content)) .color else .text,
    };
}

fn escapeAppleScriptString(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var escaped = std.ArrayList(u8){};
    errdefer escaped.deinit(allocator);
    for (content) |c| {
        switch (c) {
            '\\' => try escaped.appendSlice(allocator, "\\\\"),
            '"' => try escaped.appendSlice(allocator, "\\\""),
            '\n' => try escaped.appendSlice(allocator, "\\n"),
            '\r' => try escaped.appendSlice(allocator, "\\r"),
            '\t' => try escaped.appendSlice(allocator, "\\t"),
            // AppleScript does not support JavaScript-style \u escapes.
            0...8, 11, 12, 14...31 => return error.InvalidCharacter,
            else => try escaped.append(allocator, c),
        }
    }
    return escaped.toOwnedSlice(allocator);
}

fn validateFilePath(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    for (path) |c| {
        if (c == 0 or (c < 0x20 and c != '\n' and c != '\r' and c != '\t')) return false;
    }
    // Reject traversal components, not legitimate filenames such as "v1..png".
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validateAsset(path: []const u8, entry_type: ClipboardType) !void {
    if (!validateFilePath(path)) return error.InvalidPath;
    // Finder can copy folders too. Image data must be a non-empty regular file;
    // the actual image decoder remains AppleScript.
    if (entry_type == .file) {
        try std.fs.accessAbsolute(path, .{});
    } else {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.kind != .file or stat.size == 0) return error.UnsupportedImageFormat;
    }
}

fn buildRestoreScript(allocator: std.mem.Allocator, content: []const u8, entry_type: ClipboardType) ![]const u8 {
    if ((entry_type == .image or entry_type == .file) and !validateFilePath(content))
        return error.InvalidPath;
    const escaped = try escapeAppleScriptString(allocator, content);
    defer allocator.free(escaped);
    // Let AppleScript errors escape: a text fallback is not a successful restore.
    return switch (entry_type) {
        .text, .url, .color => std.fmt.allocPrint(allocator,
            \\set the clipboard to "{s}"
            \\return "success"
        , .{escaped}),
        .file => std.fmt.allocPrint(allocator,
            \\set the clipboard to (POSIX file "{s}" as alias)
            \\return "success"
        , .{escaped}),
        .image => std.fmt.allocPrint(allocator,
            \\set imgFile to POSIX file "{s}"
            \\set the clipboard to (read imgFile as {s})
            \\return "success"
        , .{ escaped, imageClass(content) }),
    };
}

fn imageClass(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "«class PNGf»";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg"))
        return "JPEG picture";
    if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff"))
        return "TIFF picture";
    return "picture";
}

pub fn setContentWithType(allocator: std.mem.Allocator, content: []const u8, entry_type: ClipboardType) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    // The stored type is authoritative, even for paths in managed image storage.
    if (entry_type == .image or entry_type == .file) try validateAsset(content, entry_type);
    const script = try buildRestoreScript(allocator, content, entry_type);
    defer allocator.free(script);
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "osascript", "-e", script },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try checkRestoreResult(result.term, result.stdout);
}

fn isUrl(content: []const u8) bool {
    const prefixes = [_][]const u8{ "http://", "https://", "ftp://", "ftps://" };
    var has_prefix = false;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, content, prefix)) {
            has_prefix = true;
            break;
        }
    }
    if (!has_prefix) return false;
    for (content) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return false;
    }
    return true;
}

fn isColorValue(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '#') {
        const hex = trimmed[1..];
        if (hex.len != 3 and hex.len != 6 and hex.len != 8) return false;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }
    const prefixes = [_][]const u8{ "rgb(", "rgba(", "hsl(", "hsla(" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix) and trimmed[trimmed.len - 1] == ')') return true;
    }
    return false;
}

test "restore requires both normal exit and explicit success" {
    try checkRestoreResult(.{ .Exited = 0 }, "success\n");
    try std.testing.expectError(error.CommandFailed, checkRestoreResult(.{ .Exited = 0 }, "failed\n"));
    try std.testing.expectError(error.CommandFailed, checkRestoreResult(.{ .Exited = 0 }, ""));
    try std.testing.expectError(error.CommandFailed, checkRestoreResult(.{ .Exited = 1 }, "success\n"));
    try std.testing.expectError(error.CommandFailed, checkRestoreResult(.{ .Signal = 9 }, "success\n"));
    try std.testing.expectError(error.CommandFailed, checkExit(.{ .Stopped = 19 }));
    try std.testing.expectError(error.CommandFailed, checkExit(.{ .Unknown = 1 }));
}

test "typed restore scripts escape paths and never fall back to text" {
    const allocator = std.testing.allocator;
    for ([_]ClipboardType{ .text, .url, .color, .file, .image }) |entry_type| {
        const script = try buildRestoreScript(allocator, "/tmp/a\"b\\c\n.png", entry_type);
        defer allocator.free(script);
        try std.testing.expect(std.mem.indexOf(u8, script, "/tmp/a\\\"b\\\\c\\n.png") != null);
        try std.testing.expect(std.mem.endsWith(u8, script, "return \"success\""));
        try std.testing.expect(std.mem.indexOf(u8, script, "on error") == null);
        if (entry_type == .file or entry_type == .image)
            try std.testing.expect(std.mem.indexOf(u8, script, "set the clipboard to \"") == null);
        if (entry_type == .file)
            try std.testing.expect(std.mem.indexOf(u8, script, "as alias") != null);
    }
    try std.testing.expectError(error.InvalidPath, buildRestoreScript(allocator, "[📸 PNG Screenshot]", .image));
    try std.testing.expectError(error.InvalidPath, buildRestoreScript(allocator, "no_file", .file));
}

test "capture preserves text url color and distinguishes oversized from empty" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ContentTooLarge, capturedText(allocator, "long\n", 3));
    try std.testing.expectError(error.NoClipboardContent, capturedText(allocator, "\n", 3));
    const samples = [_][]const u8{ "text \n", "https://example.com", "#ff00ff" };
    const types = [_]ClipboardType{ .text, .url, .color };
    for (samples, types) |sample, expected_type| {
        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{sample});
        defer allocator.free(output);
        const captured = try capturedText(allocator, output, 1024);
        defer allocator.free(captured.content);
        try std.testing.expectEqualStrings(sample, captured.content);
        try std.testing.expectEqual(expected_type, captured.type);
    }
    try std.testing.expectEqualStrings("«class PNGf»", imageClass("/tmp/a.PNG"));
    try std.testing.expectEqualStrings("JPEG picture", imageClass("/tmp/a.jpeg"));
    try std.testing.expectEqualStrings("TIFF picture", imageClass("/tmp/a.tiff"));
}

test "asset validation accepts real paths and rejects absent or fake assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.. image", .data = "image bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "empty", .data = "" });
    const allocator = std.testing.allocator;
    const path = try tmp.dir.realpathAlloc(allocator, "a.. image");
    defer allocator.free(path);
    try validateAsset(path, .image);
    try validateAsset(path, .file);
    const empty = try tmp.dir.realpathAlloc(allocator, "empty");
    defer allocator.free(empty);
    try std.testing.expectError(error.UnsupportedImageFormat, validateAsset(empty, .image));
    try tmp.dir.deleteFile("a.. image");
    try std.testing.expectError(error.FileNotFound, validateAsset(path, .image));
    try std.testing.expectError(error.FileNotFound, validateAsset(path, .file));
    try std.testing.expectError(error.InvalidPath, validateAsset("[File]", .file));
    try std.testing.expect(!validateFilePath("/tmp/../image.png"));
    try std.testing.expect(!validateFilePath("/tmp/a\x00.png"));
    try std.testing.expect(validateFilePath("/Volumes/Drive/image.PNG"));
    try std.testing.expectEqualStrings("/tmp/a \n", scriptValue("/tmp/a \n\n"));
}
