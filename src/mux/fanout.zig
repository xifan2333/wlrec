const std = @import("std");
const c = @import("c");
const sink = @import("sink.zig");

const FanoutSlot = struct {
    sink: sink.MuxSink,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn hasDuplicateTarget(targets: []const []const u8) bool {
    for (targets, 0..) |target, i| {
        for (targets[i + 1 ..]) |other| {
            if (std.mem.eql(u8, target, other)) return true;
        }
    }
    return false;
}

/// Multi-sink fan-out coordinator distributing immutable AVPacket references
/// across 1..N distinct container files and/or RTMP endpoints with fault isolation.
pub const MuxFanout = struct {
    allocator: std.mem.Allocator,
    slots: []FanoutSlot,

    pub fn init(allocator: std.mem.Allocator, targets: []const []const u8) sink.MuxError!MuxFanout {
        if (targets.len == 0 or hasDuplicateTarget(targets)) {
            return sink.MuxError.UnsupportedTarget;
        }

        const slots = allocator.alloc(FanoutSlot, targets.len) catch return sink.MuxError.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (slots[0..initialized]) |*slot| slot.sink.deinit();
            allocator.free(slots);
        }

        for (targets, 0..) |target, idx| {
            slots[idx] = .{ .sink = try sink.MuxSink.init(allocator, target) };
            initialized += 1;
            if (idx > 0 and slots[idx].sink.needsGlobalHeader() != slots[0].sink.needsGlobalHeader()) {
                return sink.MuxError.UnsupportedTarget;
            }
        }

        return .{
            .allocator = allocator,
            .slots = slots,
        };
    }

    pub fn sinkCount(self: *const MuxFanout) usize {
        return self.slots.len;
    }

    /// Return true when every configured target supports an audio stream.
    pub fn supportsAudio(self: *const MuxFanout) bool {
        for (self.slots) |*slot| {
            if (!slot.sink.supportsAudio()) return false;
        }
        return true;
    }

    /// Return the unified AV_CODEC_FLAG_GLOBAL_HEADER requirement across all sinks.
    pub fn needsGlobalHeader(self: *const MuxFanout) bool {
        return self.slots[0].sink.needsGlobalHeader();
    }

    /// Return true when at least one configured target is an RTMP/RTMPS stream.
    pub fn hasRtmpTarget(self: *const MuxFanout) bool {
        for (self.slots) |*slot| {
            if (slot.sink.isRtmp()) return true;
        }
        return false;
    }

    /// Open streams and write container headers across all targets, rolling back on startup error.
    pub fn openStreams(
        self: *MuxFanout,
        video_ctx: *const c.AVCodecContext,
        audio_ctx: ?*const c.AVCodecContext,
    ) sink.MuxError!void {
        if (audio_ctx != null and !self.supportsAudio()) {
            return sink.MuxError.UnsupportedTarget;
        }

        var opened: usize = 0;
        errdefer {
            for (self.slots[0..opened]) |*slot| slot.sink.requestStop();
            for (self.slots[0..opened]) |*slot| {
                slot.sink.finish() catch |err| {
                    std.log.warn("mux fanout rollback finish ({s}): {s}", .{ slot.sink.target_z, @errorName(err) });
                };
            }
        }

        for (self.slots) |*slot| {
            try slot.sink.openStreams(video_ctx, audio_ctx);
            opened += 1;
        }
    }

    fn writeToSlot(slot: *FanoutSlot, comptime is_video: bool, raw_pkt: *const c.AVPacket) bool {
        if (slot.failed.load(.acquire)) return false;
        const result = if (is_video)
            slot.sink.writeVideoPacket(raw_pkt)
        else
            slot.sink.writeAudioPacket(raw_pkt);

        result catch |err| {
            slot.failed.store(true, .release);
            std.log.warn("mux fanout sink isolated ({s}): {s}", .{ slot.sink.target_z, @errorName(err) });
            return false;
        };
        return true;
    }

    fn fanoutPacket(self: *MuxFanout, comptime is_video: bool, raw_pkt: *const c.AVPacket) sink.MuxError!void {
        var delivered: usize = 0;
        for (self.slots) |*slot| {
            if (writeToSlot(slot, is_video, raw_pkt)) delivered += 1;
        }
        if (delivered == 0) return sink.MuxError.PacketWriteFailed;
    }

    /// Fan out an immutable encoded video packet to every active sink via AVPacket refcounting.
    pub fn writeVideoPacket(self: *MuxFanout, raw_pkt: *const c.AVPacket) sink.MuxError!void {
        return self.fanoutPacket(true, raw_pkt);
    }

    /// Fan out an immutable encoded audio packet to every active sink via AVPacket refcounting.
    pub fn writeAudioPacket(self: *MuxFanout, raw_pkt: *const c.AVPacket) sink.MuxError!void {
        return self.fanoutPacket(false, raw_pkt);
    }

    /// Stop RTMP workers concurrently and flush/finalize every sink without short-circuiting siblings.
    pub fn finish(self: *MuxFanout) sink.MuxError!void {
        for (self.slots) |*slot| slot.sink.requestStop();

        var healthy_finished: usize = 0;
        var first_err: ?sink.MuxError = null;
        for (self.slots) |*slot| {
            const was_failed = slot.failed.load(.acquire);
            slot.sink.finish() catch |err| {
                slot.failed.store(true, .release);
                std.log.warn("mux fanout finish failed ({s}): {s}", .{ slot.sink.target_z, @errorName(err) });
                if (first_err == null) first_err = err;
                continue;
            };
            if (!was_failed) healthy_finished += 1;
        }

        if (healthy_finished == 0) {
            if (first_err) |err| return err;
        }
    }

    /// Return aggregated mux telemetry summed across all configured sinks.
    pub fn getStats(self: *const MuxFanout) sink.MuxStats {
        var total = sink.MuxStats{};
        for (self.slots) |*slot| {
            const st = slot.sink.getStats();
            total.packets_written += st.packets_written;
            total.packets_dropped += st.packets_dropped;
            total.bytes_written += st.bytes_written;
            total.reconnects += st.reconnects;
        }
        return total;
    }

    pub fn sinkStats(self: *const MuxFanout, index: usize) sink.MuxStats {
        return self.slots[index].sink.getStats();
    }

    pub fn sinkFailed(self: *const MuxFanout, index: usize) bool {
        return self.slots[index].failed.load(.acquire);
    }

    pub fn failedCount(self: *const MuxFanout) usize {
        var failed: usize = 0;
        for (self.slots) |*slot| {
            if (slot.failed.load(.acquire)) failed += 1;
        }
        return failed;
    }

    pub fn deinit(self: *MuxFanout) void {
        for (self.slots) |*slot| slot.sink.requestStop();
        for (self.slots) |*slot| slot.sink.deinit();
        self.allocator.free(self.slots);
    }
};

