const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const pcm = @import("pcm.zig");
const capture = @import("capture.zig");
const encoder = @import("encoder.zig");

const max_prestart_frames: usize = 24_576;
const dual_starvation_threshold: usize = pcm.frame_samples * 4;
pub const packet_queue_capacity: usize = 256;

pub const AudioPipelineError = error{
    OutOfMemory,
    InvalidConfig,
    ThreadSpawnFailed,
} || capture.AudioCaptureError || encoder.AudioEncoderError;

pub const AudioStats = struct {
    frames_captured: u64 = 0,
    frames_encoded: u64 = 0,
    frames_dropped: u64 = 0,
    packets_emitted: u64 = 0,
    packets_dropped: u64 = 0,
};

/// Real-time background audio pump bridging 1..2 AudioCapture streams into an AudioEncoder
/// and an SPSC queue of owned EncodedAudioPacket handles.
pub const AudioPipeline = struct {
    allocator: std.mem.Allocator,
    in_wake: capture.EventFd,
    out_wake: capture.EventFd,
    sources: [2]?*capture.AudioCapture = .{ null, null },
    source_count: usize = 0,
    enc: encoder.AudioEncoder,
    out_packets: common.SpscRingBuffer(encoder.EncodedAudioPacket, packet_queue_capacity) = .init(),

    session_start_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    aligned: bool = false,
    cursors: [2]pcm.SourceCursor = .{ .{}, .{} },
    next_pts_samples: i64 = 0,

    frames_encoded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_emitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: common.AudioSourceMode,
        bitrate_bps: u32,
        global_header: bool,
    ) AudioPipelineError!*AudioPipeline {
        if (!mode.isEnabled()) return AudioPipelineError.InvalidConfig;

        var in_wake = try capture.EventFd.init();
        var created: [2]?*capture.AudioCapture = .{ null, null };
        var count: usize = 0;

        const setup_ok = blk: {
            errdefer {
                for (created[0..count]) |maybe_cap| {
                    if (maybe_cap) |cap| cap.deinit();
                }
                in_wake.deinit();
            }
            if (mode == .both) {
                created[0] = try capture.AudioCapture.init(allocator, .desktop, in_wake);
                count = 1;
                created[1] = try capture.AudioCapture.init(allocator, .mic, in_wake);
                count = 2;
            } else {
                created[0] = try capture.AudioCapture.init(allocator, mode, in_wake);
                count = 1;
            }
            break :blk true;
        };
        std.debug.assert(setup_ok);

        return initFromCaptures(allocator, created[0..count], in_wake, bitrate_bps, global_header);
    }

    /// Construct a pipeline taking full ownership of pre-initialized capture streams and in_wake.
    pub fn initFromCaptures(
        allocator: std.mem.Allocator,
        captures: []const ?*capture.AudioCapture,
        in_wake: capture.EventFd,
        bitrate_bps: u32,
        global_header: bool,
    ) AudioPipelineError!*AudioPipeline {
        var owned_in_wake = in_wake;
        errdefer {
            for (captures) |maybe_cap| {
                if (maybe_cap) |cap| cap.deinit();
            }
            owned_in_wake.deinit();
        }

        if (captures.len == 0 or captures.len > 2 or owned_in_wake.fd < 0) {
            return AudioPipelineError.InvalidConfig;
        }
        for (captures) |maybe_cap| {
            if (maybe_cap == null) return AudioPipelineError.InvalidConfig;
        }

        var out_wake = try capture.EventFd.init();
        errdefer out_wake.deinit();

        var enc = try encoder.AudioEncoder.init(bitrate_bps, global_header);
        errdefer enc.deinit();

        const self = allocator.create(AudioPipeline) catch return AudioPipelineError.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .in_wake = owned_in_wake,
            .out_wake = out_wake,
            .source_count = captures.len,
            .enc = enc,
        };
        for (captures, 0..) |cap, i| {
            self.sources[i] = cap;
        }
        return self;
    }

    pub fn setSessionStartNs(self: *AudioPipeline, start_ns: u64) void {
        const safe_ns = @max(@as(u64, 1), start_ns);
        _ = self.session_start_ns.cmpxchgStrong(0, safe_ns, .release, .monotonic);
        self.in_wake.signal();
    }

    /// Pop the next encoded AAC packet from the lock-free output queue.
    pub fn popPacket(self: *AudioPipeline) ?encoder.EncodedAudioPacket {
        return self.out_packets.pop();
    }

    pub fn packetReadyFd(self: *const AudioPipeline) std.posix.fd_t {
        return self.out_wake.fd;
    }

    pub fn start(self: *AudioPipeline) AudioPipelineError!void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, pumpThreadMain, .{self}) catch {
            return AudioPipelineError.ThreadSpawnFailed;
        };
    }

    pub fn stopAndFlush(self: *AudioPipeline) void {
        self.stop_requested.store(true, .release);
        self.in_wake.signal();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *AudioPipeline) void {
        self.stopAndFlush();
        while (self.out_packets.pop()) |pkt_val| {
            var pkt = pkt_val;
            pkt.deinit();
        }
        for (self.sources[0..self.source_count]) |maybe_cap| {
            if (maybe_cap) |cap| cap.deinit();
        }
        self.enc.deinit();
        self.out_wake.deinit();
        self.in_wake.deinit();
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
            .packets_dropped = self.packets_dropped.load(.acquire),
        };
    }

    fn tryAlignToSession(self: *AudioPipeline) bool {
        if (self.aligned) return true;

        const t0_ns = self.session_start_ns.load(.acquire);
        if (t0_ns == 0) {
            for (self.sources[0..self.source_count]) |maybe_cap| {
                if (maybe_cap) |cap| cap.trimPrestartBacklog(max_prestart_frames);
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
            const maybe_pkt = self.enc.receivePacket() catch {
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
                return;
            };
            var pkt = maybe_pkt orelse return;
            if (self.out_packets.push(pkt)) {
                _ = self.packets_emitted.fetchAdd(1, .monotonic);
                self.out_wake.signal();
            } else {
                pkt.deinit();
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
            }
        }
    }

    fn syncDualOverflowDrops(self: *AudioPipeline, s0: *capture.AudioCapture, s1: *capture.AudioCapture) void {
        const d0 = self.cursors[0].consumeDrops(s0.droppedFrames());
        const d1 = self.cursors[1].consumeDrops(s1.droppedFrames());
        const max_drops = @max(d0, d1);
        self.cursors[0].skip_remaining += max_drops - d0;
        self.cursors[1].skip_remaining += max_drops - d1;
        self.next_pts_samples += @intCast(max_drops);
    }

    fn pullNextMixedBlock(self: *AudioPipeline, out_block: *[pcm.block_floats]f32, flushing: bool) bool {
        const s0 = self.sources[0] orelse return false;
        if (self.source_count == 1) {
            self.next_pts_samples += @intCast(self.cursors[0].consumeDrops(s0.droppedFrames()));
            return self.cursors[0].readBlock(&s0.ring, out_block, flushing);
        }

        const s1 = self.sources[1] orelse return false;
        self.syncDualOverflowDrops(s0, s1);

        const r0 = self.cursors[0].readyFrames(&s0.ring);
        const r1 = self.cursors[1].readyFrames(&s1.ring);
        if (r0 == 0 and r1 == 0) return false;

        const pad_lagging = flushing or (@max(r0, r1) >= dual_starvation_threshold);
        if (!pad_lagging and (r0 < pcm.frame_samples or r1 < pcm.frame_samples)) return false;

        var b0: [pcm.block_floats]f32 = @splat(0.0);
        var b1: [pcm.block_floats]f32 = @splat(0.0);
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
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
                continue;
            };
            _ = self.frames_encoded.fetchAdd(pcm.frame_samples, .monotonic);
            self.drainEncodedPackets();
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
                self.in_wake.wait(25);
            }
        }
        self.flushTailAndEncoder();
    }
};

