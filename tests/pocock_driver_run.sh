#!/usr/bin/env bash
# The pocock driver's own orchestration -- run the session inside the
# target repo, honour the fixed-location contract, refuse to report success
# when nothing was written -- exercised against a stub `claude` CLI. No
# network, no billed call, so this runs in the normal suite, the same way
# spec_kit_driver_run.sh covers the spec-kit driver.
#
# What this file does not claim, and must not be read as claiming: that the
# domain-modeling skill still produces a usable context map. Every
# assertion below is satisfied by a stub that writes four words to
# CONTEXT.md, so what is proved here is that *our* half still holds -- the
# half most likely to break from our own edits. The upstream half is
# pocock-driver-e2e.sh, which makes the real billed call and is run by
# .github/workflows/live-drivers.yml on a schedule.
#
# The stubs are what make the failure paths reachable at all: a session
# that writes nothing, a session that dies, and -- the one this driver
# exists to survive -- a session that ignores the prompt and writes all over
# the repo are ordinary outcomes of a headless agent run, and none of them
# is something you can ask a real, billed, minutes-long `claude -p` to do on
# demand.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_BIN="$ROOT/drivers/pocock/run.sh"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# Stands in for the headless `claude -p` session. Records where it was run
# and what it was asked to do -- the driver's whole job is getting those two
# right -- then behaves the way CLAUDE_STUB_MODE says.
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
{
  echo "cwd=$PWD"
  for a in "$@"; do echo "arg=$a"; done
} > "$CLAUDE_STUB_LOG"
write_map() {
  cat > CONTEXT.md <<'MAP'
# Widget Catalog

**Widget** -- a catalog entry with a name and a price in cents.
MAP
}
# The session doing what the prompt spent a paragraph asking it not to.
# Deliberately not just the ADR the prompt argues with: a settings file the
# skill thought was a favour, and an edit to a source file it thought was
# tidying, are the shapes a cleanup written as a list of known leftovers
# would walk straight past.
write_more_than_the_map() {
  mkdir -p docs/adr .claude
  echo "# 1. Widgets are priced in cents" > docs/adr/001-widgets.md
  echo '{"model":"opus"}' > .claude/settings.local.json
  echo "// tidied up while I was here" >> src/index.js
}
# The session tidying up work the operator had not committed. Not a leftover
# and not a change against HEAD either: both of these paths were already dirty
# when the run started, so the snapshot has them by name and every check
# written against a name reads the write as the state that predated it.
write_over_uncommitted_work() {
  echo "helpfully rewritten" > scratch-note.md
  echo "console.log('reformatted')" > src/index.js
}
case "${CLAUDE_STUB_MODE:-write}" in
  write)
    write_map ;;
  clobber)
    write_map; write_over_uncommitted_work ;;
  noop)
    : ;;   # a session that read the repo and wrote nothing
  fail)
    echo "claude: session failed" >&2; exit 1 ;;
  extra)
    write_map; write_more_than_the_map ;;
  commit)
    write_map
    echo "# 1. Widgets are priced in cents" > ADR.md
    git add -A
    # The one identity in this suite still spelled out at the call site, and
    # deliberately not the fixture's: the case is a commit somebody else made
    # in the operator's repo, so it has to be somebody else's name on it.
    git -c user.email=agent@example.com -c user.name=agent commit -qm "agent committed its own work"
    ;;
  hang)
    # Everything a run that got all the way through would have done -- so an
    # interrupt that gets swallowed rather than acted on finishes normally
    # and harvests a perfectly good map from a repo nobody finished cleaning
    # up, which is exactly the failure this mode exists to catch. Then it
    # announces itself and sits in the foreground, so the test can signal the
    # driver while bash is blocked on a child, which is where a real Ctrl-C
    # lands.
    #
    # Only the map, deliberately, though this mode used to disobey as well.
    # The disobedience gave the driver a second reason to exit non-zero that
    # had nothing to do with the interrupt, and the case passed on it: a
    # driver that swallowed the signal outright still failed the run for
    # writing more than it was asked to. Left with the map alone, the
    # interrupt is the only thing that can end this run badly.
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
    write_map
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
chmod +x "$STUB_BIN/claude"

export PATH="$STUB_BIN:$PATH"
export CLAUDE_STUB_LOG="$WORK/session.log"

