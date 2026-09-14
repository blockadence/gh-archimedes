#!/usr/bin/env bash
# A run that dies without its trap leaves a repo somebody holds a record of.
#
# This is the layer tests/interrupted_run.sh cannot reach. That one stops a
# run with a signal a driver can trap, and asks whether the driver is told;
# these cases kill the driver outright, which is the case
# drivers/lib/repo-snapshot.sh has always named as beyond a shell's reach --
# "SIGKILL, and a machine that loses power, cannot be trapped at all. The
# repo is left exactly as the session left it -- scaffolding, half-written
# map and all -- and nothing announces that."
#
# Two deaths, and the difference between them is the whole file:
#
#   * The driver dies and archimedes is still there. It holds the snapshot
#     the driver handed it before it started, so it runs that driver's own
#     rollback itself and the operator's repo comes back.
#   * Archimedes dies too. Nothing can act at the time, so what has to
#     survive is the record -- on disk, naming the repo and holding the
#     snapshot -- for `unfinished-runs` to report and, when the operator
#     says so, to act on.
#
# The stub driver is written from drivers/README.md the way
# fixed_location_conformance.sh's is, and its snapshot and rollback are the
# real drivers/lib/repo-snapshot.sh: what a driver does with an interrupt is
# covered elsewhere, and what these cases need is a run with something in
# the repo at the moment it is killed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

# The stub's snapshot and rollback are drivers/lib/repo-snapshot.sh, which
# needs bash 4+ for its associative arrays -- and so does the backstop
# archimedes runs, which sources the same file. Why the bash a *driver*
# would get is the one that decides here is written down once at the helper.
skip_without_driver_bash_4 "dead_run_record.sh" \
  "the stub driver and the backstop both source drivers/lib/repo-snapshot.sh, which needs bash 4+"

ROOT="$(cd "$HERE/.." && pwd)"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
DRIVERS="$WORK/drivers"
STARTED="$WORK/driver-started"
DRIVER_PID="$WORK/driver-pid"
RECORDS="$WORK/.archimedes-runs"

# A drivers directory of its own, holding the real shared helpers and one
# driver that scaffolds into the repo and then dies in whichever of two ways
# the case asks for.
mkdir -p "$DRIVERS/dies"
cp -R "$ROOT/drivers/lib" "$DRIVERS/lib"

cat > "$DRIVERS/dies/driver.yaml" <<'YAML'
name: dies
description: A fixed-location driver that scaffolds, then dies without running its trap.
output_mode: fixed-location
fixed_path: DEAD.md
command: run.sh
YAML

cat > "$DRIVERS/dies/run.sh" <<'DRIVER'
#!/usr/bin/env bash
# Everything a fixed-location driver does -- snapshot handed over, rollback
# armed, scaffolding unpacked -- and then a death the rollback cannot
# survive. The trap below is real and correct, and that is the point: what
# these cases are about is not a driver that forgot to clean up, it is a
# driver that was given no chance to.
set -uo pipefail
REPO_PATH="$1"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

SNAPSHOT="$(take_run_snapshot "$REPO_PATH")"
RESTORE_ON_EXIT=1
cleanup() {
  local status=$?
  if [ "$RESTORE_ON_EXIT" -eq 1 ] && ! restore_repo_state "$REPO_PATH" "$SNAPSHOT"; then
    echo "could not roll $REPO_PATH back to how it was found -- it needs looking at by hand" >&2
    hand_over_snapshot "$SNAPSHOT"
  else
    release_snapshot "$SNAPSHOT"
  fi
  exit "$status"
}
trap cleanup EXIT
exit_on_interrupt "$REPO_PATH"

# The scaffolding a real one unpacks, in miniature, plus the fixed_path
# itself: what an operator is left holding when nothing puts it back.
mkdir -p "$REPO_PATH/.dead/memory"
echo "helper" > "$REPO_PATH/.dead/memory/helper.sh"
echo "# a context map" > "$REPO_PATH/DEAD.md"

case "${DEAD_DRIVER_MODE:-kill}" in
  # The death that skips every trap this script holds.
  kill)
    kill -KILL $$
    ;;
  # Or wait to be killed from outside, once the test has killed the
  # archimedes that was watching. Its own pid is left where the test can
  # reach it, since by then there is no archimedes left to ask.
  hang)
    printf '%s\n' "$$" > "$DEAD_DRIVER_PID"
    touch "$DEAD_DRIVER_STARTED"
    waited=0
    while [ "$waited" -lt 600 ]; do
      sleep 0.1; waited=$((waited + 1))
    done
    ;;
