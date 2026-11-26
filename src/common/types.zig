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

pub const AudioSourceParseError = error{
    InvalidAudioSource,
};

/// Selected real-time audio capture source mode.
pub const AudioSourceMode = union(enum) {
    none,
    desktop,
    mic,
    both,
    device: []const u8,

    pub fn isEnabled(self: AudioSourceMode) bool {
        return self != .none;
    }

    pub fn parse(spec: []const u8) AudioSourceParseError!AudioSourceMode {
        if (spec.len == 0) return AudioSourceParseError.InvalidAudioSource;
        if (std.ascii.eqlIgnoreCase(spec, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(spec, "desktop")) return .desktop;
        if (std.ascii.eqlIgnoreCase(spec, "mic")) return .mic;
        if (std.ascii.eqlIgnoreCase(spec, "both")) return .both;
        if (std.mem.indexOfScalar(u8, spec, 0) != null) {
            return AudioSourceParseError.InvalidAudioSource;
        }
        return .{ .device = spec };
    }
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

test "AudioSourceMode parses built-in modes and custom source names" {
    const none_mode = try AudioSourceMode.parse("none");
    try std.testing.expect(!none_mode.isEnabled());

    const desktop_mode = try AudioSourceMode.parse("DESKTOP");
    try std.testing.expect(desktop_mode.isEnabled());
    try std.testing.expectEqual(AudioSourceMode.desktop, desktop_mode);

    const mic_mode = try AudioSourceMode.parse("mic");
    try std.testing.expectEqual(AudioSourceMode.mic, mic_mode);

    const both_mode = try AudioSourceMode.parse("Both");
    try std.testing.expectEqual(AudioSourceMode.both, both_mode);

    const custom_mode = try AudioSourceMode.parse("alsa_input.usb-mic.mono-fallback");
    try std.testing.expect(custom_mode.isEnabled());
    try std.testing.expectEqualStrings("alsa_input.usb-mic.mono-fallback", custom_mode.device);

    try std.testing.expectError(AudioSourceParseError.InvalidAudioSource, AudioSourceMode.parse(""));
    const nul_spec = [_]u8{ 'b', 'a', 'd', 0, 's', 'r', 'c' };
    try std.testing.expectError(AudioSourceParseError.InvalidAudioSource, AudioSourceMode.parse(&nul_spec));
}