REPO="$WORK/repo"

# <path> -- the same signature as spec_kit_driver_run.sh's, so the two
# don't read alike and mean different things. Clearing the session log is
# this file's addition: every case asks what the driver did to the stub,
# and a stale log would answer for the previous one.
fresh_repo() {
  rm -rf "$1"
  make_widget_repo "$1"
  rm -f "$CLAUDE_STUB_LOG"
}

echo "pocock driver, successful run:"

fresh_repo "$REPO"
OUT="$WORK/CONTEXT.md"
if "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" >"$WORK/run.log" 2>&1; then
  pass "a run whose session writes CONTEXT.md exits zero"
else
  fail "a run whose session writes CONTEXT.md exits zero"
  cat "$WORK/run.log" >&2
fi
assert_file_exists "$OUT" "the context map is harvested to the exact requested path"
assert_contains "$(cat "$OUT" 2>/dev/null)" "Widget Catalog" \
  "the harvested file is what the session wrote"
assert_file_missing "$REPO/CONTEXT.md" \
  "CONTEXT.md is gone from the target repo, not just untracked"
assert_widget_repo_pristine "$REPO" "successful run"

echo ""
echo "pocock driver, how the session is invoked:"

# The fixed-location contract rests entirely on this: the skill writes
# CONTEXT.md at the root of whatever repo it is invoked in and cannot be
# pointed anywhere else, so a driver that ran the session from its own
# working directory would harvest nothing -- or, worse, harvest this repo's
# CONTEXT.md.
session="$(cat "$CLAUDE_STUB_LOG" 2>/dev/null)"
assert_contains "$session" "cwd=$REPO" "the session runs inside the target repo, which is where the skill writes"
assert_contains "$session" "arg=-p" "the session is headless -- nobody is there to answer a prompt"
assert_contains "$session" "domain-modeling" "the session is told to use the domain-modeling skill"
assert_contains "$session" "CONTEXT.md" "the session is told which file to produce"
# The driver runner harvests exactly one file by moving it. Anything else
# the session writes is left in someone else's repo, so the prompt has to
# ask for that restraint even though nothing downstream can enforce it.
assert_contains "$session" "do not create or modify any other file" \
  "the session is told to write nothing but that file"

echo ""
echo "pocock driver, the session writes nothing:"

fresh_repo "$REPO"
OUT="$WORK/noop.md"
if err="$(CLAUDE_STUB_MODE=noop "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session wrote no CONTEXT.md exits non-zero"
else
  pass "a run whose session wrote no CONTEXT.md exits non-zero"
fi
assert_contains "$err" "did not produce" \
  "the failure says the session produced nothing, rather than blaming the driver runner"
assert_file_missing "$OUT" "a session that wrote nothing produces no output file"
assert_widget_repo_pristine "$REPO" "session wrote nothing"

echo ""
echo "pocock driver, the session fails:"

fresh_repo "$REPO"
OUT="$WORK/fail.md"
if CLAUDE_STUB_MODE=fail "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" >/dev/null 2>&1; then
  fail "a run whose session exits non-zero fails the driver too"
else
  pass "a run whose session exits non-zero fails the driver too"
fi
assert_file_missing "$OUT" "a failed session produces no output file"
assert_widget_repo_pristine "$REPO" "session failed"

echo ""
echo "pocock driver, the session writes more than the map:"

# The case the whole driver turns on. The prompt asks the session, at
# length, to write CONTEXT.md and nothing else; the session is a
# non-deterministic agent and the domain-modeling skill's own criteria call
# for ADRs, so the prompt is arguing with the thing it invokes and will
# sometimes lose. Losing must not look like winning.
fresh_repo "$REPO"
OUT="$WORK/extra.md"
if err="$(CLAUDE_STUB_MODE=extra "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session wrote more than the map exits non-zero"
else
  pass "a run whose session wrote more than the map exits non-zero"
