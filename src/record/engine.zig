const std = @import("std");
const common = @import("../common/lib.zig");
const capture = @import("../capture/lib.zig");
const encode = @import("../encode/lib.zig");
const audio = @import("../audio/lib.zig");
const mux = @import("../mux/lib.zig");

pub const RecordError = error{
    WaylandConnectFailed,
    VaapiInitFailed,
    UnsupportedFormat,
    SurfaceAllocFailed,
    BufferImportFailed,
    FilterInitFailed,
    EncoderInitFailed,
    AudioInitFailed,
    CaptureFailed,
    EncodeFailed,
    UnsupportedTarget,
    MuxInitFailed,
    MuxWriteFailed,
};

pub const RecordConfig = struct {
    output_paths: []const []const u8,
    device_path: ?[*:0]const u8 = null,
    fps: u32 = 60,
    qp: u8 = 23,
    bitrate: ?u32 = null,
    audio_mode: common.AudioSourceMode = .none,
    audio_bitrate: u32 = audio.default_bitrate_bps,
    max_frames: ?u64 = null,
    duration_secs: u64 = 0,
    stop_fd: ?std.posix.fd_t = null,
};

pub const RecordStats = struct {
    frames_captured: u64 = 0,
    frames_encoded: u64 = 0,
    bytes_written: u64 = 0,
    packets_dropped: u64 = 0,
    reconnects: u64 = 0,
    outputs_count: usize = 0,
    outputs_failed: usize = 0,
    first_keyframe_seen: bool = false,
    audio_frames_captured: u64 = 0,
    audio_frames_encoded: u64 = 0,
    audio_frames_dropped: u64 = 0,
    audio_packets_dropped: u64 = 0,
};

pub const SurfaceSlot = struct {
    surface: encode.ExportedSurface,
    buffer: capture.DmabufBuffer,
};

pub fn selectRateControl(config: RecordConfig) common.RateControlProfile {
    if (config.bitrate) |bps| {
        const kbps = @max(@as(u32, 1), bps / 1000);
        const maxrate = kbps + @max(@as(u32, 1), kbps / 2);
        const bufsize_kb = @max(@as(u32, 1), kbps / 4);
        return common.RateControlProfile.vbr(kbps, maxrate, bufsize_kb);
    }
    for (config.output_paths) |path| {
        if (mux.parseTarget(path)) |target| {
            if (target.sink_type == .rtmp) {
                return common.RateControlProfile.vbr(4500, 6750, 1125);
            }
        } else |err| {
            std.log.debug("target rate-control fallback for {s}: {s}", .{ path, @errorName(err) });
        }
    }
    return common.RateControlProfile.cqp(config.qp);
}

fn createSurfaceSlots(device: *encode.VaapiDevice, session: *capture.CopyCaptureSession, slots: *[2]SurfaceSlot) !void {
    const dmabuf = session.dmabuf orelse return error.BufferImportFailed;
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            slots[initialized].buffer.deinit();
            device.destroySurface(&slots[initialized].surface);
        }
    }

    while (initialized < 2) : (initialized += 1) {
        var surf = device.createAndExportSurface(session.advertisedFormats()) catch |err| {
            return if (err == encode.VaapiError.UnsupportedFormat) error.UnsupportedFormat else error.SurfaceAllocFailed;
        };
        errdefer device.destroySurface(&surf);
        const buf = capture.DmabufBuffer.import(
            dmabuf,
            session.width,
            session.height,
            surf.drm_format,
            surf.planeSlice(),
        ) catch return error.BufferImportFailed;

        slots[initialized] = .{
            .surface = surf,
            .buffer = buf,
        };
    }
}

fn destroySurfaceSlots(device: *encode.VaapiDevice, slots: *[2]SurfaceSlot) void {
    for (slots) |*slot| {
        slot.buffer.deinit();
        device.destroySurface(&slot.surface);
    }
}