fn sendFanoutVideoBatch(fanout: *MuxFanout) !void {
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
        try fanout.writeVideoPacket(pkt);
    }
}

fn sendFanoutAudioBatch(fanout: *MuxFanout) !void {
    const aac_frame_bytes = [_]u8{ 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c };
    for (0..6) |idx| {
        const pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        var pkt_opt: ?*c.AVPacket = pkt;
        defer c.av_packet_free(&pkt_opt);
        try std.testing.expectEqual(@as(c_int, 0), c.av_new_packet(pkt, aac_frame_bytes.len));
        @memcpy(pkt.*.data[0..aac_frame_bytes.len], &aac_frame_bytes);
        const sample_pts: i64 = @as(i64, @intCast(idx)) * 1024;
        pkt.*.pts = sample_pts;
        pkt.*.dts = sample_pts;
        pkt.*.duration = 1024;
        try fanout.writeAudioPacket(pkt);
    }
}

test "MuxFanout validates empty, duplicate, and incompatible header combinations" {
    try std.testing.expectError(sink.MuxError.UnsupportedTarget, MuxFanout.init(std.testing.allocator, &.{}));

    const dup_targets = [_][]const u8{ "/tmp/a.mp4", "/tmp/a.mp4" };
    try std.testing.expectError(sink.MuxError.UnsupportedTarget, MuxFanout.init(std.testing.allocator, &dup_targets));

    const mixed_h264_mp4 = [_][]const u8{ "/tmp/raw.h264", "/tmp/out.mp4" };
    try std.testing.expectError(sink.MuxError.UnsupportedTarget, MuxFanout.init(std.testing.allocator, &mixed_h264_mp4));

    const mixed_rtmp_h264 = [_][]const u8{ "rtmp://127.0.0.1/live/a", "/tmp/raw.h264" };
    try std.testing.expectError(sink.MuxError.UnsupportedTarget, MuxFanout.init(std.testing.allocator, &mixed_rtmp_h264));

    const compat_targets = [_][]const u8{ "/tmp/out.mp4", "/tmp/out.mkv", "rtmp://127.0.0.1/live/a" };
    var fanout = try MuxFanout.init(std.testing.allocator, &compat_targets);
    defer fanout.deinit();
    try std.testing.expectEqual(@as(usize, 3), fanout.sinkCount());
    try std.testing.expect(fanout.needsGlobalHeader());
    try std.testing.expect(fanout.supportsAudio());
    try std.testing.expect(fanout.hasRtmpTarget());

    const raw_pair = [_][]const u8{ "/tmp/a.h264", "/tmp/b.264" };
    var raw_fanout = try MuxFanout.init(std.testing.allocator, &raw_pair);
    defer raw_fanout.deinit();
    try std.testing.expect(!raw_fanout.needsGlobalHeader());
    try std.testing.expect(!raw_fanout.supportsAudio());
    try std.testing.expect(!raw_fanout.hasRtmpTarget());
}

