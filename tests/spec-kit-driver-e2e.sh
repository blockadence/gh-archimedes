#!/usr/bin/env bash
# End-to-end: runs the real spec-kit driver, through the same
# `archimedes run-driver` seam a context-mapping pass uses, against a
# throwaway git repo. This is the hardest case for the fixed-location
# contract's guarantees -- the driver has to unpack a whole toolchain into
# the target repo to produce anything -- so the assertions are the same ones
# the pocock driver has to satisfy: the canonical artifact lands in the
# control repo (here, $WORK), and the target repo is left with no trace of
# the run at all.
#
# This makes a real, billed `claude -p` call and downloads Spec Kit's
# templates, so it's opt-in: set ARCHIMEDES_TEST_LIVE_DRIVERS=1 to run it.
# Skips with a clear message otherwise, same as pocock-driver-e2e.sh.
#
# The driver's own orchestration -- snapshot, scaffold, restore, and every
# failure path -- is exercised on every push by tests/spec_kit_driver_run.sh
# against stub CLIs. This file adds the half that needs the real tools, and
# runs weekly in .github/workflows/live-drivers.yml.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

if [ "${ARCHIMEDES_TEST_LIVE_DRIVERS:-0}" != "1" ]; then
  echo "skip: spec-kit-driver-e2e.sh (makes a real claude -p call -- set ARCHIMEDES_TEST_LIVE_DRIVERS=1 to run it; runs weekly in .github/workflows/live-drivers.yml, and tests/spec_kit_driver_run.sh covers this driver's orchestration for free)"
  exit 77
fi

if ! command -v specify >/dev/null 2>&1; then
  echo "skip: spec-kit-driver-e2e.sh (specify CLI not on PATH -- uv tool install specify-cli --from git+https://github.com/github/spec-kit.git; runs weekly in .github/workflows/live-drivers.yml)"
  exit 77
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "skip: spec-kit-driver-e2e.sh (claude CLI not on PATH -- npm install -g @anthropic-ai/claude-code; runs weekly in .github/workflows/live-drivers.yml)"
  exit 77
fi

build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/throwaway-repo"
make_widget_repo "$REPO"

echo "spec-kit driver end-to-end:"

OUT="$WORK/CONTEXT.md"
if "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" >"$WORK/run.log" 2>&1; then
  pass "driver run exits zero against a throwaway repo"
else
  fail "driver run exits zero against a throwaway repo"
  cat "$WORK/run.log" >&2
fi

assert_file_exists "$OUT" "context map lands at the exact requested path in the control repo"

content="$(cat "$OUT" 2>/dev/null)"
assert_contains "$content" "Constitution" "the harvested artifact is Spec Kit's constitution"
# The scaffolded template is nothing but [ALL_CAPS] placeholders, so a
# constitution still carrying them is one nobody filled in. The Sync Impact
# Report is skipped when checking: it legitimately names the tokens it
# replaced, which is the opposite of the problem being looked for.
body="$(awk '/<!--/{c=1} !c; /-->/{c=0}' "$OUT")"
if printf '%s' "$body" | grep -qE '\[[A-Z][A-Z0-9_]+\]'; then
  fail "the constitution's placeholder tokens were filled in, not harvested as-scaffolded"
  printf '%s\n' "$body" | grep -E '\[[A-Z][A-Z0-9_]+\]' >&2
else
  pass "the constitution's placeholder tokens were filled in, not harvested as-scaffolded"
fi

status="$(git -C "$REPO" status --porcelain)"
assert_eq "$status" "" "target repo has no trace of the artifact after harvesting (clean git status)"
assert_file_missing "$REPO/.specify/memory/constitution.md" \
  "the constitution is gone from the target repo, not just untracked"

# git status can't see these: it doesn't track directories at all, so a
# scaffolded toolchain left behind in empty (or ignored) directories would
# pass the check above while very much still being there.
assert_dir_missing "$REPO/.specify" \
  "Spec Kit's own .specify/ scaffolding is stripped back out of the target repo"
assert_dir_missing "$REPO/.claude" \
  "the speckit-* agent skills Spec Kit installed are stripped back out of the target repo"
assert_eq "$(cd "$REPO" && ls -A | sort | tr '\n' ' ')" ".git src " \
  "the target repo holds exactly what it held before the run"

report
