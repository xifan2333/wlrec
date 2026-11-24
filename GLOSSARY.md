# Domain Glossary

Shared vocabulary for `wlrec`. Skills and agents must use these terms as defined here; when a
concept is missing, add it here rather than inventing a synonym.

---

## Capture & GPU Zero-Copy Pipeline

### CaptureSource

The target surface bound through Wayland image capture source protocols:
- **Output source**: `ext-output-image-capture-source-manager-v1` bound to a `wl_output`.
- **Toplevel source**: `ext-foreign-toplevel-image-capture-source-manager-v1` bound to a window handle.

### CopyCaptureSession

An active `ext_image_copy_capture_session_v1` (plus optional `ext_image_copy_capture_cursor_session_v1`)
driving frame requests (`create_frame` -> `capture`) and receiving compositor presentation timestamps
(`presentation_time`) and buffer constraints (`buffer_size`, `dmabuf_format`, `dmabuf_device`).

### DmabufFrame

A GPU-resident video frame backed by one or more Linux `dma-buf` file descriptors (`zwp_linux_dmabuf_v1`),
described by `fourcc`, DRM format `modifier`, dimensions, plane strides/offsets, and compositor
monotonic presentation timestamp.

### HwFrameContext

The FFmpeg/VAAPI hardware bridge (`AVHWDeviceContext` + `AVHWFramesContext`) importing `DmabufFrame`
descriptors as `AV_PIX_FMT_DRM_PRIME` and mapping/deriving them to `AV_PIX_FMT_VAAPI` surfaces
without CPU pixel readback.

### VaapiEncoder

The hardware `h264_vaapi` / `hevc_vaapi` encoder consuming `AV_PIX_FMT_VAAPI` frames on a variable
framerate timebase (`VfrClock`) and emitting compressed packets to `MuxSink`.

---

## Timing, Rate Control & Audio

### VfrClock

Presentation-timestamp driven variable framerate clock. Converts Wayland monotonic
`presentation_time` into `AVRational` PTS anchored at session start (`t0 = 0`), eliminating
software frame duplication on static screens while clamping minimum frame intervals to `--fps`.

### RateControlProfile

Encoder rate-control policy selected by target sink:
- **Streaming (`VBR`)**: bounded `maxrate` and `bufsize` so live RTMP streams do not saturate uplink
  buffers or starve audio.
- **Local high-quality (`CQP` / `ICQ`)**: constant-quality encoding without artificial bitrate caps.
- **Strict constant (`CBR`)**: fixed bitrate for ingest endpoints requiring strict CBR.

### AudioRingBuffer

Pre-allocated, lock-free single-producer single-consumer (SPSC) ring buffer bridging the real-time
audio capture thread and the audio encoding loop. Audio capture never waits on video encoding or
network I/O.

### MuxSink

Unified packet output boundary supporting local container files (`.mp4`, `.mkv`, `.flv`) and live
`rtmp://` endpoints with explicit non-blocking reconnect and packet-drop telemetry.

---

## Telemetry Sidecar

### TelemetryEvent

One JSONL record written to the sidecar stream (`--telemetry`), normalized to capture-source
coordinates `[0.0, 1.0]` with `t_ms` aligned to `VfrClock` zero:
- Kinds: `move`, `down`, `up`, `scroll`, `key`, `stop`
- Used downstream for Recorderly-style automated zoom, keyframe, and cursor-follow post-editing.

### PointerSource

Independent pointer/input collector (compositor seat/cursor or `libinput`) feeding `TelemetryEvent`
records through a bounded lock-free queue without touching the video capture or VAAPI hot path.

---

## C-ABI & Ownership

### CDepsModule

The single curated Zig `translateC` module generated from `src/c/c_deps.h` and `wayland-scanner`
outputs. Direct `@cImport` outside `src/c/` is forbidden.

### BoundaryTrampoline

A thin `callconv(.c)` callback function registered with Wayland, FFmpeg, or PulseAudio/PipeWire.
Immediately translates C pointers and error codes into typed Zig domain calls without holding
owning logic.

### OwningHandle

A Zig wrapper struct around a C resource or file descriptor (`wl_display`, `AVFormatContext`,
`AVCodecContext`, `AVFrame`, `AVPacket`, `dma-buf` fd) that guarantees deterministic release via
`deinit()` paired with `defer` / `errdefer`.
