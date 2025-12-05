const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const image_storage = @import("image_storage.zig");

pub const ClipboardError = error{
    CommandFailed,
    NoClipboardContent,
    UnsupportedPlatform,
};

pub const ClipboardType = enum {
    text,
    image,
    file,
};

pub const ClipboardContent = struct {
    content: []const u8,
    type: ClipboardType,
};

pub fn getContent(allocator: std.mem.Allocator) !ClipboardContent {
    return getContentWithConfig(allocator, config.Config.default());
}

pub fn getContentWithConfig(allocator: std.mem.Allocator, cfg: config.Config) !ClipboardContent {
    switch (builtin.os.tag) {
        .macos => {
            // First, check what type of content is in the clipboard
            const clipboard_type = try getClipboardType(allocator);

            switch (clipboard_type) {
                .text => {
                    const result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "get the clipboard as text" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(result.stderr);

                    if (result.term.Exited != 0) {
                        allocator.free(result.stdout);
                        return ClipboardError.CommandFailed;
                    }

                    if (result.stdout.len == 0) {
                        allocator.free(result.stdout);
                        return ClipboardError.NoClipboardContent;
                    }

                    // Remove trailing newline if present
                    const content = if (result.stdout.len > 0 and result.stdout[result.stdout.len - 1] == '\n')
                        result.stdout[0 .. result.stdout.len - 1]
                    else
                        result.stdout;

                    // Reject content that's too large for storage
                    if (content.len > cfg.max_content_size) {
                        allocator.free(result.stdout);
                        return ClipboardError.NoClipboardContent; // Treat as no content
                    }

                    const final_content = try allocator.dupe(u8, content);
                    allocator.free(result.stdout);

                    return ClipboardContent{
                        .content = final_content,
                        .type = .text,
                    };
                },
                .image => {
                    // First try to get file path (for copied files)
                    const file_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "try\n    set fileURL to (get the clipboard as «class furl»)\n    return POSIX path of fileURL\non error\n    return \"no_file\"\nend try" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(file_result.stderr);
                    defer allocator.free(file_result.stdout);

                    if (file_result.term.Exited == 0) {
                        const file_content = std.mem.trim(u8, file_result.stdout, " \t\r\n");
                        if (!std.mem.eql(u8, file_content, "no_file")) {
                            // We have a file path, return it
                            const final_content = try allocator.dupe(u8, file_content);
                            return ClipboardContent{
                                .content = final_content,
                                .type = .image,
                            };
                        }
                    }

                    // No file path available. Try to get any text content that might be associated
                    const text_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "try\n    get the clipboard as text\non error\n    return \"no_text\"\nend try" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(text_result.stderr);
                    defer allocator.free(text_result.stdout);

                    // If we have meaningful text content, use that instead of generic image label
                    if (text_result.term.Exited == 0) {
                        const text_content = std.mem.trim(u8, text_result.stdout, " \t\r\n");
                        if (!std.mem.eql(u8, text_content, "no_text") and text_content.len > 0 and text_content.len < 200) {
                            // Check if it's not one of our own generated labels
                            if (!std.mem.startsWith(u8, text_content, "[📸")) {
                                const final_content = try allocator.dupe(u8, text_content);
                                return ClipboardContent{
                                    .content = final_content,
                                    .type = .text, // Treat as text since we have readable content
                                };
                            }
                        }
                    }

                    // Last resort: we know there's image data but can't get file path or meaningful text
                    // Get clipboard info to determine format, then save the image to temp storage
                    const info_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "get (clipboard info) as string" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(info_result.stderr);

                    if (info_result.term.Exited != 0) {
                        allocator.free(info_result.stdout);
                        return ClipboardError.CommandFailed;
                    }

                    if (info_result.stdout.len == 0) {
                        allocator.free(info_result.stdout);
                        return ClipboardError.NoClipboardContent;
                    }

                    const info_content = std.mem.trim(u8, info_result.stdout, " \t\r\n");
                    allocator.free(info_result.stdout);

                    // Determine format from clipboard info
                    var format: []const u8 = "PNG";
                    if (std.mem.indexOf(u8, info_content, "PNGf") != null) {
                        format = "PNG";
                    } else if (std.mem.indexOf(u8, info_content, "JPEG") != null) {
                        format = "JPEG";
                    } else if (std.mem.indexOf(u8, info_content, "TIFF") != null) {
                        format = "TIFF";
                    }

                    // Try to save the image to temp storage
                    const saved_path = image_storage.saveImageFromClipboard(allocator, format) catch {
                        // If saving fails, fall back to label
                        const format_label = if (std.mem.eql(u8, format, "PNG"))
                            "PNG Screenshot"
                        else if (std.mem.eql(u8, format, "JPEG"))
                            "JPEG Image"
                        else if (std.mem.eql(u8, format, "TIFF"))
                            "TIFF Image"
                        else
                            "Unknown Image";

                        const content = try std.fmt.allocPrint(allocator, "[📸 {s}]", .{format_label});
                        return ClipboardContent{
                            .content = content,
                            .type = .image,
                        };
                    };

                    return ClipboardContent{
                        .content = saved_path,
                        .type = .image,
                    };
                },
                .file => {
                    // First try to get file path (for copied files)
                    const file_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "try\n    set fileURL to (get the clipboard as «class furl»)\n    return POSIX path of fileURL\non error\n    return \"no_file\"\nend try" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(file_result.stderr);
                    defer allocator.free(file_result.stdout);

                    if (file_result.term.Exited == 0) {
                        const file_content = std.mem.trim(u8, file_result.stdout, " \t\r\n");
                        if (!std.mem.eql(u8, file_content, "no_file")) {
                            // We have a file path, return it
                            const final_content = try allocator.dupe(u8, file_content);
                            return ClipboardContent{
                                .content = final_content,
                                .type = .file,
                            };
                        }
                    }

                    // No file path available. Try to get any text content that might be associated
                    const text_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "try\n    get the clipboard as text\non error\n    return \"no_text\"\nend try" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(text_result.stderr);
                    defer allocator.free(text_result.stdout);

                    // Last resort: we know there's image data but can't get file path or meaningful text
                    // Get clipboard info to determine format, but be more specific
                    const info_result = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "osascript", "-e", "get (clipboard info) as string" },
                        .max_output_bytes = cfg.max_fetch_size,
                    });
                    defer allocator.free(info_result.stderr);

                    if (info_result.term.Exited != 0) {
                        allocator.free(info_result.stdout);
                        return ClipboardError.CommandFailed;
                    }

                    if (info_result.stdout.len == 0) {
                        allocator.free(info_result.stdout);
                        return ClipboardError.NoClipboardContent;
                    }

                    const info_content = std.mem.trim(u8, info_result.stdout, " \t\r\n");

                    // Determine format from clipboard info with more specific detection
                    var format: []const u8 = "Unknown File";
                    if (std.mem.indexOf(u8, info_content, "pdf") != null) {
                        format = "PDF Document";
                    } else if (std.mem.indexOf(u8, info_content, "docx") != null) {
                        format = "Word Document";
                    }

                    const content = try std.fmt.allocPrint(allocator, "[💾 {s}]", .{format});
                    allocator.free(info_result.stdout);

                    return ClipboardContent{
                        .content = content,
                        .type = .file,
                    };
                },
            }
        },
        else => return ClipboardError.UnsupportedPlatform,
    }
}

