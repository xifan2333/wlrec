const std = @import("std");
const c = @import("c");
const wlrec = @import("wlrec");
const record = wlrec.record;

test "live desktop zero-copy capture to h264 file" {
    // 1. Guard: Check if running in a Wayland environment with VAAPI render node
    const dpy = c.wl_display_connect(null);
    if (dpy == null) {
        std.log.info("SKIPPED: No Wayland display available in test environment", .{});
        return;
    }
    c.wl_display_disconnect(dpy);

    const drm_fd = c.open("/dev/dri/renderD128", c.O_RDWR);
    if (drm_fd < 0) {
        std.log.info("SKIPPED: /dev/dri/renderD128 not accessible", .{});
        return;
    }
    _ = c.close(drm_fd);

    // 2. Run live capture for 5 frames
    const test_output_path = "/tmp/wlrec_test_burst.h264";
    defer {
        const path_z = "/tmp/wlrec_test_burst.h264\x00";
        _ = c.unlink(path_z.ptr);
    }

    const config = record.engine.RecordConfig{
        .output_path = test_output_path,
        .device_path = "/dev/dri/renderD128",
        .fps = 60,
        .qp = 23,
        .max_frames = 5,
    };

    const stats = try record.engine.runRecording(std.testing.allocator, config);

    // 3. Assertions on captured and encoded data
    try std.testing.expect(stats.frames_captured >= 5);
    try std.testing.expect(stats.frames_encoded >= 5);
    try std.testing.expect(stats.bytes_written > 1000);
    try std.testing.expect(stats.first_keyframe_seen);

    // 4. Verify the output file on disk
    const check_fd = c.open("/tmp/wlrec_test_burst.h264\x00".ptr, c.O_RDONLY);
    try std.testing.expect(check_fd >= 0);
    defer _ = c.close(check_fd);

    // Check first 4 bytes for H.264 NAL start code (0x00, 0x00, 0x00, 0x01)
    var header: [4]u8 = undefined;
    const n = c.read(check_fd, &header[0], 4);
    try std.testing.expectEqual(@as(isize, 4), n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, &header);
}
