const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const pcm = @import("pcm.zig");

pub const AudioCaptureError = error{
    OutOfMemory,
    InvalidSource,
    MainloopInitFailed,
    ContextConnectFailed,
    StreamConnectFailed,
};

pub const default_monitor_source: [:0]const u8 = "@DEFAULT_MONITOR@";
pub const default_mic_source: [:0]const u8 = "@DEFAULT_SOURCE@";

pub fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 1;
    const sec: u64 = @intCast(@max(@as(i64, 0), ts.tv_sec));
    const nsec: u64 = @intCast(@max(@as(i64, 0), ts.tv_nsec));
    return @max(@as(u64, 1), sec * std.time.ns_per_s + nsec);
}

fn signalEventFd(fd: std.posix.fd_t) void {
    if (fd < 0) return;
    const val: u64 = 1;
    _ = c.write(fd, &val, @sizeOf(u64));
}

fn copyCStringBounded(dest: []u8, raw: [*c]const u8) usize {
    if (raw == null) return 0;
    const slice = std.mem.span(raw);
    const len = @min(dest.len, slice.len);
    @memcpy(dest[0..len], slice[0..len]);
    return len;
}

const ResolvedTarget = struct {
    ptr: [*:0]const u8,
    owned: ?[:0]u8 = null,
};

fn resolveSourceTarget(
    allocator: std.mem.Allocator,
    mode: common.AudioSourceMode,
) AudioCaptureError!ResolvedTarget {
    return switch (mode) {
        .desktop => .{ .ptr = default_monitor_source.ptr },
        .mic => .{ .ptr = default_mic_source.ptr },
        .device => |name| {
            if (name.len == 0) return AudioCaptureError.InvalidSource;
            const duped = allocator.dupeSentinel(u8, name, 0) catch return AudioCaptureError.OutOfMemory;
            return .{ .ptr = duped.ptr, .owned = duped };
        },
        .none, .both => AudioCaptureError.InvalidSource,
    };
}

fn mainloopSignalCb(ml_ptr: ?*c.pa_threaded_mainloop) void {
    if (ml_ptr) |ml| c.pa_threaded_mainloop_signal(ml, 0);
}

fn contextStateTrampoline(ctx: ?*c.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    const ml: *c.pa_threaded_mainloop = @ptrCast(@alignCast(userdata orelse return));
    const state = c.pa_context_get_state(ctx);
    if (state == c.PA_CONTEXT_READY or state == c.PA_CONTEXT_FAILED or state == c.PA_CONTEXT_TERMINATED) {
        mainloopSignalCb(ml);
    }
}

fn streamStateTrampoline(stream: ?*c.pa_stream, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioCapture = @ptrCast(@alignCast(userdata orelse return));
    const state = c.pa_stream_get_state(stream);
    if (state == c.PA_STREAM_READY or state == c.PA_STREAM_FAILED or state == c.PA_STREAM_TERMINATED) {
        mainloopSignalCb(self.mainloop);
    }
}

fn streamReadTrampoline(stream: ?*c.pa_stream, _: usize, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioCapture = @ptrCast(@alignCast(userdata orelse return));
    const s = stream orelse return;
    self.handleStreamRead(s);
}

fn waitForContextReady(ml: *c.pa_threaded_mainloop, ctx: *c.pa_context) bool {
    while (true) {
        const state = c.pa_context_get_state(ctx);
        if (state == c.PA_CONTEXT_READY) return true;
        if (c.PA_CONTEXT_IS_GOOD(state) == 0) return false;
        c.pa_threaded_mainloop_wait(ml);
    }
}

fn waitForStreamReady(ml: *c.pa_threaded_mainloop, stream: *c.pa_stream) bool {
    while (true) {
        const state = c.pa_stream_get_state(stream);
        if (state == c.PA_STREAM_READY) return true;
        if (c.PA_STREAM_IS_GOOD(state) == 0) return false;
        c.pa_threaded_mainloop_wait(ml);
    }
}

fn computeStreamStartNs(stream: *c.pa_stream) u64 {
    const now_ns = monotonicNs();
    var lat_usec: c.pa_usec_t = 0;
    var negative: c_int = 0;
    if (c.pa_stream_get_latency(stream, &lat_usec, &negative) == 0 and negative == 0) {
        const lat_ns = @as(u64, lat_usec) * std.time.ns_per_us;
        return @max(@as(u64, 1), now_ns -| lat_ns);
    }
    return now_ns;
}

