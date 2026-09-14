#!/usr/bin/env bash
# The spec-kit driver's own orchestration -- snapshot, scaffold, check the
# constitution actually got filled in, restore keeping only that one file --
# exercised against stub `specify` and `claude` CLIs. No network, no billed
# calls, so this runs in the normal suite; spec-kit-driver-e2e.sh covers the
# same shape against the real tools and is opt-in.
#
# The stubs matter more than they look: they're what makes the failure paths
# testable at all. A driver that unpacks a toolchain into someone else's
# repo has to put it back on *every* exit -- the tool failing, the agent
# doing nothing, someone hitting Ctrl-C halfway -- and none of those are
# reachable when the run costs money and takes minutes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_BIN="$ROOT/drivers/spec-kit/run.sh"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# Stands in for `specify init --here ...`: unpacks a miniature of the real
# layout -- a placeholder constitution, helper scripts, agent skills, and an
# empty directory -- into whatever repo it's run in.
cat > "$STUB_BIN/specify" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${SPECIFY_STUB_FAIL:-0}" = "1" ]; then
  echo "specify: could not download templates" >&2
  exit 1
fi
mkdir -p .specify/memory .specify/scripts/bash .specify/workflows/speckit .claude/skills/speckit-constitution
cat > .specify/memory/constitution.md <<'TEMPLATE'
# [PROJECT_NAME] Constitution

### [PRINCIPLE_1_NAME]
[PRINCIPLE_1_DESCRIPTION]
TEMPLATE
echo "resolver" > .specify/scripts/bash/resolve-template.sh
echo "feature.json" > .specify/.gitignore
echo "skill" > .claude/skills/speckit-constitution/SKILL.md
if [ "${SPECIFY_STUB_NO_CONSTITUTION:-0}" = "1" ]; then
  rm .specify/memory/constitution.md
fi
exit 0
STUB

# Stands in for the headless `claude -p` session. CLAUDE_STUB_MODE picks
# which way the session goes.
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${CLAUDE_STUB_MODE:-fill}" in
  fill)
    cat > .specify/memory/constitution.md <<'FILLED'
# Widget Catalog Constitution

### I. Zero-Dependency CommonJS Core
Every module stays dependency-free.
FILLED
    ;;
  noop)
    : ;;   # leaves the template exactly as specify unpacked it
  fail)
    echo "claude: session failed" >&2; exit 1 ;;
  commit)
    git add -A
    # Deliberately not the fixture's identity, as in pocock_driver_run.sh:
    # the case is a commit somebody else made in the operator's repo.
    git -c user.email=agent@example.com -c user.name=agent commit -qm "agent committed the scaffolding"
    echo "# filled" > .specify/memory/constitution.md
    ;;
  hang)
    # Does everything a successful session would first -- so if the
    # interrupt gets swallowed rather than acted on, the run finishes
    # normally and reports success, which is exactly the failure being
    # tested for. Then announces itself and sits in the foreground, so the
    # test can signal the driver while bash is blocked on a child, which is
    # where a real Ctrl-C lands.
    #
    # CLAUDE_STUB_ON_SIGNAL picks which of the two shapes an interrupted
    # session takes, because the driver has to survive both and only one of
    # them used to be exercised:
    #
    #   dies   killed by the signal, the shape the driver's rollback was
    #          originally reasoned about
    #   traps  catches it, shuts down cleanly and exits zero, which is what
    #          a well-behaved CLI does -- and what bash reads as "the child
    #          handled the interrupt", so the shell's own copy of it is
    #          dropped and the run carries on as if nothing happened
    cat > .specify/memory/constitution.md <<'FILLED'
# Widget Catalog Constitution

### I. Zero-Dependency CommonJS Core
Every module stays dependency-free.
FILLED
    if [ "${CLAUDE_STUB_ON_SIGNAL:-dies}" = "traps" ]; then
      trap 'touch "$CLAUDE_STUB_SENTINEL.signalled"; exit 0' INT TERM
    fi
    touch "$CLAUDE_STUB_SENTINEL"
    # Nothing releases this but the signal. The bound is a backstop for a
    # signal that never arrives, and it is long enough that hitting it is a
    # broken test rather than a slow machine -- the driver then finishes an
    # ordinary successful run, and the assertions below say so loudly.
    waited=0
    while [ "$waited" -lt 300 ]; do
      sleep 0.1; waited=$((waited + 1))
    done
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/specify" "$STUB_BIN/claude"

