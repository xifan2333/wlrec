const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const dmabuf_mod = @import("dmabuf.zig");

pub const CaptureError = error{
    OutOfMemory,
    DisplayConnectFailed,
    RegistryFailed,
    MissingGlobals,
    SourceCreationFailed,
    SessionCreationFailed,
    DispatchFailed,
    SessionStopped,
    BufferConstraints,
    CaptureFailed,
    Interrupted,
    Timeout,
};

pub const FormatModifierPair = common.FormatModifierPair;

pub const WaylandCapabilities = struct {
    wayland_ok: bool = false,
    copy_capture_ok: bool = false,
    source_mgr_ok: bool = false,
    dmabuf_ok: bool = false,
};

const supported_drm_formats = [_]u32{
    c.DRM_FORMAT_ARGB8888,
    c.DRM_FORMAT_XRGB8888,
    c.DRM_FORMAT_ABGR8888,
    c.DRM_FORMAT_XBGR8888,
};

pub fn isSupportedRgbDrmFormat(format: u32) bool {
    for (supported_drm_formats) |supported| {
        if (format == supported) return true;
    }
    return false;
}

pub fn isSupportedDmabufVersion(ver: u32) bool {
    return ver >= 2;
}

/// Active Wayland zero-copy screen capture session.
pub const CopyCaptureSession = struct {
    allocator: ?std.mem.Allocator = null,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    output: ?*c.wl_output = null,
    capture_mgr: ?*c.ext_image_copy_capture_manager_v1 = null,
    source_mgr: ?*c.ext_output_image_capture_source_manager_v1 = null,
    dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,

    source: ?*c.ext_image_capture_source_v1 = null,
    session: ?*c.ext_image_copy_capture_session_v1 = null,

    width: u32 = 0,
    height: u32 = 0,
    device_major: u32 = 0,
    device_minor: u32 = 0,
    formats: std.ArrayList(FormatModifierPair) = .empty,
    constraint_alloc_failed: bool = false,
    session_done: bool = false,
    session_stopped: bool = false,

    // Per-frame state
    frame_ready: bool = false,
    frame_failed: bool = false,
    frame_failure_reason: u32 = 0,
    frame_transform: u32 = c.WL_OUTPUT_TRANSFORM_NORMAL,
    pts_sec_hi: u32 = 0,
    pts_sec_lo: u32 = 0,
    pts_nsec: u32 = 0,

    pub fn monotonicMs() u64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.tv_nsec, 1_000_000)));
    }

    fn remainingTimeoutMs(deadline_ms: ?u64) CaptureError!i32 {
        const dl = deadline_ms orelse return -1;
        const now = monotonicMs();
        if (now >= dl) return CaptureError.Timeout;
        return @intCast(@min(dl - now, @as(u64, std.math.maxInt(i32))));
    }

    /// Initialize the capture session in caller-owned storage so Wayland listener pointers remain stable.
    pub fn init(self: *CopyCaptureSession, allocator: std.mem.Allocator, wayland_display: ?[*:0]const u8) CaptureError!void {
        self.* = .{ .allocator = allocator };
        errdefer self.deinit();

        const dpy = c.wl_display_connect(wayland_display) orelse return CaptureError.DisplayConnectFailed;
        self.display = dpy;

        const reg = c.wl_display_get_registry(dpy) orelse return CaptureError.RegistryFailed;
        self.registry = reg;

        _ = c.wl_registry_add_listener(reg, &registry_listener, self);
        if (c.wl_display_roundtrip(dpy) < 0) return CaptureError.DispatchFailed;

        if (self.output == null or self.capture_mgr == null or self.source_mgr == null or self.dmabuf == null) {
            return CaptureError.MissingGlobals;
        }

        const src = c.ext_output_image_capture_source_manager_v1_create_source(self.source_mgr.?, self.output.?) orelse {
            return CaptureError.SourceCreationFailed;
        };
        self.source = src;

        const sess = c.ext_image_copy_capture_manager_v1_create_session(self.capture_mgr.?, src, 0) orelse {
            return CaptureError.SessionCreationFailed;
        };
        self.session = sess;

        _ = c.ext_image_copy_capture_session_v1_add_listener(sess, &session_listener, self);

        while (!self.session_done and !self.session_stopped) {
            if (c.wl_display_dispatch(dpy) < 0) return CaptureError.DispatchFailed;
        }

        if (self.session_stopped) return CaptureError.SessionStopped;
        if (self.constraint_alloc_failed) return CaptureError.OutOfMemory;
    }

    pub fn deinit(self: *CopyCaptureSession) void {
        if (self.session) |s| c.ext_image_copy_capture_session_v1_destroy(s);
        if (self.source) |src| c.ext_image_capture_source_v1_destroy(src);
        if (self.dmabuf) |d| c.zwp_linux_dmabuf_v1_destroy(d);
        if (self.source_mgr) |sm| c.ext_output_image_capture_source_manager_v1_destroy(sm);
        if (self.capture_mgr) |cm| c.ext_image_copy_capture_manager_v1_destroy(cm);
        if (self.output) |o| c.wl_output_destroy(o);
        if (self.registry) |r| c.wl_registry_destroy(r);
        if (self.display) |d| c.wl_display_disconnect(d);
        if (self.allocator) |alloc| self.formats.deinit(alloc);
        self.* = .{};
    }

    pub fn advertisedFormats(self: *const CopyCaptureSession) []const FormatModifierPair {
        return self.formats.items;
    }

    pub fn beginConstraintBatch(self: *CopyCaptureSession) void {
        if (self.session_done) {
            self.session_done = false;
            self.formats.clearRetainingCapacity();
            self.constraint_alloc_failed = false;
        }
    }

    pub fn recordBufferSize(self: *CopyCaptureSession, width: u32, height: u32) void {
        self.beginConstraintBatch();
        self.width = width;
        self.height = height;
    }

    pub fn recordShmFormat(self: *CopyCaptureSession) void {
        self.beginConstraintBatch();
    }

    pub fn recordDmabufDevice(self: *CopyCaptureSession, major: u32, minor: u32) void {
        self.beginConstraintBatch();
        self.device_major = major;
        self.device_minor = minor;
    }

    fn appendUniqueFormatPair(self: *CopyCaptureSession, format: u32, modifier: u64) void {
        if (self.constraint_alloc_failed) return;
        for (self.formats.items) |existing| {
            if (existing.format == format and existing.modifier == modifier) return;
        }
        const alloc = self.allocator orelse {
            self.constraint_alloc_failed = true;
            return;
        };
        self.formats.append(alloc, .{ .format = format, .modifier = modifier }) catch |err| {
            std.log.err("failed to retain dmabuf format pair: {s}", .{@errorName(err)});
            self.constraint_alloc_failed = true;
        };
    }

    pub fn recordDmabufFormat(self: *CopyCaptureSession, format: u32, modifiers: []const u64) void {
        self.beginConstraintBatch();
        if (!isSupportedRgbDrmFormat(format)) return;

        if (modifiers.len == 0) {
            self.appendUniqueFormatPair(format, common.drm_mod_invalid);
            return;
        }
        for (modifiers) |mod| {
            self.appendUniqueFormatPair(format, mod);
        }
    }

    pub fn markSessionDone(self: *CopyCaptureSession) void {
        self.session_done = true;
    }

    pub fn markSessionStopped(self: *CopyCaptureSession) void {
        self.session_stopped = true;
    }

    pub fn validateBufferDimensions(self: *const CopyCaptureSession, width: u32, height: u32) CaptureError!void {
        if (width != self.width or height != self.height) {
            return CaptureError.BufferConstraints;
        }
    }

    /// Perform one bounded poll step against the Wayland display and optional stop_fd.
    fn pollDispatchStep(self: *CopyCaptureSession, stop_fd: ?std.posix.fd_t, deadline_ms: ?u64) CaptureError!void {
        const dpy = self.display orelse return CaptureError.SessionStopped;
        if (c.wl_display_prepare_read(dpy) != 0) {
            if (c.wl_display_dispatch_pending(dpy) < 0) return CaptureError.DispatchFailed;
            return;
        }

        const timeout_ms = remainingTimeoutMs(deadline_ms) catch |err| {
            c.wl_display_cancel_read(dpy);
            return err;
        };

        var pfd_list = [_]std.posix.pollfd{
            .{ .fd = c.wl_display_get_fd(dpy), .events = std.posix.POLL.IN, .revents = 0 },
            .{
                .fd = stop_fd orelse -1,
                .events = if (stop_fd != null) std.posix.POLL.IN else 0,
                .revents = 0,
            },
        };

        const poll_count: usize = if (stop_fd != null) 2 else 1;
        const ret = std.posix.poll(pfd_list[0..poll_count], timeout_ms) catch |err| {
            c.wl_display_cancel_read(dpy);
            std.log.err("poll failed in capture loop: {s}", .{@errorName(err)});
            return CaptureError.DispatchFailed;
        };

        if (ret == 0) {
            c.wl_display_cancel_read(dpy);
            return CaptureError.Timeout;
        }

        if (stop_fd != null and (pfd_list[1].revents & std.posix.POLL.IN) != 0) {
            c.wl_display_cancel_read(dpy);
            return CaptureError.Interrupted;
        }

        if (c.wl_display_read_events(dpy) < 0) return CaptureError.DispatchFailed;
        if (c.wl_display_dispatch_pending(dpy) < 0) return CaptureError.DispatchFailed;
    }

    pub fn waitConstraints(self: *CopyCaptureSession, stop_fd: ?std.posix.fd_t, deadline_ms: ?u64) CaptureError!void {
        while (!self.session_done and !self.session_stopped) {
            try self.pollDispatchStep(stop_fd, deadline_ms);
        }
        if (self.session_stopped) return CaptureError.SessionStopped;
        if (self.constraint_alloc_failed) return CaptureError.OutOfMemory;
    }

    fn mapFailureReason(reason: u32) CaptureError {
        if (reason == c.EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_STOPPED) return CaptureError.SessionStopped;
        if (reason == c.EXT_IMAGE_COPY_CAPTURE_FRAME_V1_FAILURE_REASON_BUFFER_CONSTRAINTS) return CaptureError.BufferConstraints;
        return CaptureError.CaptureFailed;
    }

    /// Request a frame capture into the provided DMA-BUF Wayland buffer.
    pub fn captureFrame(
        self: *CopyCaptureSession,
        dmabuf_buf: *const dmabuf_mod.DmabufBuffer,
        stop_fd: ?std.posix.fd_t,
        deadline_ms: ?u64,
    ) CaptureError!u64 {
        const dpy = self.display orelse return CaptureError.SessionStopped;
        const sess = self.session orelse return CaptureError.SessionStopped;

        try self.waitConstraints(stop_fd, deadline_ms);
        try self.validateBufferDimensions(dmabuf_buf.width, dmabuf_buf.height);
        _ = try remainingTimeoutMs(deadline_ms);

        self.frame_ready = false;
        self.frame_failed = false;
        self.frame_transform = c.WL_OUTPUT_TRANSFORM_NORMAL;

        const frame = c.ext_image_copy_capture_session_v1_create_frame(sess) orelse {
            return CaptureError.CaptureFailed;
        };
        defer {
            c.ext_image_copy_capture_frame_v1_destroy(frame);
            _ = c.wl_display_flush(dpy);
        }

        _ = c.ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener, self);
        c.ext_image_copy_capture_frame_v1_attach_buffer(frame, dmabuf_buf.buffer);
        c.ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, @intCast(dmabuf_buf.width), @intCast(dmabuf_buf.height));
        c.ext_image_copy_capture_frame_v1_capture(frame);

        if (c.wl_display_flush(dpy) < 0) return CaptureError.DispatchFailed;

        while (!self.frame_ready and !self.frame_failed and !self.session_stopped) {
            try self.pollDispatchStep(stop_fd, deadline_ms);
        }

        if (self.session_stopped) return CaptureError.SessionStopped;
        if (self.frame_failed) return mapFailureReason(self.frame_failure_reason);

        return common.VfrClock.parseWaylandTimestamp(self.pts_sec_hi, self.pts_sec_lo, self.pts_nsec);
    }
};