fn getClipboardType(allocator: std.mem.Allocator) !ClipboardType {
    // First try to actually get image data - this is the most reliable image indicator
    const image_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "osascript", "-e", "try\n    get the clipboard as «class PNGf»\n    return \"has_image\"\non error\n    try\n        get the clipboard as JPEG picture\n        return \"has_image\"\n    on error\n        return \"no_image\"\n    end try\nend try" },
    });
    defer allocator.free(image_result.stdout);
    defer allocator.free(image_result.stderr);

    if (image_result.term.Exited == 0) {
        const result = std.mem.trim(u8, image_result.stdout, " \t\r\n");
        if (std.mem.eql(u8, result, "has_image")) {
            return .image;
        }
    }

    // If no image data, try to get a file URL - but only if there's no actual image data
    // This is secondary because file URLs can be falsely detected for text content
    const file_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "osascript", "-e", "try\n    get the clipboard as «class furl»\n    return \"has_file\"\non error\n    return \"no_file\"\nend try" },
    });
    defer allocator.free(file_result.stdout);
    defer allocator.free(file_result.stderr);

    if (file_result.term.Exited == 0) {
        const result = std.mem.trim(u8, file_result.stdout, " \t\r\n");
        if (std.mem.eql(u8, result, "has_file")) {
            // Double-check that this is actually an image file by trying to get its path
            const path_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "osascript", "-e", "try\n    set fileURL to (get the clipboard as «class furl»)\n    return POSIX path of fileURL\non error\n    return \"no_path\"\nend try" },
            });
            defer allocator.free(path_result.stdout);
            defer allocator.free(path_result.stderr);

            if (path_result.term.Exited == 0) {
                const path_content = std.mem.trim(u8, path_result.stdout, " \t\r\n");
                // Only treat as image if it's a valid file path with an image extension
                if (!std.mem.eql(u8, path_content, "no_path") and isImagePath(path_content)) {
                    return .image;
                }
            }
        }
    }

    return .text;
}

