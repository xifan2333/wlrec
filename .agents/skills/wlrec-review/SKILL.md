---
name: wlrec-review
description: "Review diffs along dual axes (Spec + Standards) and triage bot comments. 触发：代码审查、双轴评审、审查机器人对质、/wlrec-review。"
---

# Offline Dual-Axis Code Review & Bot Triage

Independent static diff review along two separate axes, plus dialectical review bot triage:

- **Spec Axis**: Verify diff against originating issue requirements and scope boundaries.
- **Standards Axis**: Audit diff against `CODING_STANDARDS.md` and Fowler code smell heuristics.
- **Review Bot Triage**: Three-way classification (`[FIX] / [DISMISS] / [ASK]`) guarding against AI slop and bot hallucinations.

---

## 1. Dual-Axis Static Review (Pre-Ready Gate)

Run in two parallel, isolated read-only subagents.

### Step 1: Pin Diff & Merge Base
```bash
git diff $(git merge-base main HEAD)...HEAD
git log $(git merge-base main HEAD)..HEAD --oneline
```
*Completion criterion*: Confirmed non-empty diff and valid merge-base.

### Step 2: Spawn Parallel Subagents
Spawn both subagents concurrently with fresh context windows:

1. **Subagent A (Spec Verification)**:
   - *Injected Context*: Full diff command, commit list, originating Issue body or Draft PR checklist.
   - *Prompt*: "Report under 400 words: (a) explicit requirements missed or partial; (b) unrequested behavior or scope creep; (c) logic that deviates from specification. Quote the issue requirement and diff hunk."
2. **Subagent B (Standards & Architecture Audit)**:
   - *Injected Context*: Full diff command, commit list, `CODING_STANDARDS.md`.
   - *Prompt*: "Report under 400 words: (a) breaches of documented standards (Deep modules, Seam discipline, lock-free/zero-alloc RT audio & capture paths, DMA-BUF zero-copy invariant, C-ABI `deinit()`/`errdefer` ownership); (b) Fowler smells. Skip anything tooling enforces (zig fmt, AST rules, complexity <= 15). Quote diff hunks."

### Step 3: Aggregate Findings
Present reports side-by-side without merging or reranking:

```markdown
## Spec Audit
- [Pass | Concern]: <Finding with citation of diff hunk and issue requirement>

## Standards Audit
- [Hard Violation]: <Breach of CODING_STANDARDS.md with file:line>
- [Judgement Smell]: <Fowler smell or architectural observation>

## Verdict
- [Ready | Action Required]: <Single-line summary of blocking items, if any>
```

---

## 2. Code Duplication Triage Protocol (S2.5 Anti-Slop Gate)

Before finalizing PR readiness, run duplication analysis:
```bash
mise run check:dup
```

When clones are detected in touched files:
1. **Type A (Procedural Duplication / AI Slop)**: Copy-pasted algorithms, error wrappers, or ring-buffer helpers. Consolidate into `src/common/`.
2. **Type B (Legitimate Domain Boilerplate)**: Wayland listener vtables, CLI option tables, or C-struct field mappings where artificial abstraction hurts clarity.
3. **Mandatory Pre-Action Report to Maintainer (Awaiting Confirmation)** before modifying code.

---

## 3. Review Bot Dialectical Triage Protocol

When automated bots post comments, classify every finding into:
1. **`[FIX]`**: Real FD/memory leak, missing `errdefer`, data race, DMA-BUF lifetime bug, or logic defect.
2. **`[DISMISS]`**: Hallucinations urging heap allocations/mutexes in RT audio/frame callbacks, removing `callconv(.c)` / `?*anyopaque` at Wayland/FFmpeg boundaries, or adding redundant checks inside trusted internals.
3. **`[ASK]`**: Ambiguous product trade-offs or naming choices.

Deliver the triage report and wait for maintainer confirmation before applying fixes.