export PATH="$STUB_BIN:$PATH"

# Every case below starts from the same untouched repo and ends with the
# same question, asked by helpers.sh's assert_widget_repo_pristine: is it
# back exactly as it was found?
fresh_repo() { # <path>
  rm -rf "$1"
  make_widget_repo "$1"
}

REPO="$WORK/repo"

echo "spec-kit driver, successful run:"

fresh_repo "$REPO"
OUT="$WORK/CONTEXT.md"
if "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" >"$WORK/run.log" 2>&1; then
  pass "a run whose session fills the constitution in exits zero"
else
  fail "a run whose session fills the constitution in exits zero"
  cat "$WORK/run.log" >&2
fi
assert_file_exists "$OUT" "the constitution is harvested to the exact requested path"
assert_contains "$(cat "$OUT" 2>/dev/null)" "Zero-Dependency" \
  "the harvested file is what the session wrote, not the template specify unpacked"
assert_widget_repo_pristine "$REPO" "successful run"
assert_dir_missing "$REPO/.specify" "successful run: the scaffolding directory tree is gone, empty ones included"
assert_dir_missing "$REPO/.claude" "successful run: the installed agent skills are gone"

echo ""
echo "spec-kit driver, the session does nothing:"

fresh_repo "$REPO"
OUT="$WORK/noop.md"
if err="$(CLAUDE_STUB_MODE=noop "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session leaves the template untouched exits non-zero"
else
  pass "a run whose session leaves the template untouched exits non-zero"
fi
assert_contains "$err" "unfilled template" \
  "the failure says the session did nothing, rather than reporting a constitution that is really just placeholders"
assert_file_missing "$OUT" "a session that did nothing produces no output file"
assert_widget_repo_pristine "$REPO" "session did nothing"

echo ""
echo "spec-kit driver, the session fails:"

fresh_repo "$REPO"
OUT="$WORK/fail.md"
if CLAUDE_STUB_MODE=fail "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" >/dev/null 2>&1; then
  fail "a run whose session exits non-zero fails the driver too"
else
  pass "a run whose session exits non-zero fails the driver too"
fi
assert_file_missing "$OUT" "a failed session produces no output file"
assert_widget_repo_pristine "$REPO" "session failed"

echo ""
echo "spec-kit driver, specify itself fails:"

fresh_repo "$REPO"
OUT="$WORK/specify-fail.md"
if err="$(SPECIFY_STUB_FAIL=1 "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose specify init fails exits non-zero"
else
  pass "a run whose specify init fails exits non-zero"
fi
assert_contains "$err" "specify init failed" "the failure names the step that failed"
assert_file_missing "$OUT" "a failed specify init produces no output file"
assert_widget_repo_pristine "$REPO" "specify init failed"

echo ""
echo "spec-kit driver, specify scaffolds no constitution:"

fresh_repo "$REPO"
OUT="$WORK/no-constitution.md"
if err="$(SPECIFY_STUB_NO_CONSTITUTION=1 "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run where specify scaffolds no constitution exits non-zero"
else
  pass "a run where specify scaffolds no constitution exits non-zero"
fi
assert_contains "$err" "did not scaffold" "the failure names what specify was expected to produce"
assert_file_missing "$OUT" "no output file is produced"
assert_widget_repo_pristine "$REPO" "specify scaffolded no constitution"

echo ""
echo "spec-kit driver, the run replaces a constitution the repo already had:"

# The same note the pocock driver makes, asked of the other shipped driver
# because the mechanism is not that driver's. An operator with uncommitted
# work at .specify/memory/constitution.md is a good deal less likely than one
# with a hand-edited CONTEXT.md -- but "less likely" is not a reason for the
# helper to know which fixed_path it is answering for, and a driver that only
# reported the likely case would be the one that stopped reporting when a
# third driver arrived.
#
# Here `specify init` is what does the replacing, before the session has said
# anything: the scaffolded template lands on top of the operator's file and
# the session then fills that in. Which of the two wrote over it does not
# change what the operator lost.
fresh_repo "$REPO"
mkdir -p "$REPO/.specify/memory"
echo "the constitution I was half way through drafting" > "$REPO/.specify/memory/constitution.md"
OUT="$WORK/replaced.md"
if err="$("$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  pass "a run that replaced an uncommitted constitution still succeeds -- filling that file in is what the run is for"
else
  fail "a run that replaced an uncommitted constitution still succeeds -- filling that file in is what the run is for"
  printf '%s\n' "$err" >&2
