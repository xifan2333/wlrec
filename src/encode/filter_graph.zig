const std = @import("std");
const c = @import("c");
const common = @import("../common/lib.zig");
const vaapi_device = @import("vaapi_device.zig");

pub const FilterError = error{
    GraphAllocFailed,
    InputFilterFailed,
    OutputFilterFailed,
    TransposeFilterFailed,
    ScaleFilterFailed,
    LinkFailed,
    GraphConfigFailed,
    FrameAllocFailed,
    PushFrameFailed,
    PullFrameFailed,
};

fn dummyFree(opaque_ptr: ?*anyopaque, data: [*c]u8) callconv(.c) void {
    _ = opaque_ptr;
    _ = data;
}

/// Compute upright output dimensions after undoing a Wayland buffer transform.
pub fn transformedDimensions(width: u32, height: u32, wl_transform: u32) common.Dimensions {
    return switch (wl_transform) {
        c.WL_OUTPUT_TRANSFORM_90,
        c.WL_OUTPUT_TRANSFORM_270,
        c.WL_OUTPUT_TRANSFORM_FLIPPED_90,
        c.WL_OUTPUT_TRANSFORM_FLIPPED_270,
        => .{ .width = height, .height = width },
        else => .{ .width = width, .height = height },
    };
}

/// Map a Wayland buffer transform to the inverse transpose_vaapi filter argument.
pub fn transposeArgsForTransform(wl_transform: u32) ?[:0]const u8 {
    return switch (wl_transform) {
        c.WL_OUTPUT_TRANSFORM_90 => "dir=clock",
        c.WL_OUTPUT_TRANSFORM_180 => "dir=reversal",
        c.WL_OUTPUT_TRANSFORM_270 => "dir=cclock",
        c.WL_OUTPUT_TRANSFORM_FLIPPED => "dir=hflip",
        c.WL_OUTPUT_TRANSFORM_FLIPPED_90 => "dir=cclock_flip",
        c.WL_OUTPUT_TRANSFORM_FLIPPED_180 => "dir=vflip",
        c.WL_OUTPUT_TRANSFORM_FLIPPED_270 => "dir=clock_flip",
        else => null,
    };
}

