const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const sink = @import("sink.zig");

const video_queue_capacity = 128;
const audio_queue_capacity = 256;
const io_timeout_ms: u64 = 2000;
const initial_backoff_ms: u64 = 500;
const max_backoff_ms: u64 = 4000;

pub const StreamKind = enum {
    video,
    audio,
};

const QueuedPacket = struct {
    kind: StreamKind,
    pkt: *c.AVPacket,
};

fn monotonicMs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    const sec: u64 = @intCast(@max(@as(i64, 0), ts.tv_sec));
    const nsec: u64 = @intCast(@max(@as(i64, 0), ts.tv_nsec));
    return sec * 1000 + nsec / 1_000_000;
}

fn rtmpInterruptCb(opaque_ptr: ?*anyopaque) callconv(.c) c_int {
    const worker: *RtmpWorker = @ptrCast(@alignCast(opaque_ptr orelse return 0));
    if (worker.stop_requested.load(.acquire) and !worker.flushing_tail.load(.acquire)) return 1;
    const deadline = worker.io_deadline_ms.load(.acquire);
    if (deadline > 0 and monotonicMs() >= deadline) return 1;
    return 0;
}

const RtmpConnection = struct {
    fmt_ctx: *c.AVFormatContext,
    video_stream: *c.AVStream,
    audio_stream: ?*c.AVStream = null,

    fn close(self: *RtmpConnection, write_trailer: bool) void {
        if (write_trailer) {
            _ = c.av_write_trailer(self.fmt_ctx);
        }
        if (self.fmt_ctx.*.pb != null) {
            _ = c.avio_closep(&self.fmt_ctx.*.pb);
        }
        c.avformat_free_context(self.fmt_ctx);
    }
};

const ReconnectState = struct {
    conn: ?RtmpConnection = null,
    next_connect_ms: u64 = 0,
    backoff_ms: u64 = initial_backoff_ms,
    had_connected: bool = false,
    wait_for_keyframe: bool = true,
    last_drop_seq: u64 = 0,
};

/// Evaluate whether a packet must be dropped while waiting for the next video IDR keyframe.
pub fn shouldDropForKeyframe(is_video: bool, is_keyframe: bool, wait_for_keyframe: *bool) bool {
    if (!wait_for_keyframe.*) return false;
    if (is_video and is_keyframe) {
        wait_for_keyframe.* = false;
        return false;
    }
    return true;
}

fn freeRawPacket(pkt: *c.AVPacket) void {
    var p: ?*c.AVPacket = pkt;
    c.av_packet_free(&p);
}

fn effectiveDts(pkt: *const c.AVPacket) i64 {
    if (pkt.*.dts != c.AV_NOPTS_VALUE) return pkt.*.dts;
    if (pkt.*.pts != c.AV_NOPTS_VALUE) return pkt.*.pts;
    return 0;
}

fn copyCodecParams(codec_ctx: *const c.AVCodecContext) sink.MuxError!*c.AVCodecParameters {
    const codecpar = c.avcodec_parameters_alloc() orelse return sink.MuxError.OutOfMemory;
    errdefer {
        var cp: ?*c.AVCodecParameters = codecpar;
        c.avcodec_parameters_free(&cp);
    }
    if (c.avcodec_parameters_from_context(codecpar, codec_ctx) < 0) {
        return sink.MuxError.CodecParamsCopyFailed;
    }
    return codecpar;
}

fn addStreamFromParams(
    ctx: *c.AVFormatContext,
    params: *const c.AVCodecParameters,
    time_base: c.AVRational,
    avg_frame_rate: ?c.AVRational,
) sink.MuxError!*c.AVStream {
    const stream = c.avformat_new_stream(ctx, null) orelse return sink.MuxError.StreamAllocFailed;
    stream.*.id = @intCast(ctx.*.nb_streams - 1);
    stream.*.time_base = time_base;
    if (avg_frame_rate) |fps| {
        if (fps.num > 0 and fps.den > 0) stream.*.avg_frame_rate = fps;
    }
    if (c.avcodec_parameters_copy(stream.*.codecpar, params) < 0) {
        return sink.MuxError.CodecParamsCopyFailed;
    }
    return stream;
}