fn mapMuxError(err: mux.MuxError) (RecordError || error{OutOfMemory}) {
    return switch (err) {
        mux.MuxError.OutOfMemory => error.OutOfMemory,
        mux.MuxError.UnsupportedTarget => error.UnsupportedTarget,
        mux.MuxError.MuxContextAllocFailed,
        mux.MuxError.StreamAllocFailed,
        mux.MuxError.CodecParamsCopyFailed,
        mux.MuxError.OutputOpenFailed,
        mux.MuxError.HeaderWriteFailed,
        => error.MuxInitFailed,
        mux.MuxError.PacketWriteFailed,
        mux.MuxError.TrailerWriteFailed,
        => error.MuxWriteFailed,
    };
}

fn drainEncoderPackets(encoder: *encode.VaapiEncoder, sink: *mux.MuxFanout, stats: *RecordStats) !void {
    while (try encoder.receivePacket()) |pkt_val| {
        var pkt = pkt_val;
        defer pkt.deinit();
        if (pkt.is_keyframe) stats.first_keyframe_seen = true;
        sink.writeVideoPacket(pkt.raw_packet) catch |err| return mapMuxError(err);
        stats.frames_encoded += 1;
    }
}

fn syncMuxStats(sink: *const mux.MuxFanout, stats: *RecordStats) void {
    const m = sink.getStats();
    stats.bytes_written = m.bytes_written;
    stats.packets_dropped = m.packets_dropped;
    stats.reconnects = m.reconnects;
    stats.outputs_count = sink.sinkCount();
    stats.outputs_failed = sink.failedCount();
}

fn mapAudioError(err: audio.AudioPipelineError) (RecordError || error{OutOfMemory}) {
    return if (err == audio.AudioPipelineError.OutOfMemory) error.OutOfMemory else error.AudioInitFailed;
}

