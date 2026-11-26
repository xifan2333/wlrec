const std = @import("std");
const common = @import("../common/lib.zig");

pub const sample_rate: u32 = 48_000;
pub const channels: usize = 2;
pub const frame_samples: usize = 1024;
pub const block_floats: usize = frame_samples * channels;
pub const ring_capacity_floats: usize = 65_536;

/// Pre-allocated lock-free SPSC ring buffer holding interleaved stereo f32 PCM samples.
pub const AudioRingBuffer = common.SpscRingBuffer(f32, ring_capacity_floats);

pub fn readableFrames(ring: *const AudioRingBuffer) usize {
    return ring.readable() / channels;
}

pub fn writableFrames(ring: *const AudioRingBuffer) usize {
    return ring.writable() / channels;
}

/// Push complete stereo f32 frame pairs into the ring buffer, preserving L/R channel alignment.
pub fn pushStereoFrames(ring: *AudioRingBuffer, interleaved: []const f32) usize {
    const count = @min(interleaved.len / channels, writableFrames(ring));
    if (count == 0) return 0;
    _ = ring.pushSlice(interleaved[0 .. count * channels]);
    return count;
}

/// Push zeroed stereo frame pairs (used for PulseAudio stream holes).
pub fn pushSilenceFrames(ring: *AudioRingBuffer, frame_count: usize) usize {
    const zeros: [256]f32 = @splat(0.0);
    const chunk_frames = zeros.len / channels;
    var remaining = @min(frame_count, writableFrames(ring));
    var pushed: usize = 0;

    while (remaining > 0) {
        const step = @min(remaining, chunk_frames);
        _ = ring.pushSlice(zeros[0 .. step * channels]);
        remaining -= step;
        pushed += step;
    }
    return pushed;
}

/// Pop and discard up to frame_count stereo frames from the ring buffer.
pub fn discardStereoFrames(ring: *AudioRingBuffer, frame_count: usize) usize {
    var scratch: [256]f32 = undefined;
    const chunk_frames = scratch.len / channels;
    var remaining = @min(frame_count, readableFrames(ring));
    var discarded: usize = 0;

    while (remaining > 0) {
        const step = @min(remaining, chunk_frames);
        const got = ring.popSlice(scratch[0 .. step * channels]) / channels;
        if (got == 0) break;
        remaining -= got;
        discarded += got;
    }
    return discarded;
}

fn sanitizeSample(v: f32) f32 {
    if (std.math.isNan(v)) return 0.0;
    return std.math.clamp(v, -1.0, 1.0);
}

/// Soft-knee limiter preserving unity gain below 0.75 and smoothly saturating toward +-1.0.
pub fn softClampSample(sum: f32) f32 {
    if (std.math.isNan(sum)) return 0.0;
    const abs_v = @abs(sum);
    if (abs_v <= 0.75) return sum;
    const excess = abs_v - 0.75;
    const mag = 0.75 + (0.25 * excess) / (0.25 + excess);
    return std.math.copysign(mag, sum);
}

/// Convert interleaved stereo f32 samples into planar left/right FLTP buffers.
pub fn deinterleaveStereo(interleaved: []const f32, left: []f32, right: []f32) void {
    std.debug.assert(left.len == right.len);
    std.debug.assert(interleaved.len >= left.len * channels);

    for (left, right, 0..) |*l, *r, i| {
        l.* = sanitizeSample(interleaved[i * channels]);
        r.* = sanitizeSample(interleaved[i * channels + 1]);
    }
}

/// Sum two interleaved stereo f32 buffers with soft-knee limiting in (-1.0, 1.0).
pub fn mixStereoSoftClamped(a: []const f32, b: []const f32, out: []f32) void {
    std.debug.assert(a.len == out.len and b.len == out.len);
    for (a, b, out) |sa, sb, *dst| {
        dst.* = softClampSample(sanitizeSample(sa) + sanitizeSample(sb));
    }
}

/// Convert nanosecond duration to rounded 48 kHz sample frames via VfrClock.rescaleNs.
pub fn nsToFrames(delta_ns: u64) u64 {
    return @intCast(common.VfrClock.rescaleNs(delta_ns, 1, sample_rate));
}

pub const StreamAlignment = struct {
    skip_frames: u64 = 0,
    offset_frames: u64 = 0,
};

/// Compute per-stream sample skip or start offset relative to VfrClock t0.
pub fn computeStreamAlignment(audio_start_ns: u64, session_start_ns: u64) StreamAlignment {
    if (audio_start_ns < session_start_ns) {
        return .{ .skip_frames = nsToFrames(session_start_ns - audio_start_ns) };
    }
    return .{ .offset_frames = nsToFrames(audio_start_ns - session_start_ns) };
}

