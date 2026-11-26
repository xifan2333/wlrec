const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const rtmp = @import("rtmp.zig");

pub const interleave_delta_us: i64 = 100_000;

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
    scratch_pkt: ?*c.AVPacket = null,
    video_stream: ?*c.AVStream = null,
    audio_stream: ?*c.AVStream = null,
    video_src_time_base: c.AVRational = .{ .num = 1, .den = 1000 },
    audio_src_time_base: c.AVRational = .{ .num = 1, .den = 48000 },
    header_written: bool = false,
    finished: bool = false,
    rtmp_worker: ?*rtmp.RtmpWorker = null,
    write_mutex: std.Io.Mutex = .init,
    file_packets_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    file_bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Allocate the FFmpeg output format context without performing disk or network I/O.
    pub fn init(allocator: std.mem.Allocator, target: []const u8) MuxError!MuxSink {
        const target_info = try parseTarget(target);
        const target_z = allocator.dupeSentinel(u8, target, 0) catch return MuxError.OutOfMemory;
        errdefer allocator.free(target_z);

        var fmt_ctx: ?*c.AVFormatContext = null;
        var scratch_pkt: ?*c.AVPacket = null;
        if (target_info.sink_type == .file) {
            if (c.avformat_alloc_output_context2(&fmt_ctx, null, target_info.format_name.ptr, target_z.ptr) < 0 or fmt_ctx == null) {
                return MuxError.MuxContextAllocFailed;
            }
            errdefer if (fmt_ctx) |ctx| c.avformat_free_context(ctx);
            scratch_pkt = c.av_packet_alloc() orelse return MuxError.OutOfMemory;
        }

        return .{
            .allocator = allocator,
            .target_z = target_z,
            .target_info = target_info,
            .fmt_ctx = fmt_ctx,
            .scratch_pkt = scratch_pkt,
        };
    }

    /// Return true when the container supports an audio track alongside video.
    pub fn supportsAudio(self: *const MuxSink) bool {
        return !std.mem.eql(u8, self.target_info.format_name, "h264");
    }

    /// Return true when the container requires AV_CODEC_FLAG_GLOBAL_HEADER before avcodec_open2.
    pub fn needsGlobalHeader(self: *const MuxSink) bool {
        if (self.target_info.sink_type == .rtmp) return true;
        const ctx = self.fmt_ctx orelse return false;
        return (ctx.*.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0;
    }

    fn registerStream(
        ctx: *c.AVFormatContext,
        codec_ctx: *const c.AVCodecContext,
        is_video: bool,
    ) MuxError!*c.AVStream {
        const stream = c.avformat_new_stream(ctx, null) orelse return MuxError.StreamAllocFailed;
        stream.*.id = @intCast(ctx.*.nb_streams - 1);
        stream.*.time_base = codec_ctx.*.time_base;
        if (is_video and codec_ctx.*.framerate.num > 0 and codec_ctx.*.framerate.den > 0) {
            stream.*.avg_frame_rate = codec_ctx.*.framerate;
        }
        if (c.avcodec_parameters_from_context(stream.*.codecpar, codec_ctx) < 0) {
            return MuxError.CodecParamsCopyFailed;
        }
        return stream;
    }

    /// Create video and optional audio streams, open the output, and write the container header.
    pub fn openStreams(
        self: *MuxSink,
        video_ctx: *const c.AVCodecContext,
        audio_ctx: ?*const c.AVCodecContext,
    ) MuxError!void {
        if (audio_ctx != null and !self.supportsAudio()) {
            return MuxError.UnsupportedTarget;
        }

        if (self.target_info.sink_type == .rtmp) {
            const worker = try rtmp.RtmpWorker.init(self.allocator, self.target_z, video_ctx, audio_ctx);
            errdefer worker.deinit();
            try worker.start();
            self.rtmp_worker = worker;
            self.header_written = true;
            return;
        }

        const ctx = self.fmt_ctx orelse return MuxError.MuxContextAllocFailed;
        const v_stream = try registerStream(ctx, video_ctx, true);
        self.video_stream = v_stream;
        self.video_src_time_base = video_ctx.*.time_base;

        if (audio_ctx) |actx| {
            self.audio_stream = try registerStream(ctx, actx, false);
            self.audio_src_time_base = actx.*.time_base;
        }

        // Bound sparse-stream interleave buffering so static VFR pauses do not stall live audio.
        ctx.*.max_interleave_delta = interleave_delta_us;

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

    pub fn openVideoStream(self: *MuxSink, codec_ctx: *const c.AVCodecContext) MuxError!void {
        return self.openStreams(codec_ctx, null);
    }

    fn writeFilePacket(
        self: *MuxSink,
        stream: *c.AVStream,
        src_tb: c.AVRational,
        raw_pkt: *const c.AVPacket,
    ) MuxError!void {
        const ctx = self.fmt_ctx orelse return MuxError.PacketWriteFailed;
        const out_pkt = self.scratch_pkt orelse return MuxError.PacketWriteFailed;
        if (!self.header_written) return MuxError.PacketWriteFailed;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);

        if (c.av_packet_ref(out_pkt, raw_pkt) < 0) {
            return MuxError.PacketWriteFailed;
        }
        defer c.av_packet_unref(out_pkt);

        c.av_packet_rescale_ts(out_pkt, src_tb, stream.*.time_base);
        out_pkt.*.stream_index = stream.*.index;
        out_pkt.*.pos = -1;

        const pkt_bytes: u64 = if (out_pkt.*.size > 0) @intCast(out_pkt.*.size) else 0;
        if (c.av_interleaved_write_frame(ctx, out_pkt) < 0) {
            return MuxError.PacketWriteFailed;
        }
        _ = self.file_bytes_written.fetchAdd(pkt_bytes, .monotonic);
        _ = self.file_packets_written.fetchAdd(1, .monotonic);
    }

    /// Reference, rescale, and write an encoded video packet to the container or RTMP worker.
    pub fn writeVideoPacket(self: *MuxSink, raw_pkt: *const c.AVPacket) MuxError!void {
        if (self.rtmp_worker) |worker| {
            worker.enqueueVideoPacket(raw_pkt);
            return;
        }
        const stream = self.video_stream orelse return MuxError.PacketWriteFailed;
        return self.writeFilePacket(stream, self.video_src_time_base, raw_pkt);
    }

    /// Reference, rescale, and write an encoded audio packet to the container or RTMP worker.
    pub fn writeAudioPacket(self: *MuxSink, raw_pkt: *const c.AVPacket) MuxError!void {
        if (self.rtmp_worker) |worker| {
            worker.enqueueAudioPacket(raw_pkt);
            return;
        }
        const stream = self.audio_stream orelse return MuxError.PacketWriteFailed;
        return self.writeFilePacket(stream, self.audio_src_time_base, raw_pkt);
    }

    pub fn writePacket(self: *MuxSink, raw_pkt: *const c.AVPacket) MuxError!void {
        return self.writeVideoPacket(raw_pkt);
    }

    /// Flush buffered packets, write the container trailer, and close the output handle.
    pub fn finish(self: *MuxSink) MuxError!void {
        if (self.finished) return;
        self.finished = true;

        if (self.rtmp_worker) |worker| {
            worker.stopAndJoin();
            return;
        }

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
        if (self.rtmp_worker) |worker| {
            return worker.getStats();
        }
        return .{
            .packets_written = self.file_packets_written.load(.monotonic),
            .bytes_written = self.file_bytes_written.load(.monotonic),
        };
    }

    pub fn deinit(self: *MuxSink) void {
        if (!self.finished) {
            self.finish() catch |err| {
                std.log.warn("mux finish during deinit: {s}", .{@errorName(err)});
            };
        }
        if (self.rtmp_worker) |worker| {
            worker.deinit();
            self.rtmp_worker = null;
        }
        if (self.scratch_pkt) |pkt| {
            var owned: ?*c.AVPacket = pkt;
            c.av_packet_free(&owned);
            self.scratch_pkt = null;
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

    const rtmp_target = try parseTarget("rtmp://live.example.com/app/key");
    try std.testing.expectEqual(common.MuxSinkType.rtmp, rtmp_target.sink_type);
    try std.testing.expectEqualStrings("flv", rtmp_target.format_name);

    const rtmps_target = try parseTarget("rtmps://live.example.com/app/key");
    try std.testing.expectEqual(common.MuxSinkType.rtmp, rtmps_target.sink_type);
    try std.testing.expectEqualStrings("flv", rtmps_target.format_name);

    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget(""));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget(".mp4"));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget("rtmp://"));
    try std.testing.expectError(MuxError.UnsupportedTarget, parseTarget("output.avi"));
}

