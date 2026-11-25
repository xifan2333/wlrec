const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");

pub const VaapiError = error{
    DeviceCreateFailed,
    FramesContextAllocFailed,
    FramesContextInitFailed,
    SurfaceCreateFailed,
    SurfaceExportFailed,
    UnsupportedLayout,
    UnsupportedFormat,
};

pub const SurfacePlane = common.DmabufPlane;

const max_modifiers = 64;

const FormatSpec = struct {
    drm_format: u32,
    va_fourcc: c_int,
    sw_format: c_int,
};

const supported_rgb_formats = [_]FormatSpec{
    .{ .drm_format = c.DRM_FORMAT_ARGB8888, .va_fourcc = c.VA_FOURCC_ARGB, .sw_format = c.AV_PIX_FMT_BGRA },
    .{ .drm_format = c.DRM_FORMAT_ARGB8888, .va_fourcc = c.VA_FOURCC_BGRA, .sw_format = c.AV_PIX_FMT_BGRA },
    .{ .drm_format = c.DRM_FORMAT_XRGB8888, .va_fourcc = c.VA_FOURCC_XRGB, .sw_format = c.AV_PIX_FMT_BGR0 },
    .{ .drm_format = c.DRM_FORMAT_XRGB8888, .va_fourcc = c.VA_FOURCC_BGRX, .sw_format = c.AV_PIX_FMT_BGR0 },
    .{ .drm_format = c.DRM_FORMAT_BGRA8888, .va_fourcc = c.VA_FOURCC_BGRA, .sw_format = c.AV_PIX_FMT_BGRA },
    .{ .drm_format = c.DRM_FORMAT_BGRX8888, .va_fourcc = c.VA_FOURCC_BGRX, .sw_format = c.AV_PIX_FMT_BGR0 },
    .{ .drm_format = c.DRM_FORMAT_ABGR8888, .va_fourcc = c.VA_FOURCC_RGBA, .sw_format = c.AV_PIX_FMT_RGBA },
    .{ .drm_format = c.DRM_FORMAT_XBGR8888, .va_fourcc = c.VA_FOURCC_RGBX, .sw_format = c.AV_PIX_FMT_RGB0 },
};

pub const ExportedSurface = struct {
    surface_id: c.VASurfaceID = c.VA_INVALID_ID,
    drm_format: u32 = 0,
    num_planes: u32 = 0,
    planes: [4]SurfacePlane = @splat(.{ .fd = -1, .offset = 0, .pitch = 0, .modifier = 0 }),
    num_objects: u32 = 0,
    fds: [4]std.posix.fd_t = @splat(-1),

    pub fn planeSlice(self: *const ExportedSurface) []const SurfacePlane {
        return self.planes[0..self.num_planes];
    }

    pub fn deinit(self: *ExportedSurface, va_display: c.VADisplay) void {
        var i: usize = 0;
        while (i < self.num_objects) : (i += 1) {
            if (self.fds[i] >= 0) {
                _ = c.close(self.fds[i]);
                self.fds[i] = -1;
            }
        }
        self.num_objects = 0;
        self.num_planes = 0;
        if (self.surface_id != c.VA_INVALID_ID) {
            var s = self.surface_id;
            _ = c.vaDestroySurfaces(va_display, &s, 1);
            self.surface_id = c.VA_INVALID_ID;
        }
    }
};

fn closeDescriptorFds(desc: *const c.VADRMPRIMESurfaceDescriptor) void {
    const count = @min(@as(usize, desc.num_objects), 4);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (desc.objects[i].fd >= 0) _ = c.close(desc.objects[i].fd);
    }
}

pub fn collectModifiersForFormat(
    constraints: []const common.FormatModifierPair,
    drm_format: u32,
    out_mods: *[max_modifiers]u64,
) struct { count: usize, found_format: bool } {
    var count: usize = 0;
    var found = false;
    for (constraints) |pair| {
        if (pair.format != drm_format) continue;
        found = true;
        if (pair.modifier != common.drm_mod_invalid and count < max_modifiers) {
            out_mods[count] = pair.modifier;
            count += 1;
        }
    }
    return .{ .count = count, .found_format = found };
}

pub fn isPairSupported(constraints: []const common.FormatModifierPair, drm_format: u32, modifier: u64) bool {
    if (constraints.len == 0) return true;
    for (constraints) |pair| {
        if (pair.format != drm_format) continue;
        if (pair.modifier == modifier or pair.modifier == common.drm_mod_invalid or modifier == common.drm_mod_invalid) {
            return true;
        }
    }
    return false;
}