test "MuxFanout writes multi-container A/V while isolating unreachable RTMP endpoints" {
    const prev_log = c.av_log_get_level();
    c.av_log_set_level(c.AV_LOG_QUIET);
    defer c.av_log_set_level(prev_log);

    const vctx = try sink.allocTestH264Context(true);
    var vctx_opt: ?*c.AVCodecContext = vctx;
    defer c.avcodec_free_context(&vctx_opt);

    const actx = try sink.allocTestAacContext();
    var actx_opt: ?*c.AVCodecContext = actx;
    defer c.avcodec_free_context(&actx_opt);

    var dir_tpl = "/tmp/wlrec-fanout-test-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);
    defer _ = c.rmdir(dir_ptr);

    var mp4_buf: [128]u8 = undefined;
    const mp4_slice = try std.fmt.bufPrint(mp4_buf[0 .. mp4_buf.len - 1], "{s}/archive.mp4", .{dir_slice});
    mp4_buf[mp4_slice.len] = 0;
    const mp4_z = mp4_buf[0..mp4_slice.len :0];
    defer _ = c.unlink(mp4_z.ptr);

    var mkv_buf: [128]u8 = undefined;
    const mkv_slice = try std.fmt.bufPrint(mkv_buf[0 .. mkv_buf.len - 1], "{s}/backup.mkv", .{dir_slice});
    mkv_buf[mkv_slice.len] = 0;
    const mkv_z = mkv_buf[0..mkv_slice.len :0];
    defer _ = c.unlink(mkv_z.ptr);

    const targets = [_][]const u8{
        mp4_slice,
        mkv_slice,
        "rtmp://127.0.0.1:19358/live/primary",
        "rtmp://127.0.0.1:19359/live/secondary",
    };

    var fanout = try MuxFanout.init(std.testing.allocator, &targets);
    defer fanout.deinit();
    try fanout.openStreams(vctx, actx);

    const audio_thread = try std.Thread.spawn(.{}, sendFanoutAudioBatch, .{&fanout});
    try sendFanoutVideoBatch(&fanout);
    audio_thread.join();

    const sleep_ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 30_000_000 };
    _ = c.nanosleep(&sleep_ts, null);

    try fanout.finish();

    const mp4_st = fanout.sinkStats(0);
    const mkv_st = fanout.sinkStats(1);
    const rtmp0_st = fanout.sinkStats(2);
    const rtmp1_st = fanout.sinkStats(3);

    try std.testing.expectEqual(@as(u64, 9), mp4_st.packets_written);
    try std.testing.expectEqual(@as(u64, 0), mp4_st.packets_dropped);
    try std.testing.expect(mp4_st.bytes_written > 0);

    try std.testing.expectEqual(@as(u64, 9), mkv_st.packets_written);
    try std.testing.expectEqual(@as(u64, 0), mkv_st.packets_dropped);
    try std.testing.expect(mkv_st.bytes_written > 0);

    try std.testing.expectEqual(@as(u64, 0), rtmp0_st.packets_written);
    try std.testing.expectEqual(@as(u64, 9), rtmp0_st.packets_dropped);
    try std.testing.expectEqual(@as(u64, 0), rtmp1_st.packets_written);
    try std.testing.expectEqual(@as(u64, 9), rtmp1_st.packets_dropped);

    const agg = fanout.getStats();
    try std.testing.expectEqual(@as(u64, 18), agg.packets_written);
    try std.testing.expectEqual(@as(u64, 18), agg.packets_dropped);
    try std.testing.expectEqual(@as(usize, 0), fanout.failedCount());

    const mp4_fd = c.open(mp4_z.ptr, c.O_RDONLY);
    try std.testing.expect(mp4_fd >= 0);
    defer _ = c.close(mp4_fd);
    var head: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 8), c.read(mp4_fd, &head[0], 8));
    try std.testing.expectEqualSlices(u8, "ftyp", head[4..8]);
}

