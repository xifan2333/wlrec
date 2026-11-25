const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");

pub const MuxError = error{
    OutOfMemory,
    UnsupportedTarget,
    MuxContextAllocFailed,
    StreamAllocFailed,
    CodecParamsCopyFailed,
    OutputOpenFailed,
    HeaderWriteFailed,
    PacketWriteFailed,
    TrailerWriteFailed,
};

pub const MuxStats = struct {
    packets_written: u64 = 0,
    packets_dropped: u64 = 0,
    bytes_written: u64 = 0,
    reconnects: u64 = 0,
};

pub const MuxTarget = struct {
    sink_type: common.MuxSinkType,
    format_name: [:0]const u8,
};

const ExtensionFormat = struct {
    ext: []const u8,
    format_name: [:0]const u8,
};

const supported_extensions = [_]ExtensionFormat{
    .{ .ext = ".mp4", .format_name = "mp4" },
    .{ .ext = ".mkv", .format_name = "matroska" },
    .{ .ext = ".flv", .format_name = "flv" },
    .{ .ext = ".h264", .format_name = "h264" },
    .{ .ext = ".264", .format_name = "h264" },
};

fn hasValidRtmpPrefix(target: []const u8) bool {
    const schemes = [_][]const u8{ "rtmp://", "rtmps://" };
    for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(target, scheme)) {
            return target.len > scheme.len;
        }
    }
    return false;
}

/// Parse an output path or streaming URL into a validated sink target and FFmpeg muxer name.
pub fn parseTarget(target: []const u8) MuxError!MuxTarget {
    if (target.len == 0) return MuxError.UnsupportedTarget;
    if (hasValidRtmpPrefix(target)) {
        return .{ .sink_type = .rtmp, .format_name = "flv" };
    }
    for (supported_extensions) |entry| {
        if (std.ascii.endsWithIgnoreCase(target, entry.ext) and target.len > entry.ext.len) {
            return .{ .sink_type = .file, .format_name = entry.format_name };
        }
    }
    return MuxError.UnsupportedTarget;
}

fn closeAvio(ctx: *c.AVFormatContext) void {
    if ((ctx.*.oformat.*.flags & c.AVFMT_NOFILE) == 0 and ctx.*.pb != null) {
        _ = c.avio_closep(&ctx.*.pb);
    }
}