fn createRawSurface(
    va_display: c.VADisplay,
    width: u32,
    height: u32,
    va_fourcc: c_int,
    mods: []const u64,
) VaapiError!c.VASurfaceID {
    var surf: c.VASurfaceID = c.VA_INVALID_ID;
    var mod_list = c.VADRMFormatModifierList{
        .num_modifiers = @intCast(mods.len),
        .modifiers = if (mods.len > 0) @constCast(mods.ptr) else null,
    };

    var attribs: [3]c.VASurfaceAttrib = undefined;
    attribs[0] = std.mem.zeroes(c.VASurfaceAttrib);
    attribs[0].type = c.VASurfaceAttribPixelFormat;
    attribs[0].flags = c.VA_SURFACE_ATTRIB_SETTABLE;
    attribs[0].value.type = c.VAGenericValueTypeInteger;
    attribs[0].value.value.i = va_fourcc;

    attribs[1] = std.mem.zeroes(c.VASurfaceAttrib);
    attribs[1].type = c.VASurfaceAttribUsageHint;
    attribs[1].flags = c.VA_SURFACE_ATTRIB_SETTABLE;
    attribs[1].value.type = c.VAGenericValueTypeInteger;
    attribs[1].value.value.i = c.VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER;

    if (mods.len > 0) {
        attribs[2] = std.mem.zeroes(c.VASurfaceAttrib);
        attribs[2].type = c.VASurfaceAttribDRMFormatModifiers;
        attribs[2].flags = c.VA_SURFACE_ATTRIB_SETTABLE;
        attribs[2].value.type = c.VAGenericValueTypePointer;
        attribs[2].value.value.p = &mod_list;

        const st = c.vaCreateSurfaces(va_display, c.VA_RT_FORMAT_RGB32, width, height, &surf, 1, &attribs[0], 3);
        if (st == c.VA_STATUS_SUCCESS) return surf;
    }

    const fallback_st = c.vaCreateSurfaces(va_display, c.VA_RT_FORMAT_RGB32, width, height, &surf, 1, &attribs[0], 2);
    if (fallback_st != c.VA_STATUS_SUCCESS) return VaapiError.SurfaceCreateFailed;
    return surf;
}

fn exportAndValidateSurface(
    va_display: c.VADisplay,
    surf: c.VASurfaceID,
    expected_drm_format: u32,
    constraints: []const common.FormatModifierPair,
) VaapiError!ExportedSurface {
    var desc: c.VADRMPRIMESurfaceDescriptor = std.mem.zeroes(c.VADRMPRIMESurfaceDescriptor);
    const exp_st = c.vaExportSurfaceHandle(
        va_display,
        surf,
        c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
        c.VA_EXPORT_SURFACE_READ_WRITE | c.VA_EXPORT_SURFACE_COMPOSED_LAYERS,
        &desc,
    );
    if (exp_st != c.VA_STATUS_SUCCESS) return VaapiError.SurfaceExportFailed;

    if (desc.num_layers != 1 or desc.layers[0].num_planes == 0 or desc.layers[0].num_planes > 4 or desc.num_objects == 0 or desc.num_objects > 4) {
        closeDescriptorFds(&desc);
        return VaapiError.UnsupportedLayout;
    }

    if (desc.layers[0].drm_format != expected_drm_format) {
        closeDescriptorFds(&desc);
        return VaapiError.UnsupportedFormat;
    }

    var exported = ExportedSurface{
        .surface_id = surf,
        .drm_format = desc.layers[0].drm_format,
        .num_planes = desc.layers[0].num_planes,
        .num_objects = desc.num_objects,
    };

    var obj_i: usize = 0;
    while (obj_i < desc.num_objects) : (obj_i += 1) {
        exported.fds[obj_i] = desc.objects[obj_i].fd;
    }

    var pl_i: usize = 0;
    while (pl_i < desc.layers[0].num_planes) : (pl_i += 1) {
        const obj_idx = desc.layers[0].object_index[pl_i];
        if (obj_idx >= desc.num_objects) {
            exported.deinit(va_display);
            return VaapiError.UnsupportedLayout;
        }
        const mod = desc.objects[obj_idx].drm_format_modifier;
        if (!isPairSupported(constraints, exported.drm_format, mod)) {
            exported.deinit(va_display);
            return VaapiError.UnsupportedFormat;
        }
        exported.planes[pl_i] = .{
            .fd = desc.objects[obj_idx].fd,
            .offset = desc.layers[0].offset[pl_i],
            .pitch = desc.layers[0].pitch[pl_i],
            .modifier = mod,
        };
    }

    return exported;
}