// C Trampolines
fn registryGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    const span = std.mem.span(iface);

    if (std.mem.eql(u8, span, "wl_output")) {
        if (self.output == null) {
            self.output = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_output_interface, @min(ver, 4)));
        }
        return;
    }
    if (std.mem.eql(u8, span, "ext_image_copy_capture_manager_v1")) {
        self.capture_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.ext_image_copy_capture_manager_v1_interface, 1));
        return;
    }
    if (std.mem.eql(u8, span, "ext_output_image_capture_source_manager_v1")) {
        self.source_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.ext_output_image_capture_source_manager_v1_interface, 1));
        return;
    }
    if (std.mem.eql(u8, span, "zwp_linux_dmabuf_v1")) {
        if (isSupportedDmabufVersion(ver)) {
            self.dmabuf = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_linux_dmabuf_v1_interface, @min(ver, 4)));
        }
        return;
    }
}

fn registryGlobalRemove(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = reg;
    _ = name;
}

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn probeRegistryGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
    _ = reg;
    _ = name;
    const caps: *WaylandCapabilities = @ptrCast(@alignCast(data));
    const span = std.mem.span(iface);
    if (std.mem.eql(u8, span, "ext_image_copy_capture_manager_v1")) caps.copy_capture_ok = true;
    if (std.mem.eql(u8, span, "ext_output_image_capture_source_manager_v1")) caps.source_mgr_ok = true;
    if (std.mem.eql(u8, span, "zwp_linux_dmabuf_v1") and isSupportedDmabufVersion(ver)) caps.dmabuf_ok = true;
}