/// Hardware filter graph managing orientation, scaling, and RGB -> NV12 conversion in GPU memory.
pub const VaapiFilterGraph = struct {
    graph: *c.AVFilterGraph,
    in_ctx: *c.AVFilterContext,
    out_ctx: *c.AVFilterContext,
    in_frames_ref: *c.AVBufferRef,

    in_width: u32,
    in_height: u32,
    out_width: u32,
    out_height: u32,
    wl_transform: u32,

    fn createInputFilter(graph: *c.AVFilterGraph, device: *vaapi_device.VaapiDevice) FilterError!*c.AVFilterContext {
        const buffersrc = c.avfilter_get_by_name("buffer") orelse return FilterError.InputFilterFailed;
        const in_ctx = c.avfilter_graph_alloc_filter(graph, buffersrc, "in") orelse return FilterError.InputFilterFailed;
        const par = c.av_buffersrc_parameters_alloc() orelse return FilterError.InputFilterFailed;
        defer c.av_free(par);

        par.*.format = c.AV_PIX_FMT_VAAPI;
        par.*.width = @intCast(device.width);
        par.*.height = @intCast(device.height);
        par.*.time_base = c.AVRational{ .num = 1, .den = 1000 };
        par.*.hw_frames_ctx = device.in_frames_ref;

        if (c.av_buffersrc_parameters_set(in_ctx, par) < 0) return FilterError.InputFilterFailed;
        if (c.avfilter_init_str(in_ctx, null) < 0) return FilterError.InputFilterFailed;
        return in_ctx;
    }

    fn attachOptionalTranspose(
        graph: *c.AVFilterGraph,
        device: *vaapi_device.VaapiDevice,
        prev_ctx: *c.AVFilterContext,
        wl_transform: u32,
    ) FilterError!*c.AVFilterContext {
        const t_args = transposeArgsForTransform(wl_transform) orelse return prev_ctx;
        const t_filter = c.avfilter_get_by_name("transpose_vaapi") orelse return FilterError.TransposeFilterFailed;
        const t_ctx = c.avfilter_graph_alloc_filter(graph, t_filter, "transpose") orelse return FilterError.TransposeFilterFailed;
        t_ctx.*.hw_device_ctx = c.av_buffer_ref(device.hw_device_ctx);
        if (c.avfilter_init_str(t_ctx, t_args.ptr) < 0) return FilterError.TransposeFilterFailed;
        if (c.avfilter_link(prev_ctx, 0, t_ctx, 0) < 0) return FilterError.LinkFailed;
        return t_ctx;
    }

    fn createScaleFilter(
        graph: *c.AVFilterGraph,
        device: *vaapi_device.VaapiDevice,
        post_t: common.Dimensions,
        out_width: u32,
        out_height: u32,
    ) FilterError!*c.AVFilterContext {
        const scale_filter = c.avfilter_get_by_name("scale_vaapi") orelse return FilterError.ScaleFilterFailed;
        const scale_ctx = c.avfilter_graph_alloc_filter(graph, scale_filter, "scale") orelse return FilterError.ScaleFilterFailed;
        scale_ctx.*.hw_device_ctx = c.av_buffer_ref(device.hw_device_ctx);

        if (post_t.width == out_width and post_t.height == out_height) {
            if (c.avfilter_init_str(scale_ctx, "format=nv12") < 0) return FilterError.ScaleFilterFailed;
            return scale_ctx;
        }

        var args_buf: [64]u8 = undefined;
        const args_slice = std.fmt.bufPrint(args_buf[0 .. args_buf.len - 1], "w={}:h={}:format=nv12", .{ out_width, out_height }) catch {
            return FilterError.ScaleFilterFailed;
        };
        args_buf[args_slice.len] = 0;
        if (c.avfilter_init_str(scale_ctx, @ptrCast(args_buf[0..args_slice.len :0].ptr)) < 0) return FilterError.ScaleFilterFailed;
        return scale_ctx;
    }

    pub fn init(
        device: *vaapi_device.VaapiDevice,
        out_width: u32,
        out_height: u32,
        wl_transform: u32,
    ) FilterError!VaapiFilterGraph {
        var graph: ?*c.AVFilterGraph = c.avfilter_graph_alloc() orelse return FilterError.GraphAllocFailed;
        errdefer c.avfilter_graph_free(&graph);

        const in_ctx = try createInputFilter(graph.?, device);

        const buffersink = c.avfilter_get_by_name("buffersink") orelse return FilterError.OutputFilterFailed;
        var out_ctx: ?*c.AVFilterContext = null;
        if (c.avfilter_graph_create_filter(&out_ctx, buffersink, "out", null, null, graph.?) < 0 or out_ctx == null) {
            return FilterError.OutputFilterFailed;
        }

        const prev_ctx = try attachOptionalTranspose(graph.?, device, in_ctx, wl_transform);
        const post_t = transformedDimensions(device.width, device.height, wl_transform);
        const scale_ctx = try createScaleFilter(graph.?, device, post_t, out_width, out_height);

        if (c.avfilter_link(prev_ctx, 0, scale_ctx, 0) < 0) return FilterError.LinkFailed;
        if (c.avfilter_link(scale_ctx, 0, out_ctx.?, 0) < 0) return FilterError.LinkFailed;
        if (c.avfilter_graph_config(graph.?, null) < 0) return FilterError.GraphConfigFailed;

        return .{
            .graph = graph.?,
            .in_ctx = in_ctx,
            .out_ctx = out_ctx.?,
            .in_frames_ref = device.in_frames_ref,
            .in_width = device.width,
            .in_height = device.height,
            .out_width = out_width,
            .out_height = out_height,
            .wl_transform = wl_transform,
        };
    }

    pub fn deinit(self: *VaapiFilterGraph) void {
        var g: ?*c.AVFilterGraph = self.graph;
        c.avfilter_graph_free(&g);
    }

    /// Process a VAAPI RGB surface through the GPU filter graph and return an NV12 AVFrame.
    /// Caller owns the returned AVFrame and must release it with av_frame_free.
    pub fn filterSurface(self: *VaapiFilterGraph, surface_id: c.VASurfaceID, pts_ms: i64) FilterError!*c.AVFrame {
        const in_frame = c.av_frame_alloc() orelse return FilterError.FrameAllocFailed;
        var in_f: ?*c.AVFrame = in_frame;
        defer c.av_frame_free(&in_f);

        in_frame.*.format = c.AV_PIX_FMT_VAAPI;
        in_frame.*.width = @intCast(self.in_width);
        in_frame.*.height = @intCast(self.in_height);
        in_frame.*.hw_frames_ctx = c.av_buffer_ref(self.in_frames_ref);
        in_frame.*.data[3] = @ptrFromInt(@as(usize, surface_id));
        in_frame.*.buf[0] = c.av_buffer_create(null, 0, dummyFree, null, 0);
        in_frame.*.pts = pts_ms;

        if (c.av_buffersrc_add_frame_flags(self.in_ctx, in_frame, c.AV_BUFFERSRC_FLAG_KEEP_REF) < 0) {
            return FilterError.PushFrameFailed;
        }

        const out_frame = c.av_frame_alloc() orelse return FilterError.FrameAllocFailed;
        var out_f: ?*c.AVFrame = out_frame;
        errdefer c.av_frame_free(&out_f);

        if (c.av_buffersink_get_frame(self.out_ctx, out_frame) < 0) {
            return FilterError.PullFrameFailed;
        }

        return out_frame;
    }
};

test "VaapiFilterGraph transform mapping" {
    try std.testing.expect(transposeArgsForTransform(c.WL_OUTPUT_TRANSFORM_NORMAL) == null);
    try std.testing.expectEqualStrings("dir=clock", transposeArgsForTransform(c.WL_OUTPUT_TRANSFORM_90).?);
    const dims = transformedDimensions(1920, 1080, c.WL_OUTPUT_TRANSFORM_90);
    try std.testing.expectEqual(@as(u32, 1080), dims.width);
    try std.testing.expectEqual(@as(u32, 1920), dims.height);
}
