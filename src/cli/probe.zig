const std = @import("std");
const c = @import("c");
const capture = @import("../capture/lib.zig");
const audio = @import("../audio/lib.zig");

pub const ProbeResult = struct {
    wayland_ok: bool = false,
    copy_capture_ok: bool = false,
    source_mgr_ok: bool = false,
    dmabuf_ok: bool = false,

    vaapi_ok: bool = false,
    h264_encode_ok: bool = false,
    vpp_ok: bool = false,
    driver_name: [64]u8 = undefined,
    driver_name_len: usize = 0,

    audio_ok: bool = false,
    audio_monitor_ok: bool = false,
    audio_mic_ok: bool = false,
};

fn probeWayland(writer: anytype, result: *ProbeResult) !void {
    try writer.writeAll("[Wayland Display]\n");
    const caps = capture.probeWaylandCapabilities(null);
    if (!caps.wayland_ok) {
        try writer.writeAll("  Status: FAILED to connect to Wayland display\n");
        return;
    }
    result.wayland_ok = true;
    result.copy_capture_ok = caps.copy_capture_ok;
    result.source_mgr_ok = caps.source_mgr_ok;
    result.dmabuf_ok = caps.dmabuf_ok;

    try writer.writeAll("  Status: Connected to $WAYLAND_DISPLAY\n");
    try writer.print("  ext_image_copy_capture_manager_v1:        {s}\n", .{if (result.copy_capture_ok) "YES" else "MISSING"});
    try writer.print("  ext_output_image_capture_source_manager_v1: {s}\n", .{if (result.source_mgr_ok) "YES" else "MISSING"});
    try writer.print("  zwp_linux_dmabuf_v1:                       {s}\n", .{if (result.dmabuf_ok) "YES" else "MISSING"});
}

fn checkH264Encode(va_dpy: c.VADisplay) bool {
    var entrypoints: [16]c.VAEntrypoint = undefined;
    var num_entrypoints: c_int = 0;
    const q_st = c.vaQueryConfigEntrypoints(va_dpy, c.VAProfileH264Main, &entrypoints[0], &num_entrypoints);
    if (q_st != c.VA_STATUS_SUCCESS) return false;

    var i: usize = 0;
    const count = @as(usize, @intCast(num_entrypoints));
    while (i < count) : (i += 1) {
        if (entrypoints[i] == c.VAEntrypointEncSlice or entrypoints[i] == c.VAEntrypointEncSliceLP) {
            return true;
        }
    }
    return false;
}

fn checkVpp(va_dpy: c.VADisplay) bool {
    var vpp_entries: [16]c.VAEntrypoint = undefined;
    var num_vpp: c_int = 0;
    const vpp_st = c.vaQueryConfigEntrypoints(va_dpy, c.VAProfileNone, &vpp_entries[0], &num_vpp);
    if (vpp_st != c.VA_STATUS_SUCCESS) return false;

    var i: usize = 0;
    const count = @as(usize, @intCast(num_vpp));
    while (i < count) : (i += 1) {
        if (vpp_entries[i] == c.VAEntrypointVideoProc) {
            return true;
        }
    }
    return false;
}

fn probeVaapi(writer: anytype, result: *ProbeResult) !void {
    try writer.writeAll("\n[VAAPI & GPU Acceleration]\n");
    const drm_fd = c.open("/dev/dri/renderD128", c.O_RDWR);
    if (drm_fd < 0) {
        try writer.writeAll("  Cannot open /dev/dri/renderD128\n");
        return;
    }
    defer _ = c.close(drm_fd);

    const va_dpy = c.vaGetDisplayDRM(drm_fd);
    var va_maj: c_int = 0;
    var va_min: c_int = 0;
    const st = c.vaInitialize(va_dpy, &va_maj, &va_min);
    if (st != c.VA_STATUS_SUCCESS) {
        try writer.writeAll("  vaInitialize failed\n");
        return;
    }
    defer _ = c.vaTerminate(va_dpy);
    result.vaapi_ok = true;

    const vendor = c.vaQueryVendorString(va_dpy);
    const vendor_span = if (vendor != null) std.mem.span(vendor) else "Unknown";
    const len = @min(vendor_span.len, result.driver_name.len);
    @memcpy(result.driver_name[0..len], vendor_span[0..len]);
    result.driver_name_len = len;

    try writer.print("  Device: /dev/dri/renderD128 (VA-API ver {}.{})\n", .{ va_maj, va_min });
    try writer.print("  Driver: {s}\n", .{vendor_span});

    result.h264_encode_ok = checkH264Encode(va_dpy);
    result.vpp_ok = checkVpp(va_dpy);

    try writer.print("  H.264 Hardware Encode: {s}\n", .{if (result.h264_encode_ok) "SUPPORTED" else "NO"});
    try writer.print("  VideoProc (GPU Scaling): {s}\n", .{if (result.vpp_ok) "SUPPORTED" else "NO"});
}

fn probeAudio(writer: anytype, result: *ProbeResult) !void {
    try writer.writeAll("\n[Audio (PulseAudio / PipeWire)]\n");
    const report = audio.probePulseAudio();
    if (!report.available) {
        try writer.writeAll("  Status: UNAVAILABLE (no PulseAudio/PipeWire-Pulse daemon reachable)\n");
        return;
    }

    result.audio_ok = true;
    result.audio_monitor_ok = report.monitor_available;
    result.audio_mic_ok = report.mic_available;

    const srv = if (report.serverName().len > 0) report.serverName() else "Unknown";
    try writer.print("  Server: {s}\n", .{srv});
    try writer.print("  Desktop Monitor (@DEFAULT_MONITOR@): {s} ({s})\n", .{
        if (result.audio_monitor_ok) "YES" else "MISSING",
        if (report.defaultSink().len > 0) report.defaultSink() else "none",
    });
    try writer.print("  Microphone (@DEFAULT_SOURCE@):      {s} ({s})\n", .{
        if (result.audio_mic_ok) "YES" else "MISSING",
        if (report.defaultSource().len > 0) report.defaultSource() else "none",
    });
}

/// Run system environment and hardware acceleration probe.
pub fn runProbe(writer: anytype) !ProbeResult {
    var result = ProbeResult{};

    try writer.writeAll("=== wlrec Environment & Hardware Probe ===\n\n");

    try probeWayland(writer, &result);
    try probeVaapi(writer, &result);
    try probeAudio(writer, &result);

    try writer.writeAll("\n[Verdict]\n");
    const fully_supported = result.wayland_ok and result.copy_capture_ok and result.source_mgr_ok and
        result.dmabuf_ok and result.vaapi_ok and result.h264_encode_ok and result.vpp_ok;

    if (fully_supported) {
        try writer.writeAll("  PASS: System fully supports zero-copy Wayland capture & VAAPI hardware encoding.\n");
    } else {
        try writer.writeAll("  WARN: One or more prerequisites are missing. See details above.\n");
    }

    return result;
}

test "ProbeResult struct check" {
    const res = ProbeResult{};
    try std.testing.expect(!res.wayland_ok);
    try std.testing.expect(!res.audio_ok);
}