fn escapeAppleScriptString(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var escaped = std.ArrayList(u8).init(allocator);
    errdefer escaped.deinit();

    for (content) |c| {
        switch (c) {
            '\\' => try escaped.appendSlice("\\\\"),
            '"' => try escaped.appendSlice("\\\""),
            '\n' => try escaped.appendSlice("\\n"),
            '\r' => try escaped.appendSlice("\\r"),
            '\t' => try escaped.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(escaped.writer(), "\\u{0:0>4}", .{c});
                } else {
                    try escaped.append(c);
                }
            },
        }
    }

    return try escaped.toOwnedSlice();
}

fn validateFilePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path.len > 1024) return false;

    for (path) |c| {
        if (c == 0) return false;
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') return false;
    }

    if (std.mem.indexOf(u8, path, "..") != null) return false;

    return true;
}

pub fn setContent(allocator: std.mem.Allocator, content: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => {
            // Check if this is a temp image path first
            if (image_storage.isTempImagePath(content)) {
                if (!validateFilePath(content)) {
                    return ClipboardError.CommandFailed;
                }

                const escaped_path = try escapeAppleScriptString(allocator, content);
                defer allocator.free(escaped_path);

                // Restore image from temp file
                const script = try std.fmt.allocPrint(allocator,
                    \\try
                    \\  set imgFile to POSIX file "{s}"
                    \\  set the clipboard to (read imgFile as picture)
                    \\on error
                    \\  return "failed"
                    \\end try
                , .{escaped_path});
                defer allocator.free(script);

                var child = std.process.Child.init(&[_][]const u8{ "osascript", "-e", script }, allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                const result = try child.wait();
                switch (result) {
                    .Exited => |code| {
                        if (code == 0) return;
                    },
                    else => {},
                }
                return ClipboardError.CommandFailed;
            }

            // Check if this is a complete image file path that we should restore as image
            if (isImagePath(content)) {
                if (!validateFilePath(content)) {
                    return ClipboardError.CommandFailed;
                }

                const escaped_path = try escapeAppleScriptString(allocator, content);
                defer allocator.free(escaped_path);

                // Only try to restore as image if it's a complete, absolute path
                // and the file actually exists
                const script = try std.fmt.allocPrint(allocator,
                    \\try
                    \\  set imgFile to POSIX file "{s}"
                    \\  -- Check if file exists before trying to read it
                    \\  set fileExists to false
                    \\  try
                    \\    get info for imgFile
                    \\    set fileExists to true
                    \\  end try
                    \\
                    \\  if fileExists then
                    \\    set the clipboard to (read imgFile as picture)
                    \\  else
                    \\    set the clipboard to "{s}"
                    \\  end if
                    \\on error
                    \\  set the clipboard to "{s}"
                    \\end try
                , .{ escaped_path, escaped_path, escaped_path });
                defer allocator.free(script);

                var child = std.process.Child.init(&[_][]const u8{ "osascript", "-e", script }, allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                const result = try child.wait();
                switch (result) {
                    .Exited => |code| {
                        if (code == 0) return;
                    },
                    else => {},
                }
            }

            // Set as text content - properly escape for AppleScript
            const escaped_content = try escapeAppleScriptString(allocator, content);
            defer allocator.free(escaped_content);

            const script = try std.fmt.allocPrint(allocator, "set the clipboard to \"{s}\"", .{escaped_content});
            defer allocator.free(script);

            var child = std.process.Child.init(&[_][]const u8{ "osascript", "-e", script }, allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            try child.spawn();
            const result = try child.wait();
            switch (result) {
                .Exited => |code| {
                    if (code != 0) {
                        return ClipboardError.CommandFailed;
                    }
                },
                else => return ClipboardError.CommandFailed,
            }
        },
        else => return ClipboardError.UnsupportedPlatform,
    }
}

fn isImagePath(content: []const u8) bool {
    // Don't process any content that starts with our image indicators
    if (std.mem.startsWith(u8, content, "[📸")) {
        return false;
    }

    // Validate file path first
    if (!validateFilePath(content)) {
        return false;
    }

    // Only process complete absolute paths that start with /Users/ or /Applications/ etc.
    // This prevents processing partial or corrupted paths
    if (content.len < 10 or content[0] != '/' or (!std.mem.startsWith(u8, content, "/Users/") and !std.mem.startsWith(u8, content, "/Applications/") and !std.mem.startsWith(u8, content, "/System/") and !std.mem.startsWith(u8, content, "/Library/"))) {
        return false;
    }

    // Additional path traversal check
    if (std.mem.indexOf(u8, content, "/../") != null or std.mem.indexOf(u8, content, "..") != null) {
        return false;
    }

    // Check for image file extensions
    const extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".webp", ".svg" };
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, content, ext)) {
            return true;
        }
    }

    return false;
}
