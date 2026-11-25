const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const capture = @import("../capture/lib.zig");
const encode = @import("../encode/lib.zig");

pub const RecordError = error{
    WaylandConnectFailed,
    VaapiInitFailed,
    UnsupportedFormat,
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
    bitrate: ?u32 = null,
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

pub fn selectRateControl(config: RecordConfig) common.RateControlProfile {
    if (config.bitrate) |bps| {
        const kbps = @max(@as(u32, 1), bps / 1000);
        const maxrate = kbps + @max(@as(u32, 1), kbps / 2);
        const bufsize_kb = @max(@as(u32, 1), kbps / 4);
        return common.RateControlProfile.vbr(kbps, maxrate, bufsize_kb);
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

fn drainEncoderPackets(encoder: *encode.VaapiEncoder, out_fd: std.posix.fd_t, stats: *RecordStats) !void {
    while (try encoder.receivePacket()) |pkt_val| {
        var pkt = pkt_val;
        defer pkt.deinit();
        if (pkt.is_keyframe) stats.first_keyframe_seen = true;
        const slice = pkt.dataSlice();
        const written = c.write(out_fd, slice.ptr, slice.len);
        if (written < 0 or @as(usize, @intCast(written)) != slice.len) {
            return error.WriteFailed;
        }
        stats.bytes_written += pkt.size;
        stats.frames_encoded += 1;
    }
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
    out_fd: std.posix.fd_t,
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
    try drainEncoderPackets(ctx.encoder, ctx.out_fd, ctx.stats);
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

/// Run end-to-end zero-copy screen recording session.
pub fn runRecording(allocator: std.mem.Allocator, config: RecordConfig) !RecordStats {
    var stats = RecordStats{};

    const path_z = try allocator.dupeSentinel(u8, config.output_path, 0);
    defer allocator.free(path_z);
    const out_fd = c.open(path_z.ptr, c.O_CREAT | c.O_WRONLY | c.O_TRUNC, @as(c_uint, 0o600));
    if (out_fd < 0) return error.FileOpenFailed;
    defer _ = c.close(out_fd);

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

    const init_res = initFirstFrame(&session, &device, &slots, deadline_ms, &clock, config) catch |err| {
        if (isGracefulStop(err)) return stats;
        return err;
    };
    var filter = init_res.filter;
    defer filter.deinit();
    var encoder = init_res.encoder;
    defer encoder.deinit();
    stats.frames_captured += 1;

    {
        var first_out = init_res.first_out;
        defer first_out.deinit();
        encoder.sendFrame(&first_out) catch return error.EncodeFailed;
    }
    try drainEncoderPackets(&encoder, out_fd, &stats);

    var ctx = RecordingContext{
        .session = &session,
        .device = &device,
        .slots = &slots,
        .filter = &filter,
        .encoder = &encoder,
        .clock = &clock,
        .config = &config,
        .deadline_ms = deadline_ms,
        .out_fd = out_fd,
        .stats = &stats,
    };
    try recordLoop(&ctx);

    encoder.sendFrame(null) catch return error.EncodeFailed;
    try drainEncoderPackets(&encoder, out_fd, &stats);

    return stats;
}

test "RecordStats default values and rate control selection" {
    const stats = RecordStats{};
    try std.testing.expectEqual(@as(u64, 0), stats.frames_captured);
    try std.testing.expectEqual(@as(u64, 0), stats.frames_encoded);
    try std.testing.expectEqual(false, stats.first_keyframe_seen);

    const cqp_rc = selectRateControl(.{ .output_path = "a.h264", .qp = 21 });
    try std.testing.expectEqual(common.RateControlProfile.Mode.cqp, cqp_rc.mode);
    try std.testing.expectEqual(@as(u8, 21), cqp_rc.qp);

    const vbr_rc = selectRateControl(.{ .output_path = "a.h264", .bitrate = 6_000_000 });
    try std.testing.expectEqual(common.RateControlProfile.Mode.vbr, vbr_rc.mode);
    try std.testing.expectEqual(@as(u32, 6000), vbr_rc.bitrate_kbps);

    try std.testing.expectEqual(RecordError.UnsupportedFormat, mapVaapiError(encode.VaapiError.UnsupportedFormat));
    try std.testing.expectEqual(RecordError.VaapiInitFailed, mapVaapiError(encode.VaapiError.DeviceCreateFailed));
    try std.testing.expect(isGracefulStop(capture.CaptureError.Timeout));
    try std.testing.expect(isGracefulStop(capture.CaptureError.Interrupted));
    try std.testing.expect(!isGracefulStop(capture.CaptureError.BufferConstraints));
}
