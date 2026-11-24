const std = @import("std");
const c = @import("c");

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
};

const WaylandGlobals = struct {
    copy_capture: bool = false,
    source_mgr: bool = false,
    dmabuf: bool = false,

    fn handleGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
        _ = reg;
        _ = name;
        _ = ver;
        const self: *@This() = @ptrCast(@alignCast(data));
        const span = std.mem.span(iface);
        if (std.mem.eql(u8, span, "ext_image_copy_capture_manager_v1")) self.copy_capture = true;
        if (std.mem.eql(u8, span, "ext_output_image_capture_source_manager_v1")) self.source_mgr = true;
        if (std.mem.eql(u8, span, "zwp_linux_dmabuf_v1")) self.dmabuf = true;
    }

    fn removeGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32) callconv(.c) void {
        _ = data;
        _ = reg;
        _ = name;
    }
};

fn probeWayland(writer: anytype, result: *ProbeResult) !void {
    try writer.writeAll("[Wayland Display]\n");
    const display = c.wl_display_connect(null);
    if (display == null) {
        try writer.writeAll("  Status: FAILED to connect to Wayland display\n");
        return;
    }
    const dpy = display.?;
    defer c.wl_display_disconnect(dpy);
    result.wayland_ok = true;
    try writer.writeAll("  Status: Connected to $WAYLAND_DISPLAY\n");

    var globals = WaylandGlobals{};
    const reg = c.wl_display_get_registry(dpy) orelse return;
    defer c.wl_registry_destroy(reg);

    const listener = c.wl_registry_listener{
        .global = WaylandGlobals.handleGlobal,
        .global_remove = WaylandGlobals.removeGlobal,
    };
    _ = c.wl_registry_add_listener(reg, &listener, &globals);
    _ = c.wl_display_roundtrip(dpy);

    result.copy_capture_ok = globals.copy_capture;
    result.source_mgr_ok = globals.source_mgr;
    result.dmabuf_ok = globals.dmabuf;

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

/// Run system environment and hardware acceleration probe.
pub fn runProbe(writer: anytype) !ProbeResult {
    var result = ProbeResult{};

    try writer.writeAll("=== wlrec Environment & Hardware Probe ===\n\n");

    try probeWayland(writer, &result);
    try probeVaapi(writer, &result);

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
}
