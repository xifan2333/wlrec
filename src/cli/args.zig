const std = @import("std");

pub const Subcommand = enum {
    probe,
    record,
    help,
    version,
};

pub const RecordOptions = struct {
    output_path: []const u8 = "output.h264",
    device_path: []const u8 = "/dev/dri/renderD128",
    fps: u32 = 60,
    qp: u8 = 23,
    bitrate: ?u32 = null,
    duration_secs: u64 = 0,
};

pub const CliOptions = struct {
    subcommand: Subcommand = .help,
    record: RecordOptions = .{},
};

pub const CliError = error{
    UnknownSubcommand,
    UnknownOption,
    MissingOptionValue,
    InvalidNumber,
};

fn parseEncoderOption(flag: []const u8, val: []const u8, opts: *RecordOptions) !bool {
    if (std.mem.eql(u8, flag, "-q") or std.mem.eql(u8, flag, "--qp")) {
        opts.qp = std.fmt.parseInt(u8, val, 10) catch return error.InvalidNumber;
        opts.bitrate = null;
        return true;
    }
    if (std.mem.eql(u8, flag, "-b") or std.mem.eql(u8, flag, "--bitrate")) {
        const br = std.fmt.parseInt(u32, val, 10) catch return error.InvalidNumber;
        if (br == 0) return error.InvalidNumber;
        opts.bitrate = br;
        return true;
    }
    return false;
}

fn parseTimeOption(flag: []const u8, val: []const u8, opts: *RecordOptions) !bool {
    if (std.mem.eql(u8, flag, "-f") or std.mem.eql(u8, flag, "--fps")) {
        opts.fps = std.fmt.parseInt(u32, val, 10) catch return error.InvalidNumber;
        return true;
    }
    if (std.mem.eql(u8, flag, "--duration")) {
        opts.duration_secs = std.fmt.parseInt(u64, val, 10) catch return error.InvalidNumber;
        return true;
    }
    return false;
}

fn parseRecordFlag(opts: *RecordOptions, flag: []const u8, val: []const u8) !void {
    if (std.mem.eql(u8, flag, "-o") or std.mem.eql(u8, flag, "--output")) {
        opts.output_path = val;
        return;
    }
    if (std.mem.eql(u8, flag, "-d") or std.mem.eql(u8, flag, "--device")) {
        opts.device_path = val;
        return;
    }
    if (try parseEncoderOption(flag, val, opts)) return;
    if (try parseTimeOption(flag, val, opts)) return;
    return error.UnknownOption;
}

fn parseRecordArgs(opts: *RecordOptions, args: []const []const u8) !void {
    var i: usize = 0;
    while (i < args.len) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const val = args[i + 1];
        try parseRecordFlag(opts, flag, val);
        i += 2;
    }
}

pub fn parseFromSlice(args: []const []const u8) !CliOptions {
    if (args.len <= 1) {
        return CliOptions{ .subcommand = .help };
    }

    const first = args[1];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "help")) {
        return CliOptions{ .subcommand = .help };
    }
    if (std.mem.eql(u8, first, "-v") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version")) {
        return CliOptions{ .subcommand = .version };
    }
    if (std.mem.eql(u8, first, "probe")) {
        return CliOptions{ .subcommand = .probe };
    }
    if (std.mem.eql(u8, first, "record")) {
        var opts = CliOptions{ .subcommand = .record };
        if (args.len > 2) {
            try parseRecordArgs(&opts.record, args[2..]);
        }
        return opts;
    }

    return error.UnknownSubcommand;
}

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\wlrec - Zero-copy Wayland screen recording & streaming engine
        \\
        \\Usage:
        \\  wlrec <subcommand> [options]
        \\
        \\Subcommands:
        \\  probe               Probe Wayland & VAAPI hardware acceleration environment
        \\  record              Record screen using Wayland copy capture & VAAPI
        \\  help, -h, --help    Show this help message
        \\  version, -v         Show version information
        \\
        \\Record Options:
        \\  -o, --output <path>    Output file path (default: output.h264)
        \\  -d, --device <path>    DRM render node path (default: /dev/dri/renderD128)
        \\  -f, --fps <num>        Capture framerate (default: 60)
        \\  -q, --qp <num>         H.264 CQP quantization parameter (default: 23)
        \\  -b, --bitrate <num>    Target VBR bitrate in bps (overrides --qp)
        \\  --duration <seconds>   Recording duration limit in seconds (0 = unlimited)
        \\
    );
}