/// Unified container and stream multiplexer wrapping FFmpeg libavformat.
pub const MuxSink = struct {
    allocator: std.mem.Allocator,
    target_z: [:0]u8,
    target_info: MuxTarget,
    fmt_ctx: ?*c.AVFormatContext = null,
    video_stream: ?*c.AVStream = null,
    src_time_base: c.AVRational = .{ .num = 1, .den = 1000 },
    header_written: bool = false,
    finished: bool = false,
    stats: MuxStats = .{},

    /// Allocate the FFmpeg output format context without performing disk or network I/O.
    pub fn init(allocator: std.mem.Allocator, target: []const u8) MuxError!MuxSink {
        const target_info = try parseTarget(target);
        const target_z = allocator.dupeSentinel(u8, target, 0) catch return MuxError.OutOfMemory;
        errdefer allocator.free(target_z);

        var fmt_ctx: ?*c.AVFormatContext = null;
        if (c.avformat_alloc_output_context2(&fmt_ctx, null, target_info.format_name.ptr, target_z.ptr) < 0 or fmt_ctx == null) {
            return MuxError.MuxContextAllocFailed;
        }

        return .{
            .allocator = allocator,
            .target_z = target_z,
            .target_info = target_info,
            .fmt_ctx = fmt_ctx,
        };
    }

    /// Return true when the container requires AV_CODEC_FLAG_GLOBAL_HEADER before avcodec_open2.
    pub fn needsGlobalHeader(self: *const MuxSink) bool {
        const ctx = self.fmt_ctx orelse return false;
        return (ctx.*.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0;
    }

    /// Create the video stream from an opened encoder context, open the output, and write the header.
    pub fn openVideoStream(self: *MuxSink, codec_ctx: *const c.AVCodecContext) MuxError!void {
        const ctx = self.fmt_ctx orelse return MuxError.MuxContextAllocFailed;
        const stream = c.avformat_new_stream(ctx, null) orelse return MuxError.StreamAllocFailed;
        stream.*.id = @intCast(ctx.*.nb_streams - 1);
        stream.*.time_base = codec_ctx.*.time_base;
        if (codec_ctx.*.framerate.num > 0 and codec_ctx.*.framerate.den > 0) {
            stream.*.avg_frame_rate = codec_ctx.*.framerate;
        }

        if (c.avcodec_parameters_from_context(stream.*.codecpar, codec_ctx) < 0) {
            return MuxError.CodecParamsCopyFailed;
        }

        self.src_time_base = codec_ctx.*.time_base;
        self.video_stream = stream;

        if ((ctx.*.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
            if (c.avio_open(&ctx.*.pb, self.target_z.ptr, c.AVIO_FLAG_WRITE) < 0) {
                return MuxError.OutputOpenFailed;
            }
        }
        errdefer closeAvio(ctx);

        if (c.avformat_write_header(ctx, null) < 0) {
            return MuxError.HeaderWriteFailed;
        }
        self.header_written = true;
    }

    /// Reference, rescale, and write an encoded packet to the container.
    pub fn writePacket(self: *MuxSink, raw_pkt: *const c.AVPacket) MuxError!void {
        const ctx = self.fmt_ctx orelse return MuxError.PacketWriteFailed;
        const stream = self.video_stream orelse return MuxError.PacketWriteFailed;
        if (!self.header_written) return MuxError.PacketWriteFailed;

        const out_pkt = c.av_packet_alloc() orelse return MuxError.OutOfMemory;
        var owned: ?*c.AVPacket = out_pkt;
        defer c.av_packet_free(&owned);

        if (c.av_packet_ref(out_pkt, raw_pkt) < 0) {
            return MuxError.PacketWriteFailed;
        }

        c.av_packet_rescale_ts(out_pkt, self.src_time_base, stream.*.time_base);
        out_pkt.*.stream_index = stream.*.index;
        out_pkt.*.pos = -1;

        const pkt_bytes: u64 = if (out_pkt.*.size > 0) @intCast(out_pkt.*.size) else 0;
        if (c.av_interleaved_write_frame(ctx, out_pkt) < 0) {
            return MuxError.PacketWriteFailed;
        }
        self.stats.bytes_written += pkt_bytes;
        self.stats.packets_written += 1;
    }

    /// Flush buffered packets, write the container trailer, and close the output handle.
    pub fn finish(self: *MuxSink) MuxError!void {
        if (self.finished) return;
        self.finished = true;

        const ctx = self.fmt_ctx orelse return;
        defer closeAvio(ctx);

        if (self.header_written) {
            self.header_written = false;
            if (c.av_write_trailer(ctx) < 0) {
                return MuxError.TrailerWriteFailed;
            }
        }
    }

    pub fn getStats(self: *const MuxSink) MuxStats {
        return self.stats;
    }

    pub fn deinit(self: *MuxSink) void {
        if (!self.finished) {
            self.finish() catch |err| {
                std.log.warn("mux finish during deinit: {s}", .{@errorName(err)});
            };
        }
        if (self.fmt_ctx) |ctx| {
            c.avformat_free_context(ctx);
            self.fmt_ctx = null;
        }
        self.allocator.free(self.target_z);
    }
};

test "parseTarget classifies container files and RTMP URLs" {
    const mp4 = try parseTarget("/tmp/demo.mp4");
    try std.testing.expectEqual(common.MuxSinkType.file, mp4.sink_type);
    try std.testing.expectEqualStrings("mp4", mp4.format_name);

    const mkv = try parseTarget("capture.MKV");
    try std.testing.expectEqual(common.MuxSinkType.file, mkv.sink_type);
    try std.testing.expectEqualStrings("matroska", mkv.format_name);

    const flv = try parseTarget("stream.flv");
    try std.testing.expectEqual(common.MuxSinkType.file, flv.sink_type);
    try std.testing.expectEqualStrings("flv", flv.format_name);

    const h264 = try parseTarget("raw.h264");
    try std.testing.expectEqual(common.MuxSinkType.file, h264.sink_type);
    try std.testing.expectEqualStrings("h264", h264.format_name);

    const rtmp = try parseTarget("rtmp://live.example.com/app/key");
    try std.testing.expectEqual(common.MuxSinkType.rtmp, rtmp.sink_type);
    try std.testing.expectEqualStrings("flv", rtmp.format_name);

    const rtmps = try parseTarget("rtmps://live.example.com/app/key");
    try std.testing.expectEqual(common.MuxSinkType.rtmp, rtmps.sink_type);
    try std.testing.expectEqualStrings("flv", rtmps.format_name);

    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget(""));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget(".mp4"));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget("rtmp://"));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget("output.avi"));
}