/// Owning real-time PulseAudio/PipeWire capture stream writing into a lock-free SPSC ring buffer.
pub const AudioCapture = struct {
    allocator: std.mem.Allocator,
    owned_device_z: ?[:0]u8 = null,
    wake_fd: std.posix.fd_t = -1,
    mainloop: ?*c.pa_threaded_mainloop = null,
    context: ?*c.pa_context = null,
    stream: ?*c.pa_stream = null,

    ring: pcm.AudioRingBuffer = .init(),
    first_sample_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    captured_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        mode: common.AudioSourceMode,
        wake_fd: std.posix.fd_t,
    ) AudioCaptureError!*AudioCapture {
        const target = try resolveSourceTarget(allocator, mode);
        errdefer if (target.owned) |owned| allocator.free(owned);

        const self = allocator.create(AudioCapture) catch return AudioCaptureError.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .owned_device_z = target.owned,
            .wake_fd = wake_fd,
        };
        errdefer {
            self.owned_device_z = null;
            self.deinit();
        }

        try self.connectPulseStream(target.ptr);
        return self;
    }

    fn connectPulseStream(self: *AudioCapture, device_ptr: [*:0]const u8) AudioCaptureError!void {
        const ml = c.pa_threaded_mainloop_new() orelse return AudioCaptureError.MainloopInitFailed;
        self.mainloop = ml;

        const api = c.pa_threaded_mainloop_get_api(ml);
        const ctx = c.pa_context_new(api, "wlrec") orelse return AudioCaptureError.ContextConnectFailed;
        self.context = ctx;
        c.pa_context_set_state_callback(ctx, contextStateTrampoline, ml);

        c.pa_threaded_mainloop_lock(ml);
        defer c.pa_threaded_mainloop_unlock(ml);

        if (c.pa_threaded_mainloop_start(ml) < 0) return AudioCaptureError.MainloopInitFailed;
        const ctx_flags: c.pa_context_flags_t = @intCast(c.PA_CONTEXT_NOFLAGS);
        if (c.pa_context_connect(ctx, null, ctx_flags, null) < 0) return AudioCaptureError.ContextConnectFailed;
        if (!waitForContextReady(ml, ctx)) return AudioCaptureError.ContextConnectFailed;

        const spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = pcm.sample_rate,
            .channels = @intCast(pcm.channels),
        };
        const stream = c.pa_stream_new(ctx, "wlrec-audio", &spec, null) orelse {
            return AudioCaptureError.StreamConnectFailed;
        };
        self.stream = stream;
        c.pa_stream_set_state_callback(stream, streamStateTrampoline, self);
        c.pa_stream_set_read_callback(stream, streamReadTrampoline, self);

        const attr = c.pa_buffer_attr{
            .maxlength = std.math.maxInt(u32),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = @intCast(pcm.block_floats * @sizeOf(f32)),
        };
        const flags: c.pa_stream_flags_t = @intCast(c.PA_STREAM_ADJUST_LATENCY | c.PA_STREAM_AUTO_TIMING_UPDATE);
        if (c.pa_stream_connect_record(stream, device_ptr, &attr, flags) < 0) {
            return AudioCaptureError.StreamConnectFailed;
        }
        if (!waitForStreamReady(ml, stream)) return AudioCaptureError.StreamConnectFailed;
    }

    /// Zero-allocation, lock-free ingestion of one PulseAudio read fragment.
    pub fn ingestRawChunk(
        self: *AudioCapture,
        data_ptr: ?*const anyopaque,
        nbytes: usize,
        sample_start_ns: u64,
    ) void {
        const stereo_frames = (nbytes / @sizeOf(f32)) / pcm.channels;
        if (stereo_frames == 0) return;

        if (sample_start_ns > 0) {
            _ = self.first_sample_ns.cmpxchgStrong(0, sample_start_ns, .release, .monotonic);
        }

        const pushed = if (data_ptr) |ptr| blk: {
            const floats: [*]const f32 = @ptrCast(@alignCast(ptr));
            break :blk pcm.pushStereoFrames(&self.ring, floats[0 .. stereo_frames * pcm.channels]);
        } else pcm.pushSilenceFrames(&self.ring, stereo_frames);

        if (pushed > 0) {
            _ = self.captured_frames.fetchAdd(pushed, .monotonic);
            signalEventFd(self.wake_fd);
        }
        if (pushed < stereo_frames) {
            _ = self.dropped_frames.fetchAdd(stereo_frames - pushed, .release);
        }
    }

    fn handleStreamRead(self: *AudioCapture, stream: *c.pa_stream) void {
        while (c.pa_stream_readable_size(stream) > 0) {
            var data_ptr: ?*const anyopaque = null;
            var nbytes: usize = 0;
            if (c.pa_stream_peek(stream, &data_ptr, &nbytes) < 0 or nbytes == 0) break;

            const start_ns = if (self.first_sample_ns.load(.monotonic) == 0)
                computeStreamStartNs(stream)
            else
                0;
            self.ingestRawChunk(data_ptr, nbytes, start_ns);
            _ = c.pa_stream_drop(stream);
        }
    }

    pub fn firstSampleNs(self: *const AudioCapture) u64 {
        return self.first_sample_ns.load(.acquire);
    }

    pub fn capturedFrames(self: *const AudioCapture) u64 {
        return self.captured_frames.load(.acquire);
    }

    pub fn droppedFrames(self: *const AudioCapture) u64 {
        return self.dropped_frames.load(.acquire);
    }

    pub fn deinit(self: *AudioCapture) void {
        if (self.mainloop) |ml| {
            c.pa_threaded_mainloop_lock(ml);
            if (self.stream) |s| {
                c.pa_stream_set_read_callback(s, null, null);
                c.pa_stream_set_state_callback(s, null, null);
                _ = c.pa_stream_disconnect(s);
                c.pa_stream_unref(s);
                self.stream = null;
            }
            if (self.context) |ctx| {
                c.pa_context_set_state_callback(ctx, null, null);
                c.pa_context_disconnect(ctx);
                c.pa_context_unref(ctx);
                self.context = null;
            }
            c.pa_threaded_mainloop_unlock(ml);
            c.pa_threaded_mainloop_stop(ml);
            c.pa_threaded_mainloop_free(ml);
            self.mainloop = null;
        }
        if (self.owned_device_z) |owned| {
            self.allocator.free(owned);
            self.owned_device_z = null;
        }
        self.allocator.destroy(self);
    }
};

