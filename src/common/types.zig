const std = @import("std");

/// Visual surface dimensions in pixels.
pub const Dimensions = struct {
    width: u32,
    height: u32,

    pub fn isZero(self: Dimensions) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn pixelCount(self: Dimensions) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }
};

/// Advertised DRM pixel format and format modifier pair.
pub const drm_mod_linear: u64 = 0;
pub const drm_mod_invalid: u64 = 0x00ffffffffffffff;

pub const FormatModifierPair = struct {
    format: u32,
    modifier: u64,
};

/// Non-owning descriptor for a single DMA-BUF memory plane.
pub const DmabufPlane = struct {
    fd: std.posix.fd_t,
    offset: u32,
    pitch: u32,
    modifier: u64,
};

/// Capture source target type.
pub const CaptureSourceType = enum {
    output,
    toplevel,
};

/// Multiplexer sink target type.
pub const MuxSinkType = enum {
    file,
    rtmp,
};

/// Aggregate recording session metrics returned upon completion.
pub const SessionStats = struct {
    frames_captured: u64 = 0,
    frames_encoded: u64 = 0,
    frames_dropped: u64 = 0,
    bytes_written: u64 = 0,
    duration_ms: u64 = 0,

    pub fn averageFps(self: SessionStats) f64 {
        if (self.duration_ms == 0) return 0.0;
        const dur_s = @as(f64, @floatFromInt(self.duration_ms)) / 1000.0;
        return @as(f64, @floatFromInt(self.frames_encoded)) / dur_s;
    }
};

test "SessionStats averageFps calculation" {
    const stats = SessionStats{
        .frames_captured = 300,
        .frames_encoded = 300,
        .duration_ms = 10_000,
    };
    try std.testing.expectEqual(@as(f64, 30.0), stats.averageFps());
}
