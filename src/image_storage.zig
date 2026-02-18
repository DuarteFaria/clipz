const std = @import("std");
const builtin = @import("builtin");

pub const ImageStorageError = error{
    FailedToCreateDir,
    FailedToSaveImage,
    InvalidPath,
    UnsupportedPlatform,
};

const IMAGE_STORAGE_DIR = "/tmp/clipz_images";

pub fn getImageStoragePath() []const u8 {
    return IMAGE_STORAGE_DIR;
}

pub fn ensureImageDir() !void {
    switch (builtin.os.tag) {
        .macos, .linux => {
            std.fs.cwd().makePath(IMAGE_STORAGE_DIR) catch |err| switch (err) {
                error.AccessDenied => return ImageStorageError.FailedToCreateDir,
                else => return err,
            };
        },
        else => return ImageStorageError.UnsupportedPlatform,
    }
}

fn generateImageFilename(allocator: std.mem.Allocator, format: []const u8) ![]const u8 {
    const timestamp = std.time.timestamp();
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = prng.random().int(u64);

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
            try ensureImageDir();

            const filename = try generateImageFilename(allocator, format);
            defer allocator.free(filename);

            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ IMAGE_STORAGE_DIR, filename });
            errdefer allocator.free(file_path);

            // Use osascript to save clipboard image to file
            // First, determine the image format and save accordingly
            const script = try std.fmt.allocPrint(allocator,
                \\try
                \\  set imgData to the clipboard as «class PNGf»
                \\  set imgFile to open for access file POSIX file "{s}" with write permission
                \\  write imgData to imgFile
                \\  close access imgFile
                \\  return "success"
                \\on error
                \\  try
                \\    set imgData to the clipboard as JPEG picture
                \\    set imgFile to open for access file POSIX file "{s}" with write permission
                \\    write imgData to imgFile
                \\    close access imgFile
                \\    return "success"
                \\  on error
                \\    return "failed"
                \\  end try
                \\end try
            , .{ file_path, file_path });
            defer allocator.free(script);

            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "osascript", "-e", script },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.term.Exited != 0) {
                return ImageStorageError.FailedToSaveImage;
            }

            const output = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (!std.mem.eql(u8, output, "success")) {
                return ImageStorageError.FailedToSaveImage;
            }

            return file_path;
        },
        else => return ImageStorageError.UnsupportedPlatform,
    }
}

pub fn deleteImageFile(file_path: []const u8) !void {
    // Only delete files in our temp directory for safety
    if (!std.mem.startsWith(u8, file_path, IMAGE_STORAGE_DIR)) {
        return ImageStorageError.InvalidPath;
    }

    std.fs.cwd().deleteFile(file_path) catch |err| switch (err) {
        error.FileNotFound => {}, // File already deleted, that's fine
        else => return err,
    };
}

pub fn isTempImagePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, IMAGE_STORAGE_DIR);
}

pub fn compareImageFiles(file1_path: []const u8, file2_path: []const u8) !bool {
    // Compare two image files by size and first 1KB
    // This is a fast way to detect if images are likely the same
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

    // Compare first 1KB to quickly detect differences
    var buffer1: [1024]u8 = undefined;
    var buffer2: [1024]u8 = undefined;

    const read_size = @min(@min(stat1.size, 1024), stat2.size);

    const read1 = try file1.readAll(buffer1[0..read_size]);
    const read2 = try file2.readAll(buffer2[0..read_size]);

    if (read1 != read_size or read2 != read_size) return false;

    // If first 1KB matches and sizes match, they're likely the same image
    // (very unlikely for two different images to have same size and first 1KB)
    return std.mem.eql(u8, buffer1[0..read_size], buffer2[0..read_size]);
}
