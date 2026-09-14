#!/usr/bin/env bash
# End-to-end: runs the real openspec driver, through the same
# `archimedes run-driver` seam a context-mapping pass uses, against a
# throwaway git repo. Requires the `openspec` CLI on PATH (npm install -g
# @fission-ai/openspec); skips with a clear message if it isn't available
# rather than failing the suite -- exit 77, which run-all.sh counts as a
# skip and names in its summary rather than folding into "0 failed".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

if ! command -v openspec >/dev/null 2>&1; then
  echo "skip: openspec-driver-e2e.sh (openspec CLI not on PATH — npm install -g @fission-ai/openspec)"
  exit 77
fi

build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/throwaway-repo"
mkdir -p "$REPO/src"
echo "console.log('hi')" > "$REPO/src/index.js"
make_repo_at "$REPO"

echo "openspec driver end-to-end:"

OUT="$WORK/CONTEXT.md"
if "$ARCHIMEDES_BIN" run-driver --root "$WORK" openspec "$REPO" "$OUT" >"$WORK/run.log" 2>&1; then
  pass "driver run exits zero against a throwaway repo"
else
  fail "driver run exits zero against a throwaway repo"
  cat "$WORK/run.log" >&2
fi

assert_file_exists "$OUT" "context map lands at the exact requested path"
content="$(cat "$OUT" 2>/dev/null)"
assert_contains "$content" "Context map for throwaway-repo" "context map is stamped with the repo it was generated for"
assert_contains "$content" "OpenSpec root" "context map contains OpenSpec's own working-context report"

report
