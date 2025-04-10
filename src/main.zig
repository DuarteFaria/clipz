const std = @import("std");
const manager = @import("manager.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var clipboard_manager = manager.ClipboardManager.init(allocator, 10);
    defer clipboard_manager.deinit();

    try clipboard_manager.interactive();
}