esac
DRIVER
chmod +x "$DRIVERS/dies/run.sh"

# A run of that driver against <repo>, freshly made for the case. The repo
# is an argument rather than always $REPO because a record outstanding about
# one repo has to survive a later run somewhere else: re-making the repo a
# record points at would leave the record describing a repo that no longer
# exists in the state it describes, which is a different case than the one
# being tested and one the rollback rightly refuses.
# <repo> <mode> <log-file> -> the run's exit status, for the modes that end
# by themselves.
run_the_driver() { # <repo> <mode> <log-file>
  rm -rf "$1"
  make_widget_repo "$1"
  env ARCHIMEDES_DRIVERS_DIR="$DRIVERS" DEAD_DRIVER_MODE="$2" \
    "$ARCHIMEDES_BIN" run-driver --root "$WORK" dies "$1" "$WORK/harvested.md" \
    >"$3" 2>&1
}

# The one record left under the instance root, or the empty string. Named
# rather than counted at each call site, because "which record" is the id an
# operator types and every case below has to say it back to archimedes.
the_record_id() {
  ls "$RECORDS" 2>/dev/null | head -1
}

records_left() {
  ls "$RECORDS" 2>/dev/null | grep -c . | tr -d ' '
}

echo "a driver killed outright, with archimedes still there:"

LOG="$WORK/killed.log"
run_the_driver "$REPO" kill "$LOG"
STATUS=$?
SAID="$(cat "$LOG" 2>/dev/null)"

assert_eq "$([ "$STATUS" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
  "the run fails rather than reporting a map for a session that was killed"
assert_contains "$SAID" "did not put $REPO back" \
  "archimedes says that the driver did not put the repo back, rather than leaving the operator to find out"
assert_contains "$SAID" "rolling $REPO back from the snapshot" \
  "and says it is running that driver's own rollback from out here"
assert_widget_repo_pristine "$REPO" "a driver killed outright"
assert_dir_missing "$REPO/.dead" \
  "the scaffolded tree is gone, empty directories included"
assert_file_missing "$WORK/harvested.md" \
  "nothing is harvested out of a run that was killed"
assert_eq "$(records_left)" "0" \
  "the record goes with the repo it was about: there is nothing left for anyone to act on"

echo ""
echo "archimedes killed too, so nothing could act at the time:"

LOG="$WORK/both-killed.log"
rm -rf "$REPO"; make_widget_repo "$REPO"
rm -f "$STARTED" "$DRIVER_PID"
start_run_in_background "$LOG" \
  env ARCHIMEDES_DRIVERS_DIR="$DRIVERS" DEAD_DRIVER_MODE=hang \
  DEAD_DRIVER_STARTED="$STARTED" DEAD_DRIVER_PID="$DRIVER_PID" \
  "$ARCHIMEDES_BIN" run-driver --root "$WORK" dies "$REPO" "$WORK/harvested.md"

if wait_until_under_way "$STARTED" 600; then
  pass "the driver gets as far as scaffolding the repo"
else
  fail "the driver gets as far as scaffolding the repo (timed out waiting)"
  abandon_run process
  report
  exit
fi

# Archimedes first -- the pid alone, the way anything that aims at a process
# does -- and then the driver it was watching. In that order because it is
# the order that leaves nothing able to clean up: an archimedes killed while
# a driver is still writing in a repo is the case no forwarding and no exit
# trap reaches.
abandon_run process
kill -KILL "$(cat "$DRIVER_PID")" 2>/dev/null

assert_dir_exists "$REPO/.dead" \
  "the repo really is left holding what the run put there"
assert_eq "$(records_left)" "1" \
  "the record outlived both processes"

ID="$(the_record_id)"
assert_file_exists "$RECORDS/$ID/run.yaml" \
  "the record says which run it was about"
assert_file_exists "$RECORDS/$ID/snapshot" \
  "and holds the snapshot that is the only thing able to put the repo back"
assert_contains "$(cat "$RECORDS/$ID/run.yaml")" "$REPO" \
  "the record names the repo, which is the thing nobody had before"