fi
# Named, because the operator's next question is "what did it write?", and
# a run that says only "it wrote something" sends them looking through a
# repo this driver has already tidied.
assert_contains "$err" "docs/adr/001-widgets.md" "the failure names the file the session was told not to write"
assert_contains "$err" ".claude/settings.local.json" "and the one no prompt thought to forbid"
assert_contains "$err" "src/index.js" "and the tracked file it edited, which is not a leftover but a change"
assert_file_missing "$OUT" "no context map is harvested from a run that would not keep to one file"
assert_widget_repo_pristine "$REPO" "session wrote more than the map"
assert_eq "$(cat "$REPO/src/index.js" 2>/dev/null | tail -1)" "module.exports = { Widget };" \
  "the tracked file the session edited is put back to what HEAD says"

echo ""
echo "pocock driver, a repo that was already dirty:"

# The other half of "never worse off": putting the run's work back must not
# take the operator's with it. A repo with uncommitted work in it is the
# normal state of a repo somebody is working in, and the driver is pointed
# at those.
fresh_repo "$REPO"
echo "notes to self" > "$REPO/scratch-note.md"
echo "// mine, uncommitted" >> "$REPO/src/index.js"
before_status="$(git -C "$REPO" status --porcelain)"
OUT="$WORK/dirty.md"
if "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" >"$WORK/dirty.log" 2>&1; then
  pass "a run against a repo that was already dirty still succeeds"
else
  fail "a run against a repo that was already dirty still succeeds"
  cat "$WORK/dirty.log" >&2
fi
assert_file_exists "$REPO/scratch-note.md" "an untracked file that predates the run is still there"
assert_contains "$(cat "$REPO/src/index.js" 2>/dev/null)" "// mine, uncommitted" \
  "and an uncommitted edit to a tracked file is still there"
assert_eq "$(git -C "$REPO" status --porcelain)" "$before_status" \
  "the repo is dirty in exactly the way it was dirty before, and no other"

echo ""
echo "pocock driver, the session writes over work the repo already had:"

# The half of "never worse off" the driver cannot deliver, and therefore has
# to say. Leaving the operator's uncommitted work alone is right up until the
# session writes to it, and then there is nothing to put back: what those
# files said was never committed and nothing here kept a copy. So the run
# fails naming them, the same way it fails for a leftover, and the rollback
# says separately which of them it could not undo -- because a driver whose
# floor reads "the repo ends as it was found" must not quietly mean "except
# where it doesn't".
fresh_repo "$REPO"
echo "notes to self" > "$REPO/scratch-note.md"
echo "// mine, uncommitted" >> "$REPO/src/index.js"
OUT="$WORK/clobber.md"
if err="$(CLAUDE_STUB_MODE=clobber "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session wrote over the operator's uncommitted work exits non-zero"
else
  pass "a run whose session wrote over the operator's uncommitted work exits non-zero"
fi
assert_contains "$err" "scratch-note.md" \
  "the failure names the untracked file the session wrote over"
assert_contains "$err" "src/index.js" \
  "and the tracked one it had no more right to rewrite for having been dirty already"
assert_contains "$err" "cannot be put back" \
  "and says plainly that this is the one thing the rollback cannot undo"
assert_file_missing "$OUT" \
  "no context map is harvested from a run that wrote over the operator's own work"
assert_eq "$(cat "$REPO/scratch-note.md" 2>/dev/null)" "helpfully rewritten" \
  "the file is left as the session left it -- there is no copy of what it said, so guessing would be the worse answer"

echo ""
echo "pocock driver, the session replaces a CONTEXT.md the repo already had:"

# The one path the section above exempts, and the one case where saying so is
# not the same as failing. A repo this driver is pointed at may well already
# have a CONTEXT.md the operator was part-way through editing -- writing that
# file is the whole of what the run does, so refusing every repo with one in
# flight would leave the driver unusable on exactly the repos it is for. The
# run succeeds and harvests, as it should.
#
# What was missing is that the harvest *moves* it: the operator's version is
# replaced and then carried out of the repo, and until this the entire
# sequence was an ordinary success with nothing printed anywhere. No stub mode
# of its own -- the ordinary `write` session, run against a repo that already
# had the file, is precisely the case.
fresh_repo "$REPO"
echo "the map I was half way through writing" > "$REPO/CONTEXT.md"
OUT="$WORK/replaced.md"
if err="$("$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  pass "a run that replaced an uncommitted CONTEXT.md still succeeds -- writing that file is what the run is for"
else
  fail "a run that replaced an uncommitted CONTEXT.md still succeeds -- writing that file is what the run is for"
  printf '%s\n' "$err" >&2
