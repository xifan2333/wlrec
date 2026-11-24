# Module Boundaries, Complexity Budgets, and Resource Trade-offs

Authoritative architectural specification governing module layering and objective complexity gates in `wlrec`.

---

## 1. Architectural Boundary Mandate: `src/common/` vs. Subsystems

`wlrec` enforces strict separation between pure shared infrastructure (`src/common/`) and C-ABI/domain subsystems (`src/capture/`, `src/encode/`, `src/audio/`, `src/mux/`, `src/telemetry/`, `src/cli/`).

```
                    ┌────────────────────────────────────────────────────────┐
                    │      src/common/ (Pure Zig Shared Infrastructure)      │
                    │  - VfrClock (PTS normalization & interval clamping)    │
                    │  - RateControlProfile (VBR/CBR/CQP parameter math)     │
                    │  - SpscRingBuffer (lock-free, zero-alloc queue)        │
                    │  - Structured Logger (non-blocking stderr/json log)    │
                    │  - Config & Types (validated domain value types)       │
                    └────────────────────────────────────────────────────────┘
                                   ▲            ▲            ▲
       ┌───────────────────────────┴──┐         │         ┌──┴───────────────────────────┐
       │                              │         │         │                              │
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
│ src/capture/ │  │  src/encode/ │  │  src/audio/  │  │   src/mux/   │  │  src/telemetry/  │
│ Wayland Copy │  │  DRM->VAAPI  │  │ RT PCM Pump  │  │ File / RTMP  │  │ Pointer JSONL    │
└──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────────┘
       ▲                                                                         ▲
       └──────────────────────────────────┬──────────────────────────────────────┘
                                   ┌──────────────┐
                                   │   src/cli/   │
                                   │ Args & Probe │
                                   └──────────────┘
```

### A. Common Infrastructure (`src/common/`) Contracts
1. **Zero C-ABI Dependency**: Modules in `src/common/` must remain pure Zig primitives. They must never import `c`, Wayland protocols, FFmpeg headers, or depend on `capture/`, `encode/`, `audio/`, `mux/`, `telemetry/`, or `cli/`.
2. **Testability Without Hardware**: All clock math, rate-control calculations, ring-buffer mechanics, and telemetry serialization must be unit-testable in pure `zig build test` without a running Wayland compositor or VAAPI GPU.

### B. Subsystem Contracts
1. **Single Responsibility per Boundary**: Each subsystem owns one C-ABI/hardware domain and exposes clean Zig owning types (`init` / `deinit`) to the pipeline coordinator.
2. **No Cross-Subsystem Backdoors**: `capture/` does not talk directly to `mux/`; `audio/` does not touch `encode/` video contexts; `telemetry/` does not block `capture/`.

---

## 2. Objective Complexity Gates

Code simplicity is enforced mechanically via `lizard` and `ast-grep`:

- **Cyclomatic Complexity**: $\text{CCN} \le 15$
- **Cognitive Complexity**: $\text{CogC} \le 15$
- **Nesting Ceiling**: $\le 2$ levels inside happy-path bodies; use `errdefer`, early `return`, and helper extraction to keep functions flat.
- **No Silent Error Swallowing**: `catch {}` is rejected by `ast-grep`.

---

## 3. Allocation & Zero-Copy Budgets

1. **Pre-allocate Pools Once**: Ring buffers, frame pools, and JSONL formatting scratch buffers are allocated once during session `init()`, never per video frame or audio buffer.
2. **Slice Views (`[]const u8`)**: Pass slices by value; avoid temporary heap string copies in telemetry or CLI formatting.
3. **Bounded Queues**: Every inter-thread queue (audio PCM, encoded packets, telemetry events) has a fixed capacity and an explicit overflow policy.
