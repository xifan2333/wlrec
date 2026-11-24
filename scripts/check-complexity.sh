#!/usr/bin/env bash
# Analyzes cyclomatic and cognitive complexity across modified or specified Zig/C files.
# Uses lizard with cognitive complexity extension (-Ecognitive).
#
# Usage:
#   scripts/check-complexity.sh           # Audit changed .zig/.c/.h files vs origin/main + working tree
#   scripts/check-complexity.sh --all     # Audit all Zig/C files under src/
#   scripts/check-complexity.sh <file>…   # Audit specific files
set -euo pipefail

ALL=0
FILES=()
for arg in "$@"; do
  case "$arg" in
  --all) ALL=1 ;;
  *) FILES+=("$arg") ;;
  esac
done

if [ "$ALL" -eq 1 ]; then
  if [ -d src ]; then
    mapfile -t FILES < <(find src -type f \( -name '*.zig' -o -name '*.c' -o -name '*.h' \) | sort)
  fi
elif [ "${#FILES[@]}" -eq 0 ]; then
  BASE_REF=""
  if git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null 2>&1; then
    BASE_REF="$(git merge-base HEAD origin/main 2>/dev/null || echo origin/main)"
  fi
  mapfile -t FILES < <({
    if [ -n "${BASE_REF}" ]; then
      git diff --name-only "${BASE_REF}"
    fi
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | grep -E '^(src|tests)/.*\.(zig|c|h)$' | sort -u || true)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No modified Zig/C files to audit for complexity."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NORMALIZED_FILES=()
for f in "${FILES[@]}"; do
  if [ -e "$f" ]; then
    NORMALIZED_FILES+=("$(realpath --relative-to="${REPO_ROOT}" "$f" 2>/dev/null || echo "$f")")
  fi
done

if [ "${#NORMALIZED_FILES[@]}" -eq 0 ]; then
  echo "No existing Zig/C files to audit for complexity."
  exit 0
fi

cd "${REPO_ROOT}"
echo "Auditing complexity on ${#NORMALIZED_FILES[@]} file(s) (CCN <= 15, CogC <= 15)..."
lizard -Ecognitive -C 15 -T "cognitive_complexity=15" "${NORMALIZED_FILES[@]}"
