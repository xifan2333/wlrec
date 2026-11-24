# C-ABI Hard Boundary Specification & Triage Guide

This document defines the architectural boundaries between **C-ABI system interfaces** and **pure Zig domain logic** in `wlrec`.

---

## 1. Architectural Philosophy: C at the Boundary, Idiomatic Zig Everywhere Else

- **Core Axiom**: *Interface in C (forced by Wayland, kernel DRM, VAAPI, FFmpeg, and audio ABIs), implementation in idiomatic Zig everywhere else.*
- **Hard Red Line**: Never wrap designated C-ABI callbacks in heavyweight dynamic abstractions, and never leak raw `?*anyopaque`, unmanaged C pointers, or raw file descriptors past the boundary module.
- **Single C Translation Unit**: All C headers (`wayland-client.h`, generated protocol headers, `libav*`, `libdrm`, `libva`, `pulse/pulseaudio.h`) are imported strictly through `src/c/c_deps.h` as the `c` module. Direct `@cImport` outside `src/c/` is forbidden.

---

## 2. The Five Canonical C-ABI Hard Boundaries

### Boundary 1: Wayland Client & Generated Protocols
- **Files**: `src/capture/`
- **ABI Constraints**:
  - Listeners (`wl_registry_listener`, `wl_output_listener`, `ext_image_copy_capture_session_v1_listener`, `ext_image_copy_capture_frame_v1_listener`, `zwp_linux_dmabuf_v1_listener`) require `callconv(.c)` function pointers taking `data: ?*anyopaque`.
  - **Action Rule**: Trampolines immediately `@ptrCast(@alignCast(data))` to the owning Zig session struct and delegate to typed Zig methods. Never allocate inside protocol event callbacks without explicit error handling.

### Boundary 2: Linux DMA-BUF & DRM/VAAPI Hardware Context
- **Files**: `src/encode/`
- **ABI Constraints**:
  - `AVDRMFrameDescriptor` / `AVHWDeviceContext` / `AVHWFramesContext` / `VADisplay` operate on kernel file descriptors and C structs (`AV_PIX_FMT_DRM_PRIME` -> `AV_PIX_FMT_VAAPI`).
  - **Action Rule**: Wrap `AVBufferRef*`, `AVFrame*`, and DMA-BUF `fd`s in Zig `OwningHandle` structs with deterministic `deinit()` + `errdefer`. Never fall back silently to CPU `sws_scale` copies on the primary VAAPI path.

### Boundary 3: FFmpeg Muxer & Network I/O (`libavformat` / `libavcodec`)
- **Files**: `src/encode/`, `src/mux/`
- **ABI Constraints**:
  - `AVFormatContext*`, `AVCodecContext*`, `AVPacket*`, `AVDictionary*`, and custom `avio_alloc_context` callbacks use C integer error codes (`AVERROR(...)`).
  - **Action Rule**: Translate FFmpeg negative error codes into typed Zig error unions at the boundary (`avCheck(rc)`). Always free `AVDictionary` and flush/close `avio` handles via `defer`/`errdefer`.

### Boundary 4: Real-Time Audio Capture (PipeWire / PulseAudio)
- **Files**: `src/audio/`
- **ABI Constraints**:
  - Audio callbacks (`pa_stream_set_read_callback` / `pw_stream_events.process`) execute on real-time audio threads with `callconv(.c)` trampolines.
  - **Action Rule**: Copy PCM payload into the pre-allocated lock-free `AudioRingBuffer` and return immediately. Zero heap allocations and zero blocking locks inside the callback.

### Boundary 5: POSIX Signals, Event Loop & Pointer Telemetry
- **Files**: `src/cli/`, `src/telemetry/`
- **ABI Constraints**:
  - Signal handlers (`SIGINT`, `SIGTERM`), `poll()` / `eventfd`, and `libinput` / Wayland seat events interact with Linux kernel syscalls and C structs.
  - **Action Rule**: Signal handlers must be `callconv(.c)` async-signal-safe functions writing only to an atomic stop flag or `eventfd` pipe.

---

## 3. Pure Zig Domain (Outside Boundaries)

Code outside the five C-ABI boundaries (`src/common/`, CLI config/validation, VFR clock math, rate-control calculation, JSONL telemetry formatting) must be pure Zig:
- No `?*anyopaque` type erasure unless required by a genuine multi-implementation interface.
- No C-style `[*c]const u8` string manipulation; convert at the boundary via `std.mem.span` into `[]const u8`.
- Explicit `std.mem.Allocator` parameters and exhaustive `switch` statements.