/// Dedicated non-blocking dual-track RTMP packet queues, DTS interleaver, and reconnect state machine.
pub const RtmpWorker = struct {
    allocator: std.mem.Allocator,
    target_z: [:0]u8,
    saved_video_codecpar: *c.AVCodecParameters,
    video_src_time_base: c.AVRational,
    avg_frame_rate: c.AVRational,
    saved_audio_codecpar: ?*c.AVCodecParameters = null,
    audio_src_time_base: c.AVRational = .{ .num = 1, .den = 48_000 },
    wake_fd: std.posix.fd_t,

    video_queue: common.SpscRingBuffer(*c.AVPacket, video_queue_capacity) = .init(),
    audio_queue: common.SpscRingBuffer(*c.AVPacket, audio_queue_capacity) = .init(),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    flushing_tail: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    io_deadline_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    push_drop_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    packets_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reconnects: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        target: []const u8,
        video_ctx: *const c.AVCodecContext,
        audio_ctx: ?*const c.AVCodecContext,
    ) sink.MuxError!*RtmpWorker {
        const target_z = allocator.dupeSentinel(u8, target, 0) catch return sink.MuxError.OutOfMemory;
        errdefer allocator.free(target_z);

        const video_par = try copyCodecParams(video_ctx);
        errdefer {
            var vp: ?*c.AVCodecParameters = video_par;
            c.avcodec_parameters_free(&vp);
        }

        var audio_par: ?*c.AVCodecParameters = null;
        var audio_tb = c.AVRational{ .num = 1, .den = 48_000 };
        if (audio_ctx) |actx| {
            audio_par = try copyCodecParams(actx);
            audio_tb = actx.*.time_base;
        }
        errdefer if (audio_par) |ap| {
            var opt_ap: ?*c.AVCodecParameters = ap;
            c.avcodec_parameters_free(&opt_ap);
        };

        const wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (wake_fd < 0) return sink.MuxError.OutputOpenFailed;
        errdefer _ = c.close(wake_fd);

        const worker = allocator.create(RtmpWorker) catch return sink.MuxError.OutOfMemory;
        worker.* = .{
            .allocator = allocator,
            .target_z = target_z,
            .saved_video_codecpar = video_par,
            .video_src_time_base = video_ctx.*.time_base,
            .avg_frame_rate = video_ctx.*.framerate,
            .saved_audio_codecpar = audio_par,
            .audio_src_time_base = audio_tb,
            .wake_fd = wake_fd,
        };
        return worker;
    }

    pub fn start(self: *RtmpWorker) sink.MuxError!void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, workerLoop, .{self}) catch {
            return sink.MuxError.OutputOpenFailed;
        };
    }

    fn signalWake(self: *const RtmpWorker) void {
        const val: u64 = 1;
        _ = c.write(self.wake_fd, &val, @sizeOf(u64));
    }

    fn clearWake(self: *const RtmpWorker) void {
        var val: u64 = 0;
        _ = c.read(self.wake_fd, &val, @sizeOf(u64));
    }

    fn cloneForQueue(raw_pkt: *const c.AVPacket) ?*c.AVPacket {
        const cloned = c.av_packet_alloc() orelse return null;
        if (c.av_packet_ref(cloned, raw_pkt) < 0) {
            freeRawPacket(cloned);
            return null;
        }
        return cloned;
    }

    /// Non-blocking video packet enqueue. Drops the packet and arms keyframe gating if full.
    pub fn enqueueVideoPacket(self: *RtmpWorker, raw_pkt: *const c.AVPacket) void {
        const cloned = cloneForQueue(raw_pkt) orelse {
            self.recordPushDrop(true);
            return;
        };
        if (!self.video_queue.push(cloned)) {
            freeRawPacket(cloned);
            self.recordPushDrop(true);
            return;
        }
        self.signalWake();
    }

    /// Non-blocking audio packet enqueue. Drops the packet immediately if the audio queue is full.
    pub fn enqueueAudioPacket(self: *RtmpWorker, raw_pkt: *const c.AVPacket) void {
        const cloned = cloneForQueue(raw_pkt) orelse {
            self.recordPushDrop(false);
            return;
        };
        if (!self.audio_queue.push(cloned)) {
            freeRawPacket(cloned);
            self.recordPushDrop(false);
            return;
        }
        self.signalWake();
    }

    fn recordPushDrop(self: *RtmpWorker, trigger_keyframe_gate: bool) void {
        _ = self.packets_dropped.fetchAdd(1, .monotonic);
        if (trigger_keyframe_gate) {
            _ = self.push_drop_seq.fetchAdd(1, .release);
        }
    }

    pub fn getStats(self: *const RtmpWorker) sink.MuxStats {
        return .{
            .packets_written = self.packets_written.load(.monotonic),
            .packets_dropped = self.packets_dropped.load(.monotonic),
            .bytes_written = self.bytes_written.load(.monotonic),
            .reconnects = self.reconnects.load(.monotonic),
        };
    }

    pub fn stopAndJoin(self: *RtmpWorker) void {
        self.stop_requested.store(true, .release);
        self.signalWake();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *RtmpWorker) void {
        self.stopAndJoin();
        self.drainRemainingDropped();
        _ = c.close(self.wake_fd);
        var vp: ?*c.AVCodecParameters = self.saved_video_codecpar;
        c.avcodec_parameters_free(&vp);
        if (self.saved_audio_codecpar) |ap| {
            var ap_opt: ?*c.AVCodecParameters = ap;
            c.avcodec_parameters_free(&ap_opt);
        }
        self.allocator.free(self.target_z);
        self.allocator.destroy(self);
    }

    fn drainRemainingDropped(self: *RtmpWorker) void {
        while (self.video_queue.pop()) |pkt| {
            freeRawPacket(pkt);
            _ = self.packets_dropped.fetchAdd(1, .monotonic);
        }
        while (self.audio_queue.pop()) |pkt| {
            freeRawPacket(pkt);
            _ = self.packets_dropped.fetchAdd(1, .monotonic);
        }
    }

    fn waitWake(self: *const RtmpWorker, timeout_ms: i32) void {
        self.clearWake();
        if (self.stop_requested.load(.acquire)) return;
        var pfd = [_]c.struct_pollfd{
            .{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&pfd[0], 1, timeout_ms);
    }

    fn openConnection(self: *RtmpWorker) ?RtmpConnection {
        return self.openConnectionFallible() catch |err| {
            std.log.debug("rtmp connect attempt failed: {s}", .{@errorName(err)});
            return null;
        };
    }

    fn openConnectionFallible(self: *RtmpWorker) sink.MuxError!RtmpConnection {
        var fmt_ctx: ?*c.AVFormatContext = null;
        if (c.avformat_alloc_output_context2(&fmt_ctx, null, "flv", self.target_z.ptr) < 0 or fmt_ctx == null) {
            return sink.MuxError.MuxContextAllocFailed;
        }
        const ctx = fmt_ctx.?;
        errdefer c.avformat_free_context(ctx);

        ctx.*.interrupt_callback = .{
            .callback = rtmpInterruptCb,
            .@"opaque" = self,
        };

        const video_stream = try addStreamFromParams(
            ctx,
            self.saved_video_codecpar,
            self.video_src_time_base,
            self.avg_frame_rate,
        );
        var audio_stream: ?*c.AVStream = null;
        if (self.saved_audio_codecpar) |audio_par| {
            audio_stream = try addStreamFromParams(ctx, audio_par, self.audio_src_time_base, null);
        }
        ctx.*.max_interleave_delta = sink.interleave_delta_us;

        var opts: ?*c.AVDictionary = null;
        _ = c.av_dict_set(&opts, "rw_timeout", "2000000", 0);
        defer c.av_dict_free(&opts);

        self.io_deadline_ms.store(monotonicMs() + io_timeout_ms, .release);
        const open_rc = c.avio_open2(&ctx.*.pb, self.target_z.ptr, c.AVIO_FLAG_WRITE, &ctx.*.interrupt_callback, &opts);
        self.io_deadline_ms.store(0, .release);
        if (open_rc < 0) return sink.MuxError.OutputOpenFailed;
        errdefer _ = c.avio_closep(&ctx.*.pb);

        self.io_deadline_ms.store(monotonicMs() + io_timeout_ms, .release);
        const hdr_rc = c.avformat_write_header(ctx, null);
        self.io_deadline_ms.store(0, .release);
        if (hdr_rc < 0) return sink.MuxError.HeaderWriteFailed;

        return .{
            .fmt_ctx = ctx,
            .video_stream = video_stream,
            .audio_stream = audio_stream,
        };
    }

    fn popNextOrderedPacket(self: *RtmpWorker) ?QueuedPacket {
        const v_peek = self.video_queue.peek();
        const a_peek = self.audio_queue.peek();
        if (v_peek == null and a_peek == null) return null;

        const pick_video = if (v_peek != null and a_peek != null)
            c.av_compare_ts(
                effectiveDts(v_peek.?),
                self.video_src_time_base,
                effectiveDts(a_peek.?),
                self.audio_src_time_base,
            ) <= 0
        else
            v_peek != null;

        if (pick_video) {
            return .{ .kind = .video, .pkt = self.video_queue.pop().? };
        }
        return .{ .kind = .audio, .pkt = self.audio_queue.pop().? };
    }

    fn writeOnePacket(self: *RtmpWorker, conn: *RtmpConnection, item: QueuedPacket) bool {
        const target_stream = switch (item.kind) {
            .video => conn.video_stream,
            .audio => conn.audio_stream orelse return true,
        };
        const src_tb = switch (item.kind) {
            .video => self.video_src_time_base,
            .audio => self.audio_src_time_base,
        };

        c.av_packet_rescale_ts(item.pkt, src_tb, target_stream.*.time_base);
        item.pkt.*.stream_index = target_stream.*.index;
        item.pkt.*.pos = -1;
        const pkt_bytes: u64 = if (item.pkt.*.size > 0) @intCast(item.pkt.*.size) else 0;

        self.io_deadline_ms.store(monotonicMs() + io_timeout_ms, .release);
        const rc = c.av_interleaved_write_frame(conn.fmt_ctx, item.pkt);
        self.io_deadline_ms.store(0, .release);
        if (rc < 0) return false;

        _ = self.bytes_written.fetchAdd(pkt_bytes, .monotonic);
        _ = self.packets_written.fetchAdd(1, .monotonic);
        return true;
    }

    fn syncDropGate(self: *const RtmpWorker, state: *ReconnectState) void {
        const cur_drop_seq = self.push_drop_seq.load(.acquire);
        if (cur_drop_seq != state.last_drop_seq) {
            state.last_drop_seq = cur_drop_seq;
            state.wait_for_keyframe = true;
        }
    }

    fn flushConnectedTail(self: *RtmpWorker, conn: *RtmpConnection, state: *ReconnectState) void {
        self.flushing_tail.store(true, .release);
        defer self.flushing_tail.store(false, .release);

        while (self.popNextOrderedPacket()) |item| {
            defer freeRawPacket(item.pkt);
            self.syncDropGate(state);
            const is_key = (item.pkt.*.flags & c.AV_PKT_FLAG_KEY) != 0;
            if (shouldDropForKeyframe(item.kind == .video, is_key, &state.wait_for_keyframe)) {
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
                continue;
            }
            if (!self.writeOnePacket(conn, item)) {
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
                break;
            }
        }
        self.io_deadline_ms.store(monotonicMs() + io_timeout_ms, .release);
        conn.close(true);
        self.io_deadline_ms.store(0, .release);
    }

    fn handleDisconnected(self: *RtmpWorker, state: *ReconnectState) void {
        const now = monotonicMs();
        if (now < state.next_connect_ms) {
            self.drainRemainingDropped();
            const wait_ms: i32 = @intCast(@min(@as(u64, 50), state.next_connect_ms - now));
            self.waitWake(wait_ms);
            return;
        }
        if (self.openConnection()) |new_conn| {
            state.conn = new_conn;
            state.wait_for_keyframe = true;
            state.backoff_ms = initial_backoff_ms;
            if (state.had_connected) {
                _ = self.reconnects.fetchAdd(1, .monotonic);
            }
            state.had_connected = true;
            return;
        }
        self.drainRemainingDropped();
        state.wait_for_keyframe = true;
        state.next_connect_ms = monotonicMs() + state.backoff_ms;
        state.backoff_ms = @min(state.backoff_ms * 2, max_backoff_ms);
    }

    fn processNextPacket(self: *RtmpWorker, state: *ReconnectState) void {
        const item = self.popNextOrderedPacket() orelse {
            self.waitWake(50);
            return;
        };
        defer freeRawPacket(item.pkt);

        self.syncDropGate(state);

        const is_key = (item.pkt.*.flags & c.AV_PKT_FLAG_KEY) != 0;
        if (shouldDropForKeyframe(item.kind == .video, is_key, &state.wait_for_keyframe)) {
            _ = self.packets_dropped.fetchAdd(1, .monotonic);
            return;
        }

        var conn = state.conn.?;
        if (self.writeOnePacket(&conn, item)) {
            state.backoff_ms = initial_backoff_ms;
            return;
        }

        conn.close(false);
        state.conn = null;
        _ = self.packets_dropped.fetchAdd(1, .monotonic);
        state.wait_for_keyframe = true;
        state.next_connect_ms = monotonicMs() + state.backoff_ms;
        state.backoff_ms = @min(state.backoff_ms * 2, max_backoff_ms);
    }

    fn workerLoop(self: *RtmpWorker) void {
        var state = ReconnectState{
            .last_drop_seq = self.push_drop_seq.load(.acquire),
        };

        while (!self.stop_requested.load(.acquire)) {
            if (state.conn == null) {
                self.handleDisconnected(&state);
                continue;
            }
            self.processNextPacket(&state);
        }

        if (state.conn) |*active| {
            self.flushConnectedTail(active, &state);
            state.conn = null;
        }
        self.drainRemainingDropped();
    }
};

