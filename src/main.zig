const std = @import("std");
const manager = @import("manager.zig");
const ui = @import("ui.zig");

const c = @cImport({
    @cInclude("signal.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var clipboard_manager = try manager.ClipboardManager.init(allocator, 10);
    defer clipboard_manager.deinit();

    // Parse command line arguments
    const mode = parseArguments(args) catch |err| {
        printUsage();
        return err;
    };

    switch (mode) {
        .cli => {
            var clipboard_ui = ui.ClipboardUI.init(&clipboard_manager);
            try clipboard_ui.run();
        },
        .json_api => {
            // JSON API mode for Electron communication
            try runJsonApi(allocator, &clipboard_manager);
        },
    }
}

const RunMode = enum {
    cli,
    json_api,
};

fn parseArguments(args: []const []const u8) !RunMode {
    if (args.len == 1) {
        return .cli; // Default to CLI mode
    }

    const flag = args[1];
    if (std.mem.eql(u8, flag, "--json-api") or std.mem.eql(u8, flag, "-j")) {
        return .json_api;
    } else if (std.mem.eql(u8, flag, "--cli") or std.mem.eql(u8, flag, "-c")) {
        return .cli;
    } else if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
        printUsage();
        return error.HelpRequested;
    } else {
        std.debug.print("Unknown option: {s}\n", .{flag});
        printUsage();
        return error.InvalidArgument;
    }
}

fn printUsage() void {
    std.debug.print(
        \\Clipz - Clipboard Manager
        \\
        \\Usage: clipz [OPTION]
        \\
        \\Options:
        \\  -c, --cli       Run in CLI mode (default)
        \\  -j, --json-api  Run in JSON API mode for Electron integration
        \\  -h, --help      Show this help message
        \\
        \\CLI Controls:
        \\  get           Display clipboard entries
        \\  get <n>       Copy entry n to clipboard
        \\  clean         Clear all entries
        \\  exit          Quit application
        \\
        \\Note: For global hotkeys, use the Electron frontend with 'npm start'
        \\
    , .{});
}

// NEW: JSON API mode for Electron communication
fn runJsonApi(allocator: std.mem.Allocator, clipboard_manager: *manager.ClipboardManager) !void {
    // Start clipboard monitoring in background
    try clipboard_manager.startMonitoring();
    defer clipboard_manager.stopMonitoring();

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    // Send ready signal
    try stdout.writeAll("{\"type\":\"ready\"}\n");

    var buffer: [1024]u8 = undefined;
    while (true) {
        if (try stdin.reader().readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (std.mem.eql(u8, trimmed, "quit")) {
                break;
            } else if (std.mem.eql(u8, trimmed, "get-entries")) {
                try sendClipboardEntries(allocator, stdout, clipboard_manager);
            } else if (std.mem.startsWith(u8, trimmed, "select-entry:")) {
                const index_str = trimmed["select-entry:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    if (clipboard_manager.selectEntry(index)) {
                        try sendSelectResult(stdout, index, true);
                        // Send updated entries to frontend
                        try sendClipboardEntries(allocator, stdout, clipboard_manager);
                    } else |_| {
                        try sendSelectResult(stdout, index, false);
                    }
                } else |_| {
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.eql(u8, trimmed, "clear")) {
                clipboard_manager.clean() catch {};
                try stdout.writeAll("{\"type\":\"success\",\"message\":\"Clipboard cleared\"}\n");
            } else {
                try stdout.writeAll("{\"type\":\"error\",\"message\":\"Unknown command\"}\n");
            }
        } else {
            break;
        }
    }
}

fn sendClipboardEntries(allocator: std.mem.Allocator, stdout: std.fs.File, clipboard_manager: *manager.ClipboardManager) !void {
    const entries = clipboard_manager.getEntries();

    try stdout.writeAll("{\"type\":\"entries\",\"data\":[");

    if (entries.len > 0) {
        // First, send the most recent entry (current clipboard) with id=1
        const most_recent = entries[entries.len - 1];

        // Escape JSON string for most recent
        var escaped_content_recent = std.ArrayList(u8).init(allocator);
        defer escaped_content_recent.deinit();

        for (most_recent.content) |char| {
            switch (char) {
                '"' => try escaped_content_recent.appendSlice("\\\""),
                '\\' => try escaped_content_recent.appendSlice("\\\\"),
                '\n' => try escaped_content_recent.appendSlice("\\n"),
                '\r' => try escaped_content_recent.appendSlice("\\r"),
                '\t' => try escaped_content_recent.appendSlice("\\t"),
                else => try escaped_content_recent.append(char),
            }
        }

        const recent_json = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"content\":\"{s}\",\"timestamp\":{d},\"type\":\"text\",\"isCurrent\":true}}", .{ escaped_content_recent.items, most_recent.timestamp * 1000 });
        defer allocator.free(recent_json);
        try stdout.writeAll(recent_json);

        // Then send the rest from newest to oldest (if there are more than 1 entry)
        if (entries.len > 1) {
            var entry_id: usize = 2;
            var i: usize = entries.len - 2; // Start from second most recent
            while (true) {
                try stdout.writeAll(",");

                const entry = entries[i];

                // Escape JSON string
                var escaped_content = std.ArrayList(u8).init(allocator);
                defer escaped_content.deinit();

                for (entry.content) |char| {
                    switch (char) {
                        '"' => try escaped_content.appendSlice("\\\""),
                        '\\' => try escaped_content.appendSlice("\\\\"),
                        '\n' => try escaped_content.appendSlice("\\n"),
                        '\r' => try escaped_content.appendSlice("\\r"),
                        '\t' => try escaped_content.appendSlice("\\t"),
                        else => try escaped_content.append(char),
                    }
                }

                const json_entry = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"content\":\"{s}\",\"timestamp\":{d},\"type\":\"text\",\"isCurrent\":false}}", .{ entry_id, escaped_content.items, entry.timestamp * 1000 });
                defer allocator.free(json_entry);

                try stdout.writeAll(json_entry);
                entry_id += 1;

                if (i == 0) break;
                i -= 1;
            }
        }
    }

    try stdout.writeAll("]}\n");
}

fn sendSelectResult(stdout: std.fs.File, index: usize, success: bool) !void {
    if (success) {
        const response = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"type\":\"select-success\",\"index\":{d}}}\n", .{index});
        defer std.heap.page_allocator.free(response);
        try stdout.writeAll(response);
    } else {
        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Failed to select entry\"}\n");
    }
}
