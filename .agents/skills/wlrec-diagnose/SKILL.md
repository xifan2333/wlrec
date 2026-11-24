---
name: wlrec-diagnose
description: "Diagnose Wayland copy-capture, DMA-BUF/VAAPI zero-copy, A/V sync, RTMP drop, or CI failures. 触发：排查崩溃、卡顿、花屏、音画不同步、断流、/wlrec-diagnose。"
---

# Wayland / VAAPI / Media Forensics Loop

Diagnostic workflow for capture, encoding, A/V sync, RTMP, and CI defects.

## 1. Isolate the Failing Layer

| Symptom | Primary Layer | First Probe |
| --- | --- | --- |
| Protocol missing / `capture` fails immediately | Wayland (`src/capture/`) | `wlrec probe`, `WAYLAND_DISPLAY`, `river -version` |
| Black/corrupted frames or high CPU usage | DMA-BUF / VAAPI (`src/encode/`) | `vainfo`, DRM fourcc + modifier negotiation, `DRM_PRIME` -> `VAAPI` mapping |
| A/V drift, audio crackling, or dropped audio | Audio / Clock (`src/audio/`, `src/common/`) | `AudioRingBuffer` overruns, `VfrClock` PTS vs audio PTS delta |
| RTMP stutter, lag, or disconnect | Mux / Rate Control (`src/mux/`, `src/common/`) | `maxrate`/`bufsize` vs uplink, packet drop counters, `avio` reconnect logs |
| Telemetry misaligned with video | Telemetry (`src/telemetry/`) | `t_ms` monotonic anchor vs `VfrClock` `t0` |

## 2. Capture Objective Evidence

1. Reproduce with minimal flags and record structured logs to `/tmp/wlrec-diag.log` (or a Herdr split pane per `execution-adapters.md` section 3).
2. Inspect output streams with `ffprobe -show_packets -show_frames` to distinguish VFR PTS gaps from dropped frames or muxer timestamp skew.
3. Never guess root cause without checking exact error codes (`AVERROR` / Wayland protocol error / VAStatus).

## 3. Fix & Immunize

1. Trace all callers and fix the root cause once under `laziness-protocol.md`.
2. Add a regression unit test in the owning module (`src/common/` or subsystem test).
3. If the fault revealed a mechanical or governance gap, feed it into `wlrec-retro`.