test "MuxSink writes valid MP4, MKV, FLV, and H264 files with synthetic packets" {
    // Minimal H.264 Baseline 320x240 SPS + PPS in Annex-B (valid for avformat/mp4/flv/mkv)
    const extradata_bytes = [_]u8{
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x15, 0xd9, 0x01, 0x41, 0xfb, 0x01, 0x10, 0x00, 0x00,
        0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc8, 0xf1, 0x42, 0x99, 0x60, 0x00, 0x00, 0x00, 0x01,
        0x68, 0xcb, 0x8c, 0xb2,
    };
    const idr_slice_bytes = [_]u8{
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21, 0xa0,
    };

    var dir_tpl = "/tmp/wlrec-mux-test-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);
    defer _ = c.rmdir(dir_ptr);

    const exts = [_][]const u8{ "mp4", "mkv", "flv", "h264" };
    for (exts) |ext| {
        var path_buf: [128]u8 = undefined;
        const path_slice = try std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{s}/test.{s}", .{ dir_slice, ext });
        path_buf[path_slice.len] = 0;
        const path_z = path_buf[0..path_slice.len :0];
        defer _ = c.unlink(path_z.ptr);

        var sink = try MuxSink.init(std.testing.allocator, path_slice);
        defer sink.deinit();

        const expect_global = !std.mem.eql(u8, ext, "h264");
        try std.testing.expectEqual(expect_global, sink.needsGlobalHeader());

        const ctx = c.avcodec_alloc_context3(null) orelse return error.CodecCtxFailed;
        var ctx_opt: ?*c.AVCodecContext = ctx;
        defer c.avcodec_free_context(&ctx_opt);

        ctx.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
        ctx.*.codec_id = c.AV_CODEC_ID_H264;
        ctx.*.width = 320;
        ctx.*.height = 240;
        ctx.*.pix_fmt = c.AV_PIX_FMT_NV12;
        ctx.*.time_base = .{ .num = 1, .den = 1000 };
        ctx.*.framerate = .{ .num = 30, .den = 1 };

        const ed = c.av_mallocz(extradata_bytes.len + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse return error.OutOfMemory;
        @memcpy(@as([*]u8, @ptrCast(ed))[0..extradata_bytes.len], &extradata_bytes);
        ctx.*.extradata = @ptrCast(ed);
        ctx.*.extradata_size = extradata_bytes.len;

        try sink.openVideoStream(ctx);

        const pts_vals = [_]i64{ 0, 33, 100 };
        for (pts_vals, 0..) |pts, idx| {
            const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
            var pkt_opt: ?*c.AVPacket = pkt;
            defer c.av_packet_free(&pkt_opt);

            try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, idr_slice_bytes.len));
            @memcpy(pkt.*.data[0..idr_slice_bytes.len], &idr_slice_bytes);
            pkt.*.pts = pts;
            pkt.*.dts = pts;
            pkt.*.duration = 33;
            if (idx == 0) pkt.*.flags |= c.AV_PKT_FLAG_KEY;

            try sink.writePacket(pkt);
        }

        try sink.finish();
        const stats = sink.getStats();
        try std.testing.expectEqual(@as(u64, 3), stats.packets_written);
        try std.testing.expectEqual(@as(u64, 0), stats.packets_dropped);
        try std.testing.expect(stats.bytes_written > 0);

        const fd = c.open(path_z.ptr, c.O_RDONLY);
        try std.testing.expect(fd >= 0);
        defer _ = c.close(fd);
        var head: [8]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 8), c.read(fd, &head[0], 8));
        if (std.mem.eql(u8, ext, "mp4")) {
            try std.testing.expectEqualSlices(u8, "ftyp", head[4..8]);
        } else if (std.mem.eql(u8, ext, "flv")) {
            try std.testing.expectEqualSlices(u8, "FLV", head[0..3]);
        } else if (std.mem.eql(u8, ext, "mkv")) {
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 }, head[0..4]);
        }
    }
}
