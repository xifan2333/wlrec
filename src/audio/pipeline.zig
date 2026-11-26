const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const pcm = @import("pcm.zig");
const capture = @import("capture.zig");
const encoder = @import("encoder.zig");

const max_prestart_frames: usize = 24_576;
const dual_starvation_threshold: usize = pcm.frame_samples * 4;

pub const AudioPipelineError = error{
    OutOfMemory,
    InvalidConfig,
    WakeFdCreateFailed,
    ThreadSpawnFailed,
} || capture.AudioCaptureError || encoder.AudioEncoderError;

/// Typed packet receiver decoupling src/audio/ from downstream container/RTMP muxers.
pub const PacketSink = struct {
    ptr: *anyopaque,
    on_packet: *const fn (*anyopaque, *const c.AVPacket) bool,

    pub fn bind(
        comptime Ptr: type,
        target: Ptr,
        comptime handler: fn (Ptr, *const c.AVPacket) bool,
    ) PacketSink {
        const Adapter = struct {
            fn invoke(raw: *anyopaque, pkt: *const c.AVPacket) bool {
                const typed: Ptr = @ptrCast(@alignCast(raw));
                return handler(typed, pkt);
            }
        };
        return .{
            .ptr = @ptrCast(target),
            .on_packet = Adapter.invoke,
        };
    }

    pub fn send(self: PacketSink, pkt: *const c.AVPacket) bool {
        return self.on_packet(self.ptr, pkt);
    }
};

pub const AudioStats = struct {
    frames_captured: u64 = 0,
    frames_encoded: u64 = 0,
    frames_dropped: u64 = 0,
    packets_emitted: u64 = 0,
    packets_failed: u64 = 0,
};

fn trimPrestartBacklog(src: *capture.AudioCapture) void {
    const readable = pcm.readableFrames(&src.ring);
    if (readable <= max_prestart_frames) return;
    const excess = readable - max_prestart_frames;
    const discarded = pcm.discardStereoFrames(&src.ring, excess);
    if (discarded == 0) return;

    const advance_ns = (@as(u128, discarded) * std.time.ns_per_s) / pcm.sample_rate;
    const prev_ns = src.firstSampleNs();
    if (prev_ns > 0) {
        src.first_sample_ns.store(prev_ns + @as(u64, @intCast(advance_ns)), .release);
    }
}

