const std = @import("std");
const builtin = @import("builtin");

pub const ImageStorageError = error{
    FailedToCreateDir,
    FailedToSaveImage,
    InvalidPath,
    UnsupportedPlatform,
};

pub fn imageDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library/Application Support/Clipz/images" });
}

/// The root is injectable; only direct children with Clipz-generated names are owned.
pub const ImageStore = struct {
    root: []const u8,

    pub fn owns(self: ImageStore, path: []const u8) bool {
        const parent = std.fs.path.dirname(path) orelse return false;
        if (!std.mem.eql(u8, parent, self.root)) return false;
        const name = std.fs.path.basename(path);
        if (!std.mem.startsWith(u8, name, "clipz_")) return false;
        const ext = std.fs.path.extension(name);
        if (!std.mem.eql(u8, ext, ".png") and !std.mem.eql(u8, ext, ".jpg") and !std.mem.eql(u8, ext, ".tiff")) return false;
        const stem = name[6 .. name.len - ext.len];
        const separator = std.mem.indexOfScalar(u8, stem, '_') orelse return false;
        if (separator == 0 or separator == stem.len - 1) return false;
        for (stem[0..separator]) |c| if (!std.ascii.isDigit(c)) return false;
        for (stem[separator + 1 ..]) |c| if (!std.ascii.isHex(c)) return false;
        return true;
    }

    pub fn open(self: ImageStore) !std.fs.Dir {
        try std.fs.cwd().makePath(self.root);
        var dir = try std.fs.cwd().openDir(self.root, .{ .no_follow = true });
        errdefer dir.close();
        const stat = try std.posix.fstat(dir.fd);
        if (stat.uid != std.posix.getuid()) return error.InvalidPath;
        try std.posix.fchmod(dir.fd, 0o700);
        return dir;
    }

    pub fn delete(self: ImageStore, path: []const u8) !void {
        if (!self.owns(path)) return error.InvalidPath;
        var dir = try self.open();
        defer dir.close();
        const name = std.fs.path.basename(path);
        const stat = std.posix.fstatat(dir.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (!std.posix.S.ISREG(stat.mode) or stat.uid != std.posix.getuid()) return error.InvalidPath;
        try dir.deleteFile(name);
    }

    /// Copy first; legacy files remain until (and after) history is durably saved.
    pub fn migrate(self: ImageStore, allocator: std.mem.Allocator, source: []const u8) ![]u8 {
        return self.migrateFrom(allocator, "/tmp/clipz_images", source);
    }

    /// The legacy root is injectable so tests never access the user's old captures.
    pub fn migrateFrom(self: ImageStore, allocator: std.mem.Allocator, legacy_root: []const u8, source: []const u8) ![]u8 {
        if (!(ImageStore{ .root = legacy_root }).owns(source)) return error.InvalidPath;
        var dir = try self.open();
        defer dir.close();
        const source_stat = try std.posix.fstatat(std.posix.AT.FDCWD, source, std.posix.AT.SYMLINK_NOFOLLOW);
        if (!std.posix.S.ISREG(source_stat.mode) or source_stat.uid != std.posix.getuid()) return error.InvalidPath;
        const input = std.fs.File{ .handle = try std.posix.open(source, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true }, 0) };
        defer input.close();
        const opened_stat = try std.posix.fstat(input.handle);
        if (!std.posix.S.ISREG(opened_stat.mode) or opened_stat.uid != std.posix.getuid()) return error.InvalidPath;
        // Older captures sometimes used an extension different from the bytes
        // written by their PNG/JPEG fallback. Normalize known image signatures.
        var signature: [8]u8 = undefined;
        const signature_len = try input.readAll(&signature);
        try input.seekTo(0);
        const format = imageFormat(signature[0..signature_len], source);
        const filename = try generateImageFilename(allocator, format);
        defer allocator.free(filename);
        const output = try dir.createFile(filename, .{ .exclusive = true, .mode = 0o600 });
        defer output.close();
        errdefer dir.deleteFile(filename) catch {};
        var buffer: [16384]u8 = undefined;
        while (true) {
            const n = try input.read(&buffer);
            if (n == 0) break;
            try output.writeAll(buffer[0..n]);
        }
        try output.sync();
        try std.posix.fsync(dir.fd);
        return std.fs.path.join(allocator, &.{ self.root, filename });
    }
};

