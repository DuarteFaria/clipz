const std = @import("std");

pub fn getArgs() !std.process.ArgIterator {
    const allocator = std.heap.page_allocator;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var argsArray = std.ArrayList(std.zig.String).init(allocator);
    defer argsArray.deinit();

    while(args.next()) |arg| {
        argsArray.addOne(arg);
    }

    return argsArray.toOwnedSlice();
}

pub fn main() !void {
	var args = try getArgs();
	defer args.deinit();

	std.debug.print("Args: {any}\n", .{args});
}