/// Real-time background audio pump bridging 1..2 AudioCapture streams into an AudioEncoder.
pub const AudioPipeline = struct {
    allocator: std.mem.Allocator,
    wake_fd: std.posix.fd_t,
    sources: [2]?*capture.AudioCapture = .{ null, null },
    source_count: usize = 0,
    enc: encoder.AudioEncoder,
    sink: PacketSink,

    session_start_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    aligned: bool = false,
    cursors: [2]pcm.SourceCursor = .{ .{}, .{} },
    next_pts_samples: i64 = 0,

    frames_encoded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_emitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: common.AudioSourceMode,
        bitrate_bps: u32,
        global_header: bool,
        sink: PacketSink,
    ) AudioPipelineError!*AudioPipeline {
        if (!mode.isEnabled()) return AudioPipelineError.InvalidConfig;

        const wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (wake_fd < 0) return AudioPipelineError.WakeFdCreateFailed;
        errdefer _ = c.close(wake_fd);

        var created: [2]?*capture.AudioCapture = .{ null, null };
        var count: usize = 0;
        errdefer for (created[0..count]) |maybe_cap| {
            if (maybe_cap) |cap| cap.deinit();
        };

        if (mode == .both) {
            created[0] = try capture.AudioCapture.init(allocator, .desktop, wake_fd);
            count = 1;
            created[1] = try capture.AudioCapture.init(allocator, .mic, wake_fd);
            count = 2;
        } else {
            created[0] = try capture.AudioCapture.init(allocator, mode, wake_fd);
            count = 1;
        }

        const out = try initFromCaptures(
            allocator,
            created[0..count],
            wake_fd,
            bitrate_bps,
            global_header,
            sink,
        );
        return out;
    }

    /// Construct a pipeline taking ownership of pre-initialized capture streams and wake_fd.
    pub fn initFromCaptures(
        allocator: std.mem.Allocator,
        captures: []const ?*capture.AudioCapture,
        wake_fd: std.posix.fd_t,
        bitrate_bps: u32,
        global_header: bool,
        sink: PacketSink,
    ) AudioPipelineError!*AudioPipeline {
        if (captures.len == 0 or captures.len > 2 or wake_fd < 0) {
            return AudioPipelineError.InvalidConfig;
        }

        var enc = try encoder.AudioEncoder.init(bitrate_bps, global_header);
        errdefer enc.deinit();

        const self = allocator.create(AudioPipeline) catch return AudioPipelineError.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .wake_fd = wake_fd,
            .source_count = captures.len,
            .enc = enc,
            .sink = sink,
        };
        for (captures, 0..) |cap, i| {
            self.sources[i] = cap;
        }
        return self;
    }

    pub fn codecContext(self: *const AudioPipeline) *const c.AVCodecContext {
        return self.enc.codec_ctx;
    }

    pub fn setSessionStartNs(self: *AudioPipeline, start_ns: u64) void {
        const safe_ns = @max(@as(u64, 1), start_ns);
        _ = self.session_start_ns.cmpxchgStrong(0, safe_ns, .release, .monotonic);
        self.signalWake();
    }

    pub fn start(self: *AudioPipeline) AudioPipelineError!void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, pumpThreadMain, .{self}) catch {
            return AudioPipelineError.ThreadSpawnFailed;
        };
    }

    pub fn stopAndFlush(self: *AudioPipeline) void {
        self.stop_requested.store(true, .release);
        self.signalWake();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *AudioPipeline) void {
        self.stopAndFlush();
        for (self.sources[0..self.source_count]) |maybe_cap| {
            if (maybe_cap) |cap| cap.deinit();
        }
        self.enc.deinit();
        if (self.wake_fd >= 0) {
            _ = c.close(self.wake_fd);
        }
        self.allocator.destroy(self);
    }

    pub fn getStats(self: *const AudioPipeline) AudioStats {
        var captured: u64 = 0;
        var dropped: u64 = 0;
        for (self.sources[0..self.source_count]) |maybe_cap| {
            if (maybe_cap) |cap| {
                captured += cap.capturedFrames();
                dropped += cap.droppedFrames();
            }
        }
        return .{
            .frames_captured = captured,
            .frames_encoded = self.frames_encoded.load(.acquire),
            .frames_dropped = dropped,
            .packets_emitted = self.packets_emitted.load(.acquire),
            .packets_failed = self.packets_failed.load(.acquire),
        };
    }

    fn signalWake(self: *const AudioPipeline) void {
        const val: u64 = 1;
        _ = c.write(self.wake_fd, &val, @sizeOf(u64));
    }

    fn waitWake(self: *const AudioPipeline, timeout_ms: c_int) void {
        var pfd = c.struct_pollfd{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, timeout_ms) > 0) {
            var val: u64 = 0;
            _ = c.read(self.wake_fd, &val, @sizeOf(u64));
        }
    }

    fn tryAlignToSession(self: *AudioPipeline) bool {
        if (self.aligned) return true;

        const t0_ns = self.session_start_ns.load(.acquire);
        if (t0_ns == 0) {
            for (self.sources[0..self.source_count]) |maybe_cap| {
                if (maybe_cap) |cap| trimPrestartBacklog(cap);
            }
            return false;
        }

        var starts: [2]u64 = .{ 0, 0 };
        for (self.sources[0..self.source_count], 0..) |maybe_cap, i| {
            const cap = maybe_cap orelse return false;
            const st = cap.firstSampleNs();
            if (st == 0) return false;
            starts[i] = st;
        }

        const group = pcm.alignStreamGroup(starts[0..self.source_count], t0_ns);
        self.next_pts_samples = group.initial_pts_samples;
        self.cursors = group.cursors;
        self.aligned = true;
        return true;
    }

    fn drainEncodedPackets(self: *AudioPipeline) void {
        while (true) {
            const maybe_pkt = self.enc.pollPacket() catch {
                _ = self.packets_failed.fetchAdd(1, .monotonic);
                return;
            };
            const pkt = maybe_pkt orelse return;
            if (self.sink.send(pkt)) {
                _ = self.packets_emitted.fetchAdd(1, .monotonic);
            } else {
                _ = self.packets_failed.fetchAdd(1, .monotonic);
            }
        }
    }

    fn pullNextMixedBlock(self: *AudioPipeline, out_block: *[pcm.block_floats]f32, flushing: bool) bool {
        const s0 = self.sources[0] orelse return false;
        if (self.source_count == 1) {
            self.next_pts_samples += @intCast(self.cursors[0].consumeDrops(s0.droppedFrames()));
            if (flushing and pcm.readableFrames(&s0.ring) == 0) return false;
            return self.cursors[0].readBlock(&s0.ring, out_block, flushing);
        }

        const s1 = self.sources[1] orelse return false;
        const drops = @max(
            self.cursors[0].consumeDrops(s0.droppedFrames()),
            self.cursors[1].consumeDrops(s1.droppedFrames()),
        );
        self.next_pts_samples += @intCast(drops);

        const r0 = self.cursors[0].readyFrames(&s0.ring);
        const r1 = self.cursors[1].readyFrames(&s1.ring);
        if (flushing and pcm.readableFrames(&s0.ring) == 0 and pcm.readableFrames(&s1.ring) == 0) {
            return false;
        }
        const pad_lagging = flushing or (@max(r0, r1) >= dual_starvation_threshold);
        if (!pad_lagging and (r0 < pcm.frame_samples or r1 < pcm.frame_samples)) return false;

        var b0: [pcm.block_floats]f32 = undefined;
        var b1: [pcm.block_floats]f32 = undefined;
        _ = self.cursors[0].readBlock(&s0.ring, &b0, pad_lagging);
        _ = self.cursors[1].readBlock(&s1.ring, &b1, pad_lagging);
        pcm.mixStereoClamped(&b0, &b1, out_block);
        return true;
    }

    fn pumpAvailableBlocks(self: *AudioPipeline, flushing: bool) void {
        if (!self.tryAlignToSession()) return;

        var block: [pcm.block_floats]f32 = undefined;
        while (self.pullNextMixedBlock(&block, flushing)) {
            const pts = self.next_pts_samples;
            self.next_pts_samples += pcm.frame_samples;
            self.enc.submitStereoBlock(&block, pts) catch {
                _ = self.packets_failed.fetchAdd(1, .monotonic);
                continue;
            };
            _ = self.frames_encoded.fetchAdd(pcm.frame_samples, .monotonic);
            self.drainEncodedPackets();
            if (flushing) break;
        }
    }

    fn flushTailAndEncoder(self: *AudioPipeline) void {
        self.pumpAvailableBlocks(false);
        if (!self.aligned) return;
        self.pumpAvailableBlocks(true);
        self.enc.flush() catch |err| {
            std.log.warn("audio encoder flush failed: {s}", .{@errorName(err)});
            return;
        };
        self.drainEncodedPackets();
    }

    fn pumpThreadMain(self: *AudioPipeline) void {
        while (!self.stop_requested.load(.acquire)) {
            self.pumpAvailableBlocks(false);
            if (!self.stop_requested.load(.acquire)) {
                self.waitWake(25);
            }
        }
        self.flushTailAndEncoder();
    }
};

