#!/usr/bin/env bash
# A signal aimed at the `archimedes` process reaches the driver archimedes
# is waiting on, and archimedes is still there when the driver answers.
#
# This is the layer above tests/spec_kit_driver_run.sh's interrupted cases.
# Those signal a driver directly and ask whether it rolls back; this signals
# archimedes and asks whether the driver is ever told. Go forwards nothing
# to a child process, so without arranging it the two questions have
# different answers: `kill` on the archimedes pid used to stop archimedes
# and leave the driver running unsupervised in the target repo.
#
# The signal goes to the pid alone, never to a process group, and that is
# the whole point of the file. Ctrl-C at a terminal has always worked by
# accident -- a terminal signals its whole foreground process group, so a
# driver sitting in archimedes' group got a copy nobody arranged. Every
# other way of stopping a run -- `kill` by pid, a supervisor, `timeout(1)`,
# a parent harness shutting its children down -- aims at the process, and
# that is what is exercised here.
#
# The driver is a stub, written from drivers/README.md the way
# fixed_location_conformance.sh's is, but its rollback is the real
# drivers/lib/repo-snapshot.sh: what a driver does with an interrupt is
# already covered, and what this file needs from it is only that it takes
# long enough to be caught halfway.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

# The stub driver's rollback is the real drivers/lib/repo-snapshot.sh, which
# needs bash 4+ for its associative arrays. Why the bash a *driver* would get
# is the one that decides here, rather than this file's own, is written down
# once at the helper.
skip_without_driver_bash_4 "interrupted_run.sh" \
  "the stub driver's rollback is drivers/lib/repo-snapshot.sh, which needs bash 4+"

ROOT="$(cd "$HERE/.." && pwd)"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
DRIVERS="$WORK/drivers"
STARTED="$WORK/driver-started"

# A drivers directory of its own, holding the real shared helpers and one
# driver that hangs where a real one holds a `claude -p` session: scaffolded
# into the repo, its rollback armed, and nothing but a signal to release it.
mkdir -p "$DRIVERS/hangs"
cp -R "$ROOT/drivers/lib" "$DRIVERS/lib"

cat > "$DRIVERS/hangs/driver.yaml" <<'YAML'
name: hangs
description: A fixed-location driver that scaffolds, then waits to be interrupted.
output_mode: fixed-location
fixed_path: HUNG.md
command: run.sh
YAML

cat > "$DRIVERS/hangs/run.sh" <<'DRIVER'
#!/usr/bin/env bash
# Everything a fixed-location driver does, up to the point where a real one
# would be waiting minutes on an agent session -- and then it waits there.
set -uo pipefail
REPO_PATH="$1"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

SNAPSHOT="$(mktemp)"
snapshot_repo_state "$REPO_PATH" > "$SNAPSHOT"

cleanup() {
  local status=$?
  # Paced, deliberately. A real rollback is a git checkout plus a walk of
  # the whole working tree; this one is four files in a five-file repo and
  # would otherwise be over before anything could be observed happening
  # during it -- which is the window the second-signal case below is about.
  sleep 1
  restore_repo_state "$REPO_PATH" "$SNAPSHOT" \
    || echo "could not roll $REPO_PATH back to how it was found" >&2
  rm -f "$SNAPSHOT"
  exit "$status"
}
trap cleanup EXIT
exit_on_interrupt "$REPO_PATH"

# The scaffolding a real one unpacks, in miniature: files, a nested tree,
# and the fixed_path itself, so an archimedes that walked away would leave
# a whole toolchain and a harvestable map sitting in someone's repo.
mkdir -p "$REPO_PATH/.hung/memory" "$REPO_PATH/.hung/scripts"
echo "helper" > "$REPO_PATH/.hung/scripts/helper.sh"
echo "# a context map" > "$REPO_PATH/HUNG.md"

# Announced only once all of that is really in the repo, so a test that
# signals on seeing this is signalling a run there is something to undo.
touch "$HANGS_DRIVER_STARTED"

# Nothing releases this but the signal. The bound is a backstop for one that
# never arrives, long enough that reaching it is a broken test rather than a
# slow machine -- and reaching it ends in an ordinary successful run, which
# every assertion below says so about loudly.
waited=0
while [ "$waited" -lt 600 ]; do
  sleep 0.1; waited=$((waited + 1))
done
DRIVER
chmod +x "$DRIVERS/hangs/run.sh"

# The same choice tests/spec_kit_driver_run.sh makes, for the reason spelled
# out at deliverable_interrupt: a test file that was itself backgrounded
# cannot deliver SIGINT to anything, and archimedes has to treat the two
# identically anyway.
INTERRUPT="$(deliverable_interrupt)"
set_expected_status "$INTERRUPT"
announce_interrupt_fallback "$INTERRUPT" "interrupting with"

