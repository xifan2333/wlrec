const std = @import("std");
const common = @import("../common/lib.zig");

pub const sample_rate: u32 = 48_000;
pub const channels: usize = 2;
pub const frame_samples: usize = 1024;
pub const block_floats: usize = frame_samples * channels;
pub const ring_capacity_floats: usize = 65_536;
pub const max_pad_frames: u64 = sample_rate;

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

/// Convert interleaved stereo f32 samples into planar left/right FLTP buffers.
pub fn deinterleaveStereo(interleaved: []const f32, left: []f32, right: []f32) void {
    std.debug.assert(left.len == right.len);
    std.debug.assert(interleaved.len >= left.len * channels);

    for (left, right, 0..) |*l, *r, i| {
        l.* = sanitizeSample(interleaved[i * channels]);
        r.* = sanitizeSample(interleaved[i * channels + 1]);
    }
}

/// Sum two interleaved stereo f32 buffers with [-1.0, 1.0] clamping.
pub fn mixStereoClamped(a: []const f32, b: []const f32, out: []f32) void {
    std.debug.assert(a.len == out.len and b.len == out.len);
    for (a, b, out) |sa, sb, *dst| {
        dst.* = std.math.clamp(sanitizeSample(sa) + sanitizeSample(sb), -1.0, 1.0);
    }
}

