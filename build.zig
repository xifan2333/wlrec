const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_protocols_base = b.option(
        []const u8,
        "wayland-protocols-dir",
        "Directory containing wayland-protocols",
    ) orelse "/usr/share/wayland-protocols";

    const ffmpeg_include_dir = b.option(
        []const u8,
        "ffmpeg-include-dir",
        "Additional include directory for FFmpeg headers",
    );

    const Protocol = struct {
        name: []const u8,
        subpath: []const u8,
    };

    const protocols = [_]Protocol{
        .{
            .name = "ext-image-capture-source-v1",
            .subpath = "staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
        },
        .{
            .name = "ext-image-copy-capture-v1",
            .subpath = "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
        },
        .{
            .name = "ext-foreign-toplevel-list-v1",
            .subpath = "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
        },
        .{
            .name = "linux-dmabuf-v1",
            .subpath = "stable/linux-dmabuf/linux-dmabuf-v1.xml",
        },
        .{
            .name = "xdg-shell",
            .subpath = "stable/xdg-shell/xdg-shell.xml",
        },
    };

    var gen_c_files: [protocols.len]std.Build.LazyPath = undefined;
    var gen_h_files: [protocols.len]std.Build.LazyPath = undefined;

    for (protocols, 0..) |proto, i| {
        const xml_path = b.fmt("{s}/{s}", .{ wayland_protocols_base, proto.subpath });
        const h_name = b.fmt("{s}-client-protocol.h", .{proto.name});
        const c_name = b.fmt("{s}-protocol.c", .{proto.name});

        const scan_h = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xml_path });
        const h_file = scan_h.addOutputFileArg(h_name);
        gen_h_files[i] = h_file;

        const scan_c = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml_path });
        const c_file = scan_c.addOutputFileArg(c_name);
        gen_c_files[i] = c_file;
    }

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c_deps.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("src/c"));
    if (ffmpeg_include_dir) |inc_dir| {
        translate_c.addIncludePath(.{ .cwd_relative = inc_dir });
    }
    for (gen_h_files) |h_file| {
        translate_c.addIncludePath(h_file.dirname());
    }

    const c_mod = translate_c.createModule();

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("c", c_mod);
    for (gen_c_files) |c_file| {
        root_mod.addCSourceFile(.{ .file = c_file, .flags = &.{} });
    }

    root_mod.linkSystemLibrary("wayland-client", .{});
    root_mod.linkSystemLibrary("avcodec", .{});
    root_mod.linkSystemLibrary("avformat", .{});
    root_mod.linkSystemLibrary("avfilter", .{});
    root_mod.linkSystemLibrary("avutil", .{});
    root_mod.linkSystemLibrary("va", .{});
    root_mod.linkSystemLibrary("va-drm", .{});
    root_mod.linkSystemLibrary("drm", .{});
    root_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "wlrec",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run wlrec");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("c", c_mod);
    unit_tests.root_module.link_libc = true;
    for (gen_c_files) |c_file| {
        unit_tests.root_module.addCSourceFile(.{ .file = c_file, .flags = &.{} });
    }
    unit_tests.root_module.linkSystemLibrary("wayland-client", .{});
    unit_tests.root_module.linkSystemLibrary("avcodec", .{});
    unit_tests.root_module.linkSystemLibrary("avformat", .{});
    unit_tests.root_module.linkSystemLibrary("avfilter", .{});
    unit_tests.root_module.linkSystemLibrary("avutil", .{});
    unit_tests.root_module.linkSystemLibrary("va", .{});
    unit_tests.root_module.linkSystemLibrary("va-drm", .{});
    unit_tests.root_module.linkSystemLibrary("drm", .{});

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("wlrec", root_mod);
    integration_tests.root_module.addImport("c", c_mod);
    integration_tests.root_module.link_libc = true;
    integration_tests.root_module.linkSystemLibrary("wayland-client", .{});
    integration_tests.root_module.linkSystemLibrary("avcodec", .{});
    integration_tests.root_module.linkSystemLibrary("avformat", .{});
    integration_tests.root_module.linkSystemLibrary("avfilter", .{});
    integration_tests.root_module.linkSystemLibrary("avutil", .{});
    integration_tests.root_module.linkSystemLibrary("va", .{});
    integration_tests.root_module.linkSystemLibrary("va-drm", .{});
    integration_tests.root_module.linkSystemLibrary("drm", .{});

    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
}
