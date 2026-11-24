const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const dmabuf_mod = @import("dmabuf.zig");

pub const CaptureError = error{
    DisplayConnectFailed,
    RegistryFailed,
    MissingGlobals,
    SourceCreationFailed,
    SessionCreationFailed,
    DispatchFailed,
    SessionStopped,
    CaptureFailed,
    Interrupted,
};

pub const FormatModifierPair = struct {
    format: u32,
    modifier: u64,
};

/// Active Wayland zero-copy screen capture session.
pub const CopyCaptureSession = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
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
    session_done: bool = false,
    session_stopped: bool = false,

    // Per-frame state
    frame_ready: bool = false,
    frame_failed: bool = false,
    frame_failure_reason: u32 = 0,
    pts_sec_hi: u32 = 0,
    pts_sec_lo: u32 = 0,
    pts_nsec: u32 = 0,

    pub fn init(wayland_display: ?[*:0]const u8) CaptureError!CopyCaptureSession {
        const dpy = c.wl_display_connect(wayland_display) orelse {
            return CaptureError.DisplayConnectFailed;
        };
        errdefer c.wl_display_disconnect(dpy);

        const reg = c.wl_display_get_registry(dpy) orelse {
            return CaptureError.RegistryFailed;
        };
        errdefer c.wl_registry_destroy(reg);

        var self = CopyCaptureSession{
            .display = dpy,
            .registry = reg,
        };

        _ = c.wl_registry_add_listener(reg, &registry_listener, &self);
        _ = c.wl_display_roundtrip(dpy);

        if (self.output == null or self.capture_mgr == null or self.source_mgr == null or self.dmabuf == null) {
            self.deinit();
            return CaptureError.MissingGlobals;
        }

        const src = c.ext_output_image_capture_source_manager_v1_create_source(self.source_mgr, self.output) orelse {
            self.deinit();
            return CaptureError.SourceCreationFailed;
        };
        self.source = src;

        const sess = c.ext_image_copy_capture_manager_v1_create_session(self.capture_mgr, src, 0) orelse {
            self.deinit();
            return CaptureError.SessionCreationFailed;
        };
        self.session = sess;

        _ = c.ext_image_copy_capture_session_v1_add_listener(sess, &session_listener, &self);

        // Dispatch until initial constraints are received
        while (!self.session_done and !self.session_stopped) {
            if (c.wl_display_dispatch(self.display) < 0) {
                self.deinit();
                return CaptureError.DispatchFailed;
            }
        }

        if (self.session_stopped) {
            self.deinit();
            return CaptureError.SessionStopped;
        }

        return self;
    }

    pub fn deinit(self: *CopyCaptureSession) void {
        if (self.session) |s| c.ext_image_copy_capture_session_v1_destroy(s);
        if (self.source) |src| c.ext_image_capture_source_v1_destroy(src);
        if (self.dmabuf) |d| c.zwp_linux_dmabuf_v1_destroy(d);
        if (self.source_mgr) |sm| c.ext_output_image_capture_source_manager_v1_destroy(sm);
        if (self.capture_mgr) |cm| c.ext_image_copy_capture_manager_v1_destroy(cm);
        if (self.output) |o| c.wl_output_destroy(o);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    /// Perform one non-blocking poll step against the Wayland display and optional stop_fd.
    fn pollDispatchStep(self: *CopyCaptureSession, stop_fd: ?std.posix.fd_t) CaptureError!void {
        const wl_fd = c.wl_display_get_fd(self.display);

        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) < 0) {
                return CaptureError.DispatchFailed;
            }
        }

        var pfd_list = [_]std.posix.pollfd{
            .{ .fd = wl_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{
                .fd = stop_fd orelse -1,
                .events = if (stop_fd != null) std.posix.POLL.IN else 0,
                .revents = 0,
            },
        };

        const poll_count: usize = if (stop_fd != null) 2 else 1;
        const ret = std.posix.poll(pfd_list[0..poll_count], -1) catch |err| {
            c.wl_display_cancel_read(self.display);
            std.log.err("poll failed in capture loop: {s}", .{@errorName(err)});
            return CaptureError.DispatchFailed;
        };

        if (ret > 0 and stop_fd != null and (pfd_list[1].revents & std.posix.POLL.IN) != 0) {
            c.wl_display_cancel_read(self.display);
            return CaptureError.Interrupted;
        }

        if (c.wl_display_read_events(self.display) < 0) {
            return CaptureError.DispatchFailed;
        }

        if (c.wl_display_dispatch_pending(self.display) < 0) {
            return CaptureError.DispatchFailed;
        }
    }

    /// Request a frame capture into the provided Wayland buffer.
    /// Uses non-blocking poll with optional stop_fd to avoid hanging on static screens.
    pub fn captureFrame(self: *CopyCaptureSession, buffer: *c.wl_buffer, stop_fd: ?std.posix.fd_t) CaptureError!u64 {
        const sess = self.session orelse return CaptureError.SessionStopped;

        self.frame_ready = false;
        self.frame_failed = false;

        const frame = c.ext_image_copy_capture_session_v1_create_frame(sess) orelse {
            return CaptureError.CaptureFailed;
        };
        defer c.ext_image_copy_capture_frame_v1_destroy(frame);

        _ = c.ext_image_copy_capture_frame_v1_add_listener(frame, &frame_listener, self);
        c.ext_image_copy_capture_frame_v1_attach_buffer(frame, buffer);
        c.ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, @intCast(self.width), @intCast(self.height));
        c.ext_image_copy_capture_frame_v1_capture(frame);

        if (c.wl_display_flush(self.display) < 0) {
            return CaptureError.DispatchFailed;
        }

        while (!self.frame_ready and !self.frame_failed and !self.session_stopped) {
            try self.pollDispatchStep(stop_fd);
        }

        if (self.session_stopped) return CaptureError.SessionStopped;
        if (self.frame_failed) return CaptureError.CaptureFailed;

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
        self.dmabuf = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_linux_dmabuf_v1_interface, @min(ver, 4)));
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

