const std = @import("std");

pub const Command = enum {
    get,
    get_index,
    exit,
    start,
    stop,
    clean,
    clear,
    help,
    path,
    unknown,

    pub fn fromString(str: []const u8) Command {
        if (std.mem.eql(u8, str, "get")) return .get;
        if (std.mem.startsWith(u8, str, "get ")) return .get_index;
        if (std.mem.eql(u8, str, "exit")) return .exit;
        if (std.mem.eql(u8, str, "start")) return .start;
        if (std.mem.eql(u8, str, "stop")) return .stop;
        if (std.mem.eql(u8, str, "clean")) return .clean;
        if (std.mem.eql(u8, str, "clear")) return .clear;
        if (std.mem.eql(u8, str, "help")) return .help;
        if (std.mem.eql(u8, str, "path")) return .path;
        return .unknown;
    }
};