fi
assert_file_exists "$OUT" "the map is harvested"
assert_contains "$(cat "$OUT" 2>/dev/null)" "Widget Catalog" \
  "and it is the session's, not the version the operator had sitting there"
assert_contains "$err" "CONTEXT.md" \
  "the run says which file of the operator's it replaced, rather than leaving them to find it gone"
assert_contains "$err" "Commit it first" \
  "and says what would have kept it, since nothing here holds a copy of what it said"
assert_file_missing "$REPO/CONTEXT.md" \
  "the file really is gone from the repo -- replaced and then harvested away, which is why the run has to say so"
assert_widget_repo_pristine "$REPO" "session replaced a CONTEXT.md the repo already had"

echo ""
echo "pocock driver, interrupted mid-run:"

# The case hand-placed error handling cannot reach, and the reason the
# rollback is the exit trap rather than something on the success path. By
# the moment of the kill the session has already written the map, so a
# driver that shrugged the interrupt off would harvest a context map for a
# repo nobody finished cleaning up -- and leave the rest in someone else's
# repo with nobody watching.
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

  pass "interrupted mid-run, $shape_label: the driver got as far as the session, with the session's writing done"
  assert_file_exists "$REPO/CONTEXT.md" \
    "interrupted mid-run, $shape_label: the map the session wrote really is in the repo at the moment of the kill"

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
  assert_widget_repo_pristine "$REPO" "interrupted mid-run, $shape_label"
  assert_file_missing "$REPO/CONTEXT.md" \
    "interrupted mid-run, $shape_label: nothing is left behind to harvest, the map included"
done

echo ""
echo "pocock driver, the session commits:"

# Everything the cleanup reasons about is relative to the commit HEAD
# pointed at when the run started, so a session that commits has put the
# repo somewhere the driver cannot unwind -- while leaving `git status`
# reading clean, which is what makes quiet success here so bad a failure.
fresh_repo "$REPO"
OUT="$WORK/committed.md"
if err="$(CLAUDE_STUB_MODE=commit "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose session committed exits non-zero rather than quietly succeeding"
else
  pass "a run whose session committed exits non-zero rather than quietly succeeding"
fi
assert_contains "$err" "HEAD moved" "the failure explains that the repo moved out from under the cleanup"
assert_contains "$err" "by hand" "the failure tells the operator the repo needs their attention"
assert_file_missing "$OUT" "no context map is harvested from a repo the driver could not clean up"

echo ""
echo "pocock driver, the target is not a git repo:"

# The cleanup is a diff against git, so a target with no git in it is a
# target this driver cannot promise anything about. Said before the session
# runs, because afterwards is after a billed call has already written into
# a directory nothing can put back.
NOT_A_REPO="$WORK/not-a-repo"
rm -rf "$NOT_A_REPO"; mkdir -p "$NOT_A_REPO/src"
if err="$("$DRIVER_BIN" "$NOT_A_REPO" 2>&1 >/dev/null)"; then
  fail "the driver refuses a target that is not a git repo"
else
  pass "the driver refuses a target that is not a git repo"
fi
assert_contains "$err" "not a git repo" "the refusal says what is wrong with the target"
assert_file_missing "$NOT_A_REPO/CONTEXT.md" "and refuses before any session writes into it"

echo ""
echo "pocock driver, claude is not installed:"

# The driver is a wrapper around one CLI. Someone who has not installed it
# should be told that, not handed a bare command-not-found from inside a
# subshell.
fresh_repo "$REPO"
# Run through this shell by its absolute path rather than the shebang:
# with nothing on PATH, `#!/usr/bin/env bash` cannot find bash either, and
# the test would pass on the wrong error.
mkdir -p "$WORK/empty"
if err="$(PATH="$WORK/empty" "$BASH" "$DRIVER_BIN" "$REPO" 2>&1 >/dev/null)"; then
  fail "the driver refuses to run without the claude CLI"
else
  pass "the driver refuses to run without the claude CLI"
fi
assert_contains "$err" "claude CLI not found" "the refusal names the missing CLI"

echo ""
echo "pocock driver, called wrongly:"

if err="$("$DRIVER_BIN" 2>&1 >/dev/null)"; then
  fail "the driver rejects a call with no repo path"