test "MuxFanout isolates single local sink failure while preserving healthy sibling" {
    const vctx = try sink.allocTestH264Context(true);
    var vctx_opt: ?*c.AVCodecContext = vctx;
    defer c.avcodec_free_context(&vctx_opt);

    var dir_tpl = "/tmp/wlrec-fault-test-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);
    defer _ = c.rmdir(dir_ptr);

    var ok_buf: [128]u8 = undefined;
    const ok_slice = try std.fmt.bufPrint(ok_buf[0 .. ok_buf.len - 1], "{s}/healthy.mp4", .{dir_slice});
    ok_buf[ok_slice.len] = 0;
    const ok_z = ok_buf[0..ok_slice.len :0];
    defer _ = c.unlink(ok_z.ptr);

    var bad_buf: [128]u8 = undefined;
    const bad_slice = try std.fmt.bufPrint(bad_buf[0 .. bad_buf.len - 1], "{s}/faulted.mp4", .{dir_slice});
    bad_buf[bad_slice.len] = 0;
    const bad_z = bad_buf[0..bad_slice.len :0];
    defer _ = c.unlink(bad_z.ptr);

    const targets = [_][]const u8{ ok_slice, bad_slice };
    var fanout = try MuxFanout.init(std.testing.allocator, &targets);
    defer fanout.deinit();
    try fanout.openStreams(vctx, null);

    // Simulate mid-session write failure on sink 1 while sink 0 remains healthy.
    fanout.slots[1].sink.header_written = false;
    try sendFanoutVideoBatch(&fanout);
    try fanout.finish();

    try std.testing.expect(!fanout.sinkFailed(0));
    try std.testing.expect(fanout.sinkFailed(1));
    try std.testing.expectEqual(@as(usize, 1), fanout.failedCount());
    try std.testing.expectEqual(@as(u64, 3), fanout.sinkStats(0).packets_written);
    try std.testing.expectEqual(@as(u64, 0), fanout.sinkStats(1).packets_written);
}
