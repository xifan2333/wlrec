const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const capture = @import("../capture/lib.zig");
const encode = @import("../encode/lib.zig");

pub const RecordError = error{
    WaylandConnectFailed,
    VaapiInitFailed,
    SurfaceAllocFailed,
    BufferImportFailed,
    FilterInitFailed,
    EncoderInitFailed,
    CaptureFailed,
    EncodeFailed,
    FileOpenFailed,
    WriteFailed,
};

pub const RecordConfig = struct {
    output_path: []const u8,
    device_path: ?[*:0]const u8 = null,
    fps: u32 = 60,
    qp: u8 = 23,
    bitrate: u32 = 5_000_000,
    max_frames: ?u64 = null,
    duration_secs: u64 = 0,
    stop_fd: ?std.posix.fd_t = null,
};

pub const RecordStats = struct {
    frames_captured: u64 = 0,
    frames_encoded: u64 = 0,
    bytes_written: u64 = 0,
    first_keyframe_seen: bool = false,
};

pub const SurfaceSlot = struct {
    surface: encode.ExportedSurface,
    buffer: capture.DmabufBuffer,
};

fn createSurfaceSlots(device: *encode.VaapiDevice, session: *capture.CopyCaptureSession, slots: *[2]SurfaceSlot) !void {
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        var surf = device.createAndExportSurface() catch return error.SurfaceAllocFailed;
        errdefer device.destroySurface(&surf);
        const buf = capture.DmabufBuffer.import(
            session.dmabuf.?,
            session.width,
            session.height,
            surf.drm_format,
            surf.fd,
            surf.offset,
            surf.pitch,
            surf.modifier,
        ) catch return error.BufferImportFailed;

        slots[i] = .{
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

fn drainEncoderPackets(encoder: *encode.VaapiEncoder, out_fd: std.posix.fd_t, stats: *RecordStats) !void {
    while (try encoder.receivePacket()) |pkt_val| {
        var pkt = pkt_val;
        defer pkt.deinit();
        if (pkt.is_keyframe) stats.first_keyframe_seen = true;
        const slice = pkt.raw_packet.*.data[0..pkt.size];
        const written = c.write(out_fd, slice.ptr, slice.len);
        if (written < 0 or @as(usize, @intCast(written)) != slice.len) {
            return error.WriteFailed;
        }
        stats.bytes_written += pkt.size;
        stats.frames_encoded += 1;
    }
}

fn initFirstFrame(
    session: *capture.CopyCaptureSession,
    filter: *encode.VaapiFilterGraph,
    slot: *const SurfaceSlot,
    stop_fd: ?std.posix.fd_t,
    clock: *common.VfrClock,
    config: RecordConfig,
) !struct { encoder: encode.VaapiEncoder, first_out: *c.AVFrame } {
    const pts_ns = session.captureFrame(slot.buffer.buffer, stop_fd) catch return error.CaptureFailed;
    _ = clock.registerFrame(pts_ns);

    const first_out = filter.filterSurface(slot.surface.surface_id, 0) catch return error.FilterInitFailed;
    errdefer {
        var f: ?*c.AVFrame = first_out;
        c.av_frame_free(&f);
    }

    const rc = common.RateControlProfile.cqp(config.qp);
    const hw_ctx = first_out.*.hw_frames_ctx orelse return error.EncoderInitFailed;
    const encoder = encode.VaapiEncoder.init(session.width, session.height, hw_ctx, rc) catch return error.EncoderInitFailed;

    return .{ .encoder = encoder, .first_out = first_out };
}

const RecordingContext = struct {
    session: *capture.CopyCaptureSession,
    filter: *encode.VaapiFilterGraph,
    encoder: *encode.VaapiEncoder,
    clock: *common.VfrClock,
    config: *const RecordConfig,
    out_fd: std.posix.fd_t,
    stats: *RecordStats,
};

fn processFrame(ctx: *RecordingContext, slot: *const SurfaceSlot) !void {
    const pts_ns = ctx.session.captureFrame(slot.buffer.buffer, ctx.config.stop_fd) catch |err| {
        if (err == capture.CaptureError.Interrupted) return;
        return error.CaptureFailed;
    };
    ctx.stats.frames_captured += 1;
    const rel_pts_ns = ctx.clock.registerFrame(pts_ns);
    const pts_ms = common.VfrClock.rescaleNs(rel_pts_ns, 1, 1000);

    const out_frame = ctx.filter.filterSurface(slot.surface.surface_id, pts_ms) catch return error.EncodeFailed;
    var out_f: ?*c.AVFrame = out_frame;
    defer c.av_frame_free(&out_f);

    ctx.encoder.sendFrame(out_frame) catch return error.EncodeFailed;
    try drainEncoderPackets(ctx.encoder, ctx.out_fd, ctx.stats);
}

fn getMonotonicMs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.tv_nsec, 1_000_000)));
}

