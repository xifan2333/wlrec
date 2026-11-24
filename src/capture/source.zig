const std = @import("std");
const c = @import("c");

pub const SourceError = error{
    MissingOutput,
    MissingSourceManager,
    SourceCreationFailed,
};

/// Target capture source configuration.
pub const CaptureSourceConfig = union(enum) {
    output: ?[:0]const u8,
    toplevel: ?[:0]const u8,
};

/// Concrete Wayland image capture source handle.
pub const CaptureSource = struct {
    source: *c.ext_image_capture_source_v1,

    pub fn deinit(self: *CaptureSource) void {
        c.ext_image_capture_source_v1_destroy(self.source);
    }
};

test "CaptureSourceConfig variants" {
    const default_output = CaptureSourceConfig{ .output = null };
    try std.testing.expect(default_output == .output);

    const named_output = CaptureSourceConfig{ .output = "eDP-1" };
    try std.testing.expectEqualStrings("eDP-1", named_output.output.?);
}