LISTED="$("$ARCHIMEDES_BIN" unfinished-runs --root "$WORK" 2>&1)"
assert_contains "$LISTED" "$REPO" "the listing names the repo that was left dirty"
assert_contains "$LISTED" "$ID" "and the id an operator acts on it by"
assert_contains "$LISTED" "DEAD.md" "and what the run left in there"
assert_contains "$LISTED" ".dead/memory/helper.sh" "including what it left further down"
assert_dir_exists "$REPO/.dead" \
  "and the listing wrote nothing to the repo to find that out"

echo ""
echo "the next run says so before doing anything else:"

# Against a repo of its own, so the record outstanding about $REPO is still
# a record about the repo it was taken against when the restore below acts
# on it.
NOTICE_LOG="$WORK/notice.log"
run_the_driver "$WORK/another-repo" kill "$NOTICE_LOG"
assert_contains "$(cat "$NOTICE_LOG" 2>/dev/null)" "did not put the repo they were working in back" \
  "a run started while a record is outstanding says so"
assert_contains "$(cat "$NOTICE_LOG" 2>/dev/null)" "unfinished-runs" \
  "and says what to type about it"
assert_eq "$(records_left)" "1" \
  "and leaves no record of its own: it was killed too, and archimedes put that repo back on the spot"

echo ""
echo "putting the repo back, when the operator asks:"

RESTORED="$("$ARCHIMEDES_BIN" unfinished-runs restore --root "$WORK" "$ID" 2>&1)"
assert_contains "$RESTORED" "$REPO" "the restore says which repo it put back"
assert_widget_repo_pristine "$REPO" "restored from the record"
assert_dir_missing "$REPO/.dead" \
  "the scaffolded tree is gone, empty directories included"
assert_eq "$(records_left)" "0" \
  "and the record goes, because there is nothing left in that repo to hold one about"
assert_contains "$("$ARCHIMEDES_BIN" unfinished-runs --root "$WORK" 2>&1)" "No runs" \
  "the listing says so plainly rather than printing an empty heading"

echo ""
echo "a repo that has moved on since the run:"

LOG="$WORK/moved-on.log"
rm -rf "$REPO"; make_widget_repo "$REPO"
rm -f "$STARTED" "$DRIVER_PID"
start_run_in_background "$LOG" \
  env ARCHIMEDES_DRIVERS_DIR="$DRIVERS" DEAD_DRIVER_MODE=hang \
  DEAD_DRIVER_STARTED="$STARTED" DEAD_DRIVER_PID="$DRIVER_PID" \
  "$ARCHIMEDES_BIN" run-driver --root "$WORK" dies "$REPO" "$WORK/harvested.md"

if wait_until_under_way "$STARTED" 600; then
  pass "the driver gets as far as scaffolding the repo"
else
  fail "the driver gets as far as scaffolding the repo (timed out waiting)"
  abandon_run process
  report
  exit
fi
abandon_run process
kill -KILL "$(cat "$DRIVER_PID")" 2>/dev/null

# The case snapshot_head_unmoved refuses, and the reason acting on a record
# is the operator's rather than something that happens to them: everything
# the rollback reasons about is relative to the commit the snapshot was
# taken against, and a repo that has been committed to since is one where
# what the run added can no longer be told from what was already there.
git -C "$REPO" add -A
git -C "$REPO" commit -qm "work done since"

ID="$(the_record_id)"
REFUSED="$("$ARCHIMEDES_BIN" unfinished-runs restore --root "$WORK" "$ID" 2>&1)"
STATUS=$?
assert_eq "$([ "$STATUS" -ne 0 ] && echo nonzero || echo zero)" "nonzero" \
  "a restore that could not be made fails rather than reporting a repo put back"
assert_contains "$REFUSED" "HEAD moved" \
  "and says why, in the rollback's own words"
assert_eq "$(records_left)" "1" \
  "the record is kept: a rollback that refused has undone nothing, and this is all that still names the repo"
assert_contains "$("$ARCHIMEDES_BIN" unfinished-runs --root "$WORK" 2>&1)" "could not work out" \
  "the listing says it cannot work out what is in there, rather than reporting an empty list as if the repo were clean"

FORGOTTEN="$("$ARCHIMEDES_BIN" unfinished-runs forget --root "$WORK" "$ID" 2>&1)"
assert_contains "$FORGOTTEN" "$REPO" \
  "forgetting a record says which repo is being left as it is"
assert_eq "$(records_left)" "0" \
  "and the record goes, so it is not reported before every run from now on"

report
