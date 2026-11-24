const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");

pub const EncoderError = error{
    EncoderNotFound,
    ContextAllocFailed,
    EncoderOpenFailed,
    SendFrameFailed,
    ReceivePacketFailed,
};

pub const EncodedPacket = struct {
    pts: i64,
    dts: i64,
    size: usize,
    is_keyframe: bool,
    raw_packet: *c.AVPacket,

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
    ) EncoderError!VaapiEncoder {
        try profile.validate();

        const codec = c.avcodec_find_encoder_by_name("h264_vaapi") orelse {
            return EncoderError.EncoderNotFound;
        };

        const ctx = c.avcodec_alloc_context3(codec) orelse {
            return EncoderError.ContextAllocFailed;
        };
        errdefer c.avcodec_free_context(&@as(?*c.AVCodecContext, ctx));

        ctx.*.width = @intCast(width);
        ctx.*.height = @intCast(height);
        ctx.*.pix_fmt = c.AV_PIX_FMT_VAAPI;
        ctx.*.time_base = c.AVRational{ .num = 1, .den = 1000 };
        ctx.*.hw_frames_ctx = c.av_buffer_ref(hw_frames_ctx);
        ctx.*.max_b_frames = 0; // Disable B-frames for minimal latency

        applyRateControl(ctx, profile);

        if (c.avcodec_open2(ctx, codec, null) < 0) {
            return EncoderError.EncoderOpenFailed;
        }

        return .{
            .codec_ctx = ctx,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *VaapiEncoder) void {
        var ctx: ?*c.AVCodecContext = self.codec_ctx;
        c.avcodec_free_context(&ctx);
    }

    fn applyRateControl(ctx: *c.AVCodecContext, profile: common.RateControlProfile) void {
        const rc_str = profile.getFfmpegRcMode();
        _ = c.av_opt_set(ctx.*.priv_data, "rc_mode", rc_str.ptr, 0);

        switch (profile.mode) {
            .cqp => {
                _ = c.av_opt_set_int(ctx.*.priv_data, "qp", profile.qp, 0);
            },
            .vbr, .cbr => {
                ctx.*.bit_rate = @as(i64, profile.bitrate_kbps) * 1000;
                ctx.*.rc_max_rate = @as(i64, profile.maxrate_kbps) * 1000;
                ctx.*.rc_buffer_size = @as(c_int, @intCast(profile.bufsize_kb)) * 1000 * 8;
            },
        }
    }

    /// Submit a hardware frame to the encoder. Pass null to flush the encoder.
    pub fn sendFrame(self: *VaapiEncoder, frame: ?*const c.AVFrame) EncoderError!void {
        const ret = c.avcodec_send_frame(self.codec_ctx, frame);
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
        if (ret == -11 or ret == c.AVERROR_EOF) {
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
