const std = @import("std");
const c = @import("c");
const vaapi_device = @import("vaapi_device.zig");

pub const FilterError = error{
    GraphAllocFailed,
    InputFilterFailed,
    OutputFilterFailed,
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

/// Hardware filter graph managing ARGB -> NV12 color conversion in GPU memory.
pub const VaapiFilterGraph = struct {
    graph: *c.AVFilterGraph,
    in_ctx: *c.AVFilterContext,
    out_ctx: *c.AVFilterContext,
    in_frames_ref: *c.AVBufferRef,

    width: u32,
    height: u32,

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

    pub fn init(device: *vaapi_device.VaapiDevice) FilterError!VaapiFilterGraph {
        var graph: ?*c.AVFilterGraph = c.avfilter_graph_alloc() orelse return FilterError.GraphAllocFailed;
        errdefer c.avfilter_graph_free(&graph);

        const in_ctx = try createInputFilter(graph.?, device);

        const buffersink = c.avfilter_get_by_name("buffersink") orelse return FilterError.OutputFilterFailed;
        var out_ctx: ?*c.AVFilterContext = null;
        if (c.avfilter_graph_create_filter(&out_ctx, buffersink, "out", null, null, graph.?) < 0 or out_ctx == null) {
            return FilterError.OutputFilterFailed;
        }

        const scale_filter = c.avfilter_get_by_name("scale_vaapi") orelse return FilterError.ScaleFilterFailed;
        const scale_ctx = c.avfilter_graph_alloc_filter(graph.?, scale_filter, "scale") orelse return FilterError.ScaleFilterFailed;
        scale_ctx.*.hw_device_ctx = c.av_buffer_ref(device.hw_device_ctx);
        if (c.avfilter_init_str(scale_ctx, "format=nv12") < 0) return FilterError.ScaleFilterFailed;

        if (c.avfilter_link(in_ctx, 0, scale_ctx, 0) < 0) return FilterError.LinkFailed;
        if (c.avfilter_link(scale_ctx, 0, out_ctx.?, 0) < 0) return FilterError.LinkFailed;
        if (c.avfilter_graph_config(graph.?, null) < 0) return FilterError.GraphConfigFailed;

        return .{
            .graph = graph.?,
            .in_ctx = in_ctx,
            .out_ctx = out_ctx.?,
            .in_frames_ref = device.in_frames_ref,
            .width = device.width,
            .height = device.height,
        };
    }

    pub fn deinit(self: *VaapiFilterGraph) void {
        var g: ?*c.AVFilterGraph = self.graph;
        c.avfilter_graph_free(&g);
    }

    /// Process a VAAPI ARGB surface through the GPU scale filter and return an NV12 AVFrame.
    /// Caller owns the returned AVFrame and must release it with av_frame_free.
    pub fn filterSurface(self: *VaapiFilterGraph, surface_id: c.VASurfaceID, pts_ms: i64) FilterError!*c.AVFrame {
        const in_frame = c.av_frame_alloc() orelse return FilterError.FrameAllocFailed;
        var in_f: ?*c.AVFrame = in_frame;
        defer c.av_frame_free(&in_f);

        in_frame.*.format = c.AV_PIX_FMT_VAAPI;
        in_frame.*.width = @intCast(self.width);
        in_frame.*.height = @intCast(self.height);
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

test "VaapiFilterGraph structural checks" {
    try std.testing.expect(@sizeOf(VaapiFilterGraph) > 0);
}
