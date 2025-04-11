const std = @import("std");

pub const Command = enum {
    get,
    get_index,
    set,
    exit,
    monitor,
    clear,
    unknown,

    pub fn fromString(str: []const u8) Command {
        if (std.mem.eql(u8, str, "get")) return .get;
        if (std.mem.startsWith(u8, str, "get ")) return .get_index;
        if (std.mem.eql(u8, str, "set")) return .set;
        if (std.mem.eql(u8, str, "exit")) return .exit;
        if (std.mem.eql(u8, str, "monitor")) return .monitor;
        if (std.mem.eql(u8, str, "clear")) return .clear;
        return .unknown;
    }
};
