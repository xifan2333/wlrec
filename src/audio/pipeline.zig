const std = @import("std");
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
    encode_errors: u64 = 0,
};

/// Production lock-free mixer & AAC encoding state machine operating over 1..2 AudioTrackBuffers.
pub const AudioSessionMixer = struct {
    tracks: [2]*pcm.AudioTrackBuffer,
    track_count: usize,
    cursors: [2]pcm.SourceCursor = .{ .{}, .{} },
    anchor_t0_ns: u64 = 0,
    base_pts_samples: i64 = 0,
    next_pts_samples: i64 = 0,
    started: bool = false,

    pub fn init(tracks: []const *pcm.AudioTrackBuffer) AudioSessionMixer {
        std.debug.assert(tracks.len >= 1 and tracks.len <= 2);
        var m = AudioSessionMixer{
            .tracks = .{ tracks[0], if (tracks.len == 2) tracks[1] else tracks[0] },
            .track_count = tracks.len,
        };
        _ = &m;
        return m;
    }

    pub fn trimPrestart(self: *AudioSessionMixer) void {
        for (0..self.track_count) |i| {
            self.tracks[i].trimPrestartBacklog(max_prestart_frames, &self.cursors[i].consumed_frames);
        }
    }

    fn alignNewlyActiveTrack(self: *AudioSessionMixer, idx: usize, st_ns: u64) void {
        const al = pcm.computeStreamAlignment(st_ns, self.anchor_t0_ns);
        const target_pts = self.next_pts_samples;
        const stream_pts: i64 = @intCast(al.offset_frames);
        var skip = al.skip_frames;
        var pad: u64 = 0;

        if (stream_pts < target_pts) {
            skip += @intCast(target_pts - stream_pts);
        } else if (stream_pts > target_pts) {
            pad = @intCast(stream_pts - target_pts);
        }
        self.cursors[idx].configure(skip, pad, self.tracks[idx].droppedFrames());
    }

    fn tryStartBasePts(self: *AudioSessionMixer, t0_ns: u64, force_partial: bool) bool {
        var active_count: usize = 0;
        var max_buffered: usize = 0;
        var min_offset: u64 = std.math.maxInt(u64);

        for (0..self.track_count) |i| {
            const st = self.tracks[i].firstSampleNs();
            if (st == 0) continue;
            active_count += 1;
            const al = pcm.computeStreamAlignment(st, t0_ns);
            min_offset = @min(min_offset, al.offset_frames);
            max_buffered = @max(max_buffered, pcm.readableFrames(&self.tracks[i].ring));
        }
        if (active_count == 0) return false;
        if (active_count < self.track_count and !force_partial and max_buffered < dual_starvation_threshold) {
            return false;
        }

        self.base_pts_samples = @intCast(min_offset);
        self.next_pts_samples = self.base_pts_samples;
        self.started = true;
        return true;
    }

    fn refreshTrackCursors(self: *AudioSessionMixer) void {
        for (0..self.track_count) |i| {
            if (self.cursors[i].aligned) continue;
            const st = self.tracks[i].firstSampleNs();
            if (st > 0) {
                self.alignNewlyActiveTrack(i, st);
            } else {
                self.tracks[i].trimPrestartBacklog(max_prestart_frames, &self.cursors[i].consumed_frames);
            }
        }
    }

    pub fn syncAlignment(self: *AudioSessionMixer, t0_ns: u64, force_partial: bool) bool {
        if (t0_ns == 0) {
            self.trimPrestart();
            return false;
        }
        self.anchor_t0_ns = t0_ns;
        if (!self.started and !self.tryStartBasePts(t0_ns, force_partial)) return false;
        self.refreshTrackCursors();
        return true;
    }

    fn applyReachedDrops(self: *AudioSessionMixer) void {
        if (self.track_count == 1) {
            self.next_pts_samples += @intCast(self.cursors[0].consumeReachedDrops(self.tracks[0]));
            return;
        }
        const d0 = self.cursors[0].consumeReachedDrops(self.tracks[0]);
        const d1 = self.cursors[1].consumeReachedDrops(self.tracks[1]);
        const min_both = @min(d0, d1);
        self.next_pts_samples += @intCast(min_both);
        self.cursors[0].pad_remaining += d0 - min_both;
        self.cursors[1].pad_remaining += d1 - min_both;
    }

    pub fn pullNextBlock(
        self: *AudioSessionMixer,
        t0_ns: u64,
        flushing: bool,
        out_block: *[pcm.block_floats]f32,
        pts_out: *i64,
    ) bool {
        if (!self.syncAlignment(t0_ns, flushing)) return false;
        self.applyReachedDrops();

        if (self.track_count == 1) {
            if (!self.cursors[0].readBlock(self.tracks[0], out_block, flushing)) return false;
            pts_out.* = self.next_pts_samples;
            self.next_pts_samples += pcm.frame_samples;
            return true;
        }

        const r0 = self.cursors[0].readyFrames(self.tracks[0]);
        const r1 = self.cursors[1].readyFrames(self.tracks[1]);
        if (r0 == 0 and r1 == 0) return false;

        const pad_lagging = flushing or (@max(r0, r1) >= dual_starvation_threshold);
        if (!pad_lagging and (r0 < pcm.frame_samples or r1 < pcm.frame_samples)) return false;

        var b0: [pcm.block_floats]f32 = @splat(0.0);
        var b1: [pcm.block_floats]f32 = @splat(0.0);
        const got0 = self.cursors[0].readBlock(self.tracks[0], &b0, pad_lagging);
        const got1 = self.cursors[1].readBlock(self.tracks[1], &b1, pad_lagging);
        if (!got0 and self.cursors[0].aligned) self.cursors[0].skip_remaining += pcm.frame_samples;
        if (!got1 and self.cursors[1].aligned) self.cursors[1].skip_remaining += pcm.frame_samples;

        pcm.mixStereoSoftClamped(&b0, &b1, out_block);
        pts_out.* = self.next_pts_samples;
        self.next_pts_samples += pcm.frame_samples;
        return true;
    }
};

