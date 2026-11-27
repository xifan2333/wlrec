const std = @import("std");
const c = @import("c");
const wlrec = @import("wlrec");
const record = wlrec.record;

const ThreadCtx = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_fd: std.posix.fd_t,
};

const DamageClient = struct {
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    wm_base: ?*c.xdg_wm_base = null,
    configured: bool = false,

    fn deinitGlobals(self: *DamageClient) void {
        if (self.wm_base) |w| c.xdg_wm_base_destroy(w);
        if (self.shm) |s| c.wl_shm_destroy(s);
        if (self.compositor) |comp| c.wl_compositor_destroy(comp);
        if (self.registry) |r| c.wl_registry_destroy(r);
        if (self.display) |d| c.wl_display_disconnect(d);
    }
};

fn wmBasePing(data: ?*anyopaque, wm: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm, serial);
}

const wm_base_listener = c.xdg_wm_base_listener{ .ping = wmBasePing };

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surf: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const client: *DamageClient = @ptrCast(@alignCast(data));
    c.xdg_surface_ack_configure(xdg_surf, serial);
    client.configured = true;
}

const xdg_surface_listener = c.xdg_surface_listener{ .configure = xdgSurfaceConfigure };

fn toplevelConfigure(data: ?*anyopaque, top: ?*c.xdg_toplevel, w: i32, h: i32, states: [*c]c.wl_array) callconv(.c) void {
    _ = data;
    _ = top;
    _ = w;
    _ = h;
    _ = states;
}

fn toplevelClose(data: ?*anyopaque, top: ?*c.xdg_toplevel) callconv(.c) void {
    _ = data;
    _ = top;
}

const toplevel_listener = c.xdg_toplevel_listener{
    .configure = toplevelConfigure,
    .close = toplevelClose,
    .configure_bounds = null,
    .wm_capabilities = null,
};

fn damageRegistryGlobal(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32, iface: [*c]const u8, ver: u32) callconv(.c) void {
    const client: *DamageClient = @ptrCast(@alignCast(data));
    const span = std.mem.span(iface);
    if (std.mem.eql(u8, span, "wl_compositor")) {
        client.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, @min(ver, 4)));
        return;
    }
    if (std.mem.eql(u8, span, "wl_shm")) {
        client.shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
        return;
    }
    if (std.mem.eql(u8, span, "xdg_wm_base")) {
        const wm: *c.xdg_wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
        _ = c.xdg_wm_base_add_listener(wm, &wm_base_listener, client);
        client.wm_base = wm;
    }
}

fn damageRegistryRemove(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = reg;
    _ = name;
}

const damage_registry_listener = c.wl_registry_listener{
    .global = damageRegistryGlobal,
    .global_remove = damageRegistryRemove,
};

const BufferSlot = struct {
    buffer: *c.wl_buffer,
    busy: bool = false,
};

fn bufferRelease(data: ?*anyopaque, wl_buf: ?*c.wl_buffer) callconv(.c) void {
    _ = wl_buf;
    const slot: *BufferSlot = @ptrCast(@alignCast(data));
    slot.busy = false;
}

const buffer_listener = c.wl_buffer_listener{ .release = bufferRelease };