pub fn allocTestH264Context(with_extradata: bool) !*c.AVCodecContext {
    const extradata_bytes = [_]u8{
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x15, 0xd9, 0x01, 0x41, 0xfb, 0x01, 0x10, 0x00, 0x00,
        0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc8, 0xf1, 0x42, 0x99, 0x60, 0x00, 0x00, 0x00, 0x01,
        0x68, 0xcb, 0x8c, 0xb2,
    };

    const ctx = c.avcodec_alloc_context3(null) orelse return error.OutOfMemory;
    ctx.*.codec_type = c.AVMEDIA_TYPE_VIDEO;
    ctx.*.codec_id = c.AV_CODEC_ID_H264;
    ctx.*.width = 320;
    ctx.*.height = 240;
    ctx.*.pix_fmt = c.AV_PIX_FMT_NV12;
    ctx.*.time_base = .{ .num = 1, .den = 1000 };
    ctx.*.framerate = .{ .num = 30, .den = 1 };

    if (with_extradata) {
        const ed = c.av_mallocz(extradata_bytes.len + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse {
            var ctx_opt: ?*c.AVCodecContext = ctx;
            c.avcodec_free_context(&ctx_opt);
            return error.OutOfMemory;
        };
        @memcpy(@as([*]u8, @ptrCast(ed))[0..extradata_bytes.len], &extradata_bytes);
        ctx.*.extradata = @ptrCast(ed);
        ctx.*.extradata_size = extradata_bytes.len;
    }
    return ctx;
}

pub fn allocTestAacContext() !*c.AVCodecContext {
    const codec = c.avcodec_find_encoder_by_name("aac") orelse
        c.avcodec_find_encoder(c.AV_CODEC_ID_AAC) orelse
        return error.OutOfMemory;
    const ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    errdefer {
        var ctx_opt: ?*c.AVCodecContext = ctx;
        c.avcodec_free_context(&ctx_opt);
    }

    c.av_channel_layout_default(&ctx.*.ch_layout, 2);
    ctx.*.sample_rate = 48_000;
    ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
    ctx.*.bit_rate = 128_000;
    ctx.*.time_base = .{ .num = 1, .den = 48_000 };
    ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
    if (c.avcodec_open2(ctx, codec, null) < 0) return error.OutOfMemory;
    return ctx;
}

fn sendTestVideoBatch(sink_ptr: *MuxSink) !void {
    const idr_slice_bytes = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21, 0xa0 };
    for ([_]i64{ 0, 33, 100 }, 0..) |pts, idx| {
        const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        var pkt_opt: ?*c.AVPacket = pkt;
        defer c.av_packet_free(&pkt_opt);
        try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, idr_slice_bytes.len));
        @memcpy(pkt.*.data[0..idr_slice_bytes.len], &idr_slice_bytes);
        pkt.*.pts = pts;
        pkt.*.dts = pts;
        pkt.*.duration = 33;
        if (idx == 0) pkt.*.flags |= c.AV_PKT_FLAG_KEY;
        try sink_ptr.writeVideoPacket(pkt);
    }
}