pub const AudioProbeReport = struct {
    available: bool = false,
    server_name_buf: [128]u8 = @splat(0),
    server_name_len: usize = 0,
    default_sink_buf: [128]u8 = @splat(0),
    default_sink_len: usize = 0,
    default_source_buf: [128]u8 = @splat(0),
    default_source_len: usize = 0,

    pub fn serverName(self: *const AudioProbeReport) []const u8 {
        return self.server_name_buf[0..self.server_name_len];
    }

    pub fn defaultSink(self: *const AudioProbeReport) []const u8 {
        return self.default_sink_buf[0..self.default_sink_len];
    }

    pub fn defaultSource(self: *const AudioProbeReport) []const u8 {
        return self.default_source_buf[0..self.default_source_len];
    }
};

const ServerInfoProbeState = struct {
    ml: *c.pa_threaded_mainloop,
    report: AudioProbeReport = .{},
    done: bool = false,
};

fn serverInfoTrampoline(
    _: ?*c.pa_context,
    info_ptr: [*c]const c.pa_server_info,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const st: *ServerInfoProbeState = @ptrCast(@alignCast(userdata orelse return));
    if (info_ptr != null) {
        const info = info_ptr.*;
        st.report.available = true;
        st.report.server_name_len = copyCStringBounded(&st.report.server_name_buf, info.server_name);
        st.report.default_sink_len = copyCStringBounded(&st.report.default_sink_buf, info.default_sink_name);
        st.report.default_source_len = copyCStringBounded(&st.report.default_source_buf, info.default_source_name);
    }
    st.done = true;
    c.pa_threaded_mainloop_signal(st.ml, 0);
}

