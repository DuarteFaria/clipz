/// NSPasteboard.generalPasteboard.changeCount via Objective-C runtime.
/// Near-zero-cost clipboard change detection without spawning any process.

const c = struct {
    const Class = *opaque {};
    const SEL = *opaque {};
    const id = *opaque {};

    extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
    extern "c" fn sel_registerName(name: [*:0]const u8) ?SEL;
    extern "c" fn objc_msgSend() void;
};

const cc: @import("std").builtin.CallingConvention = .c;

pub fn getChangeCount() ?i64 {
    const NSPasteboard = c.objc_getClass("NSPasteboard") orelse return null;
    const generalPasteboardSel = c.sel_registerName("generalPasteboard") orelse return null;
    const changeCountSel = c.sel_registerName("changeCount") orelse return null;

    // [NSPasteboard generalPasteboard]
    const msgSend_class: *const fn (c.Class, c.SEL) callconv(cc) c.id = @ptrCast(&c.objc_msgSend);
    const pasteboard = msgSend_class(NSPasteboard, generalPasteboardSel);

    // [pasteboard changeCount]
    const msgSend_count: *const fn (c.id, c.SEL) callconv(cc) i64 = @ptrCast(&c.objc_msgSend);
    return msgSend_count(pasteboard, changeCountSel);
}
