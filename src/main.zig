const std = @import("std");
pub const c = @import("c");
pub const common = @import("common/lib.zig");
pub const capture = @import("capture/lib.zig");
pub const encode = @import("encode/lib.zig");
pub const cli = @import("cli/lib.zig");

fn dispatchSubcommand(opts: cli.args.CliOptions, stdout: anytype) !void {
    switch (opts.subcommand) {
        .help => {
            try cli.args.printUsage(stdout);
        },
        .version => {
            try stdout.writeAll("wlrec 0.1.0 (Wayland zero-copy VAAPI recorder)\n");
        },
        .probe => {
            _ = try cli.probe.runProbe(stdout);
        },
        .record => {
            try stdout.print("Starting recording to {s} (device: {s}, fps: {}, qp: {}, bitrate: {})\n", .{
                opts.record.output_path,
                opts.record.device_path,
                opts.record.fps,
                opts.record.qp,
                opts.record.bitrate,
            });
        },
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

    try dispatchSubcommand(opts, stdout);
    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