fn waitFlagOrStop(
    dpy: *c.wl_display,
    flag: *const bool,
    expect: bool,
    tctx: *ThreadCtx,
    max_wait_ms: i32,
) bool {
    var waited_ms: i32 = 0;
    const step_ms: i32 = 25;
    while (flag.* != expect and !tctx.stop.load(.acquire) and waited_ms < max_wait_ms) {
        _ = c.wl_display_flush(dpy);
        if (c.wl_display_prepare_read(dpy) != 0) {
            if (c.wl_display_dispatch_pending(dpy) < 0) return false;
            continue;
        }
        var pfd = [_]std.posix.pollfd{
            .{ .fd = c.wl_display_get_fd(dpy), .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ret = std.posix.poll(&pfd, step_ms) catch {
            c.wl_display_cancel_read(dpy);
            return false;
        };
        if (ret == 0) {
            c.wl_display_cancel_read(dpy);
            waited_ms += step_ms;
            continue;
        }
        if (c.wl_display_read_events(dpy) < 0) return false;
        if (c.wl_display_dispatch_pending(dpy) < 0) return false;
    }
    return flag.* == expect;
}

fn pumpFrames(
    dpy: *c.wl_display,
    surf: *c.wl_surface,
    slots: *[2]BufferSlot,
    pixels: [*]volatile u32,
    tctx: *ThreadCtx,
) void {
    var step: u32 = 0;
    const sleep_ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 25_000_000 };
    while (!tctx.stop.load(.acquire) and step < 160) : (step += 1) {
        const idx: usize = step % 2;
        if (!waitFlagOrStop(dpy, &slots[idx].busy, false, tctx, 500)) break;

        pixels[idx] = 0x01000000 | (step & 0x00ffffff);
        slots[idx].busy = true;
        c.wl_surface_attach(surf, slots[idx].buffer, 0, 0);
        c.wl_surface_damage_buffer(surf, 0, 0, 1, 1);
        c.wl_surface_commit(surf);
        _ = c.wl_display_dispatch_pending(dpy);
        _ = c.wl_display_flush(dpy);
        _ = c.nanosleep(&sleep_ts, null);
    }

    if (!tctx.stop.load(.acquire)) {
        const signal: u64 = 1;
        _ = c.write(tctx.stop_fd, &signal, @sizeOf(u64));
    }
}

fn initDamageClient(client: *DamageClient) bool {
    client.display = c.wl_display_connect(null) orelse return false;
    client.registry = c.wl_display_get_registry(client.display.?) orelse return false;
    _ = c.wl_registry_add_listener(client.registry.?, &damage_registry_listener, client);
    _ = c.wl_display_roundtrip(client.display.?);
    return client.compositor != null and client.shm != null and client.wm_base != null;
}

fn runDamageGenerator(tctx: *ThreadCtx) void {
    var client = DamageClient{};
    defer client.deinitGlobals();
    if (!initDamageClient(&client)) return;

    const shm_fd = c.memfd_create("wlrec-test-dmg", 0);
    if (shm_fd < 0) return;
    defer _ = c.close(shm_fd);
    if (c.ftruncate(shm_fd, 8) < 0) return;

    const map_ptr = c.mmap(null, 8, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, shm_fd, 0);
    if (map_ptr == c.MAP_FAILED or map_ptr == null) return;
    defer _ = c.munmap(map_ptr, 8);
    const pixels: [*]volatile u32 = @ptrCast(@alignCast(map_ptr));

    const pool = c.wl_shm_create_pool(client.shm.?, shm_fd, 8) orelse return;
    defer c.wl_shm_pool_destroy(pool);

    const b0 = c.wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, c.WL_SHM_FORMAT_ARGB8888) orelse return;
    defer c.wl_buffer_destroy(b0);
    const b1 = c.wl_shm_pool_create_buffer(pool, 4, 1, 1, 4, c.WL_SHM_FORMAT_ARGB8888) orelse return;
    defer c.wl_buffer_destroy(b1);

    const surf = c.wl_compositor_create_surface(client.compositor.?) orelse return;
    defer c.wl_surface_destroy(surf);
    const xdg_surf = c.xdg_wm_base_get_xdg_surface(client.wm_base.?, surf) orelse return;
    defer c.xdg_surface_destroy(xdg_surf);
    _ = c.xdg_surface_add_listener(xdg_surf, &xdg_surface_listener, &client);

    const top = c.xdg_surface_get_toplevel(xdg_surf) orelse return;
    defer c.xdg_toplevel_destroy(top);
    _ = c.xdg_toplevel_add_listener(top, &toplevel_listener, &client);
    c.xdg_toplevel_set_min_size(top, 1, 1);
    c.xdg_toplevel_set_max_size(top, 1, 1);

    c.wl_surface_commit(surf);
    _ = c.wl_display_roundtrip(client.display.?);
    if (!waitFlagOrStop(client.display.?, &client.configured, true, tctx, 2000)) return;

    var slots = [2]BufferSlot{
        .{ .buffer = b0 },
        .{ .buffer = b1 },
    };
    _ = c.wl_buffer_add_listener(slots[0].buffer, &buffer_listener, &slots[0]);
    _ = c.wl_buffer_add_listener(slots[1].buffer, &buffer_listener, &slots[1]);

    pumpFrames(client.display.?, surf, &slots, pixels, tctx);
}

fn captureEnvAvailable() bool {
    const dpy = c.wl_display_connect(null);
    if (dpy == null) {
        std.log.info("SKIPPED: No Wayland display available in test environment", .{});
        return false;
    }
    c.wl_display_disconnect(dpy);

    const drm_fd = c.open("/dev/dri/renderD128", c.O_RDWR);
    if (drm_fd < 0) {
        std.log.info("SKIPPED: /dev/dri/renderD128 not accessible", .{});
        return false;
    }
    _ = c.close(drm_fd);
    return true;
}

fn checkMagicAt(path_z: [*:0]const u8, magic_offset: usize, expected_magic: []const u8) !void {
    const fd = c.open(path_z, c.O_RDONLY);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);

    var header: [8]u8 = undefined;
    const n = c.read(fd, &header[0], 8);
    try std.testing.expectEqual(@as(isize, 8), n);
    try std.testing.expectEqualSlices(u8, expected_magic, header[magic_offset .. magic_offset + expected_magic.len]);
}