else
  pass "the driver rejects a call with no repo path"
fi
assert_contains "$err" "usage:" "the rejection says how to call it"

echo ""
echo "pocock driver, a helper that could not do its job:"

# The failure the whole rollback is written against, arriving from underneath
# it. Every question this driver asks about the operator's repo -- what the
# session wrote, what it wrote over, what could not be put back -- is answered
# by the shared helpers, and each answer is a list of paths. An empty list
# means "the run touched nothing of yours", so a helper that could not work
# the answer out at all must not be able to hand one back.
#
# Reached with a stand-in helper rather than a machine with no temp space,
# because what is under test here is this driver's answer and not how the
# helper came to fail. drivers/lib/repo-snapshot.sh's own tests are where the
# failure is traced from the fingerprinting up to each of these.

BROKEN_DRIVERS="$WORK/broken-drivers"

# A fingerprinting that cannot run at all, which the snapshot needs before the
# session is ever started. Nothing is billed and nothing is written: the run
# ends where it found out it could not keep its promise about the repo.
drivers_with_override "$BROKEN_DRIVERS" 'fingerprint_paths() { return 1; }' || exit 1
fresh_repo "$REPO"
OUT="$WORK/no-fingerprint.md"
if err="$(ARCHIMEDES_DRIVERS_DIR="$BROKEN_DRIVERS" "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run whose snapshot cannot be taken fails rather than going ahead without one"
else
  pass "a run whose snapshot cannot be taken fails rather than going ahead without one"
fi
assert_file_missing "$OUT" "and nothing is harvested from it"
assert_file_missing "$CLAUDE_STUB_LOG" \
  "and no session was started -- the promise about the repo is checked before anything is billed to write into it"
assert_widget_repo_pristine "$REPO" "snapshot could not be taken"

# And the same failure arriving after the session, where the driver has to say
# what the session wrote and cannot find out. An empty answer here is this
# driver's "the session kept to the one file it was asked for", which is the
# reading that harvests the map -- so the status has to be the difference.
drivers_with_override "$BROKEN_DRIVERS" 'paths_changed_since_snapshot() { return 1; }' || exit 1
fresh_repo "$REPO"
OUT="$WORK/no-naming.md"
if err="$(ARCHIMEDES_DRIVERS_DIR="$BROKEN_DRIVERS" "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  fail "a run that cannot find out what the session wrote fails rather than reading that as a session that wrote only the map"
else
  pass "a run that cannot find out what the session wrote fails rather than reading that as a session that wrote only the map"
fi
assert_contains "$err" "could not work out what the session wrote" \
  "and says so, rather than leaving the operator with a run that simply failed"
assert_file_missing "$OUT" "and no context map is harvested from it"
assert_widget_repo_pristine "$REPO" "could not work out what the session wrote"

# The one that must not fail the run. It is the note saying the operator's own
# CONTEXT.md was replaced and is about to be carried out of the repo, and it
# runs after the harvest is a foregone conclusion -- so a driver that let its
# status meet `set -e` would fail a run that succeeded over a courtesy note.
# It says it could not tell instead, which is the one thing worse than the
# note: not saying anything.
drivers_with_override "$BROKEN_DRIVERS" 'report_kept_paths_replaced() { return 1; }' || exit 1
fresh_repo "$REPO"
echo "the map I was half way through writing" > "$REPO/CONTEXT.md"
OUT="$WORK/no-report.md"
if err="$(ARCHIMEDES_DRIVERS_DIR="$BROKEN_DRIVERS" "$ARCHIMEDES_BIN" run-driver pocock "$REPO" "$OUT" 2>&1 >/dev/null)"; then
  pass "a run that could not work out whether it replaced the operator's own map still succeeds -- the map is written and harvested either way"
else
  fail "a run that could not work out whether it replaced the operator's own map still succeeds -- the map is written and harvested either way"
  printf '%s\n' "$err" >&2
fi
assert_file_exists "$OUT" "and the map is harvested"
assert_contains "$err" "could not work out whether" \
  "and the run says it could not tell, rather than letting silence stand for the report that there was nothing to tell"
assert_contains "$err" "CONTEXT.md" "naming the path it could not answer for"
assert_widget_repo_pristine "$REPO" "could not work out whether the map was replaced"

report