const TestPacketCollector = struct {
    count: usize = 0,
    first_pts: ?i64 = null,
    last_pts: i64 = 0,
    total_bytes: usize = 0,

    fn onPacket(self: *TestPacketCollector, pkt: *const c.AVPacket) bool {
        if (self.first_pts == null and pkt.*.pts >= 0) {
            self.first_pts = pkt.*.pts;
        }
        if (pkt.*.pts > self.last_pts) {
            self.last_pts = pkt.*.pts;
        }
        self.count += 1;
        self.total_bytes += @intCast(@max(@as(c_int, 0), pkt.*.size));
        return true;
    }
};

test "AudioPipeline pumps dual-source mixed PCM, aligns to VfrClock t0, and flushes AAC packets" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    const wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    try std.testing.expect(wake_fd >= 0);

    const desk = try std.testing.allocator.create(capture.AudioCapture);
    desk.* = .{ .allocator = std.testing.allocator, .wake_fd = wake_fd };
    const mic = try std.testing.allocator.create(capture.AudioCapture);
    mic.* = .{ .allocator = std.testing.allocator, .wake_fd = wake_fd };

    var collector = TestPacketCollector{};
    const sink = PacketSink.bind(*TestPacketCollector, &collector, TestPacketCollector.onPacket);

    try std.testing.expectError(
        AudioPipelineError.InvalidConfig,
        AudioPipeline.init(std.testing.allocator, .none, encoder.default_bitrate_bps, true, sink),
    );

    const caps = [_]?*capture.AudioCapture{ desk, mic };
    var pipe = AudioPipeline.initFromCaptures(
        std.testing.allocator,
        &caps,
        wake_fd,
        encoder.default_bitrate_bps,
        true,
        sink,
    ) catch |err| {
        mic.deinit();
        desk.deinit();
        _ = c.close(wake_fd);
        return err;
    };
    defer pipe.deinit();

    try pipe.start();

    const t0_ns: u64 = 2_000_000_000;
    const tone_a: [pcm.block_floats]f32 = @splat(0.2);
    const tone_b: [pcm.block_floats]f32 = @splat(0.15);

    // Feed 4 blocks (4096 stereo frames); desktop starts 5ms before t0, mic starts at t0
    for (0..4) |i| {
        const ts_a: u64 = if (i == 0) t0_ns - 5_000_000 else 0;
        const ts_b: u64 = if (i == 0) t0_ns else 0;
        desk.ingestRawChunk(&tone_a, @sizeOf(@TypeOf(tone_a)), ts_a);
        mic.ingestRawChunk(&tone_b, @sizeOf(@TypeOf(tone_b)), ts_b);
    }

    pipe.setSessionStartNs(t0_ns);

    const sleep_ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 40_000_000 };
    _ = c.nanosleep(&sleep_ts, null);

    pipe.stopAndFlush();

    const stats = pipe.getStats();
    try std.testing.expectEqual(@as(u64, 8192), stats.frames_captured);
    try std.testing.expect(stats.frames_encoded >= 3 * pcm.frame_samples);
    try std.testing.expect(collector.count >= 3);
    try std.testing.expect(collector.total_bytes > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_failed);
}