/// Shared lock-free producer/consumer track state embedded inside each capture source.
pub const AudioTrackBuffer = struct {
    ring: AudioRingBuffer = .init(),
    first_sample_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pushed_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_pushed_mark: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn recordStartNs(self: *AudioTrackBuffer, start_ns: u64) void {
        if (start_ns > 0) {
            _ = self.first_sample_ns.cmpxchgStrong(0, start_ns, .release, .monotonic);
        }
    }

    fn commitPush(self: *AudioTrackBuffer, pushed: usize, total_frames: usize) bool {
        const next_pushed = self.pushed_frames.fetchAdd(pushed, .monotonic) + pushed;
        if (pushed < total_frames) {
            self.overflow_pushed_mark.store(next_pushed, .monotonic);
            _ = self.dropped_frames.fetchAdd(total_frames - pushed, .release);
        }
        return pushed > 0;
    }

    pub fn pushInterleaved(self: *AudioTrackBuffer, samples: []const f32, start_ns: u64) bool {
        const stereo_frames = samples.len / channels;
        if (stereo_frames == 0) return false;
        self.recordStartNs(start_ns);
        const pushed = pushStereoFrames(&self.ring, samples[0 .. stereo_frames * channels]);
        return self.commitPush(pushed, stereo_frames);
    }

    pub fn pushHole(self: *AudioTrackBuffer, stereo_frames: usize, start_ns: u64) bool {
        if (stereo_frames == 0) return false;
        self.recordStartNs(start_ns);
        const pushed = pushSilenceFrames(&self.ring, stereo_frames);
        return self.commitPush(pushed, stereo_frames);
    }

    pub fn firstSampleNs(self: *const AudioTrackBuffer) u64 {
        return self.first_sample_ns.load(.acquire);
    }

    pub fn capturedFrames(self: *const AudioTrackBuffer) u64 {
        return self.pushed_frames.load(.acquire);
    }

    pub fn droppedFrames(self: *const AudioTrackBuffer) u64 {
        return self.dropped_frames.load(.acquire);
    }

    pub fn trimPrestartBacklog(self: *AudioTrackBuffer, max_frames: usize, consumed_out: *u64) void {
        const readable = readableFrames(&self.ring);
        if (readable <= max_frames) return;
        const discarded = discardStereoFrames(&self.ring, readable - max_frames);
        if (discarded == 0) return;
        consumed_out.* += discarded;

        const advance_ns = (@as(u128, discarded) * std.time.ns_per_s) / sample_rate;
        const prev_ns = self.firstSampleNs();
        if (prev_ns > 0) {
            self.first_sample_ns.store(prev_ns + @as(u64, @intCast(advance_ns)), .release);
        }
    }
};

/// Per-source sample alignment and boundary-accurate overflow tracking cursor.
pub const SourceCursor = struct {
    aligned: bool = false,
    skip_remaining: u64 = 0,
    pad_remaining: u64 = 0,
    consumed_frames: u64 = 0,
    accounted_drops: u64 = 0,

    pub fn configure(self: *SourceCursor, skip_frames: u64, pad_frames: u64, baseline_drops: u64) void {
        self.aligned = true;
        self.skip_remaining = skip_frames;
        self.pad_remaining = pad_frames;
        self.accounted_drops = baseline_drops;
    }

    pub fn drainSkip(self: *SourceCursor, track: *AudioTrackBuffer) void {
        if (self.skip_remaining == 0) return;
        const max_step: usize = @intCast(@min(self.skip_remaining, ring_capacity_floats));
        const dropped = discardStereoFrames(&track.ring, max_step);
        self.skip_remaining -= dropped;
        self.consumed_frames += dropped;
    }

    pub fn readyFrames(self: *SourceCursor, track: *AudioTrackBuffer) usize {
        if (!self.aligned) return 0;
        self.drainSkip(track);
        if (self.skip_remaining > 0) return 0;
        const pad_cap: usize = @intCast(@min(self.pad_remaining, frame_samples));
        return pad_cap + readableFrames(&track.ring);
    }

    pub fn readBlock(
        self: *SourceCursor,
        track: *AudioTrackBuffer,
        dest: *[block_floats]f32,
        pad_tail_silence: bool,
    ) bool {
        const avail = self.readyFrames(track);
        if (avail == 0) return false;
        if (!pad_tail_silence and avail < frame_samples) return false;

        const pad_frames: usize = @intCast(@min(self.pad_remaining, frame_samples));
        if (pad_frames > 0) {
            @memset(dest[0 .. pad_frames * channels], 0.0);
            self.pad_remaining -= pad_frames;
        }

        const need_ring = frame_samples - pad_frames;
        const ring_take = @min(need_ring, readableFrames(&track.ring));
        if (ring_take > 0) {
            const start = pad_frames * channels;
            _ = track.ring.popSlice(dest[start .. start + ring_take * channels]);
            self.consumed_frames += ring_take;
        }

        const filled = pad_frames + ring_take;
        if (filled < frame_samples) {
            @memset(dest[filled * channels .. block_floats], 0.0);
        }
        return filled > 0;
    }

    /// Return newly reached overflow drops only after pre-overflow buffered samples are drained.
    pub fn consumeReachedDrops(self: *SourceCursor, track: *const AudioTrackBuffer) u64 {
        const total = track.droppedFrames();
        if (total <= self.accounted_drops) return 0;
        const mark = track.overflow_pushed_mark.load(.acquire);
        if (self.consumed_frames < mark) return 0;
        const delta = total - self.accounted_drops;
        self.accounted_drops = total;
        return delta;
    }
};