const probe_registry_listener = c.wl_registry_listener{
    .global = probeRegistryGlobal,
    .global_remove = registryGlobalRemove,
};

/// Probe Wayland display connectivity and required capture/dmabuf globals.
pub fn probeWaylandCapabilities(wayland_display: ?[*:0]const u8) WaylandCapabilities {
    var caps = WaylandCapabilities{};
    const dpy = c.wl_display_connect(wayland_display) orelse return caps;
    defer c.wl_display_disconnect(dpy);
    caps.wayland_ok = true;

    const reg = c.wl_display_get_registry(dpy) orelse return caps;
    defer c.wl_registry_destroy(reg);

    _ = c.wl_registry_add_listener(reg, &probe_registry_listener, &caps);
    _ = c.wl_display_roundtrip(dpy);
    return caps;
}

fn sessionBufferSize(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.recordBufferSize(w, h);
}

fn sessionShmFormat(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
    _ = sess;
    _ = format;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.recordShmFormat();
}

fn sessionDmabufDevice(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, dev_array: [*c]c.wl_array) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    if (dev_array == null or dev_array.*.size < @sizeOf(c.dev_t) or dev_array.*.data == null) {
        self.recordShmFormat();
        return;
    }

    var dev: c.dev_t = 0;
    const src: [*]const u8 = @ptrCast(dev_array.*.data);
    @memcpy(std.mem.asBytes(&dev), src[0..@sizeOf(c.dev_t)]);
    const major: u32 = @intCast(((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(c.dev_t, 0xfff)));
    const minor: u32 = @intCast((dev & 0xff) | ((dev >> 12) & ~@as(c.dev_t, 0xff)));
    self.recordDmabufDevice(major, minor);
}

