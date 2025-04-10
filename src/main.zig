const std = @import("std");
const clipboard = @import("clipboard.zig");
const command = @import("command.zig");
const manager = @import("manager.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var clipboard_manager = manager.ClipboardManager.init(allocator, 10);
    defer clipboard_manager.deinit();

    const command_args = args[1..];

    if (command_args.len == 0) {
        std.debug.print("Starting clipboard manager...\n", .{});
        std.debug.print("Press Ctrl+C to exit\n\n", .{});

        try clipboard_manager.monitor();
        return;
    }

    const cmd = command.Command.fromString(command_args[0]);

    switch (cmd) {
        .get => {
            const content = clipboard.getContent(allocator) catch |err| {
                switch (err) {
                    clipboard.ClipboardError.CommandFailed => {
                        std.debug.print("Failed to get clipboard content\n", .{});
                        return;
                    },
                    clipboard.ClipboardError.NoClipboardContent => {
                        std.debug.print("Clipboard is empty\n", .{});
                        return;
                    },
                    clipboard.ClipboardError.UnsupportedPlatform => {
                        std.debug.print("Clipboard operations not supported on this platform\n", .{});
                        return;
                    },
                    else => return err,
                }
            };
            defer allocator.free(content);

            try clipboard_manager.addEntry(content);
            clipboard_manager.printEntries();
        },
        .set => {
            std.debug.print("Set command not implemented yet\n", .{});
        },
        .unknown => {
            std.debug.print("Unknown command: {s}\n", .{command_args[0]});
            std.debug.print("Available commands: get, set\n", .{});
        },
    }
}
