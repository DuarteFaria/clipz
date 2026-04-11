const std = @import("std");
const manager = @import("manager.zig");
const ui = @import("ui.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Skip gpa.deinit() — leak reporting is noisy due to std.process.Child internals.
    // Runtime safety (double-free, use-after-free) still works without deinit.
    // OS reclaims all memory on process exit; clipboard_manager.deinit() handles
    // persistence saves and thread cleanup.
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
        \\  pin <n>       Toggle pin on entry n
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
    clipboard_manager.entries_changed_callback = sendEntriesCallback;

    // Start clipboard monitoring in background
    try clipboard_manager.startMonitoring();
    defer clipboard_manager.stopMonitoring();

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Send ready signal with capability flags for frontend compatibility
    try stdout.writeAll("{\"type\":\"ready\",\"supportsIdCommands\":true}\n");

    var buffer: [1024]u8 = undefined;
    while (true) {
        if (try stdin.deprecatedReader().readUntilDelimiterOrEof(buffer[0..], '\n')) |line| {
            if (line.len >= buffer.len - 1) {
                clipboard_manager.stdout_mutex.lock();
                defer clipboard_manager.stdout_mutex.unlock();
                try stdout.writeAll("{\"type\":\"error\",\"message\":\"Command too long\"}\n");
                continue;
            }
            const trimmed = std.mem.trim(u8, line, " \t\r\n");

            if (std.mem.eql(u8, trimmed, "quit")) {
                break;
            } else if (std.mem.eql(u8, trimmed, "get-entries")) {
                clipboard_manager.stdout_mutex.lock();
                defer clipboard_manager.stdout_mutex.unlock();
                try sendClipboardEntries(allocator, stdout, clipboard_manager);
            } else if (std.mem.startsWith(u8, trimmed, "select-entry-id:")) {
                const id_str = trimmed["select-entry-id:".len..];
                if (std.fmt.parseInt(u64, id_str, 10)) |entry_id| {
                    clipboard_manager.selectEntryById(entry_id) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendSelectResultById(allocator, stdout, entry_id);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "select-entry:")) {
                const index_str = trimmed["select-entry:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    clipboard_manager.selectEntry(index) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendSelectResultByIndex(allocator, stdout, index);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "remove-entry-id:")) {
                const id_str = trimmed["remove-entry-id:".len..];
                if (std.fmt.parseInt(u64, id_str, 10)) |entry_id| {
                    clipboard_manager.removeEntryById(entry_id) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendRemoveResultById(allocator, stdout, entry_id);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "remove-entry:")) {
                const index_str = trimmed["remove-entry:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    clipboard_manager.removeEntry(index) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendRemoveResultByIndex(allocator, stdout, index);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "toggle-pin-id:")) {
                const id_str = trimmed["toggle-pin-id:".len..];
                if (std.fmt.parseInt(u64, id_str, 10)) |entry_id| {
                    const pinned = clipboard_manager.togglePinnedById(entry_id) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendPinResultById(allocator, stdout, entry_id, pinned);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid id\"}\n");
                }
            } else if (std.mem.startsWith(u8, trimmed, "toggle-pin:")) {
                const index_str = trimmed["toggle-pin:".len..];
                if (std.fmt.parseInt(usize, index_str, 10)) |index| {
                    const pinned = clipboard_manager.togglePinned(index) catch {
                        clipboard_manager.stdout_mutex.lock();
                        defer clipboard_manager.stdout_mutex.unlock();
                        try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                        continue;
                    };
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try sendPinResultByIndex(allocator, stdout, index, pinned);
                    try sendClipboardEntries(allocator, stdout, clipboard_manager);
                } else |_| {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Invalid index\"}\n");
                }
            } else if (std.mem.eql(u8, trimmed, "clear")) {
                clipboard_manager.clearHistory() catch {
                    clipboard_manager.stdout_mutex.lock();
                    defer clipboard_manager.stdout_mutex.unlock();
                    try stdout.writeAll("{\"type\":\"error\",\"message\":\"Failed to clear history\"}\n");
                    continue;
                };
                clipboard_manager.stdout_mutex.lock();
                defer clipboard_manager.stdout_mutex.unlock();
                try stdout.writeAll("{\"type\":\"success\",\"message\":\"History cleared\"}\n");
            } else {
                clipboard_manager.stdout_mutex.lock();
                defer clipboard_manager.stdout_mutex.unlock();
                try stdout.writeAll("{\"type\":\"error\",\"message\":\"Unknown command\"}\n");
            }
        } else {
            break;
        }
    }
}

