const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");

pub const DmabufError = error{
    ParamsCreationFailed,
    BufferCreationFailed,
};

pub const DmaPlane = common.DmabufPlane;

/// An imported Wayland buffer backed by GPU DMA-BUF memory.
pub const DmabufBuffer = struct {
    buffer: *c.wl_buffer,
    width: u32,
    height: u32,

    /// Import a multi-plane DMA-BUF descriptor into zwp_linux_dmabuf_v1.
    pub fn import(
        dmabuf: *c.zwp_linux_dmabuf_v1,
        width: u32,
        height: u32,
        drm_format: u32,
        planes: []const DmaPlane,
    ) DmabufError!DmabufBuffer {
        const params = c.zwp_linux_dmabuf_v1_create_params(dmabuf) orelse {
            return DmabufError.ParamsCreationFailed;
        };
        defer c.zwp_linux_buffer_params_v1_destroy(params);

        for (planes, 0..) |pl, i| {
            const mod_hi: u32 = @intCast(pl.modifier >> 32);
            const mod_lo: u32 = @intCast(pl.modifier & 0xFFFFFFFF);
            c.zwp_linux_buffer_params_v1_add(params, pl.fd, @intCast(i), pl.offset, pl.pitch, mod_hi, mod_lo);
        }

        const wl_buf = c.zwp_linux_buffer_params_v1_create_immed(
            params,
            @intCast(width),
            @intCast(height),
            drm_format,
            0,
        ) orelse {
            return DmabufError.BufferCreationFailed;
        };

        return .{
            .buffer = wl_buf,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *DmabufBuffer) void {
        c.wl_buffer_destroy(self.buffer);
    }
};

test "DmabufBuffer struct size" {
    try std.testing.expect(@sizeOf(DmabufBuffer) > 0);
}
