const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const pcm = @import("pcm.zig");

pub const AudioCaptureError = error{
    OutOfMemory,
    InvalidSource,
    WakeFdCreateFailed,
    MainloopInitFailed,
    ContextConnectFailed,
    StreamConnectFailed,
};

pub const default_monitor_source: [:0]const u8 = "@DEFAULT_MONITOR@";
pub const default_mic_source: [:0]const u8 = "@DEFAULT_SOURCE@";

/// OwningHandle around a non-blocking Linux eventfd descriptor.
pub const EventFd = struct {
    fd: std.posix.fd_t = -1,

    pub fn init() AudioCaptureError!EventFd {
        const raw_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (raw_fd < 0) return AudioCaptureError.WakeFdCreateFailed;
        return .{ .fd = raw_fd };
    }

    pub fn deinit(self: *EventFd) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn signal(self: EventFd) void {
        if (self.fd < 0) return;
        const val: u64 = 1;
        _ = c.write(self.fd, &val, @sizeOf(u64));
    }

    pub fn wait(self: EventFd, timeout_ms: c_int) void {
        if (self.fd < 0) return;
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, timeout_ms) > 0) {
            var val: u64 = 0;
            _ = c.read(self.fd, &val, @sizeOf(u64));
        }
    }
};

pub fn monotonicNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 1;
    const sec: u64 = @intCast(@max(@as(i64, 0), ts.tv_sec));
    const nsec: u64 = @intCast(@max(@as(i64, 0), ts.tv_nsec));
    return @max(@as(u64, 1), sec * std.time.ns_per_s + nsec);
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
        if (self.conn) |conn| mainloopSignalCb(conn.mainloop);
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