/// Non-spawning probe of the local PulseAudio / PipeWire-Pulse server and default endpoints.
pub fn probePulseAudio() AudioProbeReport {
    const ml = c.pa_threaded_mainloop_new() orelse return .{};
    defer c.pa_threaded_mainloop_free(ml);

    const api = c.pa_threaded_mainloop_get_api(ml);
    const ctx = c.pa_context_new(api, "wlrec-probe") orelse return .{};
    c.pa_context_set_state_callback(ctx, contextStateTrampoline, ml);

    c.pa_threaded_mainloop_lock(ml);
    var running = false;
    defer {
        c.pa_context_set_state_callback(ctx, null, null);
        c.pa_context_disconnect(ctx);
        c.pa_context_unref(ctx);
        c.pa_threaded_mainloop_unlock(ml);
        if (running) c.pa_threaded_mainloop_stop(ml);
    }

    if (c.pa_threaded_mainloop_start(ml) < 0) return .{};
    running = true;

    const flags: c.pa_context_flags_t = @intCast(c.PA_CONTEXT_NOAUTOSPAWN);
    if (c.pa_context_connect(ctx, null, flags, null) < 0) return .{};
    if (!waitForContextReady(ml, ctx)) return .{};

    var probe_state = ServerInfoProbeState{ .ml = ml };
    const op = c.pa_context_get_server_info(ctx, serverInfoTrampoline, &probe_state) orelse return .{};
    defer c.pa_operation_unref(op);

    while (!probe_state.done and c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
        c.pa_threaded_mainloop_wait(ml);
    }
    return probe_state.report;
}

test "resolveSourceTarget maps built-in modes and rejects unsupported composites" {
    const desk = try resolveSourceTarget(std.testing.allocator, .desktop);
    try std.testing.expectEqualStrings("@DEFAULT_MONITOR@", std.mem.span(desk.ptr));
    try std.testing.expect(desk.owned == null);

    const mic = try resolveSourceTarget(std.testing.allocator, .mic);
    try std.testing.expectEqualStrings("@DEFAULT_SOURCE@", std.mem.span(mic.ptr));

    const custom = try resolveSourceTarget(std.testing.allocator, .{ .device = "custom.src" });
    defer if (custom.owned) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("custom.src", std.mem.span(custom.ptr));

    try std.testing.expectError(AudioCaptureError.InvalidSource, resolveSourceTarget(std.testing.allocator, .none));
    try std.testing.expectError(AudioCaptureError.InvalidSource, resolveSourceTarget(std.testing.allocator, .both));
}

test "AudioCapture ingestRawChunk records first timestamp, handles holes, and signals wake_fd" {
    const efd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    try std.testing.expect(efd >= 0);
    defer _ = c.close(efd);

    const cap = try std.testing.allocator.create(AudioCapture);
    cap.* = .{
        .allocator = std.testing.allocator,
        .wake_fd = efd,
    };
    defer cap.deinit();

    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    cap.ingestRawChunk(&samples, @sizeOf(@TypeOf(samples)), 123_456_789);

    try std.testing.expectEqual(@as(u64, 123_456_789), cap.firstSampleNs());
    try std.testing.expectEqual(@as(u64, 2), cap.capturedFrames());
    try std.testing.expectEqual(@as(u64, 0), cap.droppedFrames());

    var wake_val: u64 = 0;
    try std.testing.expectEqual(@as(isize, @sizeOf(u64)), c.read(efd, &wake_val, @sizeOf(u64)));
    try std.testing.expectEqual(@as(u64, 1), wake_val);

    // Subsequent chunk must not overwrite firstSampleNs; null data_ptr represents stream hole
    cap.ingestRawChunk(null, 4 * pcm.channels * @sizeOf(f32), 999_999_999);
    try std.testing.expectEqual(@as(u64, 123_456_789), cap.firstSampleNs());
    try std.testing.expectEqual(@as(u64, 6), cap.capturedFrames());

    // Overflow accounting
    const cap_pairs = pcm.ring_capacity_floats / pcm.channels;
    _ = pcm.pushSilenceFrames(&cap.ring, cap_pairs);
    cap.ingestRawChunk(&samples, @sizeOf(@TypeOf(samples)), 0);
    try std.testing.expectEqual(@as(u64, 2), cap.droppedFrames());
}

test "probePulseAudio returns cleanly with or without running daemon" {
    const report = probePulseAudio();
    if (report.available) {
        try std.testing.expect(report.serverName().len > 0);
    } else {
        try std.testing.expectEqual(@as(usize, 0), report.serverName().len);
    }
}