/// Convert nanosecond duration to rounded 48 kHz sample frames.
pub fn nsToFrames(delta_ns: u64) u64 {
    const num = @as(u128, delta_ns) * @as(u128, sample_rate) + (std.time.ns_per_s / 2);
    return @intCast(num / std.time.ns_per_s);
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

/// Per-source sample alignment and overflow tracking cursor.
pub const SourceCursor = struct {
    skip_remaining: u64 = 0,
    pad_remaining: u64 = 0,
    accounted_drops: u64 = 0,

    pub fn configure(self: *SourceCursor, skip_frames: u64, pad_frames: u64) void {
        self.skip_remaining = skip_frames;
        self.pad_remaining = @min(pad_frames, max_pad_frames);
    }

    pub fn drainSkip(self: *SourceCursor, ring: *AudioRingBuffer) void {
        if (self.skip_remaining == 0) return;
        const max_step: usize = @intCast(@min(self.skip_remaining, ring_capacity_floats));
        const dropped = discardStereoFrames(ring, max_step);
        self.skip_remaining -= dropped;
    }

    pub fn readyFrames(self: *SourceCursor, ring: *AudioRingBuffer) usize {
        self.drainSkip(ring);
        if (self.skip_remaining > 0) return 0;
        const pad_cap: usize = @intCast(@min(self.pad_remaining, frame_samples));
        return pad_cap + readableFrames(ring);
    }

    pub fn readBlock(
        self: *SourceCursor,
        ring: *AudioRingBuffer,
        dest: *[block_floats]f32,
        pad_tail_silence: bool,
    ) bool {
        const avail = self.readyFrames(ring);
        if (!pad_tail_silence and avail < frame_samples) return false;
        if (pad_tail_silence and avail == 0 and self.skip_remaining > 0) {
            @memset(dest, 0.0);
            return true;
        }

        const pad_frames: usize = @intCast(@min(self.pad_remaining, frame_samples));
        if (pad_frames > 0) {
            @memset(dest[0 .. pad_frames * channels], 0.0);
            self.pad_remaining -= pad_frames;
        }

        const need_ring = frame_samples - pad_frames;
        const ring_take = @min(need_ring, readableFrames(ring));
        if (ring_take > 0) {
            const start = pad_frames * channels;
            _ = ring.popSlice(dest[start .. start + ring_take * channels]);
        }

        const filled = pad_frames + ring_take;
        if (filled < frame_samples) {
            @memset(dest[filled * channels .. block_floats], 0.0);
        }
        return filled > 0 or pad_tail_silence;
    }

    pub fn consumeDrops(self: *SourceCursor, cumulative_drops: u64) u64 {
        const delta = cumulative_drops -| self.accounted_drops;
        self.accounted_drops = cumulative_drops;
        return delta;
    }
};

pub const GroupAlignment = struct {
    initial_pts_samples: i64,
    cursors: [2]SourceCursor,
};

/// Align 1 or 2 audio streams to a shared PTS timeline anchored at VfrClock session_start_ns.
pub fn alignStreamGroup(starts_ns: []const u64, session_start_ns: u64) GroupAlignment {
    std.debug.assert(starts_ns.len >= 1 and starts_ns.len <= 2);

    var raw: [2]StreamAlignment = .{ .{}, .{} };
    var min_offset: u64 = std.math.maxInt(u64);
    for (starts_ns, 0..) |st_ns, i| {
        raw[i] = computeStreamAlignment(st_ns, session_start_ns);
        min_offset = @min(min_offset, raw[i].offset_frames);
    }

    var res = GroupAlignment{
        .initial_pts_samples = @intCast(min_offset),
        .cursors = .{ .{}, .{} },
    };
    for (starts_ns, 0..) |_, i| {
        res.cursors[i].configure(raw[i].skip_frames, raw[i].offset_frames - min_offset);
    }
    return res;
}

test "pushStereoFrames preserves stereo pair alignment on partial overflow" {
    var ring = AudioRingBuffer.init();
    const total_pairs = ring_capacity_floats / channels;
    try std.testing.expectEqual(total_pairs - 1, pushSilenceFrames(&ring, total_pairs - 1));

    // Push 3 stereo pairs (6 floats) when only 1 stereo pair (2 floats) fits, plus trailing odd float
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

test "deinterleaveStereo and mixStereoClamped sanitize and clamp samples" {
    const nan = std.math.nan(f32);
    const interleaved = [_]f32{ 0.5, -0.5, 1.5, -2.0, nan, 0.25 };
    var left: [3]f32 = undefined;
    var right: [3]f32 = undefined;
    deinterleaveStereo(&interleaved, &left, &right);

    try std.testing.expectEqualSlices(f32, &[_]f32{ 0.5, 1.0, 0.0 }, &left);
    try std.testing.expectEqualSlices(f32, &[_]f32{ -0.5, -1.0, 0.25 }, &right);

    const a = [_]f32{ 0.8, -0.7, nan, 0.3 };
    const b = [_]f32{ 0.5, -0.6, 0.4, -0.1 };
    var mixed: [4]f32 = undefined;
    mixStereoClamped(&a, &b, &mixed);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mixed[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), mixed[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mixed[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), mixed[3], 1e-6);
}

test "alignStreamGroup and SourceCursor align pre-t0 skip and post-t0 silence pad" {
    const t0_ns: u64 = 1_000_000_000;
    // Stream 0 starts 10ms before t0 (skip 480 frames); Stream 1 starts 10ms after t0 (pad 480 frames)
    const starts = [_]u64{ t0_ns - 10_000_000, t0_ns + 10_000_000 };
    var group = alignStreamGroup(&starts, t0_ns);

    try std.testing.expectEqual(@as(i64, 0), group.initial_pts_samples);
    try std.testing.expectEqual(@as(u64, 480), group.cursors[0].skip_remaining);
    try std.testing.expectEqual(@as(u64, 0), group.cursors[0].pad_remaining);
    try std.testing.expectEqual(@as(u64, 0), group.cursors[1].skip_remaining);
    try std.testing.expectEqual(@as(u64, 480), group.cursors[1].pad_remaining);

    var ring0 = AudioRingBuffer.init();
    var ring1 = AudioRingBuffer.init();

    // Feed 480 pre-t0 frames (-1.0) + 1024 post-t0 frames (+0.5) into ring0
    const pre_buf: [480 * channels]f32 = @splat(-1.0);
    _ = pushStereoFrames(&ring0, &pre_buf);
    const post_buf0: [block_floats]f32 = @splat(0.5);
    _ = pushStereoFrames(&ring0, &post_buf0);

    // Feed 544 frames (+0.25) into ring1; combined with 480 pad frames = 1024 frames
    const post_buf1: [544 * channels]f32 = @splat(0.25);
    _ = pushStereoFrames(&ring1, &post_buf1);

    var block0: [block_floats]f32 = undefined;
    var block1: [block_floats]f32 = undefined;
    try std.testing.expect(group.cursors[0].readBlock(&ring0, &block0, false));
    try std.testing.expect(group.cursors[1].readBlock(&ring1, &block1, false));

    // Stream 0 skipped -1.0 and starts directly with +0.5
    try std.testing.expectEqual(@as(f32, 0.5), block0[0]);
    // Stream 1 padded first 480 stereo frames with 0.0, then +0.25 at frame 480
    try std.testing.expectEqual(@as(f32, 0.0), block1[0]);
    try std.testing.expectEqual(@as(f32, 0.0), block1[480 * channels - 1]);
    try std.testing.expectEqual(@as(f32, 0.25), block1[480 * channels]);

    try std.testing.expectEqual(@as(u64, 12), group.cursors[0].consumeDrops(12));
    try std.testing.expectEqual(@as(u64, 3), group.cursors[0].consumeDrops(15));
}