test "shouldDropForKeyframe gates inter-frames and pre-IDR audio until next video IDR" {
    var wait_kf = true;
    try std.testing.expect(shouldDropForKeyframe(true, false, &wait_kf));
    try std.testing.expect(shouldDropForKeyframe(false, true, &wait_kf));
    try std.testing.expect(wait_kf);

    try std.testing.expect(!shouldDropForKeyframe(true, true, &wait_kf));
    try std.testing.expect(!wait_kf);

    try std.testing.expect(!shouldDropForKeyframe(true, false, &wait_kf));
    try std.testing.expect(!shouldDropForKeyframe(false, true, &wait_kf));
}

test "RtmpWorker drops overflow packets non-blockingly and interleaves A/V by DTS" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    const vctx = try sink.allocTestH264Context(false);
    var vctx_opt: ?*c.AVCodecContext = vctx;
    defer c.avcodec_free_context(&vctx_opt);

    const actx = try sink.allocTestAacContext();
    var actx_opt: ?*c.AVCodecContext = actx;
    defer c.avcodec_free_context(&actx_opt);

    const worker = try RtmpWorker.init(std.testing.allocator, "rtmp://127.0.0.1:19359/live/test", vctx, actx);
    defer worker.deinit();

    const v_dts = [_]i64{ 0, 40, 100 };
    for (v_dts) |dts| {
        const vp = c.av_packet_alloc() orelse return error.OutOfMemory;
        var vp_opt: ?*c.AVPacket = vp;
        defer c.av_packet_free(&vp_opt);
        try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(vp, 16));
        vp.*.pts = dts;
        vp.*.dts = dts;
        worker.enqueueVideoPacket(vp);
    }

    const a_dts = [_]i64{ 960, 2400 }; // 20 ms and 50 ms at 48 kHz
    for (a_dts) |dts| {
        const ap = c.av_packet_alloc() orelse return error.OutOfMemory;
        var ap_opt: ?*c.AVPacket = ap;
        defer c.av_packet_free(&ap_opt);
        try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(ap, 8));
        ap.*.pts = dts;
        ap.*.dts = dts;
        worker.enqueueAudioPacket(ap);
    }

    const expected_kinds = [_]StreamKind{ .video, .audio, .video, .audio, .video };
    for (expected_kinds) |exp_kind| {
        const item = worker.popNextOrderedPacket().?;
        defer freeRawPacket(item.pkt);
        try std.testing.expectEqual(exp_kind, item.kind);
    }
    try std.testing.expect(worker.popNextOrderedPacket() == null);

    const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    var pkt_opt: ?*c.AVPacket = pkt;
    defer c.av_packet_free(&pkt_opt);
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, 16));

    var i: usize = 0;
    while (i < video_queue_capacity + 10) : (i += 1) {
        worker.enqueueVideoPacket(pkt);
    }

    const stats = worker.getStats();
    try std.testing.expectEqual(@as(u64, 10), stats.packets_dropped);
    try std.testing.expectEqual(@as(u64, 10), worker.push_drop_seq.load(.acquire));
    try std.testing.expectEqual(@as(usize, video_queue_capacity), worker.video_queue.readable());
}