test "AudioPipeline single-source post-t0 offset and overflow PTS compensation" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    const wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    try std.testing.expect(wake_fd >= 0);

    const mic = try std.testing.allocator.create(capture.AudioCapture);
    mic.* = .{ .allocator = std.testing.allocator, .wake_fd = wake_fd };
    _ = mic.dropped_frames.fetchAdd(500, .release);

    var collector = TestPacketCollector{};
    const sink = PacketSink.bind(*TestPacketCollector, &collector, TestPacketCollector.onPacket);

    const caps = [_]?*capture.AudioCapture{mic};
    var pipe = AudioPipeline.initFromCaptures(
        std.testing.allocator,
        &caps,
        wake_fd,
        encoder.default_bitrate_bps,
        false,
        sink,
    ) catch |err| {
        mic.deinit();
        _ = c.close(wake_fd);
        return err;
    };
    defer pipe.deinit();

    const t0_ns: u64 = 1_000_000_000;
    const tone: [pcm.block_floats]f32 = @splat(0.1);
    // Audio starts 20ms (960 frames) after t0, plus 500 pre-existing dropped frames -> initial PTS >= 1460
    mic.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), t0_ns + 20_000_000);
    mic.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), 0);

    pipe.setSessionStartNs(t0_ns);
    try pipe.start();
    pipe.stopAndFlush();

    try std.testing.expect(collector.count >= 2);
    try std.testing.expect(collector.last_pts >= 1460);
}
