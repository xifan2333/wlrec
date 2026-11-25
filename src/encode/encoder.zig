const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const filter_graph = @import("filter_graph.zig");

const averror_eagain: c_int = -@as(c_int, @backingInt(std.posix.E.AGAIN));

pub const EncoderError = error{
    EncoderNotFound,
    ContextAllocFailed,
    EncoderOpenFailed,
    SendFrameFailed,
    ReceivePacketFailed,
} || common.RateControlError;

pub const EncodedPacket = struct {
    pts: i64,
    dts: i64,
    size: usize,
    is_keyframe: bool,
    raw_packet: *c.AVPacket,

    pub fn dataSlice(self: *const EncodedPacket) []const u8 {
        return self.raw_packet.*.data[0..self.size];
    }

    pub fn deinit(self: *EncodedPacket) void {
        var p = @as(?*c.AVPacket, self.raw_packet);
        c.av_packet_free(&p);
    }
};

/// Hardware H.264 VAAPI video encoder.
pub const VaapiEncoder = struct {
    codec_ctx: *c.AVCodecContext,
    width: u32,
    height: u32,

    pub fn init(
        width: u32,
        height: u32,
        hw_frames_ctx: *c.AVBufferRef,
        profile: common.RateControlProfile,
        fps: u32,
    ) EncoderError!VaapiEncoder {
        try profile.validate();

        const codec = c.avcodec_find_encoder_by_name("h264_vaapi") orelse {
            return EncoderError.EncoderNotFound;
        };

        const ctx = c.avcodec_alloc_context3(codec) orelse {
            return EncoderError.ContextAllocFailed;
        };
        var c_ctx: ?*c.AVCodecContext = ctx;
        errdefer c.avcodec_free_context(&c_ctx);

        ctx.*.width = @intCast(width);
        ctx.*.height = @intCast(height);
        ctx.*.pix_fmt = c.AV_PIX_FMT_VAAPI;
        ctx.*.time_base = c.AVRational{ .num = 1, .den = 1000 };
        const safe_fps = if (fps > 0) fps else 30;
        ctx.*.framerate = c.AVRational{ .num = @intCast(safe_fps), .den = 1 };
        ctx.*.hw_frames_ctx = c.av_buffer_ref(hw_frames_ctx);
        ctx.*.max_b_frames = 0; // Disable B-frames for minimal latency

        try applyRateControl(ctx, profile);

        if (c.avcodec_open2(ctx, codec, null) < 0) {
            return EncoderError.EncoderOpenFailed;
        }

        return .{
            .codec_ctx = ctx,
            .width = width,
            .height = height,
        };
    }

    /// Initialize an encoder targeting the hardware frames context carried by a filtered frame.
    pub fn initFromFilteredFrame(
        width: u32,
        height: u32,
        frame: *const filter_graph.FilteredFrame,
        profile: common.RateControlProfile,
        fps: u32,
    ) EncoderError!VaapiEncoder {
        const hw_ctx = frame.raw_frame.*.hw_frames_ctx orelse return EncoderError.EncoderOpenFailed;
        return init(width, height, hw_ctx, profile, fps);
    }

    pub fn deinit(self: *VaapiEncoder) void {
        var ctx: ?*c.AVCodecContext = self.codec_ctx;
        c.avcodec_free_context(&ctx);
    }

    fn applyRateControl(ctx: *c.AVCodecContext, profile: common.RateControlProfile) EncoderError!void {
        const rc_str = profile.getFfmpegRcMode();
        if (c.av_opt_set(ctx.*.priv_data, "rc_mode", rc_str.ptr, 0) < 0) {
            return EncoderError.EncoderOpenFailed;
        }

        switch (profile.mode) {
            .cqp => {
                if (c.av_opt_set_int(ctx.*.priv_data, "qp", profile.qp, 0) < 0) {
                    return EncoderError.EncoderOpenFailed;
                }
            },
            .vbr, .cbr => {
                ctx.*.bit_rate = @as(i64, profile.bitrate_kbps) * 1000;
                ctx.*.rc_max_rate = @as(i64, profile.maxrate_kbps) * 1000;
                const buf_bits: i64 = @as(i64, profile.bufsize_kb) * 1000 * 8;
                ctx.*.rc_buffer_size = @intCast(buf_bits);
            },
        }
    }

    /// Submit a filtered hardware frame to the encoder. Pass null to flush the encoder.
    pub fn sendFrame(self: *VaapiEncoder, frame: ?*const filter_graph.FilteredFrame) EncoderError!void {
        const raw: ?*const c.AVFrame = if (frame) |f| f.raw_frame else null;
        const ret = c.avcodec_send_frame(self.codec_ctx, raw);
        if (ret < 0) return EncoderError.SendFrameFailed;
    }

    /// Poll for an encoded H.264 packet. Returns null on EAGAIN or EOF.
    pub fn receivePacket(self: *VaapiEncoder) EncoderError!?EncodedPacket {
        const pkt = c.av_packet_alloc() orelse return EncoderError.ReceivePacketFailed;
        errdefer {
            var p = @as(?*c.AVPacket, pkt);
            c.av_packet_free(&p);
        }

        const ret = c.avcodec_receive_packet(self.codec_ctx, pkt);
        if (ret == averror_eagain or ret == c.AVERROR_EOF) {
            var p = @as(?*c.AVPacket, pkt);
            c.av_packet_free(&p);
            return null;
        }
        if (ret < 0) {
            return EncoderError.ReceivePacketFailed;
        }

        const is_key = (pkt.*.flags & c.AV_PKT_FLAG_KEY) != 0;
        return .{
            .pts = pkt.*.pts,
            .dts = pkt.*.dts,
            .size = @intCast(pkt.*.size),
            .is_keyframe = is_key,
            .raw_packet = pkt,
        };
    }
};

test "VaapiEncoder structural checks" {
    try std.testing.expect(@sizeOf(VaapiEncoder) > 0);
    try std.testing.expect(@sizeOf(EncodedPacket) > 0);
}
