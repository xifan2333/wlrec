# Contributing

Thanks for contributing to `wlrec`!

## Development Toolchain

`wlrec` uses `mise` and `hk` to manage toolchain versions and fast local quality gates.

```bash
mise install
mise run hooks-install
```

## Build & Test

**System dependencies (Arch Linux):** `wayland`, `wayland-protocols`, `ffmpeg`, `libdrm`, `libva`, `libpulse` (or `pipewire`)

```bash
zig build
zig build test
```

## Quality Gates

Before committing or pushing:

```bash
mise run fix            # Format changed Zig/C/Shell/JSON files
mise run check:changed  # Run hk lint gates on modified/untracked files
mise run check:ast      # Audit Zig AST rules and run rule tests
mise run check:dup      # Analyze duplication across src/
```

## Workflow

1. Every change starts from a tracked GitHub Issue.
2. Open a feature branch `<type>/issue-<id>-<slug>` from `main`.
3. Create an empty commit and open a Draft PR with an unchecked task checklist before writing functional code.
4. Implement one checklist item per atomic commit following Conventional Commits.
5. Keep commits verified by `mise run check:changed` and targeted tests before marking PR ready.
