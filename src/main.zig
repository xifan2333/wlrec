const std = @import("std");
pub const c = @import("c");
pub const common = @import("common/lib.zig");
pub const capture = @import("capture/lib.zig");
pub const encode = @import("encode/lib.zig");
pub const mux = @import("mux/lib.zig");
pub const record = @import("record/lib.zig");
pub const cli = @import("cli/lib.zig");

fn handleRecordSubcommand(allocator: std.mem.Allocator, rec_opts: cli.args.RecordOptions, stdout: anytype) !void {
    if (rec_opts.bitrate) |br| {
        try stdout.print("Recording screen to {s} (device: {s}, fps: {}, bitrate: {} bps)...\n", .{
            rec_opts.output_path,
            rec_opts.device_path,
            rec_opts.fps,
            br,
        });
    } else {
        try stdout.print("Recording screen to {s} (device: {s}, fps: {}, qp: {})...\n", .{
            rec_opts.output_path,
            rec_opts.device_path,
            rec_opts.fps,
            rec_opts.qp,
        });
    }
    try stdout.flush();

    const dev_z = try allocator.dupeSentinel(u8, rec_opts.device_path, 0);
    defer allocator.free(dev_z);

    const config = record.engine.RecordConfig{
        .output_path = rec_opts.output_path,
        .device_path = dev_z.ptr,
        .fps = rec_opts.fps,
        .qp = rec_opts.qp,
        .bitrate = rec_opts.bitrate,
        .duration_secs = rec_opts.duration_secs,
    };

    const stats = try record.engine.runRecording(allocator, config);
    try stdout.print("Recording complete: {} frames captured, {} encoded, {} bytes written\n", .{
        stats.frames_captured,
        stats.frames_encoded,
        stats.bytes_written,
    });
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
