#!/usr/bin/env bash
# End-to-end: runs the real pocock driver, through the same
# `archimedes run-driver` seam a context-mapping pass uses, against a
# throwaway git repo. Exercises the fixed-location contract's actual
# guarantees: the canonical CONTEXT.md lands in the control repo (here,
# $WORK) and the target repo is left with no trace of the run -- not of the
# map, and not of anything else the session decided to write.
#
# This makes a real, billed `claude -p` call, so it's opt-in: set
# ARCHIMEDES_TEST_LIVE_DRIVERS=1 to run it. Skips with a clear message
# otherwise, same spirit as openspec-driver-e2e.sh skipping when the
# openspec CLI isn't on PATH.
#
# Skipping here is not the same as being uncovered, and the two halves are
# worth keeping straight. The driver's own orchestration -- run the session
# in the target repo, honour the fixed-location contract, refuse to report
# success when the session wrote nothing -- is exercised on every push by
# tests/pocock_driver_run.sh, against a stub `claude`. What only this file
# can tell you is the upstream half: that the real CLI still takes these
# flags, and that the domain-modeling skill still reads the repo and writes
# a context map with the repo's domain in it -- which is why the assertions
# below go past "a file exists" to what is in it. That is the part worth
# paying for, and it runs weekly in .github/workflows/live-drivers.yml
# rather than never.
#
# The pristine-repo assertions at the bottom are here for the same reason.
# The stub session writes an ADR because that is what the driver's prompt
# argues with; a real one may write something nobody thought to forbid, and
# only a run against the real skill puts that question to the real skill.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

if [ "${ARCHIMEDES_TEST_LIVE_DRIVERS:-0}" != "1" ]; then
  echo "skip: pocock-driver-e2e.sh (makes a real claude -p call -- set ARCHIMEDES_TEST_LIVE_DRIVERS=1 to run it; runs weekly in .github/workflows/live-drivers.yml, and tests/pocock_driver_run.sh covers this driver's orchestration for free)"
  exit 77
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "skip: pocock-driver-e2e.sh (claude CLI not on PATH -- npm install -g @anthropic-ai/claude-code; runs weekly in .github/workflows/live-drivers.yml)"
  exit 77
fi

build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/throwaway-repo"
make_widget_repo "$REPO"

echo "pocock driver end-to-end:"

OUT="$WORK/CONTEXT.md"
if "$ARCHIMEDES_BIN" run-driver --root "$WORK" pocock "$REPO" "$OUT" >"$WORK/run.log" 2>&1; then
  pass "driver run exits zero against a throwaway repo"
else
  fail "driver run exits zero against a throwaway repo"
  cat "$WORK/run.log" >&2
fi

assert_file_exists "$OUT" "context map lands at the exact requested path in the control repo"

# What the billed call is actually for. An empty file, or one that never
# mentions the single domain term in the repo it was pointed at, satisfies
# "the driver produced a file" while telling us nothing about whether the
# skill still works -- and "the driver produced a file" is already proved
# for free by tests/pocock_driver_run.sh against a stub. This is the
# assertion that needs a real session, and the counterpart of the
# placeholder check the spec-kit live test makes on its constitution.
content="$(cat "$OUT" 2>/dev/null)"
if [ -s "$OUT" ]; then
  pass "the harvested context map has something in it"
else
  fail "the harvested context map has something in it (empty file)"
fi
# make_widget_repo's whole domain is one class called Widget. A context map
# of that repo that never says the word did not read it.
if printf '%s' "$content" | grep -qi 'widget'; then
  pass "the map names the domain it was asked to map, so a real session read the repo"
else
  fail "the map names the domain it was asked to map, so a real session read the repo"
  printf '%s\n' "$content" >&2
fi

status="$(git -C "$REPO" status --porcelain)"
assert_eq "$status" "" "target repo has no trace of the run after harvesting (clean git status)"
assert_file_missing "$REPO/CONTEXT.md" "CONTEXT.md is gone from the target repo, not just untracked"
# A real session that wrote an ADR, a settings file or a second markdown
# file it thought was a favour fails the run before reaching here; what this
# asks is whether the repo came out untouched either way -- empty
# directories, which `git status` cannot see, included.
assert_widget_repo_pristine "$REPO" "live run"

report
