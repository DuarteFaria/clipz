const std = @import("std");

pub const Command = enum {
    get,
    set,
    unknown,

    pub fn fromString(str: []const u8) Command {
        if (std.mem.eql(u8, str, "get")) return .get;
        if (std.mem.eql(u8, str, "set")) return .set;
        return .unknown;
    }
};