/// Shared OwningHandle managing a connected PulseAudio threaded mainloop and context.
const PulseConnection = struct {
    mainloop: *c.pa_threaded_mainloop,
    context: *c.pa_context,
    running: bool = false,

    fn connect(client_name: [*:0]const u8, no_autospawn: bool) AudioCaptureError!PulseConnection {
        const ml = c.pa_threaded_mainloop_new() orelse return AudioCaptureError.MainloopInitFailed;
        errdefer c.pa_threaded_mainloop_free(ml);

        const api = c.pa_threaded_mainloop_get_api(ml);
        const ctx = c.pa_context_new(api, client_name) orelse return AudioCaptureError.ContextConnectFailed;
        c.pa_context_set_state_callback(ctx, contextStateTrampoline, ml);

        var conn = PulseConnection{ .mainloop = ml, .context = ctx };
        errdefer conn.teardownInner();

        c.pa_threaded_mainloop_lock(ml);
        defer c.pa_threaded_mainloop_unlock(ml);

        if (c.pa_threaded_mainloop_start(ml) < 0) return AudioCaptureError.MainloopInitFailed;
        conn.running = true;

        const raw_flag = if (no_autospawn) c.PA_CONTEXT_NOAUTOSPAWN else c.PA_CONTEXT_NOFLAGS;
        const ctx_flags: c.pa_context_flags_t = @intCast(raw_flag);
        if (c.pa_context_connect(ctx, null, ctx_flags, null) < 0) return AudioCaptureError.ContextConnectFailed;
        if (!waitForContextReady(ml, ctx)) return AudioCaptureError.ContextConnectFailed;

        return conn;
    }

    fn teardownInner(self: *PulseConnection) void {
        c.pa_threaded_mainloop_lock(self.mainloop);
        c.pa_context_set_state_callback(self.context, null, null);
        c.pa_context_disconnect(self.context);
        c.pa_context_unref(self.context);
        c.pa_threaded_mainloop_unlock(self.mainloop);
        if (self.running) {
            c.pa_threaded_mainloop_stop(self.mainloop);
            self.running = false;
        }
    }

    fn deinit(self: *PulseConnection) void {
        self.teardownInner();
        c.pa_threaded_mainloop_free(self.mainloop);
    }
};

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
    wake: EventFd = .{},
    conn: ?PulseConnection = null,
    stream: ?*c.pa_stream = null,

    ring: pcm.AudioRingBuffer = .init(),
    first_sample_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    captured_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        mode: common.AudioSourceMode,
        wake: EventFd,
    ) AudioCaptureError!*AudioCapture {
        const target = try resolveSourceTarget(allocator, mode);
        errdefer if (target.owned) |owned| allocator.free(owned);

        const self = allocator.create(AudioCapture) catch return AudioCaptureError.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .owned_device_z = target.owned,
            .wake = wake,
        };
        errdefer {
            self.owned_device_z = null;
            self.deinit();
        }

        try self.openStream(target.ptr);
        return self;
    }

    fn openStream(self: *AudioCapture, device_ptr: [*:0]const u8) AudioCaptureError!void {
        self.conn = try PulseConnection.connect("wlrec", false);
        const conn = &self.conn.?;

        c.pa_threaded_mainloop_lock(conn.mainloop);
        defer c.pa_threaded_mainloop_unlock(conn.mainloop);

        const spec = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = pcm.sample_rate,
            .channels = @intCast(pcm.channels),
        };
        const stream = c.pa_stream_new(conn.context, "wlrec-audio", &spec, null) orelse {
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
        if (!waitForStreamReady(conn.mainloop, stream)) return AudioCaptureError.StreamConnectFailed;
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
            self.wake.signal();
        }
        if (pushed < stereo_frames) {
            _ = self.dropped_frames.fetchAdd(stereo_frames - pushed, .release);
        }
    }

    /// Consumer-side cap on queued pre-t0 audio before the first Wayland video frame arrives.
    pub fn trimPrestartBacklog(self: *AudioCapture, max_frames: usize) void {
        const readable = pcm.readableFrames(&self.ring);
        if (readable <= max_frames) return;
        const discarded = pcm.discardStereoFrames(&self.ring, readable - max_frames);
        if (discarded == 0) return;

        const advance_ns = (@as(u128, discarded) * std.time.ns_per_s) / pcm.sample_rate;
        const prev_ns = self.firstSampleNs();
        if (prev_ns > 0) {
            self.first_sample_ns.store(prev_ns + @as(u64, @intCast(advance_ns)), .release);
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
        if (self.conn) |*conn| {
            if (self.stream) |s| {
                c.pa_threaded_mainloop_lock(conn.mainloop);
                c.pa_stream_set_read_callback(s, null, null);
                c.pa_stream_set_state_callback(s, null, null);
                _ = c.pa_stream_disconnect(s);
                c.pa_stream_unref(s);
                self.stream = null;
                c.pa_threaded_mainloop_unlock(conn.mainloop);
            }
            conn.deinit();
            self.conn = null;
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
    var conn = PulseConnection.connect("wlrec-probe", true) catch return .{};
    defer conn.deinit();

    c.pa_threaded_mainloop_lock(conn.mainloop);
    defer c.pa_threaded_mainloop_unlock(conn.mainloop);

    var probe_state = ServerInfoProbeState{ .ml = conn.mainloop };
    const op = c.pa_context_get_server_info(conn.context, serverInfoTrampoline, &probe_state) orelse return .{};
    defer c.pa_operation_unref(op);

    while (!probe_state.done and c.pa_operation_get_state(op) == c.PA_OPERATION_RUNNING) {
        c.pa_threaded_mainloop_wait(conn.mainloop);
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

test "AudioCapture ingestRawChunk, trimPrestartBacklog, and EventFd wakeup" {
    var wake = try EventFd.init();
    defer wake.deinit();

    const cap = try std.testing.allocator.create(AudioCapture);
    cap.* = .{
        .allocator = std.testing.allocator,
        .wake = wake,
    };
    defer cap.deinit();

    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    cap.ingestRawChunk(&samples, @sizeOf(@TypeOf(samples)), 1_000_000_000);

    try std.testing.expectEqual(@as(u64, 1_000_000_000), cap.firstSampleNs());
    try std.testing.expectEqual(@as(u64, 2), cap.capturedFrames());
    wake.wait(0);

    // Stream hole (null data_ptr) + backlog trim advances first_sample_ns proportionally
    cap.ingestRawChunk(null, 48 * pcm.channels * @sizeOf(f32), 9_999_999_999);
    try std.testing.expectEqual(@as(u64, 50), cap.capturedFrames());
    cap.trimPrestartBacklog(2);
    try std.testing.expectEqual(@as(usize, 2), pcm.readableFrames(&cap.ring));
    try std.testing.expectEqual(@as(u64, 1_001_000_000), cap.firstSampleNs());

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
