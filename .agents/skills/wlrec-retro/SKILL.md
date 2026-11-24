---
name: wlrec-retro
description: "Encode post-session lessons into ast-grep rules, hooks, and standards refinement. 触发：会话复盘、规则免疫、/wlrec-retro。"
---

# Retrospective & Self-Evolution Engine

Post-session retrospective engine to analyze defects, CI failures, or review findings, converting lessons into permanent engineering guardrails.

---

## 1. Failure Analysis

Identify the root cause of the miss:
- What failed or required repeated correction? (Zig compiler error, C-ABI translation bug, CI failure, reviewer finding, runtime defect).
- What allowed the defect through? (Missing linter check, ambiguous pointer, architectural judgement gap, or stale rule).

*Completion criterion*: Defect categorized into mechanical gap vs architectural judgement gap.

---

## 2. Four-Tier Enforcement Pipeline

Route the lesson strictly into one of the four categories:

### Tier 1: Structural Enforcement (Mechanical Rule)
*If a machine can check it, never write a natural language instruction.*
- If the fault is a fixed syntax pattern, banned API, or unsafe call:
- **Action**: Author a new `ast-grep` rule under `.ast-grep/rules/<rule-name>.yml` (plus unit test under `.ast-grep/tests/`), or add a check to `mise run check:changed`.
- **Constraint**: Do not add text warnings to `AGENTS.md` or `CODING_STANDARDS.md`.

### Tier 2: Navigation Refinement (Information Access)
- If the agent struggled to locate a file or lacked context:
- **Action**: Add or sharpen a navigation pointer in `AGENTS.md` or `GLOSSARY.md`.

### Tier 3: Standards Calibration (Architectural Judgement)
- If the fault was an architectural misjudgement (shallow module, leaked FD/AVFrame, blocking lock on RT path):
- **Action**: Update `CODING_STANDARDS.md` with a concise definition and an anti-pattern example.

### Tier 4: Pruning (Sediment Removal)
- Review existing instructions in `AGENTS.md` and `CODING_STANDARDS.md`:
- **Action**: If a rule is now enforced by `ast-grep`, compiler options, or is followed by default, delete it from prose.

*Completion criterion*: Exactly one tier selected and concrete artifact drafted.

---

## 3. Proposal Delivery

Deliver a concise retrospective report:
- **Observed Defect**: The exact failure and why it occurred.
- **Classification**: Structural | Navigation | Standards | Pruning.
- **Concrete Diff**: Provide the YAML rule, pointer edit, or documentation diff for review before applying.