fi
assert_file_exists "$OUT" "the constitution is harvested"
assert_contains "$(cat "$OUT" 2>/dev/null)" "Zero-Dependency" \
  "and it is the session's, not the version the operator had sitting there"
assert_contains "$err" ".specify/memory/constitution.md" \
  "the run says which file of the operator's it replaced, rather than leaving them to find it gone"
assert_contains "$err" "Commit it first" \
  "and says what would have kept it, since nothing here holds a copy of what it said"
assert_file_missing "$REPO/.specify/memory/constitution.md" \
  "the file really is gone from the repo -- replaced and then harvested away, which is why the run has to say so"
assert_widget_repo_pristine "$REPO" "run replaced a constitution the repo already had"

echo ""
echo "spec-kit driver, interrupted mid-run:"

# The case hand-placed error handling can't reach, and the reason rollback
# is the exit trap rather than something on the success path.
#
# It is run twice, because an interrupt reaches the driver in two shapes and
# the rollback has to cover both. The session dying from the signal is the
# one the driver was originally written against. The session catching the
# signal and exiting zero is the one that used to walk straight through it:
# bash defers a signal that arrives while it is waiting on a foreground
# child, and then decides what to do with it from how that child ended, so a
# session that shuts down cleanly makes the shell drop the operator's
# interrupt and finish the run.
#
# Which signal this gets decides what the `traps` shape below can see: under
# SIGINT it catches a driver that dropped its interrupt trap, and under
# SIGTERM it cannot. deliverable_interrupt has the reasoning, and issue 67
# the decision to write it down rather than chase it.
INTERRUPT="$(deliverable_interrupt)"
set_expected_status "$INTERRUPT"
announce_interrupt_fallback "$INTERRUPT" "interrupting with"

for shape in dies traps; do
  case "$shape" in
    dies) shape_label="the session is killed by it" ;;
    traps) shape_label="the session catches it and exits zero" ;;
  esac

  fresh_repo "$REPO"
  SENTINEL="$WORK/session-started-$shape"
  rm -f "$SENTINEL" "$SENTINEL.signalled"
  # The process group start_run_in_background hands out is what this file
  # wants from it beyond the signal disposition: the interrupt can then be
  # delivered the way a real one is -- to the driver and its session
  # together -- without taking this test process down with it.
  start_run_in_background "$WORK/killed-$shape.log" \
    env CLAUDE_STUB_MODE=hang CLAUDE_STUB_SENTINEL="$SENTINEL" CLAUDE_STUB_ON_SIGNAL="$shape" \
    "$DRIVER_BIN" "$REPO"

  # A bound of its own. The stub's backstop above is 300 too and is not this
  # number: that one bounds a started session's wait for a signal, this one
  # bounds the wait for the session to start at all.
  if ! wait_until_under_way "$SENTINEL" 300; then
    fail "interrupted mid-run, $shape_label: the driver got as far as the session (timed out waiting)"
    abandon_run process-group
    continue
  fi

  pass "interrupted mid-run, $shape_label: the driver got as far as the session, with the scaffolding unpacked"
  assert_dir_exists "$REPO/.specify" \
    "interrupted mid-run, $shape_label: the scaffolding really is in the repo at the moment of the kill"

  # The group, with the leading dash: the driver and its session together.
  kill -"$INTERRUPT" -"$RUN_PID" 2>/dev/null
  wait "$RUN_PID"; killed_status=$?

  # Asked before anything else, because every assertion below it is only
  # worth reading once the signal is known to have landed. A driver that was
  # never signalled runs to an ordinary success, and an ordinary success
  # fails all of them for a reason that has nothing to do with rollback.
  if [ "$shape" = "traps" ]; then
    assert_file_exists "$SENTINEL.signalled" \
      "interrupted mid-run, $shape_label: the session really did receive the signal"
  fi

  if [ "$killed_status" -ne 0 ]; then
    pass "interrupted mid-run, $shape_label: the driver exits non-zero rather than looking like a success"
  else
    fail "interrupted mid-run, $shape_label: the driver exits non-zero rather than looking like a success"
    cat "$WORK/killed-$shape.log" >&2
  fi
  # And the exact status, not merely non-zero: 128 + the signal's number is
  # what a run stopped by that signal reports. For the `dies` shape it is
  # the only positive evidence that the signal landed and was acted on,
  # rather than the run having failed for some unrelated reason of its own
  # -- the marker file above gives `traps` that evidence directly.
  assert_eq "$killed_status" "$EXPECTED_STATUS" \
    "interrupted mid-run, $shape_label: the driver exits $EXPECTED_STATUS, the status of a run stopped by SIG$INTERRUPT"
  # The session had already written the constitution by this point, so a
  # driver that shrugged the interrupt off would have left it sitting there
  # for the driver runner to harvest -- a context map for a repo nobody
  # finished cleaning up.
  assert_widget_repo_pristine "$REPO" "interrupted mid-run, $shape_label"
  assert_file_missing "$REPO/.specify/memory/constitution.md" \
    "interrupted mid-run, $shape_label: nothing is left behind to harvest, session's work included"
