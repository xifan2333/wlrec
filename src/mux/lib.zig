pub const sink = @import("sink.zig");
pub const rtmp = @import("rtmp.zig");
pub const fanout = @import("fanout.zig");

pub const MuxError = sink.MuxError;
pub const MuxStats = sink.MuxStats;
pub const MuxTarget = sink.MuxTarget;
pub const MuxSink = sink.MuxSink;
pub const MuxFanout = fanout.MuxFanout;
pub const parseTarget = sink.parseTarget;

test {
    @import("std").testing.refAllDecls(@This());
}