fn sendTestAudioBatch(sink_ptr: *MuxSink) !void {
    const aac_frame_bytes = [_]u8{ 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c };
    for (0..6) |idx| {
        const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        var pkt_opt: ?*c.AVPacket = pkt;
        defer c.av_packet_free(&pkt_opt);
        try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, aac_frame_bytes.len));
        @memcpy(pkt.*.data[0..aac_frame_bytes.len], &aac_frame_bytes);
        const sample_pts: i64 = @as(i64, @intCast(idx)) * 1024 - 1024;
        pkt.*.pts = sample_pts;
        pkt.*.dts = sample_pts;
        pkt.*.duration = 1024;
        try sink_ptr.writeAudioPacket(pkt);
    }
}

test "MuxSink supportsAudio rejects raw h264 with audio and muxes concurrent A/V streams" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_ERROR);
    defer c.av_log_set_level(prev_log);

    const vctx = try allocTestH264Context(true);
    var vctx_opt: ?*c.AVCodecContext = vctx;
    defer c.avcodec_free_context(&vctx_opt);

    const actx = try allocTestAacContext();
    var actx_opt: ?*c.AVCodecContext = actx;
    defer c.avcodec_free_context(&actx_opt);

    var dir_tpl = "/tmp/wlrec-avmux-test-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);
    defer _ = c.rmdir(dir_ptr);

    var h264_buf: [128]u8 = undefined;
    const h264_path = try std.fmt.bufPrint(&h264_buf, "{s}/raw.h264", .{dir_slice});
    var raw_sink = try MuxSink.init(std.testing.allocator, h264_path);
    defer raw_sink.deinit();
    try std.testing.expect(!raw_sink.supportsAudio());
    try std.testing.expectError(MuxError.UnsupportedTarget, raw_sink.openStreams(vctx, actx));

    const exts = [_][]const u8{ "mp4", "mkv", "flv" };
    for (exts) |ext| {
        var path_buf: [128]u8 = undefined;
        const path_slice = try std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "{s}/av.{s}", .{ dir_slice, ext });
        path_buf[path_slice.len] = 0;
        const path_z = path_buf[0..path_slice.len :0];
        defer _ = c.unlink(path_z.ptr);

        var av_sink = try MuxSink.init(std.testing.allocator, path_slice);
        defer av_sink.deinit();
        try std.testing.expect(av_sink.supportsAudio());
        try av_sink.openStreams(vctx, actx);

        const audio_thread = try std.Thread.spawn(.{}, sendTestAudioBatch, .{&av_sink});
        try sendTestVideoBatch(&av_sink);
        audio_thread.join();

        try av_sink.finish();
        const stats = av_sink.getStats();
        try std.testing.expectEqual(@as(u64, 9), stats.packets_written);
        try std.testing.expect(stats.bytes_written > 0);
    }
}

test "MuxSink writes valid MP4, MKV, FLV, and H264 files with synthetic packets" {
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

        const ctx = try allocTestH264Context(true);
        var ctx_opt: ?*c.AVCodecContext = ctx;
        defer c.avcodec_free_context(&ctx_opt);

        try sink.openVideoStream(ctx);
        try sendTestVideoBatch(&sink);

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