done

echo ""
echo "spec-kit driver, the session commits:"

# Restore reasons entirely relative to the commit HEAD pointed at when the
# snapshot was taken, so a session that commits has put the repo somewhere
# the driver can't unwind. What matters is that it says so: `git status`
# reads clean either way, so a quiet success here would report a context map
# for a repo that now has a whole toolchain committed into it.
fresh_repo "$REPO"
OUT="$WORK/committed.md"
if err="$(CLAUDE_STUB_MODE=commit "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session committed exits non-zero rather than quietly succeeding"
else
  pass "a run whose session committed exits non-zero rather than quietly succeeding"
fi
assert_contains "$err" "HEAD moved" "the failure explains that the repo moved out from under the rollback"
assert_contains "$err" "by hand" "the failure tells the operator the repo needs their attention"
assert_file_missing "$OUT" "no context map is harvested from a repo the driver could not clean up"

echo ""
echo "spec-kit driver, a helper that could not do its job:"

# The same two answers the pocock driver's file pins, asked here because the
# shared helpers are shared: a driver that answered a broken helper one way
# while the other answered it another would mean an operator's repo is looked
# after differently depending on which driver they picked. What is under test
# is this driver's answer and not how the helper came to fail -- the failure
# is traced from the fingerprinting up to each helper in
# tests/repo_snapshot.sh.

BROKEN_DRIVERS="$WORK/broken-drivers"

# A fingerprinting that cannot run at all. The snapshot needs it before
# `specify init` unpacks a toolchain into the repo, so the run stops there --
# which is the point: nothing is unpacked that nothing could then put back.
drivers_with_override "$BROKEN_DRIVERS" 'fingerprint_paths() { return 1; }' || exit 1
fresh_repo "$REPO"
OUT="$WORK/no-fingerprint.md"
if err="$(ARCHIMEDES_DRIVERS_DIR="$BROKEN_DRIVERS" "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose snapshot cannot be taken fails rather than scaffolding into a repo it could not describe first"
else
  pass "a run whose snapshot cannot be taken fails rather than scaffolding into a repo it could not describe first"
fi
assert_file_missing "$OUT" "and nothing is harvested from it"
assert_widget_repo_pristine "$REPO" "snapshot could not be taken"

# And the note that must not fail the run, for the reason the pocock file
# gives at length: it runs after the harvest is a foregone conclusion, so its
# status is something to say rather than something to die on.
drivers_with_override "$BROKEN_DRIVERS" 'report_kept_paths_replaced() { return 1; }' || exit 1
fresh_repo "$REPO"
mkdir -p "$REPO/.specify/memory"
echo "the constitution I was half way through drafting" > "$REPO/.specify/memory/constitution.md"
OUT="$WORK/no-report.md"
if err="$(ARCHIMEDES_DRIVERS_DIR="$BROKEN_DRIVERS" "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  pass "a run that could not work out whether it replaced the operator's own constitution still succeeds"
else
  fail "a run that could not work out whether it replaced the operator's own constitution still succeeds"
  printf '%s\n' "$err" >&2
fi
assert_file_exists "$OUT" "and the constitution is harvested"
assert_contains "$err" "could not work out whether" \
  "and the run says it could not tell, rather than letting silence stand for the report that there was nothing to tell"
assert_contains "$err" ".specify/memory/constitution.md" "naming the path it could not answer for"
assert_widget_repo_pristine "$REPO" "could not work out whether the constitution was replaced"

report