fn shouldStop(stats: *const RecordStats, config: *const RecordConfig, elapsed_ms: u64) bool {
    if (config.max_frames) |mf| {
        if (stats.frames_captured >= mf) return true;
    }
    if (config.duration_secs > 0) {
        if (elapsed_ms >= config.duration_secs * 1000) return true;
    }
    return false;
}

fn recordLoop(ctx: *RecordingContext, slots: *[2]SurfaceSlot) !void {
    var slot_idx: usize = 1;
    const start_time = getMonotonicMs();

    while (true) {
        const elapsed: u64 = getMonotonicMs() - start_time;
        if (shouldStop(ctx.stats, ctx.config, elapsed)) break;

        processFrame(ctx, &slots[slot_idx]) catch |err| {
            if (err == capture.CaptureError.Interrupted) break;
            return err;
        };
        slot_idx = (slot_idx + 1) % 2;
    }
}

/// Run end-to-end zero-copy screen recording session.
pub fn runRecording(allocator: std.mem.Allocator, config: RecordConfig) !RecordStats {
    var stats = RecordStats{};

    const path_z = try allocator.dupeSentinel(u8, config.output_path, 0);
    defer allocator.free(path_z);
    const out_fd = c.open(path_z.ptr, c.O_CREAT | c.O_WRONLY | c.O_TRUNC, @as(c_uint, 0o644));
    if (out_fd < 0) return error.FileOpenFailed;
    defer _ = c.close(out_fd);

    var session = capture.CopyCaptureSession.init(null) catch return error.WaylandConnectFailed;
    defer session.deinit();

    var device = encode.VaapiDevice.init(config.device_path, session.width, session.height) catch return error.VaapiInitFailed;
    defer device.deinit();

    var slots: [2]SurfaceSlot = undefined;
    try createSurfaceSlots(&device, &session, &slots);
    defer destroySurfaceSlots(&device, &slots);

    var filter = encode.VaapiFilterGraph.init(&device) catch return error.FilterInitFailed;
    defer filter.deinit();

    var clock = common.VfrClock.init(config.fps);

    const init_res = try initFirstFrame(&session, &filter, &slots[0], config.stop_fd, &clock, config);
    var encoder = init_res.encoder;
    defer encoder.deinit();
    stats.frames_captured += 1;

    encoder.sendFrame(init_res.first_out) catch return error.EncodeFailed;
    var first_f: ?*c.AVFrame = init_res.first_out;
    c.av_frame_free(&first_f);
    try drainEncoderPackets(&encoder, out_fd, &stats);

    var ctx = RecordingContext{
        .session = &session,
        .filter = &filter,
        .encoder = &encoder,
        .clock = &clock,
        .config = &config,
        .out_fd = out_fd,
        .stats = &stats,
    };
    try recordLoop(&ctx, &slots);

    // Flush encoder
    encoder.sendFrame(null) catch return error.EncodeFailed;
    try drainEncoderPackets(&encoder, out_fd, &stats);

    return stats;
}

test "RecordStats default values" {
    const stats = RecordStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.frames_captured);
    try std.testing.expectEqual(@as(u64, 0), stats.frames_encoded);
    try std.testing.expectEqual(false, stats.first_keyframe_seen);
}
