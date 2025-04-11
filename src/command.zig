const std = @import("std");

pub const Command = enum {
    get,
    get_index,
    exit,
    monitor,
    clear,
    help,
    unknown,

    pub fn fromString(str: []const u8) Command {
        if (std.mem.eql(u8, str, "get")) return .get;
        if (std.mem.startsWith(u8, str, "get ")) return .get_index;
        if (std.mem.eql(u8, str, "exit")) return .exit;
        if (std.mem.eql(u8, str, "monitor")) return .monitor;
        if (std.mem.eql(u8, str, "clear")) return .clear;
        if (std.mem.eql(u8, str, "help")) return .help;
        return .unknown;
    }
};
