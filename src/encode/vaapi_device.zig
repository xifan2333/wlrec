const std = @import("std");
const c = @import("c");

pub const VaapiError = error{
    DeviceCreateFailed,
    FramesContextAllocFailed,
    FramesContextInitFailed,
    SurfaceCreateFailed,
    SurfaceExportFailed,
};

pub const ExportedSurface = struct {
    surface_id: c.VASurfaceID,
    fd: std.posix.fd_t,
    drm_format: u32,
    modifier: u64,
    offset: u32,
    pitch: u32,
};

/// Hardware device manager for VAAPI and DMA-BUF surface export.
pub const VaapiDevice = struct {
    hw_device_ctx: *c.AVBufferRef,
    va_display: c.VADisplay,
    in_frames_ref: *c.AVBufferRef,

    width: u32,
    height: u32,

    pub fn init(device_path: ?[*:0]const u8, width: u32, height: u32) VaapiError!VaapiDevice {
        const path = device_path orelse "/dev/dri/renderD128";

        var hw_device: ?*c.AVBufferRef = null;
        const ret = c.av_hwdevice_ctx_create(&hw_device, c.AV_HWDEVICE_TYPE_VAAPI, path, null, 0);
        if (ret < 0 or hw_device == null) {
            return VaapiError.DeviceCreateFailed;
        }
        errdefer c.av_buffer_unref(&hw_device);

        const dev_ctx: *c.AVHWDeviceContext = @ptrCast(@alignCast(hw_device.?.data));
        const va_dev_ctx: *c.AVVAAPIDeviceContext = @ptrCast(@alignCast(dev_ctx.hwctx));
        const va_dpy = va_dev_ctx.display;

        var frames_ref = c.av_hwframe_ctx_alloc(hw_device.?) orelse {
            return VaapiError.FramesContextAllocFailed;
        };
        errdefer c.av_buffer_unref(&frames_ref);

        const frames_ctx: *c.AVHWFramesContext = @ptrCast(@alignCast(frames_ref.*.data));
        frames_ctx.format = c.AV_PIX_FMT_VAAPI;
        frames_ctx.sw_format = c.AV_PIX_FMT_BGRA;
        frames_ctx.width = @intCast(width);
        frames_ctx.height = @intCast(height);

        const init_ret = c.av_hwframe_ctx_init(frames_ref);
        if (init_ret < 0) {
            return VaapiError.FramesContextInitFailed;
        }

        return .{
            .hw_device_ctx = hw_device.?,
            .va_display = va_dpy,
            .in_frames_ref = frames_ref,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *VaapiDevice) void {
        var frames = @as(?*c.AVBufferRef, self.in_frames_ref);
        c.av_buffer_unref(&frames);

        var dev = @as(?*c.AVBufferRef, self.hw_device_ctx);
        c.av_buffer_unref(&dev);
    }

    /// Create an ARGB surface and export its single-plane DMA-BUF descriptor.
    pub fn createAndExportSurface(self: *VaapiDevice) VaapiError!ExportedSurface {
        var surf: c.VASurfaceID = undefined;
        var attribs: [2]c.VASurfaceAttrib = undefined;

        attribs[0].type = c.VASurfaceAttribPixelFormat;
        attribs[0].flags = c.VA_SURFACE_ATTRIB_SETTABLE;
        attribs[0].value.type = c.VAGenericValueTypeInteger;
        attribs[0].value.value.i = c.VA_FOURCC_ARGB;

        attribs[1].type = c.VASurfaceAttribUsageHint;
        attribs[1].flags = c.VA_SURFACE_ATTRIB_SETTABLE;
        attribs[1].value.type = c.VAGenericValueTypeInteger;
        attribs[1].value.value.i = c.VA_SURFACE_ATTRIB_USAGE_HINT_ENCODER;

        const st = c.vaCreateSurfaces(self.va_display, c.VA_RT_FORMAT_RGB32, self.width, self.height, &surf, 1, &attribs[0], 2);
        if (st != c.VA_STATUS_SUCCESS) {
            return VaapiError.SurfaceCreateFailed;
        }
        errdefer _ = c.vaDestroySurfaces(self.va_display, &surf, 1);

        var desc: c.VADRMPRIMESurfaceDescriptor = undefined;
        const exp_st = c.vaExportSurfaceHandle(
            self.va_display,
            surf,
            c.VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
            c.VA_EXPORT_SURFACE_READ_ONLY | c.VA_EXPORT_SURFACE_COMPOSED_LAYERS,
            &desc,
        );
        if (exp_st != c.VA_STATUS_SUCCESS) {
            return VaapiError.SurfaceExportFailed;
        }

        return .{
            .surface_id = surf,
            .fd = desc.objects[0].fd,
            .drm_format = desc.layers[0].drm_format,
            .modifier = desc.objects[0].drm_format_modifier,
            .offset = desc.layers[0].offset[0],
            .pitch = desc.layers[0].pitch[0],
        };
    }

    pub fn destroySurface(self: *VaapiDevice, surf: c.VASurfaceID) void {
        var s = surf;
        _ = c.vaDestroySurfaces(self.va_display, &s, 1);
    }
};

test "VaapiDevice structural checks" {
    try std.testing.expect(@sizeOf(VaapiDevice) > 0);
    try std.testing.expect(@sizeOf(ExportedSurface) > 0);
}