# Starts a run and waits until the driver is really under way, leaving
# $RUN_PID holding the one process every case here signals.
#
# The process group start_run_in_background hands out is incidental here --
# archimedes puts the driver in one of its own regardless, so the kill below
# reaches the driver only by being forwarded. What that helper is there for
# is the signal disposition, which nothing downstream could restore.
# <log-file> -> 0 once the driver has scaffolded, 1 if it never got there.
start_a_run() {
  rm -rf "$REPO"
  make_widget_repo "$REPO"
  rm -f "$STARTED"

  start_run_in_background "$1" \
    env ARCHIMEDES_DRIVERS_DIR="$DRIVERS" HANGS_DRIVER_STARTED="$STARTED" \
    "$ARCHIMEDES_BIN" run-driver --root "$WORK" hangs "$REPO" "$WORK/harvested.md"

  # A bound of its own, not the stub driver's: this one waits for the driver
  # to scaffold, and that one waits, once it has, for a signal that never
  # comes.
  wait_until_under_way "$STARTED" 600
}

# The same run, with the one outcome no case below can carry on from: a
# driver that never got as far as scaffolding leaves a pristine repo, and a
# pristine repo passes most of what follows for the wrong reason. Written
# once because both cases bail identically, and a second spelling of a
# bail-out is the one that stops matching. <log-file> <label>
start_a_run_or_bail() {
  if start_a_run "$1"; then
    return 0
  fi
  fail "$2: the driver gets as far as scaffolding the repo (timed out waiting)"
  abandon_run process
  report
  exit
}

echo "a signal to the archimedes process alone:"

LOG="$WORK/interrupted.log"
start_a_run_or_bail "$LOG" "a signal to the archimedes process alone"
pass "the driver gets as far as scaffolding the repo"
assert_dir_exists "$REPO/.hung" \
  "the scaffolding really is in the repo at the moment of the kill"
assert_file_exists "$REPO/HUNG.md" \
  "and so is the map a walked-away-from run would leave to be harvested"

# No leading dash: this is the process, not the group. A driver that hears
# about it heard about it from archimedes.
kill -"$INTERRUPT" "$RUN_PID" 2>/dev/null
wait "$RUN_PID"; STATUS=$?

# Asked first, because everything below is only worth reading once the
# rollback is known to have run at all: a run that finished normally leaves
# a pristine repo too, by putting it back on its own success path.
assert_contains "$(cat "$LOG" 2>/dev/null)" "telling the driver to stop" \
  "archimedes passed the signal on rather than taking it as its own cue to leave"
assert_contains "$(cat "$LOG" 2>/dev/null)" "interrupted by SIG$INTERRUPT" \
  "the driver was told about the signal, and said so"
assert_contains "$(cat "$LOG" 2>/dev/null)" "rolling $REPO back to how it was found" \
  "archimedes was still there to relay what the driver said about the repo on its way out"

assert_eq "$STATUS" "$EXPECTED_STATUS" \
  "archimedes exits $EXPECTED_STATUS, the status the driver chose, rather than a status of its own"

# The next two are where the waiting is actually pinned down, and it is
# worth being exact about which assertion carries which guarantee, because
# the relayed message above does not carry this one: the driver prints it
# at the *start* of its rollback, so it would reach the log either way.
#
# `wait` has returned by here, so these describe the repo at the moment
# archimedes exited. The driver's rollback is deliberately paced (see the
# `sleep` in its cleanup), so an archimedes that forwarded the signal and
# left immediately -- today's behaviour with extra steps, which is the thing
# being ruled out -- would still find .hung/ sitting there.
assert_widget_repo_pristine "$REPO" "interrupted through archimedes"
assert_dir_missing "$REPO/.hung" \
  "archimedes did not return until the driver had finished rolling back: the scaffolded tree is gone, empty directories included"

# Not evidence for any of the above on its own -- an archimedes that walked
# away harvests nothing either. It is here for the contract: a stopped run
# must not produce a map, and the code that could break that is the harvest
# step, which runs after the driver returns and now has a stopped run to
# tell apart from a successful one.
assert_file_missing "$WORK/harvested.md" \
  "nothing is harvested out of a run that was stopped"

echo ""
echo "a second signal, from an operator who thought the first did nothing:"

# The case repo-snapshot.sh names as one it cannot get a repo out of: a
# signal landing partway through a restore leaves what has been undone
# undone and the rest not. Archimedes will not be the one that delivers it.
LOG="$WORK/interrupted-twice.log"
start_a_run_or_bail "$LOG" "a second signal"

kill -"$INTERRUPT" "$RUN_PID" 2>/dev/null
# Sent on seeing the driver say it has begun, which is what puts it inside
# the window the rollback occupies rather than before or after it.
waited=0
until grep -q "rolling $REPO back" "$LOG" 2>/dev/null || [ "$waited" -ge 600 ]; do
  sleep 0.1; waited=$((waited + 1))
done
kill -"$INTERRUPT" "$RUN_PID" 2>/dev/null
wait "$RUN_PID"; STATUS=$?

assert_contains "$(cat "$LOG" 2>/dev/null)" "SIG$INTERRUPT again" \
  "archimedes tells the operator what it is still waiting for rather than passing the second signal on"
assert_eq "$STATUS" "$EXPECTED_STATUS" \
  "a second signal changes nothing about how the run ended"
assert_widget_repo_pristine "$REPO" "interrupted twice"
assert_dir_missing "$REPO/.hung" \
  "interrupted twice: the rollback finished rather than stopping halfway"

report
