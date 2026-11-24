const std = @import("std");

/// VfrClock handles variable framerate timestamp math and rate limiting.
/// Presentation timestamps from the compositor (in nanoseconds) are normalized
/// to session start (t0 = 0) and converted to encoder/muxer timebases.
pub const VfrClock = struct {
    start_ns: ?u64 = null,
    last_pts_ns: u64 = 0,
    min_interval_ns: u64 = 0,

    /// Create a VfrClock. If max_fps > 0, frames arriving closer than
    /// 1 second / max_fps will be signaled for dropping.
    pub fn init(max_fps: u32) VfrClock {
        const min_interval: u64 = if (max_fps > 0)
            std.time.ns_per_s / @as(u64, max_fps)
        else
            0;
        return .{
            .min_interval_ns = min_interval,
        };
    }

    /// Combines Wayland presentation_time components into absolute nanoseconds.
    pub fn parseWaylandTimestamp(tv_sec_hi: u32, tv_sec_lo: u32, tv_nsec: u32) u64 {
        const sec = (@as(u64, tv_sec_hi) << 32) | @as(u64, tv_sec_lo);
        return (sec * std.time.ns_per_s) + @as(u64, tv_nsec);
    }

    /// Check if a frame at pts_ns should be dropped due to the maximum FPS limit.
    pub fn shouldDrop(self: *const VfrClock, pts_ns: u64) bool {
        if (self.min_interval_ns == 0) return false;
        if (self.start_ns == null) return false;
        if (pts_ns < self.last_pts_ns) return true;
        return (pts_ns - self.last_pts_ns) < self.min_interval_ns;
    }

    /// Register a frame timestamp and return the session-relative PTS in nanoseconds.
    /// Anchors session start on the first frame if not already set.
    pub fn registerFrame(self: *VfrClock, pts_ns: u64) u64 {
        const start = self.start_ns orelse {
            self.start_ns = pts_ns;
            self.last_pts_ns = pts_ns;
            return 0;
        };

        if (pts_ns > self.last_pts_ns) {
            self.last_pts_ns = pts_ns;
        }

        if (pts_ns < start) {
            return 0;
        }
        return pts_ns - start;
    }

    /// Rescale a nanosecond timestamp to an arbitrary timebase (num/den).
    pub fn rescaleNs(pts_ns: u64, num: u32, den: u32) i64 {
        if (num == 0 or den == 0) return 0;
        // Calculation: pts_ns * den / (num * 1_000_000_000)
        const ns_per_s: u128 = std.time.ns_per_s;
        const pts128: u128 = pts_ns;
        const den128: u128 = den;
        const num128: u128 = num;

        const denom = num128 * ns_per_s;
        const scaled = (pts128 * den128 + (denom / 2)) / denom;
        return @intCast(scaled);
    }
};

test "VfrClock anchors session and calculates relative PTS" {
    var clock = VfrClock.init(0); // unlimited fps

    // First frame at t = 100.5s
    const t0 = VfrClock.parseWaylandTimestamp(0, 100, 500_000_000);
    const pts0 = clock.registerFrame(t0);
    try std.testing.expectEqual(@as(u64, 0), pts0);

    // Second frame 33.3ms later
    const t1 = t0 + 33_333_333;
    const pts1 = clock.registerFrame(t1);
    try std.testing.expectEqual(@as(u64, 33_333_333), pts1);

    // Rescale to 1/1000 (milliseconds)
    const ms = VfrClock.rescaleNs(pts1, 1, 1000);
    try std.testing.expectEqual(@as(i64, 33), ms);

    // Rescale to 1/90000 (MPEG timebase)
    const mpeg_pts = VfrClock.rescaleNs(pts1, 1, 90_000);
    try std.testing.expectEqual(@as(i64, 3000), mpeg_pts);
}

test "VfrClock enforces max FPS clamping" {
    var clock = VfrClock.init(30); // 30 FPS -> 33.33ms min interval
    const t0 = 1_000_000_000;
    _ = clock.registerFrame(t0);

    // Frame arriving 10ms later should be dropped
    const t_too_soon = t0 + 10_000_000;
    try std.testing.expect(clock.shouldDrop(t_too_soon));

    // Frame arriving 35ms later should be kept
    const t_ok = t0 + 35_000_000;
    try std.testing.expect(!clock.shouldDrop(t_ok));
    const pts2 = clock.registerFrame(t_ok);
    try std.testing.expectEqual(@as(u64, 35_000_000), pts2);
}
