# wlrec Agent Guide

Routing index. Execution detail lives behind the pointers below.

> Language: reply in the user's conversational language.

## Module Boundaries

- `src/c/` — curated C-ABI header boundary (`c_deps.h`) & `wayland-scanner` protocol bindings
- `src/common/` — pure domain types, VFR clock math, rate-control profiles, SPSC ring buffer, structured logging
- `src/capture/` — Wayland `ext-image-copy-capture-v1` & `zwp_linux_dmabuf_v1` zero-copy capture session
- `src/encode/` — `DRM_PRIME` -> `VAAPI` hardware frame import & video encoding
- `src/audio/` — real-time PCM capture, lock-free SPSC pump, and AAC encoding
- `src/mux/` — local file (`.mp4`/`.mkv`/`.flv`) & `rtmp://` streaming muxer
- `src/telemetry/` — normalized pointer/click/key JSONL sidecar logger
- `src/cli/` — CLI entrypoint, argument parsing, and environment `probe`

## Hard Invariants

1. **Bootstrap Gate** — on any development, bug-fix, or refactoring task, read
   `.agents/skills/wlrec-dev/SKILL.md` before searching, editing, or branching.
2. **Issue Anchor** — every functional change traces to an existing Issue.
3. **Draft PR First** — an empty commit and an all-unchecked checklist exist before
   any functional code.
4. **Single Writer in Lockstep** — one commit per checklist item, pushed together
   with its checkbox.
5. **Fast Local Gates** — locally run `mise run fix && mise run check:changed`
   and targeted unit tests; keep heavy release builds in CI unless hardware
   capture verification is explicitly needed.

## Intent Routing

| Intent | Pointer |
| --- | --- |
| Develop, fix, refactor | `.agents/skills/wlrec-dev/SKILL.md` |
| Review, PR gate, bot triage | `.agents/skills/wlrec-review/SKILL.md` |
| Wayland, VAAPI, A/V sync, RTMP fault | `.agents/skills/wlrec-diagnose/SKILL.md` |
| Session retro, rule evolution | `.agents/skills/wlrec-retro/SKILL.md` |
| Architectural judgement | `CODING_STANDARDS.md` (review phase only) |
| Domain vocabulary | `GLOSSARY.md` |