fn imageFormat(signature: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, signature, "\x89PNG\r\n\x1a\n")) return "PNG";
    if (std.mem.startsWith(u8, signature, "\xff\xd8\xff")) return "JPEG";
    if (std.mem.startsWith(u8, signature, "II\x2a\x00") or std.mem.startsWith(u8, signature, "MM\x00\x2a")) return "TIFF";
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".jpg")) return "JPEG";
    if (std.mem.eql(u8, ext, ".tiff")) return "TIFF";
    return "PNG";
}

pub fn ensureImageDir() !void {
    const root = try imageDir(std.heap.page_allocator);
    defer std.heap.page_allocator.free(root);
    var dir = try (ImageStore{ .root = root }).open();
    dir.close();
}

fn generateImageFilename(allocator: std.mem.Allocator, format: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    const random = std.crypto.random.int(u64);

    const ext = if (std.mem.eql(u8, format, "PNG") or std.mem.eql(u8, format, "PNGf"))
        "png"
    else if (std.mem.eql(u8, format, "JPEG"))
        "jpg"
    else if (std.mem.eql(u8, format, "TIFF"))
        "tiff"
    else
        "png";

    return try std.fmt.allocPrint(allocator, "clipz_{d}_{x}.{s}", .{ timestamp, random, ext });
}

pub fn saveImageFromClipboard(allocator: std.mem.Allocator, format: []const u8) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            if (!std.mem.eql(u8, format, "PNG") and !std.mem.eql(u8, format, "JPEG") and
                !std.mem.eql(u8, format, "TIFF")) return error.FailedToSaveImage;
            try ensureImageDir();

            const filename = try generateImageFilename(allocator, format);
            defer allocator.free(filename);

            const root = try imageDir(allocator);
            defer allocator.free(root);
            const file_path = try std.fs.path.join(allocator, &.{ root, filename });
            errdefer allocator.free(file_path);
            const reserved = try std.fs.cwd().createFile(file_path, .{ .exclusive = true, .mode = 0o600 });
            defer reserved.close();
            errdefer std.fs.cwd().deleteFile(file_path) catch {};
            // Paths are passed as arguments rather than interpolated into AppleScript.

            // Read exactly the advertised representation. Never label JPEG/TIFF
            // bytes as PNG (or vice versa) after a fallback.
            const script =
                \\on run argv
                \\set imagePath to item 1 of argv
                \\set imageFormat to item 2 of argv
                \\if imageFormat is "PNG" then
                \\  set imgData to the clipboard as «class PNGf»
                \\else if imageFormat is "JPEG" then
                \\  set imgData to the clipboard as JPEG picture
                \\else if imageFormat is "TIFF" then
                \\  set imgData to the clipboard as TIFF picture
                \\else
                \\  error "Unsupported image format"
                \\end if
                \\set imgFile to open for access POSIX file imagePath with write permission
                \\try
                \\  set eof imgFile to 0
                \\  write imgData to imgFile
                \\on error errMsg number errNum
                \\  close access imgFile
                \\  error errMsg number errNum
                \\end try
                \\close access imgFile
                \\return "success"
                \\end run
            ;

            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "osascript", "-e", script, file_path, format },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.term != .Exited or result.term.Exited != 0) {
                return ImageStorageError.FailedToSaveImage;
            }

            const output = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (!std.mem.eql(u8, output, "success")) {
                return ImageStorageError.FailedToSaveImage;
            }

            if ((try reserved.stat()).size == 0) return ImageStorageError.FailedToSaveImage;
            try reserved.sync();
            var dir = try (ImageStore{ .root = root }).open();
            defer dir.close();
            try std.posix.fsync(dir.fd);
            return file_path;
        },
        else => return ImageStorageError.UnsupportedPlatform,
    }
}