const AudioMuxForwarder = struct {
    pipeline: *audio.AudioPipeline,
    sink: *mux.MuxFanout,
    stop_wake: audio.EventFd,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn init(pipeline: *audio.AudioPipeline, sink: *mux.MuxFanout) !AudioMuxForwarder {
        const stop_wake = audio.EventFd.init() catch return error.AudioInitFailed;
        return .{
            .pipeline = pipeline,
            .sink = sink,
            .stop_wake = stop_wake,
        };
    }

    fn start(self: *AudioMuxForwarder, t0_ns: ?u64) !void {
        if (t0_ns) |ns| self.pipeline.setSessionStartNs(ns);
        if (self.thread != null) return;
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch return error.AudioInitFailed;
    }

    fn stopAndJoin(self: *AudioMuxForwarder) void {
        self.stop_requested.store(true, .release);
        self.stop_wake.signaler().notify();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn deinit(self: *AudioMuxForwarder) void {
        self.stopAndJoin();
        self.stop_wake.deinit();
    }

    fn drainAvailable(self: *AudioMuxForwarder) void {
        while (self.pipeline.popPacket()) |pkt_val| {
            var pkt = pkt_val;
            defer pkt.deinit();
            if (self.write_error.load(.acquire)) continue;
            self.sink.writeAudioPacket(pkt.raw_packet) catch |err| {
                std.log.warn("audio mux write failed: {s}", .{@errorName(err)});
                self.write_error.store(true, .release);
            };
        }
    }

    fn threadMain(self: *AudioMuxForwarder) void {
        const pkt_fd = self.pipeline.packetReadyFd();
        while (!self.stop_requested.load(.acquire)) {
            self.drainAvailable();
            if (self.stop_requested.load(.acquire)) break;
            var pfds = [_]std.posix.pollfd{
                .{ .fd = pkt_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_wake.fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&pfds, 25) catch |err| {
                std.log.debug("audio forwarder poll: {s}", .{@errorName(err)});
                continue;
            };
            if (ready > 0 and (pfds[0].revents & std.posix.POLL.IN) != 0) {
                self.pipeline.ackPacketReady();
            }
        }
        self.drainAvailable();
    }
};

fn initAudioPipelineIfEnabled(
    allocator: std.mem.Allocator,
    config: RecordConfig,
    global_header: bool,
) !?*audio.AudioPipeline {
    if (!config.audio_mode.isEnabled()) return null;
    const ap = audio.AudioPipeline.init(
        allocator,
        config.audio_mode,
        config.audio_bitrate,
        global_header,
    ) catch |err| return mapAudioError(err);
    errdefer ap.deinit();
    ap.start() catch |err| return mapAudioError(err);
    return ap;
}

fn flushRecording(
    encoder: *encode.VaapiEncoder,
    sink: *mux.MuxFanout,
    maybe_audio: ?*audio.AudioPipeline,
    forwarder: *?AudioMuxForwarder,
    stats: *RecordStats,
) !void {
    encoder.sendFrame(null) catch return error.EncodeFailed;
    try drainEncoderPackets(encoder, sink, stats);

    if (maybe_audio) |ap| {
        ap.stopAndFlush();
        if (forwarder.*) |*fwd| {
            fwd.stopAndJoin();
            if (fwd.write_error.load(.acquire)) return error.MuxWriteFailed;
        }
        const a_stats = ap.getStats();
        stats.audio_frames_captured = a_stats.frames_captured;
        stats.audio_frames_encoded = a_stats.frames_encoded;
        stats.audio_frames_dropped = a_stats.frames_dropped;
        stats.audio_packets_dropped = a_stats.packets_dropped;
    }

    sink.finish() catch |err| return mapMuxError(err);
    syncMuxStats(sink, stats);
}

fn isGracefulStop(err: anyerror) bool {
    return err == capture.CaptureError.Interrupted or err == capture.CaptureError.Timeout;
}

fn mapVaapiError(err: encode.VaapiError) (RecordError || error{OutOfMemory}) {
    if (err == encode.VaapiError.OutOfMemory) return error.OutOfMemory;
    return if (err == encode.VaapiError.UnsupportedFormat) error.UnsupportedFormat else error.VaapiInitFailed;
}

fn rebindDeviceAndSlots(
    session: *capture.CopyCaptureSession,
    device: *encode.VaapiDevice,
    slots: *[2]SurfaceSlot,
    stop_fd: ?std.posix.fd_t,
    deadline_ms: ?u64,
) !void {
    session.waitConstraints(stop_fd, deadline_ms) catch |err| {
        if (isGracefulStop(err)) return err;
        if (err == capture.CaptureError.OutOfMemory) return error.OutOfMemory;
        return error.CaptureFailed;
    };

    device.reconfigure(session.width, session.height, session.advertisedFormats()) catch |err| {
        return mapVaapiError(err);
    };

    var new_slots: [2]SurfaceSlot = undefined;
    try createSurfaceSlots(device, session, &new_slots);

    destroySurfaceSlots(device, slots);
    slots.* = new_slots;
}

fn captureFirstFrameWithRetry(
    session: *capture.CopyCaptureSession,
    device: *encode.VaapiDevice,
    slots: *[2]SurfaceSlot,
    deadline_ms: ?u64,
    config: RecordConfig,
) !u64 {
    while (true) {
        return session.captureFrame(&slots[0].buffer, config.stop_fd, deadline_ms) catch |err| {
            if (isGracefulStop(err)) return err;
            if (err != capture.CaptureError.BufferConstraints) return error.CaptureFailed;
            try rebindDeviceAndSlots(session, device, slots, config.stop_fd, deadline_ms);
            continue;
        };
    }
}

fn initFirstFrame(
    session: *capture.CopyCaptureSession,
    device: *encode.VaapiDevice,
    slots: *[2]SurfaceSlot,
    deadline_ms: ?u64,
    clock: *common.VfrClock,
    config: RecordConfig,
    global_header: bool,
) !struct { filter: encode.VaapiFilterGraph, encoder: encode.VaapiEncoder, first_out: encode.FilteredFrame } {
    const pts_ns = try captureFirstFrameWithRetry(session, device, slots, deadline_ms, config);
    _ = clock.registerFrame(pts_ns);

    const enc_dims = encode.filter_graph.transformedDimensions(session.width, session.height, session.frame_transform);
    var filter = encode.VaapiFilterGraph.init(
        device,
        enc_dims.width,
        enc_dims.height,
        session.frame_transform,
    ) catch return error.FilterInitFailed;
    errdefer filter.deinit();

    var first_out = filter.filterSurface(slots[0].surface.surface_id, 0) catch return error.FilterInitFailed;
    errdefer first_out.deinit();

    const rc = selectRateControl(config);
    const encoder = encode.VaapiEncoder.initFromFilteredFrame(
        enc_dims.width,
        enc_dims.height,
        &first_out,
        rc,
        config.fps,
        global_header,
    ) catch return error.EncoderInitFailed;

    return .{ .filter = filter, .encoder = encoder, .first_out = first_out };
}

const RecordingContext = struct {
    session: *capture.CopyCaptureSession,
    device: *encode.VaapiDevice,
    slots: *[2]SurfaceSlot,
    filter: *encode.VaapiFilterGraph,
    encoder: *encode.VaapiEncoder,
    clock: *common.VfrClock,
    config: *const RecordConfig,
    deadline_ms: ?u64,
    sink: *mux.MuxFanout,
    stats: *RecordStats,
};

fn reinitFilter(ctx: *RecordingContext) encode.FilterError!void {
    const new_filter = try encode.VaapiFilterGraph.init(
        ctx.device,
        ctx.encoder.width,
        ctx.encoder.height,
        ctx.session.frame_transform,
    );
    ctx.filter.deinit();
    ctx.filter.* = new_filter;
}

fn rebindCapturePipeline(ctx: *RecordingContext) !void {
    try rebindDeviceAndSlots(ctx.session, ctx.device, ctx.slots, ctx.config.stop_fd, ctx.deadline_ms);
    reinitFilter(ctx) catch return error.FilterInitFailed;
}

fn processFrame(ctx: *RecordingContext, slot: *const SurfaceSlot) !void {
    const pts_ns = ctx.session.captureFrame(&slot.buffer, ctx.config.stop_fd, ctx.deadline_ms) catch |err| {
        if (isGracefulStop(err) or err == capture.CaptureError.BufferConstraints) return err;
        return error.CaptureFailed;
    };

    if (ctx.clock.shouldDrop(pts_ns)) return;

    if (ctx.session.frame_transform != ctx.filter.wl_transform) {
        reinitFilter(ctx) catch return error.EncodeFailed;
    }

    ctx.stats.frames_captured += 1;
    const rel_pts_ns = ctx.clock.registerFrame(pts_ns);
    const pts_ms = common.VfrClock.rescaleNs(rel_pts_ns, 1, 1000);

    var out_frame = ctx.filter.filterSurface(slot.surface.surface_id, pts_ms) catch return error.EncodeFailed;
    defer out_frame.deinit();

    ctx.encoder.sendFrame(&out_frame) catch return error.EncodeFailed;
    try drainEncoderPackets(ctx.encoder, ctx.sink, ctx.stats);
}

fn shouldStop(stats: *const RecordStats, config: *const RecordConfig, deadline_ms: ?u64) bool {
    if (config.max_frames) |mf| {
        if (stats.frames_captured >= mf) return true;
    }
    if (deadline_ms) |dl| {
        if (capture.CopyCaptureSession.monotonicMs() >= dl) return true;
    }
    return false;
}

const LoopAction = enum {
    advance,
    retry,
    stop,
};

fn stepRecording(ctx: *RecordingContext, slot: *const SurfaceSlot) !LoopAction {
    processFrame(ctx, slot) catch |err| {
        if (isGracefulStop(err)) return .stop;
        if (err != capture.CaptureError.BufferConstraints) return err;
        rebindCapturePipeline(ctx) catch |rebind_err| {
            if (isGracefulStop(rebind_err)) return .stop;
            return rebind_err;
        };
        return .retry;
    };
    return .advance;
}

fn recordLoop(ctx: *RecordingContext) !void {
    var slot_idx: usize = 1;
    while (!shouldStop(ctx.stats, ctx.config, ctx.deadline_ms)) {
        switch (try stepRecording(ctx, &ctx.slots[slot_idx])) {
            .advance => slot_idx = (slot_idx + 1) % 2,
            .retry => {},
            .stop => break,
        }
    }
}

fn runSessionPipeline(
    session: *capture.CopyCaptureSession,
    device: *encode.VaapiDevice,
    slots: *[2]SurfaceSlot,
    config: RecordConfig,
    deadline_ms: ?u64,
    clock: *common.VfrClock,
    sink: *mux.MuxFanout,
    maybe_audio: ?*audio.AudioPipeline,
    stats: *RecordStats,
) !void {
    const init_res = initFirstFrame(
        session,
        device,
        slots,
        deadline_ms,
        clock,
        config,
        sink.needsGlobalHeader(),
    ) catch |err| {
        if (isGracefulStop(err)) return;
        return err;
    };
    var filter = init_res.filter;
    defer filter.deinit();
    var encoder = init_res.encoder;
    defer encoder.deinit();
    stats.frames_captured += 1;

    const audio_ctx = if (maybe_audio) |ap| ap.enc.codec_ctx else null;
    sink.openStreams(encoder.codec_ctx, audio_ctx) catch |err| return mapMuxError(err);

    var forwarder: ?AudioMuxForwarder = if (maybe_audio) |ap|
        try AudioMuxForwarder.init(ap, sink)
    else
        null;
    defer if (forwarder) |*fwd| fwd.deinit();
    if (forwarder) |*fwd| try fwd.start(clock.start_ns);

    {
        var first_out = init_res.first_out;
        defer first_out.deinit();
        encoder.sendFrame(&first_out) catch return error.EncodeFailed;
    }
    try drainEncoderPackets(&encoder, sink, stats);

    var ctx = RecordingContext{
        .session = session,
        .device = device,
        .slots = slots,
        .filter = &filter,
        .encoder = &encoder,
        .clock = clock,
        .config = &config,
        .deadline_ms = deadline_ms,
        .sink = sink,
        .stats = stats,
    };
    try recordLoop(&ctx);
    try flushRecording(&encoder, sink, maybe_audio, &forwarder, stats);
}

/// Run end-to-end zero-copy screen recording session.
pub fn runRecording(allocator: std.mem.Allocator, config: RecordConfig) !RecordStats {
    var stats = RecordStats{};

    var sink = mux.MuxFanout.init(allocator, config.output_paths) catch |err| return mapMuxError(err);
    defer sink.deinit();
    if (config.audio_mode.isEnabled() and !sink.supportsAudio()) {
        return error.UnsupportedTarget;
    }

    const maybe_audio = try initAudioPipelineIfEnabled(allocator, config, sink.needsGlobalHeader());
    defer if (maybe_audio) |ap| ap.deinit();

    var session: capture.CopyCaptureSession = .{};
    session.init(allocator, null) catch |err| {
        if (err == capture.CaptureError.OutOfMemory) return error.OutOfMemory;
        return error.WaylandConnectFailed;
    };
    defer session.deinit();

    var device = encode.VaapiDevice.init(
        allocator,
        config.device_path,
        session.width,
        session.height,
        session.advertisedFormats(),
    ) catch |err| return mapVaapiError(err);
    defer device.deinit();

    var slots: [2]SurfaceSlot = undefined;
    try createSurfaceSlots(&device, &session, &slots);
    defer destroySurfaceSlots(&device, &slots);

    var clock = common.VfrClock.init(config.fps);
    const start_ms = capture.CopyCaptureSession.monotonicMs();
    const deadline_ms: ?u64 = if (config.duration_secs > 0) start_ms + config.duration_secs * 1000 else null;

    try runSessionPipeline(
        &session,
        &device,
        &slots,
        config,
        deadline_ms,
        &clock,
        &sink,
        maybe_audio,
        &stats,
    );

    return stats;
}

test "RecordStats default values and rate control selection" {
    const stats = RecordStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.frames_captured);
    try std.testing.expectEqual(@as(u64, 0), stats.frames_encoded);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_dropped);
    try std.testing.expectEqual(@as(u64, 0), stats.reconnects);
    try std.testing.expectEqual(false, stats.first_keyframe_seen);

    const cqp_rc = selectRateControl(.{ .output_paths = &.{"a.h264"}, .qp = 21 });
    try std.testing.expectEqual(common.RateControlProfile.Mode.cqp, cqp_rc.mode);
    try std.testing.expectEqual(@as(u8, 21), cqp_rc.qp);

    const rtmp_rc = selectRateControl(.{ .output_paths = &.{"rtmp://127.0.0.1/live/key"} });
    try std.testing.expectEqual(common.RateControlProfile.Mode.vbr, rtmp_rc.mode);
    try std.testing.expectEqual(@as(u32, 4500), rtmp_rc.bitrate_kbps);

    const mixed_rc = selectRateControl(.{
        .output_paths = &.{ "archive.mp4", "rtmps://127.0.0.1/live/key" },
    });
    try std.testing.expectEqual(common.RateControlProfile.Mode.vbr, mixed_rc.mode);
    try std.testing.expectEqual(@as(u32, 4500), mixed_rc.bitrate_kbps);

    const vbr_rc = selectRateControl(.{
        .output_paths = &.{ "archive.mp4", "rtmp://127.0.0.1/live/key" },
        .bitrate = 6_000_000,
    });
    try std.testing.expectEqual(common.RateControlProfile.Mode.vbr, vbr_rc.mode);
    try std.testing.expectEqual(@as(u32, 6000), vbr_rc.bitrate_kbps);

    try std.testing.expectEqual(RecordError.UnsupportedTarget, mapMuxError(mux.MuxError.UnsupportedTarget));
    try std.testing.expectEqual(RecordError.MuxInitFailed, mapMuxError(mux.MuxError.OutputOpenFailed));
    try std.testing.expectEqual(RecordError.MuxWriteFailed, mapMuxError(mux.MuxError.TrailerWriteFailed));
    try std.testing.expectEqual(RecordError.UnsupportedFormat, mapVaapiError(encode.VaapiError.UnsupportedFormat));
    try std.testing.expectEqual(RecordError.VaapiInitFailed, mapVaapiError(encode.VaapiError.DeviceCreateFailed));
    try std.testing.expect(isGracefulStop(capture.CaptureError.Timeout));
    try std.testing.expect(isGracefulStop(capture.CaptureError.Interrupted));
    try std.testing.expect(!isGracefulStop(capture.CaptureError.BufferConstraints));

    try std.testing.expectEqual(RecordError.AudioInitFailed, mapAudioError(audio.AudioPipelineError.EncoderOpenFailed));
    try std.testing.expectEqual(error.OutOfMemory, mapAudioError(audio.AudioPipelineError.OutOfMemory));

    try std.testing.expectError(
        RecordError.UnsupportedTarget,
        runRecording(std.testing.allocator, .{
            .output_paths = &.{"/tmp/wlrec-raw-reject.h264"},
            .audio_mode = .desktop,
        }),
    );

    try std.testing.expectError(
        RecordError.UnsupportedTarget,
        runRecording(std.testing.allocator, .{
            .output_paths = &.{ "/tmp/wlrec-mix-a.h264", "/tmp/wlrec-mix-b.mp4" },
        }),
    );
}
