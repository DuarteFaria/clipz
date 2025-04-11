const std = @import("std");
const manager = @import("manager.zig");
const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var clipboard_manager = manager.ClipboardManager.init(allocator, 10);
    defer clipboard_manager.deinit();

    var clipboard_ui = ui.ClipboardUI.init(&clipboard_manager);
    try clipboard_ui.run();
}