test "pushStereoFrames preserves stereo pair alignment on partial overflow" {
    var ring = AudioRingBuffer.init();
    const total_pairs = ring_capacity_floats / channels;
    try std.testing.expectEqual(total_pairs - 1, pushSilenceFrames(&ring, total_pairs - 1));

    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5, 0.75, -0.75, 0.9 };
    const pushed_pairs = pushStereoFrames(&ring, &samples);
    try std.testing.expectEqual(@as(usize, 1), pushed_pairs);
    try std.testing.expectEqual(@as(usize, 0), writableFrames(&ring));

    _ = discardStereoFrames(&ring, total_pairs - 1);
    var pair: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), ring.popSlice(&pair));
    try std.testing.expectEqual(@as(f32, 0.25), pair[0]);
    try std.testing.expectEqual(@as(f32, -0.25), pair[1]);
}

test "deinterleaveStereo and mixStereoSoftClamped preserve linear range and soft-limit peaks" {
    const nan = std.math.nan(f32);
    const interleaved = [_]f32{ 0.5, -0.5, 1.5, -2.0, nan, 0.25 };
    var left: [3]f32 = undefined;
    var right: [3]f32 = undefined;
    deinterleaveStereo(&interleaved, &left, &right);

    try std.testing.expectEqualSlices(f32, &[_]f32{ 0.5, 1.0, 0.0 }, &left);
    try std.testing.expectEqualSlices(f32, &[_]f32{ -0.5, -1.0, 0.25 }, &right);

    const a = [_]f32{ 0.9, -0.9, nan, 0.3 };
    const b = [_]f32{ 0.8, -0.8, 0.4, -0.1 };
    var mixed: [4]f32 = undefined;
    mixStereoSoftClamped(&a, &b, &mixed);
    // Soft knee stays strictly inside (-1.0, 1.0) rather than hard-clipping flat at 1.0
    try std.testing.expect(mixed[0] > 0.9 and mixed[0] < 1.0);
    try std.testing.expect(mixed[1] < -0.9 and mixed[1] > -1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mixed[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), mixed[3], 1e-6);
}

test "SourceCursor delays overflow PTS advance until pre-overflow samples are drained" {
    var track = AudioTrackBuffer{};
    var cursor = SourceCursor{};

    const t0_ns: u64 = 1_000_000_000;
    const align0 = computeStreamAlignment(t0_ns - 10_000_000, t0_ns);
    try std.testing.expectEqual(@as(u64, 480), align0.skip_frames);

    cursor.configure(0, 0, 0);
    const block: [block_floats]f32 = @splat(0.25);
    _ = track.pushInterleaved(&block, t0_ns);

    // Fill remaining ring capacity and force a 200-frame overflow at ring head
    const rem_space = writableFrames(&track.ring);
    _ = track.pushHole(rem_space + 200, 0);
    try std.testing.expectEqual(@as(u64, 200), track.droppedFrames());

    // Before draining queued frames, consumeReachedDrops must return 0 (not premature!)
    try std.testing.expectEqual(@as(u64, 0), cursor.consumeReachedDrops(&track));

    var out: [block_floats]f32 = undefined;
    while (cursor.readBlock(&track, &out, true)) {}

    // Once pre-overflow frames are drained, exact 200 dropped frames are reported
    try std.testing.expectEqual(@as(u64, 200), cursor.consumeReachedDrops(&track));
    try std.testing.expectEqual(@as(u64, 0), cursor.consumeReachedDrops(&track));
}
