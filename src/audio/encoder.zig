const std = @import("std");
const c = @import("c");
const pcm = @import("pcm.zig");

const averror_eagain: c_int = -@as(c_int, @backingInt(std.posix.E.AGAIN));

pub const default_bitrate_bps: u32 = 128_000;
pub const min_bitrate_bps: u32 = 32_000;
pub const max_bitrate_bps: u32 = 512_000;

pub const AudioEncoderError = error{
    InvalidBitrate,
    CodecNotFound,
    ContextAllocFailed,
    FrameAllocFailed,
    EncoderOpenFailed,
    SendSamplesFailed,
    ReceivePacketFailed,
};

/// OwningHandle wrapping a reference-counted encoded AAC packet.
pub const EncodedAudioPacket = struct {
    pts: i64,
    dts: i64,
    duration: i64,
    size: usize,
    raw_packet: *c.AVPacket,

    pub fn dataSlice(self: *const EncodedAudioPacket) []const u8 {
        return self.raw_packet.*.data[0..self.size];
    }

    pub fn deinit(self: *EncodedAudioPacket) void {
        var p: ?*c.AVPacket = self.raw_packet;
        c.av_packet_free(&p);
    }
};

fn configureCodecContext(
    ctx: *c.AVCodecContext,
    bitrate_bps: u32,
    global_header: bool,
) void {
    c.av_channel_layout_default(&ctx.*.ch_layout, @intCast(pcm.channels));
    ctx.*.sample_rate = @intCast(pcm.sample_rate);
    ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
    ctx.*.bit_rate = @intCast(bitrate_bps);
    ctx.*.time_base = .{ .num = 1, .den = @intCast(pcm.sample_rate) };
    if (global_header) {
        ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
    }
}

fn allocPlanarFrame(ctx: *const c.AVCodecContext) AudioEncoderError!*c.AVFrame {
    const frame = c.av_frame_alloc() orelse return AudioEncoderError.FrameAllocFailed;
    errdefer {
        var f: ?*c.AVFrame = frame;
        c.av_frame_free(&f);
    }

    frame.*.format = ctx.*.sample_fmt;
    frame.*.sample_rate = ctx.*.sample_rate;
    frame.*.nb_samples = @intCast(pcm.frame_samples);
    if (c.av_channel_layout_copy(&frame.*.ch_layout, &ctx.*.ch_layout) < 0) {
        return AudioEncoderError.FrameAllocFailed;
    }
    if (c.av_frame_get_buffer(frame, 0) < 0) {
        return AudioEncoderError.FrameAllocFailed;
    }
    return frame;
}

