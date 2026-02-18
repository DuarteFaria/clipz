const std = @import("std");
const manager = @import("manager.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line arguments and determine config
    const parse_result = parseArguments(args) catch |err| {
        printUsage();
        return err;
    };

    var clipboard_manager = try manager.ClipboardManager.initWithConfig(allocator, parse_result.config);
    defer clipboard_manager.deinit();

    switch (parse_result.mode) {
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

const ParseResult = struct {
    mode: RunMode,
    config: config.Config,
};

fn parseArguments(args: []const []const u8) !ParseResult {
    var mode: RunMode = .cli; // Default to CLI mode
    var cfg = config.Config.default();

    if (args.len == 1) {
        return ParseResult{ .mode = mode, .config = cfg };
    }

    var i: usize = 1;
    while (i < args.len) {
        const flag = args[i];

        if (std.mem.eql(u8, flag, "--json-api") or std.mem.eql(u8, flag, "-j")) {
            mode = .json_api;
        } else if (std.mem.eql(u8, flag, "--cli") or std.mem.eql(u8, flag, "-c")) {
            mode = .cli;
        } else if (std.mem.eql(u8, flag, "--low-power") or std.mem.eql(u8, flag, "-l")) {
            cfg = config.Config.lowPower();
        } else if (std.mem.eql(u8, flag, "--responsive") or std.mem.eql(u8, flag, "-r")) {
            cfg = config.Config.responsive();
        } else if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
            printUsage();
            return error.HelpRequested;
        } else {
            std.debug.print("Unknown option: {s}\n", .{flag});
            printUsage();
            return error.InvalidArgument;
        }
        i += 1;
    }

    return ParseResult{ .mode = mode, .config = cfg };
}

fn printUsage() void {
    std.debug.print(
        \\Clipz - Clipboard Manager
        \\
        \\Usage: clipz [OPTIONS]
        \\
        \\Mode Options:
        \\  -c, --cli       Run in CLI mode (default)
        \\  -j, --json-api  Run in JSON API mode for Electron integration
        \\
        \\Performance Options:
        \\  -l, --low-power     Low power mode (slower polling, longer saves)
        \\  -r, --responsive    Responsive mode (faster polling, frequent saves)
        \\  (default)           Balanced mode
        \\
        \\Other Options:
        \\  -h, --help      Show this help message
        \\
        \\CLI Controls:
        \\  get           Display clipboard entries
        \\  get <n>       Copy entry n to clipboard
        \\  clean         Clear all entries
        \\  exit          Quit application
        \\
        \\Performance Modes:
        \\  - Low Power: 250ms-1s polling, 30s saves (great for battery life)
        \\  - Balanced:  100ms-250ms polling, 5s saves (default)
        \\  - Responsive: 50ms-150ms polling, 2s saves (fastest response)
        \\
        \\Note: For global hotkeys, use the Electron frontend with 'npm start'
        \\
    , .{});
}

fn sendEntriesCallback(manager_ptr: *manager.ClipboardManager) void {
    const stdout = std.fs.File.stdout();
    const allocator = manager_ptr.allocator;
    sendClipboardEntries(allocator, stdout, manager_ptr) catch {};
}

// NEW: JSON API mode for Electron communication
fn runJsonApi(allocator: std.mem.Allocator, clipboard_manager: *manager.ClipboardManager) !void {
    // Start clipboard monitoring in background
    try clipboard_manager.startMonitoring();
    defer clipboard_manager.stopMonitoring();

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    clipboard_manager.entries_changed_callback = sendEntriesCallback;

    // Send ready signal
    try stdout.writeAll("{\"type\":\"ready\"}\n");

    var buffer: [1024]u8 = undefined;
    while (true) {
        if (try stdin.deprecatedReader().readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
            if (line.len >= buffer.len - 1) {
                try stdout.writeAll("{\"type\":\"error\",\"message\":\"Command too long\"}\n");
                continue;
            }
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (std.mem.eql(u8, trimmed, "quit")) {
                break;
            } else if (std.mem.eql(u8, trimmed, "get-entries")) {
                try sendClipboardEntries(allocator, stdout, clipboard_manager);
            } else if (std.mem.startsWith(u8, trimmed, "select-entry:")) {
                const index_str = trimmed["select-entry:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    clipboard_manager.selectEntry(index) catch |err| {
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                        return err;
                    };
                    try sendSelectResult(allocator, stdout, index, true);
                    // Send updated entries to frontend
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "remove-entry:")) {
                const index_str = trimmed["remove-entry:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    clipboard_manager.removeEntry(index) catch |err| {
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                        return err;
                    };
                    try sendRemoveResult(allocator, stdout, index, true);
                    // Send updated entries to frontend
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.eql(u8, trimmed, "clear")) {
                clipboard_manager.clearHistory() catch |err| {
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Failed to clear history\"}\n");
                    return err;
                };
                try stdout.writeAll("{\"type\":\"success\",\"message\":\"History cleared\"}\n");
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
        var escaped_content_recent = std.ArrayList(u8){};
        defer escaped_content_recent.deinit(allocator);

        for (most_recent.content) |char| {
            switch (char) {
                '"' => try escaped_content_recent.appendSlice(allocator, "\\\""),
                '\\' => try escaped_content_recent.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_content_recent.appendSlice(allocator, "\\n"),
                '\r' => try escaped_content_recent.appendSlice(allocator, "\\r"),
                '\t' => try escaped_content_recent.appendSlice(allocator, "\\t"),
                else => try escaped_content_recent.append(allocator, char),
            }
        }

        const entry_type_str = switch (most_recent.entry_type) {
            .text => "text",
            .image => "image",
            .file => "file",
        };
        const recent_json = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"content\":\"{s}\",\"timestamp\":{d},\"type\":\"{s}\",\"isCurrent\":true}}", .{ escaped_content_recent.items, most_recent.timestamp * 1000, entry_type_str });
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
                var escaped_content = std.ArrayList(u8){};
                defer escaped_content.deinit(allocator);

                for (entry.content) |char| {
                    switch (char) {
                        '"' => try escaped_content.appendSlice(allocator, "\\\""),
                        '\\' => try escaped_content.appendSlice(allocator, "\\\\"),
                        '\n' => try escaped_content.appendSlice(allocator, "\\n"),
                        '\r' => try escaped_content.appendSlice(allocator, "\\r"),
                        '\t' => try escaped_content.appendSlice(allocator, "\\t"),
                        else => try escaped_content.append(allocator, char),
                    }
                }

                const entry_type_str_history = switch (entry.entry_type) {
                    .text => "text",
                    .image => "image",
                    .file => "file",
                };
                const json_entry = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"content\":\"{s}\",\"timestamp\":{d},\"type\":\"{s}\",\"isCurrent\":false}}", .{ entry_id, escaped_content.items, entry.timestamp * 1000, entry_type_str_history });
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

fn sendSelectResult(allocator: std.mem.Allocator, stdout: std.fs.File, index: usize, success: bool) !void {
    if (success) {
        const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"select-success\",\"index\":{d}}}\n", .{index});
        defer allocator.free(response);
        try stdout.writeAll(response);
    } else {
        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Failed to select entry\"}\n");
    }
}

fn sendRemoveResult(allocator: std.mem.Allocator, stdout: std.fs.File, index: usize, success: bool) !void {
    if (success) {
        const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"remove-success\",\"index\":{d}}}\n", .{index});
        defer allocator.free(response);
        try stdout.writeAll(response);
    } else {
        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Failed to remove entry\"}\n");
    }
}
