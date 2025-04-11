const std = @import("std");
const manager = @import("manager.zig");


pub const ClipboardUI = struct {
    clipboard: *manager.ClipboardManager,

    pub fn init(clipboard_manager: *manager.ClipboardManager) ClipboardUI {
        return .{
            .clipboard = clipboard_manager,
        };
    }

    pub fn run(self: *ClipboardUI) !void {
        const stdin = std.io.getStdIn();
        var buffer: [1024]u8 = undefined;

        std.debug.print("Clipboard Manager - Interactive Mode\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  get       - Show all clipboard entries\n", .{});
        std.debug.print("  get <n>   - Show specific clipboard entry\n", .{});
        std.debug.print("  monitor   - Start monitoring clipboard\n", .{});
        std.debug.print("  exit      - Exit the program\n\n", .{});

        while (true) {
            std.debug.print("> ", .{});
            if (try stdin.reader().readUntilDelimiterOrEof(buffer[0..], '\n')) |user_input| {
                const trimmed = std.mem.trim(u8, user_input, " \t\r\n");
                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit")) {
                    std.debug.print("Goodbye!\n", .{});
                    break;
                }

                if (std.mem.eql(u8, trimmed, "get")) {
                    printEntries(self.clipboard);
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "monitor")) {
                    std.debug.print("\nStarting clipboard monitor (Ctrl+C to stop)...\n", .{});
                    try self.clipboard.monitor();
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "get ")) {
                    const index_str = trimmed["get ".len..];
                    const index = std.fmt.parseInt(usize, index_str, 10) catch {
                        std.debug.print("Invalid index. Usage: get <number>\n", .{});
                        continue;
                    };

                    if (self.clipboard.getEntry(index)) |entry| {
                        const now = std.time.timestamp();
                        const age_secs = now - entry.timestamp;
                        std.debug.print("\nClip {d} (from {d}s ago):\n", .{ index, age_secs });
                        std.debug.print("{s}\n", .{entry.content});
                    } else {
                        std.debug.print("No entry at index {d}\n", .{index});
                    }
                    continue;
                }

                std.debug.print("Unknown command. Available commands:\n", .{});
                std.debug.print("  get       - Show all clipboard entries\n", .{});
                std.debug.print("  get <n>   - Show specific clipboard entry\n", .{});
                std.debug.print("  monitor   - Start monitoring clipboard\n", .{});
                std.debug.print("  exit      - Exit the program\n", .{});
            }
        }
    }
};

pub fn printEntries(clipboard_entries: *manager.ClipboardManager) void {
        const entries = clipboard_entries.getEntries();

        std.debug.print("\x1b[2J\x1b[H", .{});

        std.debug.print("\nClipboard History ({d} entries):\n", .{entries.len});
        std.debug.print("----------------------------------------\n", .{});

        for (entries, 0..) |entry, i| {
            const reversed_index = entries.len - 1 - i;
            const timestamp = entry.timestamp;
            const now = std.time.timestamp();
            const age_secs = now - timestamp;

            std.debug.print("\nClip {d} (from {d}s ago):\n", .{ reversed_index + 1, age_secs });
            std.debug.print("{s}\n", .{entry.content});
        }
        std.debug.print("----------------------------------------\n", .{});
    }
