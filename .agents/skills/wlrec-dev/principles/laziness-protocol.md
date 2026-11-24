# Laziness Protocol & Minimal Complete Change Principle

Authoritative engineering principle for `wlrec`.

> *"The best code is the code you never wrote. Solve the whole problem with the least new code."*

---

## 1. Core Rule: The Smallest Complete Change

Whenever designing, implementing, or reviewing code changes, take the first option that fully works:

1. **Does it need to exist?** Skip features, flags, and speculative flexibility nobody asked for. Reject "for later" code.
2. **Reuse existing project infrastructure**: Use canonical utilities in `src/common/` (ring buffers, VFR clock, rate-control math, structured logger). Never write ad-hoc parsers or duplicate resource wrappers.
3. **Use standard Zig & curated C libraries**: If Zig `std` or `c` (`libav*`, `wayland-client`, `libva`, `libdrm`) provides the capability directly, do not re-invent it.
4. **Prefer direct clarity**: Write the simplest code a reader understands at a glance.
5. **Deletion beats addition**: Eliminating dead code, unused parameters, and obsolete wrappers is strictly superior to adding layers. The shortest working diff wins.

---

## 2. Scope vs. Bloat

- **What Scope IS**: All places the change must reach to be complete and correct—callers, tests, `deinit()` / `errdefer` cleanup paths, CLI flags, and edge-case error handling.
- **What Scope IS NOT**: Refactoring unrelated code, adding unrequested configuration toggles, building speculative abstraction layers, or reformatting untouched files.

---

## 3. Bug Fixes: Root-Cause Once

Before editing any bug fix:
1. Search all callers (`git grep` / `rg`) of the affected function or symbol.
2. Fix the root cause once in the owning module.
3. Never plaster over defects by scattering redundant null checks or fallback copies across callers when the invalid state is illegitimate.

---

## 4. Transparent Reporting Protocol

Every implementation reply and PR summary must end with 1–2 transparent lines answering:
- **What was skipped or left unverified** (e.g., live RTMP ingest, multi-output scaling, cursor session on hardware without DRM modifier support).
- **Known risks or trade-offs** the maintainer must know before merging.
