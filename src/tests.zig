// Explicit imports ensure Zig discovers module tests rather than reporting a
// successful run of zero tests from the executable's lazily analyzed root.
test {
    _ = @import("manager.zig");
    _ = @import("clipboard.zig");
    _ = @import("image_storage.zig");
    _ = @import("persistence.zig");
    _ = @import("main.zig");
}
