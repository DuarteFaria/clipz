const std = @import("std");
const manager = @import("manager.zig");
const command = @import("command.zig");

pub const ClipboardUI = struct {
    clipboard: *manager.ClipboardManager,

    pub fn init(clipboard_manager: *manager.ClipboardManager) ClipboardUI {
        return .{
            .clipboard = clipboard_manager,
        };
    }

    fn printHelp() void {
        std.debug.print("Commands:\n", .{});
        std.debug.print("  get           - Show all clipboard entries\n", .{});
        std.debug.print("  get <n>       - Show specific clipboard entry\n", .{});
        std.debug.print("  pin <n>       - Toggle pin on a clipboard entry\n", .{});
        std.debug.print("  start         - Start monitoring clipboard in background\n", .{});
        std.debug.print("  stop          - Stop monitoring clipboard\n", .{});
        std.debug.print("  clean         - Clean the clipboard\n", .{});
        std.debug.print("  clear         - Clear the screen\n", .{});
        std.debug.print("  path          - Show persistence file location\n", .{});
        std.debug.print("  exit          - Exit the program\n", .{});
        std.debug.print("\nPersistence: Clipboard history is automatically saved to disk.\n", .{});
    }

    pub fn run(self: *ClipboardUI) !void {
        const stdin = std.fs.File.stdin();
        var buffer: [1024]u8 = undefined;
        std.debug.print("\x1B[2J\x1B[H", .{});
        std.debug.print("Clipz - Interactive Mode\n", .{});
        printHelp();
        std.debug.print("\n", .{});

        while (true) {
            std.debug.print("> ", .{});
            if (try stdin.deprecatedReader().readUntilDelimiterOrEof(buffer[0..], '\n')) |user_input| {
                const trimmed = std.mem.trim(u8, user_input, " \t\r\n");
                if (trimmed.len == 0) continue;

                switch (command.Command.fromString(trimmed)) {
                    .get => printEntries(self.clipboard),
                    .start => {
                        try self.clipboard.startMonitoring();
                    },
                    .stop => {
                        self.clipboard.stopMonitoring();
                    },
                    .clear => std.debug.print("\x1B[2J\x1B[H", .{}),
                    .clean => {
                        std.debug.print("\nCleaning clipboard...\n", .{});
                        try self.clipboard.clean();
                        printEntries(self.clipboard);
                    },
                    .path => {
                        const path = self.clipboard.getPersistencePath();
                        std.debug.print("\x1B[2J\x1B[H", .{});
                        std.debug.print("Persistence file: {s}\n", .{path});
                    },
                    .exit => {
                        std.debug.print("Goodbye!\n", .{});
                        break;
                    },
                    .get_index => {
                        const index_str = trimmed["get ".len..];
                        const index = std.fmt.parseInt(usize, index_str, 10) catch {
                            std.debug.print("Invalid index. Usage: get <number>\n", .{});
                            continue;
                        };

                        try self.clipboard.selectEntry(index);
                        continue;
                    },
                    .pin_index => {
                        const index_str = trimmed["pin ".len..];
                        const index = std.fmt.parseInt(usize, index_str, 10) catch {
                            std.debug.print("Invalid index. Usage: pin <number>\n", .{});
                            continue;
                        };

                        _ = try self.clipboard.togglePinned(index);
                        printEntries(self.clipboard);
                        continue;
                    },
                    .help => {
                        printHelp();
                    },
                    .unknown => {
                        std.debug.print("Unknown command.\n", .{});
                        printHelp();
                    },
                }
            }
        }
    }
};

pub fn printEntries(clipboard_entries: *manager.ClipboardManager) void {
    const entry_count = clipboard_entries.getDisplayCount();

    std.debug.print("\x1b[2J\x1b[H", .{});

    std.debug.print("\nClipboard History ({d} entries):\n", .{entry_count});
    std.debug.print("----------------------------------------\n", .{});

    for (0..entry_count) |i| {
        const entry = clipboard_entries.getDisplayEntry(i) orelse continue;
        const timestamp = entry.timestamp;
        const now = std.time.timestamp();
        const age_secs = now - timestamp;
        const pin_label = if (entry.pinned) " [PINNED]" else "";

        std.debug.print("\nClip {d}{s} (from {d}s ago):\n", .{ i + 1, pin_label, age_secs });
        std.debug.print("{s}\n", .{entry.content});
    }
    std.debug.print("----------------------------------------\n", .{});
}