/// Owning FFmpeg native AAC encoder with pre-allocated planar frame and poll scratch packet.
pub const AudioEncoder = struct {
    codec_ctx: *c.AVCodecContext,
    frame: *c.AVFrame,
    scratch_pkt: *c.AVPacket,

    pub fn init(bitrate_bps: u32, global_header: bool) AudioEncoderError!AudioEncoder {
        if (bitrate_bps < min_bitrate_bps or bitrate_bps > max_bitrate_bps) {
            return AudioEncoderError.InvalidBitrate;
        }

        const codec = c.avcodec_find_encoder_by_name("aac") orelse
            c.avcodec_find_encoder(c.AV_CODEC_ID_AAC) orelse
            return AudioEncoderError.CodecNotFound;

        const ctx = c.avcodec_alloc_context3(codec) orelse return AudioEncoderError.ContextAllocFailed;
        errdefer {
            var opt_ctx: ?*c.AVCodecContext = ctx;
            c.avcodec_free_context(&opt_ctx);
        }

        configureCodecContext(ctx, bitrate_bps, global_header);
        if (c.avcodec_open2(ctx, codec, null) < 0) {
            return AudioEncoderError.EncoderOpenFailed;
        }

        const frame = try allocPlanarFrame(ctx);
        errdefer {
            var opt_frame: ?*c.AVFrame = frame;
            c.av_frame_free(&opt_frame);
        }

        const pkt = c.av_packet_alloc() orelse return AudioEncoderError.FrameAllocFailed;

        return .{
            .codec_ctx = ctx,
            .frame = frame,
            .scratch_pkt = pkt,
        };
    }

    pub fn deinit(self: *AudioEncoder) void {
        var pkt: ?*c.AVPacket = self.scratch_pkt;
        c.av_packet_free(&pkt);
        var frame: ?*c.AVFrame = self.frame;
        c.av_frame_free(&frame);
        var ctx: ?*c.AVCodecContext = self.codec_ctx;
        c.avcodec_free_context(&ctx);
    }

    /// Deinterleave 1024 stereo f32 frames into FLTP planes and submit to the AAC encoder.
    pub fn submitStereoBlock(
        self: *AudioEncoder,
        interleaved: []const f32,
        pts_samples: i64,
    ) AudioEncoderError!void {
        if (interleaved.len < pcm.block_floats) return AudioEncoderError.SendSamplesFailed;
        if (c.av_frame_make_writable(self.frame) < 0) return AudioEncoderError.SendSamplesFailed;

        const left_ptr: [*]f32 = @ptrCast(@alignCast(self.frame.*.data[0]));
        const right_ptr: [*]f32 = @ptrCast(@alignCast(self.frame.*.data[1]));
        pcm.deinterleaveStereo(
            interleaved[0..pcm.block_floats],
            left_ptr[0..pcm.frame_samples],
            right_ptr[0..pcm.frame_samples],
        );

        self.frame.*.pts = pts_samples;
        if (c.avcodec_send_frame(self.codec_ctx, self.frame) < 0) {
            return AudioEncoderError.SendSamplesFailed;
        }
    }

    /// Signal end-of-stream to flush delayed AAC MDCT lookahead packets.
    pub fn flush(self: *AudioEncoder) AudioEncoderError!void {
        if (c.avcodec_send_frame(self.codec_ctx, null) < 0) {
            return AudioEncoderError.SendSamplesFailed;
        }
    }

    /// Poll the next encoded AAC packet as a standalone OwningHandle.
    pub fn receivePacket(self: *AudioEncoder) AudioEncoderError!?EncodedAudioPacket {
        c.av_packet_unref(self.scratch_pkt);
        const rc = c.avcodec_receive_packet(self.codec_ctx, self.scratch_pkt);
        if (rc == averror_eagain or rc == c.AVERROR_EOF) return null;
        if (rc < 0) return AudioEncoderError.ReceivePacketFailed;

        const cloned = c.av_packet_clone(self.scratch_pkt) orelse {
            return AudioEncoderError.ReceivePacketFailed;
        };
        return .{
            .pts = cloned.*.pts,
            .dts = cloned.*.dts,
            .duration = cloned.*.duration,
            .size = @intCast(@max(@as(c_int, 0), cloned.*.size)),
            .raw_packet = cloned,
        };
    }
};

test "AudioEncoder encodes stereo f32 blocks to AAC with global header and flushes cleanly" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    try std.testing.expectError(AudioEncoderError.InvalidBitrate, AudioEncoder.init(0, true));

    var enc = try AudioEncoder.init(default_bitrate_bps, true);
    defer enc.deinit();

    try std.testing.expect(enc.codec_ctx.*.extradata_size > 0);
    try std.testing.expectEqual(@as(c_int, pcm.frame_samples), enc.codec_ctx.*.frame_size);

    var block: [pcm.block_floats]f32 = undefined;
    for (0..pcm.frame_samples) |i| {
        const phase = @as(f32, @floatFromInt(i)) * 0.05;
        const val = @sin(phase) * 0.25;
        block[i * 2] = val;
        block[i * 2 + 1] = -val;
    }

    var total_packets: usize = 0;
    var total_bytes: usize = 0;
    for (0..6) |blk_idx| {
        const pts: i64 = @intCast(blk_idx * pcm.frame_samples);
        try enc.submitStereoBlock(&block, pts);
        while (try enc.receivePacket()) |pkt_val| {
            var pkt = pkt_val;
            defer pkt.deinit();
            total_packets += 1;
            total_bytes += pkt.dataSlice().len;
        }
    }

    try enc.flush();
    while (try enc.receivePacket()) |pkt_val| {
        var pkt = pkt_val;
        defer pkt.deinit();
        total_packets += 1;
        total_bytes += pkt.dataSlice().len;
    }

    try std.testing.expect(total_packets >= 6);
    try std.testing.expect(total_bytes > 0);
}
