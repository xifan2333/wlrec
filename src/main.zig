const std = @import("std");
pub const c = @import("c");

pub fn main() !void {
    std.log.info("wlrec initialized", .{});
}

test "c module protocol symbols exist" {
    const std_test = std.testing;
    // Verify Wayland protocol interfaces are exported by the c module
    try std_test.expect(c.ext_image_copy_capture_manager_v1_interface.name != null);
    try std_test.expect(c.ext_output_image_capture_source_manager_v1_interface.name != null);
    try std_test.expect(c.zwp_linux_dmabuf_v1_interface.name != null);
}