test "parseFromSlice help and version" {
    const help_args = [_][]const u8{ "wlrec", "--help" };
    const help_opts = try parseFromSlice(&help_args);
    try std.testing.expectEqual(Subcommand.help, help_opts.subcommand);

    const ver_args = [_][]const u8{ "wlrec", "-v" };
    const ver_opts = try parseFromSlice(&ver_args);
    try std.testing.expectEqual(Subcommand.version, ver_opts.subcommand);

    const empty_args = [_][]const u8{"wlrec"};
    const default_opts = try parseFromSlice(&empty_args);
    try std.testing.expectEqual(Subcommand.help, default_opts.subcommand);
}

test "parseFromSlice probe" {
    const probe_args = [_][]const u8{ "wlrec", "probe" };
    const opts = try parseFromSlice(&probe_args);
    try std.testing.expectEqual(Subcommand.probe, opts.subcommand);
}

test "parseFromSlice record defaults and options" {
    const rec_default = [_][]const u8{ "wlrec", "record" };
    const d_opts = try parseFromSlice(&rec_default);
    try std.testing.expectEqual(Subcommand.record, d_opts.subcommand);
    try std.testing.expectEqualStrings("output.h264", d_opts.record.output_path);
    try std.testing.expectEqual(@as(u32, 60), d_opts.record.fps);
    try std.testing.expectEqual(@as(u8, 23), d_opts.record.qp);
    try std.testing.expectEqual(@as(?u32, null), d_opts.record.bitrate);

    const rec_custom = [_][]const u8{
        "wlrec",      "record",
        "-o",         "rec.h264",
        "-f",         "30",
        "-q",         "18",
        "-b",         "8000000",
        "--duration", "10",
        "-d",         "/dev/dri/renderD129",
    };
    const c_opts = try parseFromSlice(&rec_custom);
    try std.testing.expectEqual(Subcommand.record, c_opts.subcommand);
    try std.testing.expectEqualStrings("rec.h264", c_opts.record.output_path);
    try std.testing.expectEqual(@as(u32, 30), c_opts.record.fps);
    try std.testing.expectEqual(@as(u8, 18), c_opts.record.qp);
    try std.testing.expectEqual(@as(?u32, 8_000_000), c_opts.record.bitrate);
    try std.testing.expectEqual(@as(u64, 10), c_opts.record.duration_secs);
    try std.testing.expectEqualStrings("/dev/dri/renderD129", c_opts.record.device_path);

    const cqp_override = [_][]const u8{ "wlrec", "record", "-b", "8000000", "-q", "20" };
    const q_opts = try parseFromSlice(&cqp_override);
    try std.testing.expectEqual(@as(?u32, null), q_opts.record.bitrate);
    try std.testing.expectEqual(@as(u8, 20), q_opts.record.qp);
}

test "parseFromSlice error handling" {
    const bad_subcmd = [_][]const u8{ "wlrec", "invalid" };
    try std.testing.expectError(error.UnknownSubcommand, parseFromSlice(&bad_subcmd));

    const bad_opt = [_][]const u8{ "wlrec", "record", "--invalid", "foo" };
    try std.testing.expectError(error.UnknownOption, parseFromSlice(&bad_opt));

    const missing_val = [_][]const u8{ "wlrec", "record", "-o" };
    try std.testing.expectError(error.MissingOptionValue, parseFromSlice(&missing_val));

    const bad_num = [_][]const u8{ "wlrec", "record", "-f", "not_a_number" };
    try std.testing.expectError(error.InvalidNumber, parseFromSlice(&bad_num));

    const zero_bitrate = [_][]const u8{ "wlrec", "record", "-b", "0" };
    try std.testing.expectError(error.InvalidNumber, parseFromSlice(&zero_bitrate));
}
