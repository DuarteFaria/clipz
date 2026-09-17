//! Native pasteboard change detection and Finder-compatible file restoration.
//! File references must be NSURL pasteboard objects, not AppleScript aliases
//! (which can publish only a filename/text representation).
const std = @import("std");
const builtin = @import("builtin");

const c = struct {
    const Object = *opaque {};
    const SEL = *opaque {};

    extern "c" fn objc_getClass(name: [*:0]const u8) ?Object;
    extern "c" fn sel_registerName(name: [*:0]const u8) ?SEL;
    extern "c" fn objc_msgSend() void;
    extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
    extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
};

const cc: @import("std").builtin.CallingConvention = .c;

fn class(name: [*:0]const u8) !c.Object {
    return c.objc_getClass(name) orelse error.PasteboardUnavailable;
}

// The runtime entry point is variadic, but each call must use its exact ABI.
// These helpers are limited to the object, scalar, and pointer arguments here.
fn send0(comptime Return: type, object: c.Object, selector: [*:0]const u8) Return {
    const send: *const fn (c.Object, c.SEL) callconv(cc) Return = @ptrCast(&c.objc_msgSend);
    return send(object, c.sel_registerName(selector).?);
}

fn send1(comptime Return: type, object: c.Object, selector: [*:0]const u8, arg: anytype) Return {
    const send: *const fn (c.Object, c.SEL, @TypeOf(arg)) callconv(cc) Return = @ptrCast(&c.objc_msgSend);
    return send(object, c.sel_registerName(selector).?, arg);
}

fn send2(comptime Return: type, object: c.Object, selector: [*:0]const u8, first: anytype, second: anytype) Return {
    const send: *const fn (c.Object, c.SEL, @TypeOf(first), @TypeOf(second)) callconv(cc) Return = @ptrCast(&c.objc_msgSend);
    return send(object, c.sel_registerName(selector).?, first, second);
}

fn string(value: []const u8) !c.Object {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPath;
    const terminated = try std.heap.page_allocator.dupeZ(u8, value);
    defer std.heap.page_allocator.free(terminated);
    return send1(?c.Object, try class("NSString"), "stringWithUTF8String:", terminated.ptr) orelse error.InvalidPath;
}

fn generalPasteboard() !c.Object {
    return send0(?c.Object, try class("NSPasteboard"), "generalPasteboard") orelse error.PasteboardUnavailable;
}

pub fn getChangeCount() ?i64 {
    if (builtin.os.tag != .macos) return null;
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const board = generalPasteboard() catch return null;
    return send0(i64, board, "changeCount");
}

/// Publish a file URL so Finder and other file-aware apps can paste the file.
/// URL construction handles spaces, Unicode, percent signs and directories.
pub fn setFilePath(path: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    try writeFileToPasteboard(try generalPasteboard(), path);
}

// Accept a pasteboard object so the exact production writer can be exercised on
// unique, isolated boards in tests without changing the user's clipboard.
fn writeFileToPasteboard(board: c.Object, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const native_path = try string(path);
    try std.fs.accessAbsolute(path, .{});
    const url = send1(?c.Object, try class("NSURL"), "fileURLWithPath:", native_path) orelse return error.InvalidPath;
    const objects = send1(?c.Object, try class("NSArray"), "arrayWithObject:", url) orelse return error.OutOfMemory;
    // Prepare and validate before clearing anything. writeObjects advertises
    // public.file-url; writing the path as NSString would only copy text.
    _ = send0(i64, board, "clearContents");
    if (!send1(bool, board, "writeObjects:", objects)) return error.ClipboardWriteFailed;
}

fn expectFileReference(board: c.Object, expected_path: []const u8) !void {
    const types = send0(?c.Object, board, "types") orelse return error.MissingPasteboardTypes;
    try std.testing.expect(send1(bool, types, "containsObject:", try string("public.file-url")));
    const url = send1(?c.Object, try class("NSURL"), "URLFromPasteboard:", board) orelse return error.MissingFileURL;
    try std.testing.expect(send0(bool, url, "isFileURL"));
    const path = send0(?c.Object, url, "path") orelse return error.MissingFilePath;
    const utf8 = send0(?[*:0]const u8, path, "UTF8String") orelse return error.InvalidPath;
    // macOS file URLs may canonically decompose Unicode filenames. Compare the
    // normalized spelling and the actual file identity, not raw UTF-8 bytes.
    const actual_normalized = send0(c.Object, path, "precomposedStringWithCanonicalMapping");
    const expected_normalized = send0(c.Object, try string(expected_path), "precomposedStringWithCanonicalMapping");
    try std.testing.expect(send1(bool, actual_normalized, "isEqualToString:", expected_normalized));
    const expected_stat = try std.fs.cwd().statFile(expected_path);
    const actual_stat = try std.fs.cwd().statFile(std.mem.span(utf8));
    try std.testing.expectEqual(expected_stat.inode, actual_stat.inode);
}

test "native file restoration survives file-text-file switching on an isolated pasteboard" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const name = "teachers % # é.csv";
    try tmp.dir.writeFile(.{ .sub_path = name, .data = "name\nTeacher\n" });
    const path = try tmp.dir.realpathAlloc(allocator, name);
    defer allocator.free(path);

    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const board = send0(?c.Object, try class("NSPasteboard"), "pasteboardWithUniqueName") orelse return error.PasteboardUnavailable;
    defer send0(void, board, "releaseGlobally");
    try writeFileToPasteboard(board, path);
    try expectFileReference(board, path);

    // A different history entry overwrites the file clipboard with text.
    _ = send0(i64, board, "clearContents");
    try std.testing.expect(send2(bool, board, "setString:forType:", try string("another history entry"), try string("public.utf8-plain-text")));
    const types = send0(?c.Object, board, "types") orelse return error.MissingPasteboardTypes;
    try std.testing.expect(!send1(bool, types, "containsObject:", try string("public.file-url")));

    try writeFileToPasteboard(board, path);
    try expectFileReference(board, path);
    const contents = try tmp.dir.readFileAlloc(allocator, name, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("name\nTeacher\n", contents);
}

test "native file restoration preserves folders and leaves the pasteboard unchanged on missing files" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("folder");
    const allocator = std.testing.allocator;
    const path = try tmp.dir.realpathAlloc(allocator, "folder");
    defer allocator.free(path);
    const missing = try std.fs.path.join(allocator, &.{ path, "missing.csv" });
    defer allocator.free(missing);

    const pool = c.objc_autoreleasePoolPush();
    defer c.objc_autoreleasePoolPop(pool);
    const board = send0(?c.Object, try class("NSPasteboard"), "pasteboardWithUniqueName") orelse return error.PasteboardUnavailable;
    defer send0(void, board, "releaseGlobally");
    try writeFileToPasteboard(board, path);
    try expectFileReference(board, path);
    const revision = send0(i64, board, "changeCount");
    try std.testing.expectError(error.FileNotFound, writeFileToPasteboard(board, missing));
    try std.testing.expectEqual(revision, send0(i64, board, "changeCount"));
    try expectFileReference(board, path);
}