fn sessionDmabufFormat(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, format: u32, modifiers: [*c]c.wl_array) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));

    if (modifiers == null or modifiers.*.data == null or modifiers.*.size < @sizeOf(u64)) {
        self.recordDmabufFormat(format, &.{});
        return;
    }

    const total = modifiers.*.size / @sizeOf(u64);
    const bytes: [*]const u8 = @ptrCast(modifiers.*.data);
    var chunk: [64]u64 = undefined;
    var offset: usize = 0;
    while (offset < total) {
        const chunk_len = @min(total - offset, chunk.len);
        for (0..chunk_len) |i| {
            const byte_off = (offset + i) * @sizeOf(u64);
            @memcpy(std.mem.asBytes(&chunk[i]), bytes[byte_off .. byte_off + @sizeOf(u64)]);
        }
        self.recordDmabufFormat(format, chunk[0..chunk_len]);
        offset += chunk_len;
    }
}

fn sessionDone(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.markSessionDone();
}

fn sessionStopped(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.markSessionStopped();
}

const session_listener = c.ext_image_copy_capture_session_v1_listener{
    .buffer_size = sessionBufferSize,
    .shm_format = sessionShmFormat,
    .dmabuf_device = sessionDmabufDevice,
    .dmabuf_format = sessionDmabufFormat,
    .done = sessionDone,
    .stopped = sessionStopped,
};

fn frameTransform(data: ?*anyopaque, frame: ?*c.ext_image_copy_capture_frame_v1, transform: u32) callconv(.c) void {
    _ = frame;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.frame_transform = transform;
}

fn frameDamage(data: ?*anyopaque, frame: ?*c.ext_image_copy_capture_frame_v1, x: i32, y: i32, w: i32, h: i32) callconv(.c) void {
    _ = data;
    _ = frame;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
}