fn drainAllQueuedPackets(pipe: *AudioPipeline, last_pts_out: *i64, bytes_out: *usize) usize {
    var count: usize = 0;
    while (pipe.popPacket()) |pkt_val| {
        var pkt = pkt_val;
        defer pkt.deinit();
        if (pkt.pts > last_pts_out.*) last_pts_out.* = pkt.pts;
        bytes_out.* += pkt.size;
        count += 1;
    }
    return count;
}

test "AudioPipeline pumps dual-source mixed PCM, flushes multi-block asymmetric tail, and cleans up on error" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    try std.testing.expectError(
        AudioPipelineError.InvalidConfig,
        AudioPipeline.init(std.testing.allocator, .none, encoder.default_bitrate_bps, true),
    );

    // Verify initFromCaptures releases captures and wake_fd on encoder validation failure
    const err_wake = try capture.EventFd.init();
    const err_cap = try std.testing.allocator.create(capture.AudioCapture);
    err_cap.* = .{ .allocator = std.testing.allocator, .wake = err_wake };
    try std.testing.expectError(
        AudioEncoderError_alias: {
            break :AudioEncoderError_alias AudioPipelineError.InvalidBitrate;
        },
        AudioPipeline.initFromCaptures(std.testing.allocator, &.{err_cap}, err_wake, 0, true),
    );

    const in_wake = try capture.EventFd.init();
    const desk = try std.testing.allocator.create(capture.AudioCapture);
    desk.* = .{ .allocator = std.testing.allocator, .wake = in_wake };
    const mic = try std.testing.allocator.create(capture.AudioCapture);
    mic.* = .{ .allocator = std.testing.allocator, .wake = in_wake };

    const caps = [_]?*capture.AudioCapture{ desk, mic };
    var pipe = try AudioPipeline.initFromCaptures(
        std.testing.allocator,
        &caps,
        in_wake,
        encoder.default_bitrate_bps,
        true,
    );
    defer pipe.deinit();

    try std.testing.expect(pipe.packetReadyFd() >= 0);
    try pipe.start();

    const t0_ns: u64 = 2_000_000_000;
    const tone_a: [pcm.block_floats]f32 = @splat(0.2);
    const tone_b: [pcm.block_floats]f32 = @splat(0.15);

    // Desktop receives 3 blocks (3072 frames); mic stops after 1 block -> flush must drain all 3 desktop blocks
    for (0..3) |i| {
        const ts_a: u64 = if (i == 0) t0_ns else 0;
        desk.ingestRawChunk(&tone_a, @sizeOf(@TypeOf(tone_a)), ts_a);
    }
    mic.ingestRawChunk(&tone_b, @sizeOf(@TypeOf(tone_b)), t0_ns);

    pipe.setSessionStartNs(t0_ns);
    pipe.stopAndFlush();

    var last_pts: i64 = 0;
    var total_bytes: usize = 0;
    const count = drainAllQueuedPackets(pipe, &last_pts, &total_bytes);

    const stats = pipe.getStats();
    try std.testing.expectEqual(@as(u64, 4096), stats.frames_captured);
    try std.testing.expectEqual(@as(u64, 3 * pcm.frame_samples), stats.frames_encoded);
    try std.testing.expect(count >= 3);
    try std.testing.expect(total_bytes > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_dropped);
}