fn appendJsonEscapedString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            '\x08' => try output.appendSlice(allocator, "\\b"),
            '\x0c' => try output.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try output.writer(allocator).print("\\u{X:0>4}", .{char}),
            else => try output.append(allocator, char),
        }
    }
}

fn sendClipboardEntries(allocator: std.mem.Allocator, stdout: std.fs.File, clipboard_manager: *manager.ClipboardManager) !void {
    var snapshot = try clipboard_manager.snapshotDisplayEntries(allocator);
    defer manager.ClipboardManager.freeDisplayEntriesSnapshot(allocator, &snapshot);

    try stdout.writeAll("{\"type\":\"entries\",\"data\":[");

    for (snapshot.items, 0..) |entry, i| {
        if (i > 0) {
            try stdout.writeAll(",");
        }

        var escaped_content = std.ArrayList(u8){};
        defer escaped_content.deinit(allocator);

        try appendJsonEscapedString(allocator, &escaped_content, entry.content);

        const entry_type_str = switch (entry.entry_type) {
            .text => "text",
            .image => "image",
            .file => "file",
            .url => "url",
            .color => "color",
        };
        const json_entry = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"content\":\"{s}\",\"timestamp\":{d},\"type\":\"{s}\",\"isCurrent\":{s},\"pinned\":{s}}}", .{ entry.id, escaped_content.items, entry.timestamp * 1000, entry_type_str, if (entry.is_current) "true" else "false", if (entry.pinned) "true" else "false" });
        defer allocator.free(json_entry);

        try stdout.writeAll(json_entry);
    }

    try stdout.writeAll("]}\n");
}

fn sendSelectResultById(allocator: std.mem.Allocator, stdout: std.fs.File, entry_id: u64) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"select-success\",\"id\":{d}}}\n", .{entry_id});
    defer allocator.free(response);
    try stdout.writeAll(response);
}

fn sendSelectResultByIndex(allocator: std.mem.Allocator, stdout: std.fs.File, index: usize) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"select-success\",\"index\":{d}}}\n", .{index});
    defer allocator.free(response);
    try stdout.writeAll(response);
}

fn sendRemoveResultById(allocator: std.mem.Allocator, stdout: std.fs.File, entry_id: u64) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"remove-success\",\"id\":{d}}}\n", .{entry_id});
    defer allocator.free(response);
    try stdout.writeAll(response);
}

fn sendRemoveResultByIndex(allocator: std.mem.Allocator, stdout: std.fs.File, index: usize) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"remove-success\",\"index\":{d}}}\n", .{index});
    defer allocator.free(response);
    try stdout.writeAll(response);
}

fn sendPinResultById(allocator: std.mem.Allocator, stdout: std.fs.File, entry_id: u64, pinned: bool) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"pin-toggled\",\"id\":{d},\"pinned\":{s}}}\n", .{ entry_id, if (pinned) "true" else "false" });
    defer allocator.free(response);
    try stdout.writeAll(response);
}

fn sendPinResultByIndex(allocator: std.mem.Allocator, stdout: std.fs.File, index: usize, pinned: bool) !void {
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"pin-toggled\",\"index\":{d},\"pinned\":{s}}}\n", .{ index, if (pinned) "true" else "false" });
    defer allocator.free(response);
    try stdout.writeAll(response);
}