fn framePresentationTime(data: ?*anyopaque, frame: ?*c.ext_image_copy_capture_frame_v1, hi: u32, lo: u32, ns: u32) callconv(.c) void {
    _ = frame;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.pts_sec_hi = hi;
    self.pts_sec_lo = lo;
    self.pts_nsec = ns;
}

fn frameReady(data: ?*anyopaque, frame: ?*c.ext_image_copy_capture_frame_v1) callconv(.c) void {
    _ = frame;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.frame_ready = true;
}

fn frameFailed(data: ?*anyopaque, frame: ?*c.ext_image_copy_capture_frame_v1, reason: u32) callconv(.c) void {
    _ = frame;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.frame_failed = true;
    self.frame_failure_reason = reason;
}

const frame_listener = c.ext_image_copy_capture_frame_v1_listener{
    .transform = frameTransform,
    .damage = frameDamage,
    .presentation_time = framePresentationTime,
    .ready = frameReady,
    .failed = frameFailed,
};

test "CopyCaptureSession struct initialization and deadline math" {
    var sess = CopyCaptureSession{};
    try std.testing.expectEqual(@as(usize, 0), sess.advertisedFormats().len);
    try std.testing.expectEqual(@as(i32, -1), try CopyCaptureSession.remainingTimeoutMs(null));
    try std.testing.expectError(CaptureError.Timeout, CopyCaptureSession.remainingTimeoutMs(0));
    try std.testing.expect(!isSupportedDmabufVersion(1));
    try std.testing.expect(isSupportedDmabufVersion(2));
}

test "CopyCaptureSession constraint retention filters non-RGB formats and resets batches" {
    var sess = CopyCaptureSession{ .allocator = std.testing.allocator };
    defer sess.deinit();
    sess.recordBufferSize(1920, 1080);

    var nv12_mods: [150]u64 = undefined;
    for (&nv12_mods, 0..) |*m, idx| m.* = @intCast(idx + 1);
    sess.recordDmabufFormat(c.DRM_FORMAT_NV12, &nv12_mods);
    sess.recordDmabufFormat(c.DRM_FORMAT_XRGB8888, &.{ common.drm_mod_linear, common.drm_mod_linear });
    sess.markSessionDone();

    try std.testing.expectEqual(@as(usize, 1), sess.advertisedFormats().len);
    try std.testing.expectEqual(c.DRM_FORMAT_XRGB8888, sess.advertisedFormats()[0].format);
    try std.testing.expectEqual(common.drm_mod_linear, sess.advertisedFormats()[0].modifier);
    try sess.validateBufferDimensions(1920, 1080);

    // Constraint update after session_done clears previous formats and invalidates old buffer dimensions
    sess.recordBufferSize(1280, 720);
    try std.testing.expectEqual(@as(usize, 0), sess.advertisedFormats().len);
    try std.testing.expectError(CaptureError.BufferConstraints, sess.validateBufferDimensions(1920, 1080));

    sess.recordDmabufFormat(c.DRM_FORMAT_ARGB8888, &.{});
    sess.markSessionDone();
    try std.testing.expectEqual(@as(usize, 1), sess.advertisedFormats().len);
    try std.testing.expectEqual(c.DRM_FORMAT_ARGB8888, sess.advertisedFormats()[0].format);
    try std.testing.expectEqual(common.drm_mod_invalid, sess.advertisedFormats()[0].modifier);
    try std.testing.expect(!sess.constraint_alloc_failed);
}

test "CopyCaptureSession retains arbitrary modifier counts across formats without truncation" {
    var sess = CopyCaptureSession{ .allocator = std.testing.allocator };
    defer sess.deinit();
    sess.recordBufferSize(1920, 1080);

    var argb_mods: [300]u64 = undefined;
    for (&argb_mods, 0..) |*m, idx| m.* = @intCast(idx + 1);
    sess.recordDmabufFormat(c.DRM_FORMAT_ARGB8888, &argb_mods);
    sess.recordDmabufFormat(c.DRM_FORMAT_XRGB8888, &.{common.drm_mod_linear});
    sess.markSessionDone();

    try std.testing.expect(!sess.constraint_alloc_failed);
    try std.testing.expectEqual(@as(usize, 301), sess.advertisedFormats().len);
    const last = sess.advertisedFormats()[sess.advertisedFormats().len - 1];
    try std.testing.expectEqual(c.DRM_FORMAT_XRGB8888, last.format);
    try std.testing.expectEqual(common.drm_mod_linear, last.modifier);
}
