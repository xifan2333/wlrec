const std = @import("std");
pub const c = @import("c");
pub const common = @import("common/lib.zig");
pub const capture = @import("capture/lib.zig");
pub const encode = @import("encode/lib.zig");
pub const audio = @import("audio/lib.zig");
pub const mux = @import("mux/lib.zig");
pub const record = @import("record/lib.zig");
pub const cli = @import("cli/lib.zig");

fn audioModeLabel(mode: common.AudioSourceMode) []const u8 {
    return switch (mode) {
        .none => "none",
        .desktop => "desktop",
        .mic => "mic",
        .both => "both",
        .device => |name| name,
    };
}

fn printRecordStartBanner(rec_opts: cli.args.RecordOptions, stdout: anytype) !void {
    if (rec_opts.bitrate) |br| {
        try stdout.print("Recording screen to {s} (device: {s}, fps: {}, bitrate: {} bps", .{
            rec_opts.output_path,
            rec_opts.device_path,
            rec_opts.fps,
            br,
        });
    } else {
        try stdout.print("Recording screen to {s} (device: {s}, fps: {}, qp: {}", .{
            rec_opts.output_path,
            rec_opts.device_path,
            rec_opts.fps,
            rec_opts.qp,
        });
    }
    if (rec_opts.audio_mode.isEnabled()) {
        try stdout.print(", audio: {s} @ {} bps", .{
            audioModeLabel(rec_opts.audio_mode),
            rec_opts.audio_bitrate,
        });
    }
    try stdout.writeAll(")...\n");
    try stdout.flush();
}

fn printRecordSummary(
    rec_opts: cli.args.RecordOptions,
    stats: record.engine.RecordStats,
    stdout: anytype,
) !void {
    try stdout.print("Recording complete: {} frames captured, {} encoded, {} bytes written", .{
        stats.frames_captured,
        stats.frames_encoded,
        stats.bytes_written,
    });
    if (rec_opts.audio_mode.isEnabled()) {
        try stdout.print(", audio: {} frames captured, {} encoded", .{
            stats.audio_frames_captured,
            stats.audio_frames_encoded,
        });
    }
    if (stats.packets_dropped > 0 or stats.reconnects > 0 or stats.audio_packets_dropped > 0) {
        try stdout.print(" ({} video/mux dropped, {} audio dropped, {} reconnects)", .{
            stats.packets_dropped,
            stats.audio_packets_dropped,
            stats.reconnects,
        });
    }
    try stdout.writeAll("\n");
}

fn handleRecordSubcommand(allocator: std.mem.Allocator, rec_opts: cli.args.RecordOptions, stdout: anytype) !void {
    try printRecordStartBanner(rec_opts, stdout);

    const dev_z = try allocator.dupeSentinel(u8, rec_opts.device_path, 0);
    defer allocator.free(dev_z);

    const config = record.engine.RecordConfig{
        .output_path = rec_opts.output_path,
        .device_path = dev_z.ptr,
        .fps = rec_opts.fps,
        .qp = rec_opts.qp,
        .bitrate = rec_opts.bitrate,
        .audio_mode = rec_opts.audio_mode,
        .audio_bitrate = rec_opts.audio_bitrate,
        .duration_secs = rec_opts.duration_secs,
    };

    const stats = try record.engine.runRecording(allocator, config);
    try printRecordSummary(rec_opts, stats, stdout);
}

fn dispatchSubcommand(allocator: std.mem.Allocator, opts: cli.args.CliOptions, stdout: anytype) !void {
    switch (opts.subcommand) {
        .help => try cli.args.printUsage(stdout),
        .version => try stdout.writeAll("wlrec 0.1.0 (Wayland zero-copy VAAPI recorder)\n"),
        .probe => _ = try cli.probe.runProbe(stdout),
        .record => try handleRecordSubcommand(allocator, opts.record, stdout),
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const opts = cli.args.parseFromSlice(args) catch |err| {
        try stderr.print("Error: {s}\n\n", .{@errorName(err)});
        try cli.args.printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    };

    try dispatchSubcommand(arena, opts, stdout);
    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
