const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const sink = @import("sink.zig");

const queue_capacity = 128;
const io_timeout_ms: u64 = 2000;
const initial_backoff_ms: u64 = 500;
const max_backoff_ms: u64 = 4000;

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
    stream: *c.AVStream,

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

/// Evaluate whether a packet must be dropped while waiting for the next IDR keyframe.
pub fn shouldDropForKeyframe(is_keyframe: bool, wait_for_keyframe: *bool) bool {
    if (!wait_for_keyframe.*) return false;
    if (!is_keyframe) return true;
    wait_for_keyframe.* = false;
    return false;
}

fn freeRawPacket(pkt: *c.AVPacket) void {
    var p: ?*c.AVPacket = pkt;
    c.av_packet_free(&p);
}

/// Dedicated non-blocking RTMP packet queue, writer thread, and reconnect state machine.
pub const RtmpWorker = struct {
    allocator: std.mem.Allocator,
    target_z: [:0]u8,
    saved_codecpar: *c.AVCodecParameters,
    src_time_base: c.AVRational,
    avg_frame_rate: c.AVRational,
    wake_fd: std.posix.fd_t,

    queue: common.SpscRingBuffer(*c.AVPacket, queue_capacity) = .init(),
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
        codec_ctx: *const c.AVCodecContext,
    ) sink.MuxError!*RtmpWorker {
        const target_z = allocator.dupeSentinel(u8, target, 0) catch return sink.MuxError.OutOfMemory;
        errdefer allocator.free(target_z);

        const codecpar = c.avcodec_parameters_alloc() orelse return sink.MuxError.OutOfMemory;
        errdefer {
            var cp: ?*c.AVCodecParameters = codecpar;
            c.avcodec_parameters_free(&cp);
        }
        if (c.avcodec_parameters_from_context(codecpar, codec_ctx) < 0) {
            return sink.MuxError.CodecParamsCopyFailed;
        }

        const wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (wake_fd < 0) return sink.MuxError.OutputOpenFailed;
        errdefer _ = c.close(wake_fd);

        const worker = allocator.create(RtmpWorker) catch return sink.MuxError.OutOfMemory;
        worker.* = .{
            .allocator = allocator,
            .target_z = target_z,
            .saved_codecpar = codecpar,
            .src_time_base = codec_ctx.*.time_base,
            .avg_frame_rate = codec_ctx.*.framerate,
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

    /// Non-blocking packet enqueue. Drops the packet immediately if the ring buffer is full.
    pub fn enqueuePacket(self: *RtmpWorker, raw_pkt: *const c.AVPacket) void {
        const cloned = c.av_packet_alloc() orelse {
            self.recordPushDrop();
            return;
        };
        if (c.av_packet_ref(cloned, raw_pkt) < 0) {
            freeRawPacket(cloned);
            self.recordPushDrop();
            return;
        }
        if (!self.queue.push(cloned)) {
            freeRawPacket(cloned);
            self.recordPushDrop();
            return;
        }
        self.signalWake();
    }

    fn recordPushDrop(self: *RtmpWorker) void {
        _ = self.packets_dropped.fetchAdd(1, .monotonic);
        _ = self.push_drop_seq.fetchAdd(1, .release);
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
        var cp: ?*c.AVCodecParameters = self.saved_codecpar;
        c.avcodec_parameters_free(&cp);
        self.allocator.free(self.target_z);
        self.allocator.destroy(self);
    }

    fn drainRemainingDropped(self: *RtmpWorker) void {
        while (self.queue.pop()) |pkt| {
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

        const stream = c.avformat_new_stream(ctx, null) orelse return sink.MuxError.StreamAllocFailed;
        stream.*.id = 0;
        stream.*.time_base = self.src_time_base;
        if (self.avg_frame_rate.num > 0 and self.avg_frame_rate.den > 0) {
            stream.*.avg_frame_rate = self.avg_frame_rate;
        }
        if (c.avcodec_parameters_copy(stream.*.codecpar, self.saved_codecpar) < 0) {
            return sink.MuxError.CodecParamsCopyFailed;
        }

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

        return .{ .fmt_ctx = ctx, .stream = stream };
    }

    fn writeOnePacket(self: *RtmpWorker, conn: *RtmpConnection, pkt: *c.AVPacket) bool {
        c.av_packet_rescale_ts(pkt, self.src_time_base, conn.stream.*.time_base);
        pkt.*.stream_index = conn.stream.*.index;
        pkt.*.pos = -1;
        const pkt_bytes: u64 = if (pkt.*.size > 0) @intCast(pkt.*.size) else 0;

        self.io_deadline_ms.store(monotonicMs() + io_timeout_ms, .release);
        const rc = c.av_interleaved_write_frame(conn.fmt_ctx, pkt);
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

        while (self.queue.pop()) |pkt| {
            defer freeRawPacket(pkt);
            self.syncDropGate(state);
            const is_key = (pkt.*.flags & c.AV_PKT_FLAG_KEY) != 0;
            if (shouldDropForKeyframe(is_key, &state.wait_for_keyframe)) {
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
                continue;
            }
            if (!self.writeOnePacket(conn, pkt)) {
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
        const pkt = self.queue.pop() orelse {
            self.waitWake(50);
            return;
        };
        defer freeRawPacket(pkt);

        self.syncDropGate(state);

        const is_key = (pkt.*.flags & c.AV_PKT_FLAG_KEY) != 0;
        if (shouldDropForKeyframe(is_key, &state.wait_for_keyframe)) {
            _ = self.packets_dropped.fetchAdd(1, .monotonic);
            return;
        }

        var conn = state.conn.?;
        if (self.writeOnePacket(&conn, pkt)) {
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

test "shouldDropForKeyframe gates inter-frames until next IDR" {
    var wait_kf = true;
    try std.testing.expect(shouldDropForKeyframe(false, &wait_kf));
    try std.testing.expect(wait_kf);

    try std.testing.expect(!shouldDropForKeyframe(true, &wait_kf));
    try std.testing.expect(!wait_kf);

    try std.testing.expect(!shouldDropForKeyframe(false, &wait_kf));
}

test "RtmpWorker drops overflow packets non-blockingly and tracks telemetry" {
    const ctx = try sink.allocTestH264Context(false);
    var ctx_opt: ?*c.AVCodecContext = ctx;
    defer c.avcodec_free_context(&ctx_opt);

    const worker = try RtmpWorker.init(std.testing.allocator, "rtmp://127.0.0.1:19359/live/test", ctx);
    defer worker.deinit();

    const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    var pkt_opt: ?*c.AVPacket = pkt;
    defer c.av_packet_free(&pkt_opt);
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, 16));

    var i: usize = 0;
    while (i < queue_capacity + 10) : (i += 1) {
        worker.enqueuePacket(pkt);
    }

    const stats = worker.getStats();
    try std.testing.expectEqual(@as(u64, 10), stats.packets_dropped);
    try std.testing.expectEqual(@as(u64, 10), worker.push_drop_seq.load(.acquire));
    try std.testing.expectEqual(@as(usize, queue_capacity), worker.queue.readable());
}

test "RtmpWorker handles unreachable endpoint without blocking and cleans up" {
    const prev_log_level = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_QUIET);
    defer c.av_log_set_level(prev_log_level);

    const ctx = try sink.allocTestH264Context(false);
    var ctx_opt: ?*c.AVCodecContext = ctx;
    defer c.avcodec_free_context(&ctx_opt);

    const worker = try RtmpWorker.init(std.testing.allocator, "rtmp://127.0.0.1:19359/live/test", ctx);
    defer worker.deinit();

    try worker.start();

    const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    var pkt_opt: ?*c.AVPacket = pkt;
    defer c.av_packet_free(&pkt_opt);
    try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, 32));
    pkt.*.flags |= c.AV_PKT_FLAG_KEY;

    worker.enqueuePacket(pkt);
    worker.enqueuePacket(pkt);

    const sleep_ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 30_000_000 };
    _ = c.nanosleep(&sleep_ts, null);

    worker.stopAndJoin();
    const stats = worker.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.packets_written);
    try std.testing.expectEqual(@as(u64, 2), stats.packets_dropped);
}
