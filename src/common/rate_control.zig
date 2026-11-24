const std = @import("std");

pub const RateControlError = error{
    InvalidBitrate,
    InvalidMaxRate,
    InvalidBufSize,
    InvalidQp,
    CbrRateMismatch,
};

/// Hardware encoder rate-control policy.
pub const RateControlProfile = struct {
    pub const Mode = enum {
        cqp,
        vbr,
        cbr,
    };

    mode: Mode,
    bitrate_kbps: u32 = 0,
    maxrate_kbps: u32 = 0,
    bufsize_kb: u32 = 0,
    qp: u8 = 26,

    /// Create a Constant Quantization Parameter (CQP) profile.
    pub fn cqp(qp_val: u8) RateControlProfile {
        return .{
            .mode = .cqp,
            .qp = qp_val,
        };
    }

    /// Create a Variable Bitrate (VBR) profile suitable for live streaming.
    pub fn vbr(bitrate: u32, maxrate: u32, bufsize: u32) RateControlProfile {
        return .{
            .mode = .vbr,
            .bitrate_kbps = bitrate,
            .maxrate_kbps = maxrate,
            .bufsize_kb = bufsize,
        };
    }

    /// Create a Constant Bitrate (CBR) profile with identical bitrate and maxrate.
    pub fn cbr(bitrate: u32, bufsize: u32) RateControlProfile {
        return .{
            .mode = .cbr,
            .bitrate_kbps = bitrate,
            .maxrate_kbps = bitrate,
            .bufsize_kb = bufsize,
        };
    }

    /// Validates the profile invariants according to driver/FFmpeg expectations.
    pub fn validate(self: *const RateControlProfile) RateControlError!void {
        switch (self.mode) {
            .cqp => {
                if (self.qp > 51) return RateControlError.InvalidQp;
            },
            .vbr => {
                if (self.bitrate_kbps == 0) return RateControlError.InvalidBitrate;
                if (self.maxrate_kbps < self.bitrate_kbps) return RateControlError.InvalidMaxRate;
                if (self.bufsize_kb == 0) return RateControlError.InvalidBufSize;
            },
            .cbr => {
                if (self.bitrate_kbps == 0) return RateControlError.InvalidBitrate;
                if (self.maxrate_kbps != self.bitrate_kbps) return RateControlError.CbrRateMismatch;
                if (self.bufsize_kb == 0) return RateControlError.InvalidBufSize;
            },
        }
    }

    /// Returns the exact rc_mode string expected by FFmpeg h264_vaapi.
    pub fn getFfmpegRcMode(self: *const RateControlProfile) [:0]const u8 {
        return switch (self.mode) {
            .cqp => "CQP",
            .vbr => "VBR",
            .cbr => "CBR",
        };
    }
};

test "RateControlProfile CQP validation" {
    const valid = RateControlProfile.cqp(24);
    try valid.validate();
    try std.testing.expectEqualStrings("CQP", valid.getFfmpegRcMode());

    const invalid = RateControlProfile.cqp(55);
    try std.testing.expectError(RateControlError.InvalidQp, invalid.validate());
}

test "RateControlProfile VBR validation" {
    const valid = RateControlProfile.vbr(2000, 3000, 6000);
    try valid.validate();
    try std.testing.expectEqualStrings("VBR", valid.getFfmpegRcMode());

    // Maxrate lower than bitrate is invalid
    const invalid = RateControlProfile.vbr(4000, 2000, 6000);
    try std.testing.expectError(RateControlError.InvalidMaxRate, invalid.validate());
}

test "RateControlProfile CBR validation" {
    const valid = RateControlProfile.cbr(2500, 5000);
    try valid.validate();
    try std.testing.expectEqualStrings("CBR", valid.getFfmpegRcMode());
    try std.testing.expectEqual(valid.bitrate_kbps, valid.maxrate_kbps);

    var invalid = valid;
    invalid.maxrate_kbps = 3000;
    try std.testing.expectError(RateControlError.CbrRateMismatch, invalid.validate());
}
