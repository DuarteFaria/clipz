const std = @import("std");
const builtin = @import("builtin");

pub const ClipboardError = error{
    CommandFailed,
    NoClipboardContent,
    UnsupportedPlatform,
};

pub fn getContent(allocator: std.mem.Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{"pbpaste"},
                .max_output_bytes = 1024 * 1024, // 1MB max
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

            return result.stdout;
        },
        else => return ClipboardError.UnsupportedPlatform,
    }
}

pub fn setContent(allocator: std.mem.Allocator, content: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => {
       		const command = try std.fmt.allocPrint(allocator, "echo \"{s}\" | pbcopy", .{content});
         	defer allocator.free(command);

            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{command},
                .max_output_bytes = 1024 * 1024,
            });

            defer allocator.free(result.stderr);

            if (result.term.Exited != 0) {
                return ClipboardError.CommandFailed;
            }
        },
        else => return ClipboardError.UnsupportedPlatform,
    }
}