pub fn isManagedImagePath(path: []const u8) bool {
    const root = imageDir(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(root);
    return (ImageStore{ .root = root }).owns(path);
}

pub fn deleteImageFile(file_path: []const u8) !void {
    const root = try imageDir(std.heap.page_allocator);
    defer std.heap.page_allocator.free(root);
    try (ImageStore{ .root = root }).delete(file_path);
}

pub fn isTempImagePath(path: []const u8) bool {
    return isManagedImagePath(path);
}

pub fn compareImageFiles(file1_path: []const u8, file2_path: []const u8) !bool {
    // Equality is byte-for-byte, not a prefix heuristic.
    const file1 = std.fs.cwd().openFile(file1_path, .{}) catch return false;
    defer file1.close();

    const file2 = std.fs.cwd().openFile(file2_path, .{}) catch return false;
    defer file2.close();

    const stat1 = try file1.stat();
    const stat2 = try file2.stat();

    // If sizes differ, they're different images
    if (stat1.size != stat2.size) return false;

    // If both files are empty, they're the same
    if (stat1.size == 0) return true;

    // Stream the entire file with bounded memory.
    var buffer1: [1024]u8 = undefined;
    var buffer2: [1024]u8 = undefined;

    while (true) {
        const n1 = try file1.readAll(&buffer1);
        const n2 = try file2.readAll(&buffer2);
        if (n1 != n2 or !std.mem.eql(u8, buffer1[0..n1], buffer2[0..n2])) return false;
        if (n1 == 0) return true;
    }
}

test "image equality compares beyond first kilobyte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const one = try std.fs.path.join(a, &.{ root, "one" });
    defer a.free(one);
    const two = try std.fs.path.join(a, &.{ root, "two" });
    defer a.free(two);
    var data = [_]u8{42} ** 4096;
    try tmp.dir.writeFile(.{ .sub_path = "one", .data = &data });
    try tmp.dir.writeFile(.{ .sub_path = "two", .data = &data });
    try std.testing.expect(try compareImageFiles(one, two));
    data[4095] = 43;
    try tmp.dir.writeFile(.{ .sub_path = "two", .data = &data });
    try std.testing.expect(!try compareImageFiles(one, two));
}

test "migration preserves image encoding even when legacy extension is wrong" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    try tmp.dir.makeDir("legacy");
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const legacy = try std.fs.path.join(allocator, &.{ root, "legacy" });
    defer allocator.free(legacy);
    const durable = try std.fs.path.join(allocator, &.{ root, "images" });
    defer allocator.free(durable);
    const store = ImageStore{ .root = durable };
    const samples = [_][]const u8{ "\x89PNG\r\n\x1a\npayload", "\xff\xd8\xffpayload", "II\x2a\x00payload" };
    const extensions = [_][]const u8{ ".png", ".jpg", ".tiff" };
    for (samples, extensions) |sample, extension| {
        // All legacy paths claim PNG regardless of the actual representation.
        try tmp.dir.writeFile(.{ .sub_path = "legacy/clipz_123_ab.png", .data = sample });
        const source = try std.fs.path.join(allocator, &.{ legacy, "clipz_123_ab.png" });
        defer allocator.free(source);
        const destination = try store.migrateFrom(allocator, legacy, source);
        defer allocator.free(destination);
        try std.testing.expect(std.mem.endsWith(u8, destination, extension));
        try std.testing.expect(try compareImageFiles(source, destination));
        const stat = try std.fs.cwd().statFile(destination);
        try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), stat.mode & 0o777);
    }
    const stat = try std.fs.cwd().statFile(durable);
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o700), stat.mode & 0o777);
}

test "image deletion rejects traversal unowned files and symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const store = ImageStore{ .root = root };
    const good = try std.fs.path.join(a, &.{ root, "clipz_123_ab.png" });
    defer a.free(good);
    try std.testing.expect(store.owns(good));
    try std.testing.expect(!store.owns("/tmp/clipz_images/../other"));
    const traversal = try std.fmt.allocPrint(a, "{s}/../clipz_123_ab.png", .{root});
    defer a.free(traversal);
    try std.testing.expectError(error.InvalidPath, store.delete(traversal));
    try tmp.dir.symLink("outside", "clipz_123_ab.png", .{});
    try std.testing.expectError(error.InvalidPath, store.delete(good));
    try tmp.dir.deleteFile("clipz_123_ab.png");
    try tmp.dir.writeFile(.{ .sub_path = "clipz_123_ab.png", .data = "image" });
    try store.delete(good);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("clipz_123_ab.png", .{}));
}