fn runLiveCaptureCase(filename: []const u8, magic_offset: usize, expected_magic: []const u8) !void {
    if (!captureEnvAvailable()) return;

    var dir_tpl = "/tmp/wlrec-test-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);
    var out_buf: [128]u8 = undefined;
    const out_slice = try std.fmt.bufPrint(out_buf[0 .. out_buf.len - 1], "{s}/{s}", .{ dir_slice, filename });
    out_buf[out_slice.len] = 0;
    const out_path_z = out_buf[0..out_slice.len :0];
    defer {
        _ = c.unlink(out_path_z.ptr);
        _ = c.rmdir(dir_ptr);
    }

    const stop_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    try std.testing.expect(stop_fd >= 0);
    defer _ = c.close(stop_fd);

    var tctx = ThreadCtx{ .stop_fd = stop_fd };
    const dmg_thread = try std.Thread.spawn(.{}, runDamageGenerator, .{&tctx});
    defer {
        tctx.stop.store(true, .release);
        dmg_thread.join();
    }

    const outputs = [_][]const u8{out_path_z};
    const config = record.engine.RecordConfig{
        .output_paths = &outputs,
        .device_path = "/dev/dri/renderD128",
        .fps = 60,
        .qp = 23,
        .max_frames = 5,
        .duration_secs = 5,
        .stop_fd = stop_fd,
    };

    const stats = try record.engine.runRecording(std.testing.allocator, config);

    try std.testing.expect(stats.frames_captured >= 5);
    try std.testing.expect(stats.frames_encoded >= 5);
    try std.testing.expect(stats.bytes_written > 1000);
    try std.testing.expectEqual(@as(u64, 0), stats.packets_dropped);
    try std.testing.expect(stats.first_keyframe_seen);

    try checkMagicAt(out_path_z.ptr, magic_offset, expected_magic);
}

/// One encode session fanning out to a local container backup plus an unreachable
/// RTMP endpoint: the archive must stay valid while the stalled RTMP sink is isolated.
fn runMultiOutputFanoutCase() !void {
    if (!captureEnvAvailable()) return;

    var dir_tpl = "/tmp/wlrec-fanout-e2e-XXXXXX".*;
    const dir_ptr = c.mkdtemp(&dir_tpl[0]) orelse return error.TempDirFailed;
    const dir_slice = std.mem.span(dir_ptr);

    var mp4_buf: [128]u8 = undefined;
    const mp4_slice = try std.fmt.bufPrint(mp4_buf[0 .. mp4_buf.len - 1], "{s}/archive.mp4", .{dir_slice});
    mp4_buf[mp4_slice.len] = 0;
    const mp4_z = mp4_buf[0..mp4_slice.len :0];

    var mkv_buf: [128]u8 = undefined;
    const mkv_slice = try std.fmt.bufPrint(mkv_buf[0 .. mkv_buf.len - 1], "{s}/backup.mkv", .{dir_slice});
    mkv_buf[mkv_slice.len] = 0;
    const mkv_z = mkv_buf[0..mkv_slice.len :0];

    defer {
        _ = c.unlink(mp4_z.ptr);
        _ = c.unlink(mkv_z.ptr);
        _ = c.rmdir(dir_ptr);
    }

    const stop_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
    try std.testing.expect(stop_fd >= 0);
    defer _ = c.close(stop_fd);

    var tctx = ThreadCtx{ .stop_fd = stop_fd };
    const dmg_thread = try std.Thread.spawn(.{}, runDamageGenerator, .{&tctx});
    defer {
        tctx.stop.store(true, .release);
        dmg_thread.join();
    }

    const outputs = [_][]const u8{ mp4_slice, mkv_slice, "rtmp://127.0.0.1:19361/live/fanout-e2e" };
    const config = record.engine.RecordConfig{
        .output_paths = &outputs,
        .device_path = "/dev/dri/renderD128",
        .fps = 60,
        .qp = 23,
        .max_frames = 5,
        .duration_secs = 5,
        .stop_fd = stop_fd,
    };

    const stats = try record.engine.runRecording(std.testing.allocator, config);

    try std.testing.expectEqual(@as(usize, 3), stats.outputs_count);
    try std.testing.expect(stats.frames_encoded >= 5);
    try std.testing.expect(stats.first_keyframe_seen);
    // Archive bytes survive even though the RTMP sibling cannot deliver packets.
    try std.testing.expect(stats.bytes_written > 1000);
    try std.testing.expect(stats.packets_dropped >= 1);

    try checkMagicAt(mp4_z.ptr, 4, "ftyp");
    try checkMagicAt(mkv_z.ptr, 0, &[_]u8{ 0x1a, 0x45, 0xdf, 0xa3 });
}

test "live desktop zero-copy capture to h264 file" {
    try runLiveCaptureCase("burst.h264", 0, &[_]u8{ 0, 0, 0, 1 });
}

test "live desktop zero-copy capture to mp4 container" {
    try runLiveCaptureCase("burst.mp4", 4, "ftyp");
}

test "live desktop multi-output fan-out to container and rtmp" {
    try runMultiOutputFanoutCase();
}
