# Coding Standards

Authoritative engineering rules for code review in `wlrec`.

> **Implementation vs. Review Notice**:
> - **Implementation Agents**: Keep context focused on minimal working diffs under `.agents/skills/wlrec-dev/principles/laziness-protocol.md`. Do not pre-load this entire file during active coding.
> - **Review Agents (`wlrec-review`) & Human Reviewers**: Audit diffs against the judgement standards below.
> - **Mechanical Checks**: Formatting, AST patterns, cognitive complexity, duplication, and spelling are strictly enforced by automated tooling (`mise run check:changed`). Reviewers skip anything tooling already enforces.

---

## 1. Architecture & Module Depth

### Modules must be deep, not shallow
Favor deep modules: substantial functionality hidden behind a compact, intuitive interface. Avoid shallow wrappers—structs or functions whose interface is as complex as their implementation, or one-line forwarding adapters that merely pass parameters through.

- **The Cost**: Shallow modules inflate cognitive load, scatter domain logic across files, and obscure resource ownership.
- **Review Test**: The Deletion Test—does deleting the wrapper concentrate complexity into one cohesive unit, or merely shift it?

### State Machines must be Deep: Encapsulate transitions and actions
State machines must not be anemic flag emitters. Avoid designs where a state machine merely returns a struct of boolean flags (e.g., `should_reconnect`, `should_drop_frame`) and forces callers into cascading `if` trees to execute transitions.

- **Review Test**: Does the state machine directly drive the lifecycle transition and own its state invariants, or does it leak booleans that force callers to write `if/else` ladders?

### Seam Discipline & The Single-Implementation Rule
Never introduce a vtable, `anyopaque` interface, or function-pointer indirection solely to facilitate mocking in unit tests.

- **Rule of Two**: One implementation represents a hypothetical seam; at least two genuine production implementations justify an interface (e.g., local file muxer vs RTMP muxer, or output capture source vs toplevel capture source).
- **Test Surface**: The production interface is the test surface. Tests verify observable behavior through public APIs using deterministic inputs, temporary files, or in-process loopback sockets—never through test-only backdoors.

### Boundary Discipline: Guard the edges, trust the internals
Concentrate defensive checks, argument validation, and C error-code translation strictly at system boundaries (CLI parser, Wayland protocol events, FFmpeg return codes, audio callbacks, file/network I/O). Once validated and translated into domain types, internal pure functions trust their inputs without redundant defensive checks.

---

## 2. Real-Time Capture, GPU Zero-Copy & Audio Thread Safety

### Hot paths must be lock-free and allocation-free
Real-time audio callbacks, Wayland frame callbacks, and pointer telemetry hooks must never allocate heap memory (`std.mem.Allocator`) or acquire blocking mutexes.

- **Audio**: Transfer PCM frames from the audio thread via a pre-allocated lock-free SPSC ring buffer (`AudioRingBuffer`).
- **Telemetry**: Push `TelemetryEvent` records into a bounded pre-allocated ring buffer; drop/coalesce `move` events on overflow rather than blocking capture.

### Zero-Copy DMA-BUF Invariant
The primary capture path must keep video frames in GPU memory from compositor DMA-BUF export through `AV_PIX_FMT_DRM_PRIME` -> `AV_PIX_FMT_VAAPI` hardware encoding.

- Never silently fall back to CPU `mmap` / `sws_scale` pixel copies on the primary VAAPI path.
- Always release/close DMA-BUF file descriptors and `ext_image_copy_capture_frame_v1` objects deterministically on both `ready` and `failed` events.

### Non-Stalling Capture Loop
Compositor frame delivery and audio capture must never block indefinitely on slow disk I/O or RTMP uplink stalls. Bound encoder/muxer queues and handle backpressure explicitly via `RateControlProfile` and `MuxSink` drop/reconnect policy.

---

## 3. C-ABI Boundaries & Resource Lifetimes

### Exclusive resource ownership via `deinit()` + `errdefer`
Raw owning C pointers and raw POSIX file descriptors must never float across module boundaries. Wrap every C resource (`wl_display`, `AVFormatContext`, `AVCodecContext`, `AVFrame`, `AVPacket`, `dma-buf` fds, audio handles) in an `OwningHandle` struct with `deinit()` immediately upon acquisition, paired with `errdefer` on multi-step initialization.