/// Real-time background audio pump bridging 1..2 AudioCapture streams into an AudioEncoder
/// and an SPSC queue of owned EncodedAudioPacket handles.
pub const AudioPipeline = struct {
    allocator: std.mem.Allocator,
    in_wake: capture.EventFd,
    out_wake: capture.EventFd,
    sources: [2]?*capture.AudioCapture = .{ null, null },
    source_count: usize = 0,
    mixer: AudioSessionMixer,
    enc: encoder.AudioEncoder,
    out_packets: common.SpscRingBuffer(encoder.EncodedAudioPacket, packet_queue_capacity) = .init(),

    session_start_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frames_encoded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_emitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    packets_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    encode_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: common.AudioSourceMode,
        bitrate_bps: u32,
        global_header: bool,
    ) AudioPipelineError!*AudioPipeline {
        if (!mode.isEnabled()) return AudioPipelineError.InvalidConfig;

        var in_wake = try capture.EventFd.init();
        errdefer in_wake.deinit();

        var out_wake = try capture.EventFd.init();
        errdefer out_wake.deinit();

        var enc = try encoder.AudioEncoder.init(bitrate_bps, global_header);
        errdefer enc.deinit();

        const sig = in_wake.signaler();
        var created: [2]?*capture.AudioCapture = .{ null, null };
        var count: usize = 0;
        errdefer for (created[0..count]) |maybe_cap| {
            if (maybe_cap) |cap| cap.deinit();
        };

        if (mode == .both) {
            created[0] = try capture.AudioCapture.init(allocator, .desktop, sig);
            count = 1;
            created[1] = try capture.AudioCapture.init(allocator, .mic, sig);
            count = 2;
        } else {
            created[0] = try capture.AudioCapture.init(allocator, mode, sig);
            count = 1;
        }

        const self = allocator.create(AudioPipeline) catch return AudioPipelineError.OutOfMemory;
        var track_ptrs: [2]*pcm.AudioTrackBuffer = .{
            &created[0].?.track,
            if (count == 2) &created[1].?.track else &created[0].?.track,
        };
        self.* = .{
            .allocator = allocator,
            .in_wake = in_wake,
            .out_wake = out_wake,
            .sources = created,
            .source_count = count,
            .mixer = AudioSessionMixer.init(track_ptrs[0..count]),
            .enc = enc,
        };
        return self;
    }

    pub fn setSessionStartNs(self: *AudioPipeline, start_ns: u64) void {
        const safe_ns = @max(@as(u64, 1), start_ns);
        _ = self.session_start_ns.cmpxchgStrong(0, safe_ns, .release, .monotonic);
        self.in_wake.signaler().notify();
    }

    pub fn popPacket(self: *AudioPipeline) ?encoder.EncodedAudioPacket {
        return self.out_packets.pop();
    }

    pub fn packetReadyFd(self: *const AudioPipeline) std.posix.fd_t {
        return self.out_wake.fd;
    }

    pub fn ackPacketReady(self: *const AudioPipeline) void {
        self.out_wake.clear();
    }

    pub fn start(self: *AudioPipeline) AudioPipelineError!void {
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, pumpThreadMain, .{self}) catch {
            return AudioPipelineError.ThreadSpawnFailed;
        };
    }

    pub fn stopAndFlush(self: *AudioPipeline) void {
        self.stop_requested.store(true, .release);
        self.in_wake.signaler().notify();
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
                captured += cap.track.capturedFrames();
                dropped += cap.track.droppedFrames();
            }
        }
        return .{
            .frames_captured = captured,
            .frames_encoded = self.frames_encoded.load(.acquire),
            .frames_dropped = dropped,
            .packets_emitted = self.packets_emitted.load(.acquire),
            .packets_dropped = self.packets_dropped.load(.acquire),
            .encode_errors = self.encode_errors.load(.acquire),
        };
    }

    fn drainEncodedPackets(self: *AudioPipeline) void {
        while (true) {
            const maybe_pkt = self.enc.receivePacket() catch |err| {
                std.log.warn("audio encoder receivePacket failed: {s}", .{@errorName(err)});
                _ = self.encode_errors.fetchAdd(1, .monotonic);
                return;
            };
            var pkt = maybe_pkt orelse return;
            if (self.out_packets.push(pkt)) {
                _ = self.packets_emitted.fetchAdd(1, .monotonic);
                self.out_wake.signaler().notify();
            } else {
                pkt.deinit();
                _ = self.packets_dropped.fetchAdd(1, .monotonic);
            }
        }
    }

    fn pumpAvailableBlocks(self: *AudioPipeline, flushing: bool) void {
        const t0_ns = self.session_start_ns.load(.acquire);
        var block: [pcm.block_floats]f32 = undefined;
        var pts: i64 = 0;

        while (self.mixer.pullNextBlock(t0_ns, flushing, &block, &pts)) {
            self.enc.submitStereoBlock(&block, pts) catch |err| {
                std.log.warn("audio encoder submitStereoBlock failed: {s}", .{@errorName(err)});
                _ = self.encode_errors.fetchAdd(1, .monotonic);
                continue;
            };
            _ = self.frames_encoded.fetchAdd(pcm.frame_samples, .monotonic);
            self.drainEncodedPackets();
        }
    }

    fn flushTailAndEncoder(self: *AudioPipeline) void {
        self.pumpAvailableBlocks(false);
        self.pumpAvailableBlocks(true);
        if (!self.mixer.started) return;
        self.enc.flush() catch |err| {
            std.log.warn("audio encoder flush failed: {s}", .{@errorName(err)});
            _ = self.encode_errors.fetchAdd(1, .monotonic);
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

test "AudioSessionMixer + AudioEncoder dual-source silent endpoint resilience and multi-block flush" {
    try std.testing.expectError(
        AudioPipelineError.InvalidConfig,
        AudioPipeline.init(std.testing.allocator, .none, encoder.default_bitrate_bps, true),
    );

    var enc = try encoder.AudioEncoder.init(encoder.default_bitrate_bps, true);
    defer enc.deinit();

    var desk = pcm.AudioTrackBuffer{};
    var mic = pcm.AudioTrackBuffer{};
    const tracks = [_]*pcm.AudioTrackBuffer{ &desk, &mic };
    var mixer = AudioSessionMixer.init(&tracks);

    const t0_ns: u64 = 2_000_000_000;
    const tone_a: [pcm.block_floats]f32 = @splat(0.2);

    // Desktop pushes 3 blocks while mic never emits a single callback (silent/idle endpoint)
    for (0..3) |i| {
        const ts_a: u64 = if (i == 0) t0_ns else 0;
        _ = desk.pushInterleaved(&tone_a, ts_a);
    }

    var block: [pcm.block_floats]f32 = undefined;
    var pts: i64 = 0;
    var encoded_blocks: usize = 0;
    var packet_count: usize = 0;

    // Flush must align active desktop stream despite silent mic and encode all 3 blocks
    while (mixer.pullNextBlock(t0_ns, true, &block, &pts)) {
        try enc.submitStereoBlock(&block, pts);
        encoded_blocks += 1;
        while (try enc.receivePacket()) |pkt_val| {
            var pkt = pkt_val;
            pkt.deinit();
            packet_count += 1;
        }
    }
    try enc.flush();
    while (try enc.receivePacket()) |pkt_val| {
        var pkt = pkt_val;
        pkt.deinit();
        packet_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), encoded_blocks);
    try std.testing.expect(packet_count >= 3);
}

test "AudioSessionMixer preserves continuous stream PTS when sibling overflows" {
    var desk = pcm.AudioTrackBuffer{};
    var mic = pcm.AudioTrackBuffer{};
    const tracks = [_]*pcm.AudioTrackBuffer{ &desk, &mic };
    var mixer = AudioSessionMixer.init(&tracks);

    const t0_ns: u64 = 1_000_000_000;
    const tone: [pcm.block_floats]f32 = @splat(0.15);
    _ = desk.pushInterleaved(&tone, t0_ns);
    _ = desk.pushInterleaved(&tone, 0);

    // Mic overflows by 500 frames after block 0 while desktop stays continuous
    _ = mic.pushInterleaved(&tone, t0_ns);
    mic.overflow_pushed_mark.store(pcm.frame_samples, .release);
    _ = mic.dropped_frames.fetchAdd(500, .release);
    _ = mic.pushInterleaved(&tone, 0);

    var block: [pcm.block_floats]f32 = undefined;
    var pts0: i64 = -1;
    var pts1: i64 = -1;
    try std.testing.expect(mixer.pullNextBlock(t0_ns, false, &block, &pts0));
    try std.testing.expect(mixer.pullNextBlock(t0_ns, false, &block, &pts1));

    // Continuous desktop timeline stays at exact 0 -> 1024 without jumping ahead of VfrClock,
    // while mic receives 500 frames of silence pad to stay phase-aligned after its drop!
    try std.testing.expectEqual(@as(i64, 0), pts0);
    try std.testing.expectEqual(@as(i64, 1024), pts1);
}