test "RtmpWorker handles unreachable endpoint without blocking and cleans up" {
    const prev_log_level = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_QUIET);
    defer c.av_log_set_level(prev_log_level);

    const ctx = try sink.allocTestH264Context(false);
    var ctx_opt: ?*c.AVCodecContext = ctx;
    defer c.avcodec_free_context(&ctx_opt);

    const actx = try sink.allocTestAacContext();
    var actx_opt: ?*c.AVCodecContext = actx;
    defer c.avcodec_free_context(&actx_opt);

    const worker = try RtmpWorker.init(std.testing.allocator, "rtmp://127.0.0.1:19359/live/test", ctx, actx);
    defer worker.deinit();

    try worker.start();

    const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    var pkt_opt: ?*c.AVPacket = pkt;
    defer c.av_packet_free(&pkt_opt);
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, 32));
    pkt.*.flags |= c.AV_PKT_FLAG_KEY;

    const apkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    var apkt_opt: ?*c.AVPacket = apkt;
    defer c.av_packet_free(&apkt_opt);
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(apkt, 16));
    apkt.*.pts = 1024;
    apkt.*.dts = 1024;

    worker.enqueueVideoPacket(pkt);
    worker.enqueueAudioPacket(apkt);
    worker.enqueueVideoPacket(pkt);

    const sleep_ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 30_000_000 };
    _ = c.nanosleep(&sleep_ts, null);

    worker.stopAndJoin();
    const stats = worker.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.packets_written);
    try std.testing.expectEqual(@as(u64, 3), stats.packets_dropped);
}