test "AudioPipeline single-source post-t0 offset and asymmetric dual overflow phase lock" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    const in_wake = try capture.EventFd.init();
    const desk = try std.testing.allocator.create(capture.AudioCapture);
    desk.* = .{ .allocator = std.testing.allocator, .wake = in_wake };
    const mic = try std.testing.allocator.create(capture.AudioCapture);
    mic.* = .{ .allocator = std.testing.allocator, .wake = in_wake };

    // Simulate asymmetric overflow: mic dropped 500 frames while desktop dropped 0 -> desktop skips 500 frames
    _ = mic.dropped_frames.fetchAdd(500, .release);

    const caps = [_]?*capture.AudioCapture{ desk, mic };
    var pipe = try AudioPipeline.initFromCaptures(
        std.testing.allocator,
        &caps,
        in_wake,
        encoder.default_bitrate_bps,
        false,
    );
    defer pipe.deinit();

    const t0_ns: u64 = 1_000_000_000;
    const tone: [pcm.block_floats]f32 = @splat(0.1);
    desk.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), t0_ns + 20_000_000);
    desk.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), 0);
    mic.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), t0_ns + 20_000_000);
    mic.ingestRawChunk(&tone, @sizeOf(@TypeOf(tone)), 0);

    pipe.setSessionStartNs(t0_ns);
    try pipe.start();
    pipe.stopAndFlush();

    var last_pts: i64 = 0;
    var total_bytes: usize = 0;
    const count = drainAllQueuedPackets(pipe, &last_pts, &total_bytes);
    try std.testing.expect(count >= 2);
    // 20ms (960 frames) + 500 drop-compensated frames = initial PTS 1460, second block PTS 2484
    try std.testing.expect(last_pts >= 1460);
}