### Hard C-ABI Isolation
Keep `callconv(.c)` Wayland/FFmpeg/Audio trampolines strictly in boundary adapter files (`src/capture/`, `src/encode/`, `src/audio/`). Trampolines must immediately convert raw C pointers and status integers into typed Zig methods—never propagate `?*anyopaque` or raw C structs into `src/common/` or `src/cli/`.

### Single `c` Translation Unit
All `@cImport` / C library header includes live behind `src/c/c_deps.h` exposed as the `c` build module. Scattered `@cImport` blocks across domain modules are prohibited (enforced mechanically by `ast-grep`).

---

## 4. Zig Control Flow & Idioms

### Exhaustive `switch` without catch-all `else =>`
On domain enums and tagged unions, omit `else =>` so the Zig compiler fails compilation whenever a new variant is added.

### Guard Clauses & Straight Happy Path
Precondition checks and error exits must return early (`return`, `continue`, `errdefer`). Keep the primary flow at root indentation (0–2 levels). Deep pyramid nesting ($\ge 4$ levels) is prohibited.

### Explicit Allocator & Explicit Error Unions
- Domain APIs that allocate must accept `allocator: std.mem.Allocator` explicitly; never hide global `page_allocator` / `c_allocator` inside helper functions.
- Silent error swallowing (`catch {}`) is prohibited (enforced mechanically by `ast-grep`). Handle, propagate (`try`), or explicitly log and recover.
- Avoid `@panic` in runtime code paths; return typed errors.

### Table-Driven Dispatch for homogeneous rules
For homogeneous CLI flags, pixel-format mappings, or protocol name matches ($N \ge 3$), prefer `comptime` lookup tables or `std.StaticStringMap` over procedural `if / else if` chains.

---

## 5. Dependencies & Protocol Build Boundary

- **Tier 1 (Host System Shared Libraries)**: `wayland-client`, `libavcodec`, `libavformat`, `libavutil`, `libavfilter`, `libdrm`, `libva`, `libva-drm`, `libpulse` (or `libpipewire-0.3`) resolved via host `pkg-config`.
- **Tier 2 (Build-Time Protocol Generation)**: Wayland staging/unstable XMLs from system `wayland-protocols` compiled at build time via `wayland-scanner` (`client-header` + `private-code`).
- Build-time network downloading is prohibited; builds must remain reproducible offline given system headers and Zig toolchain.

---

## 6. Fowler Code Smell Baseline

During review, evaluate the diff against these baseline heuristics:

- **Mysterious Name**: Name does not reveal what the entity does or holds.
- **Duplicated Code**: Identical logic structure appears in more than one place.
- **Feature Envy**: A function accesses fields of another struct more than its own.
- **Data Clumps**: The same group of parameters travels together repeatedly; encapsulate into a domain struct.
- **Primitive Obsession**: Raw `u32`/`i32`/strings stand in for domain concepts (`Fps`, `BitrateKbps`, `PtsNs`, `DrmFourcc`).
- **Repeated Switches**: Same conditional cascade recurs across call sites.
- **Shotgun Surgery**: One logical change forces scattered edits across unrelated files.
- **Divergent Change**: One module changes for unrelated reasons.
- **Speculative Generality**: Abstractions, flags, or hooks added for hypothetical future needs.
- **Middle Man**: A wrapper that merely delegates calls without adding ownership or invariant logic.

---

## Appendix: Automated Quality Gates

| Rule Category | Mechanical Enforcement | Command |
| :--- | :--- | :--- |
| **AST Anti-Patterns** | `ast-grep` (no `catch {}`, no scattered `@cImport`, no `std.debug.print`, no `@panic`, nesting depth) | `mise run check:ast` |
| **Complexity Ceiling** | `lizard` ($\text{CCN} \le 15, \text{CogC} \le 15$) | `mise run check:complexity` |
| **Code Duplication** | `jscpd` across `src/` | `mise run check:dup` |
| **Code Formatting** | `hk` (`zig fmt`, `clang-format`, `shfmt`, `prettier`) | `mise run fix` / `check:changed` |
| **Typos & Spelling** | `typos` | `mise run check:typos` |
