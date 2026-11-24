const std = @import("std");
pub const c = @import("c");
pub const common = @import("common/lib.zig");

pub fn main() !void {
    std.log.info("wlrec initialized", .{});
}

test {
    std.testing.refAllDecls(@This());
}