/// Hardware device manager for VAAPI and negotiated DMA-BUF surface export.
pub const VaapiDevice = struct {
    hw_device_ctx: *c.AVBufferRef,
    va_display: c.VADisplay,
    in_frames_ref: *c.AVBufferRef,

    width: u32,
    height: u32,
    selected_spec: FormatSpec,
    modifiers: [max_modifiers]u64 = undefined,
    modifier_count: usize = 0,

    fn negotiateFormat(
        va_dpy: c.VADisplay,
        width: u32,
        height: u32,
        constraints: []const common.FormatModifierPair,
        out_mods: *[max_modifiers]u64,
    ) VaapiError!struct { spec: FormatSpec, mod_count: usize } {
        for (supported_rgb_formats) |spec| {
            const collected = collectModifiersForFormat(constraints, spec.drm_format, out_mods);
            if (constraints.len > 0 and !collected.found_format) continue;

            const surf = createRawSurface(va_dpy, width, height, spec.va_fourcc, out_mods[0..collected.count]) catch continue;
            var exported = exportAndValidateSurface(va_dpy, surf, spec.drm_format, constraints) catch {
                var s = surf;
                _ = c.vaDestroySurfaces(va_dpy, &s, 1);
                continue;
            };
            exported.deinit(va_dpy);
            return .{ .spec = spec, .mod_count = collected.count };
        }
        return VaapiError.UnsupportedFormat;
    }

    pub fn init(
        device_path: ?[*:0]const u8,
        width: u32,
        height: u32,
        constraints: []const common.FormatModifierPair,
    ) VaapiError!VaapiDevice {
        const path = device_path orelse "/dev/dri/renderD128";

        var hw_device: ?*c.AVBufferRef = null;
        const ret = c.av_hwdevice_ctx_create(&hw_device, c.AV_HWDEVICE_TYPE_VAAPI, path, null, 0);
        if (ret < 0 or hw_device == null) return VaapiError.DeviceCreateFailed;
        errdefer c.av_buffer_unref(&hw_device);

        const dev_ctx: *c.AVHWDeviceContext = @ptrCast(@alignCast(hw_device.?.data));
        const va_dev_ctx: *c.AVVAAPIDeviceContext = @ptrCast(@alignCast(dev_ctx.hwctx));
        const va_dpy = va_dev_ctx.display;

        var mods: [max_modifiers]u64 = undefined;
        const neg = try negotiateFormat(va_dpy, width, height, constraints, &mods);

        var frames_ref = c.av_hwframe_ctx_alloc(hw_device.?) orelse return VaapiError.FramesContextAllocFailed;
        errdefer c.av_buffer_unref(&frames_ref);

        const frames_ctx: *c.AVHWFramesContext = @ptrCast(@alignCast(frames_ref.*.data));
        frames_ctx.format = c.AV_PIX_FMT_VAAPI;
        frames_ctx.sw_format = neg.spec.sw_format;
        frames_ctx.width = @intCast(width);
        frames_ctx.height = @intCast(height);

        if (c.av_hwframe_ctx_init(frames_ref) < 0) return VaapiError.FramesContextInitFailed;

        return .{
            .hw_device_ctx = hw_device.?,
            .va_display = va_dpy,
            .in_frames_ref = frames_ref,
            .width = width,
            .height = height,
            .selected_spec = neg.spec,
            .modifiers = mods,
            .modifier_count = neg.mod_count,
        };
    }

    pub fn deinit(self: *VaapiDevice) void {
        var frames = @as(?*c.AVBufferRef, self.in_frames_ref);
        c.av_buffer_unref(&frames);

        var dev = @as(?*c.AVBufferRef, self.hw_device_ctx);
        c.av_buffer_unref(&dev);
    }

    /// Create a negotiated RGB surface and export its multi-plane write-capable DMA-BUF descriptor.
    pub fn createAndExportSurface(self: *VaapiDevice) VaapiError!ExportedSurface {
        const surf = try createRawSurface(
            self.va_display,
            self.width,
            self.height,
            self.selected_spec.va_fourcc,
            self.modifiers[0..self.modifier_count],
        );
        return exportAndValidateSurface(self.va_display, surf, self.selected_spec.drm_format, &.{}) catch |err| {
            var s = surf;
            _ = c.vaDestroySurfaces(self.va_display, &s, 1);
            return err;
        };
    }

    pub fn destroySurface(self: *VaapiDevice, surf: *ExportedSurface) void {
        surf.deinit(self.va_display);
    }
};

test "VaapiDevice format constraint matching" {
    const constraints = [_]common.FormatModifierPair{
        .{ .format = c.DRM_FORMAT_XRGB8888, .modifier = common.drm_mod_linear },
    };
    try std.testing.expect(isPairSupported(&constraints, c.DRM_FORMAT_XRGB8888, common.drm_mod_linear));
    try std.testing.expect(!isPairSupported(&constraints, c.DRM_FORMAT_ARGB8888, common.drm_mod_linear));

    var mods: [max_modifiers]u64 = undefined;
    const res = collectModifiersForFormat(&constraints, c.DRM_FORMAT_XRGB8888, &mods);
    try std.testing.expect(res.found_format);
    try std.testing.expectEqual(@as(usize, 1), res.count);
}