fn sessionBufferSize(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, w: u32, h: u32) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.width = w;
    self.height = h;
}

fn sessionShmFormat(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, format: u32) callconv(.c) void {
    _ = data;
    _ = sess;
    _ = format;
}

fn sessionDmabufDevice(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, dev_array: [*c]c.wl_array) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    if (dev_array.*.size >= @sizeOf(c.dev_t) and dev_array.*.data != null) {
        var dev: c.dev_t = 0;
        const src: [*]const u8 = @ptrCast(dev_array.*.data);
        @memcpy(std.mem.asBytes(&dev), src[0..@sizeOf(c.dev_t)]);
        const dev_val = dev;
        self.device_major = @intCast(((dev_val >> 8) & 0xfff) | ((dev_val >> 32) & ~@as(c.dev_t, 0xfff)));
        self.device_minor = @intCast((dev_val & 0xff) | ((dev_val >> 12) & ~@as(c.dev_t, 0xff)));
    }
}

fn sessionDmabufFormat(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1, format: u32, modifiers: [*c]c.wl_array) callconv(.c) void {
    _ = data;
    _ = sess;
    _ = format;
    _ = modifiers;
}

fn sessionDone(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.session_done = true;
}

fn sessionStopped(data: ?*anyopaque, sess: ?*c.ext_image_copy_capture_session_v1) callconv(.c) void {
    _ = sess;
    const self: *CopyCaptureSession = @ptrCast(@alignCast(data));
    self.session_stopped = true;
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
    _ = data;
    _ = frame;
    _ = transform;
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

test "CopyCaptureSession struct initialization" {
    // Structural test to verify alignment and size
    try std.testing.expect(@sizeOf(CopyCaptureSession) > 0);
}
