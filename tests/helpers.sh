#!/usr/bin/env bash
# Minimal assertion + e2e-fixture helpers shared by tests/*.sh. Not a
# framework — this repo is plain bash throughout, so tests stay plain bash
# too.
set -uo pipefail

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_REPO_ROOT="$(cd "$HELPERS_DIR/.." && pwd)"

# shellcheck source=tests/gitfixture.sh
. "$HELPERS_DIR/gitfixture.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); echo "  ok: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  FAIL: $1" >&2; }

assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected [$2], got [$1])"; fi
}

assert_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3 (expected to contain [$2], got [$1])" ;;
  esac
}

assert_not_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) fail "$3 (expected not to contain [$2], got [$1])" ;;
    *) pass "$3" ;;
  esac
}

assert_file_exists() { # <path> <label>
  [ -f "$1" ] && pass "$2" || fail "$2 (no file at $1)"
}

assert_file_missing() { # <path> <label>
  [ -f "$1" ] && fail "$2 (unexpectedly found $1)" || pass "$2"
}

# Directories need their own assertions rather than reusing the file ones,
# because `git status` can't stand in for them: git doesn't track
# directories, so a scaffolded toolchain left behind in empty ones is
# invisible to every porcelain check.
assert_dir_exists() { # <path> <label>
  [ -d "$1" ] && pass "$2" || fail "$2 (no directory at $1)"
}

assert_dir_missing() { # <path> <label>
  [ -d "$1" ] && fail "$2 (unexpectedly found $1/)" || pass "$2"
}

report() { # call at end of each test file
  echo "$TESTS_RUN run, $TESTS_FAILED failed"
  [ "$TESTS_FAILED" -eq 0 ]
}

# A bare "origin" plus a clone with one commit pushed to main, so an
# e2e test's fetch/rev-parse work with no network. <work-dir> <name> ->
# creates <work-dir>/<name> (the clone tests operate on) and
# <work-dir>/<name>-origin.git (the bare remote).
make_origin_and_clone() {
  local work="$1" name="$2"
  make_origin_and_clone_at "$work/$name-origin.git" "$work/$name" README.md $'hi\n'
}

# The compiled CLI these tests drive. An instance carries no scripts of its
# own any more, so every test that acts on one acts through this binary —
# the same one an operator installs. It is built into archimedes at the
# repo root, the path .gitignore already covers, so a whole suite run shares
# one build instead of each file making its own; `go build` no-ops when it
# is current.
ARCHIMEDES_BIN="$TESTS_REPO_ROOT/archimedes"

# Every `run-driver` in this suite passes `--root "$WORK"`, and it is worth
# saying once why rather than in eleven places. --root names the instance:
# the drivers/ searched before the ones the binary ships -- none of these
# tests has one, so every driver still resolves out of the binary -- and,
# since a run is noted down while it is under way, where .archimedes-runs/
# goes. Left at its default that is the checkout the suite runs from, so a
# case that deliberately leaves a repo nothing can roll back (a session that
# commits) would drop a record into this repository and nothing would ever
# take it back. Pointed at the test's own work directory, the record goes
# when the work directory does -- and the case still exercises exactly what
# an operator gets, since an operator's --root is their instance.

build_archimedes() {
  ( cd "$TESTS_REPO_ROOT" && go build -o archimedes ./cmd/archimedes ) || {
    echo "could not build the archimedes CLI" >&2
    return 1
  }
}

# The block of lines nested under a header line in a YAML file --
# everything indented more deeply than the header, up to the first line
# that dedents back to it or past it. Blank lines don't end a block.
#
# Several test files read the workflows to pin guarantees that live nowhere
# but there -- the release waits on the tests (ci_gates_release.sh), the
# published assets are attested (release_provenance.sh), the billed suite is
# not reachable from a fork (ci_runs_live_drivers.sh), no action is on a
# deprecated Node (ci_action_runtimes.sh). They all need the same thing of a
# workflow file, and reading it several ways would be several answers to the
# same question.
#
# <file> <header-line>, the header given exactly as it appears, indent and
# trailing colon included: `yaml_block wf.yml "  release:"`.
yaml_block() {
  awk -v header="$2" '
    BEGIN {
      match(header, /^[ ]*/)
      header_indent = RLENGTH
    }
    !inblock { if ($0 == header) inblock = 1; next }
    /^[[:space:]]*$/ { print; next }
    { match($0, /^[ ]*/) }
    RLENGTH <= header_indent { inblock = 0; next }
    { print }
  ' "$1"
}

# One top-level scalar field out of a driver manifest — enough for the flat
# key/value manifests drivers actually ship, and it reads nothing nested.
# Deliberately not yq: retiring the vendored scripts took yq off the list of
# things an operator has to install, and a test suite that still needed it
# would put it back. <manifest> <field>
manifest_field() {
  sed -n "s/^$2: *//p" "$1"
}

# One job's body out of a GitHub workflow: everything indented under
# `  <name>:` up to the next job. Enough structure for the files that read
# workflows -- ci_gates_release.sh, release_provenance.sh and
# ci_runs_live_drivers.sh -- to tell "the release job needs the test job"
# from "the file contains the word needs somewhere". Shared rather than
# copied into each, so their readings of the same YAML cannot drift apart.
#
# A job block is one case of yaml_block above, and is spelled as one: the
# job name is what varies, and the nesting rule should not be restated per
# caller.
# <workflow-file> <job-name>
workflow_job_block() {
  yaml_block "$1" "  $2:"
}

# Every action a workflow will actually run, one `owner/action@ref` per
# line, deduplicated. Beside the two readers above rather than inside the
# file that wants it today, for the reason stated there: one reading of the
# workflows, not one per question asked of them.
#
# Instruction lines only. These files explain themselves at length, so a
# paragraph naming an action is not a step that runs it -- the anchored
# match is what draws that line, since a commented-out `# - uses: ...` can
# never satisfy it. <workflow-file>...
workflow_uses() {
  grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' "$@" \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
    | sort -u
}

# The names of every job in a workflow, one per line. <workflow-file>
workflow_job_names() {
  awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [^ #]/ && /:/ { sub(/:.*/, ""); gsub(/ /, ""); print }
  ' "$1"
}

# A throwaway one-commit git repo with just enough of a domain in it for a
# context-mapping driver to have something to say about. Shared by the
# driver e2e tests so they're all pointed at the same target -- what varies
# between them should be the driver, not the repo. <path> -> creates it.
make_widget_repo() {
  local repo="$1"
  mkdir -p "$repo/src"
  cat > "$repo/src/index.js" <<'EOF'
// A tiny widget-catalog service: Widgets have a name and a price.
class Widget {
  constructor(name, priceCents) {
    this.name = name;
    this.priceCents = priceCents;
  }
}
module.exports = { Widget };
EOF
  make_repo_at "$repo"
}

# What a repo make_widget_repo built holds when nothing has been done to
# it. It lives beside the fixture because it is that fixture's other half:
# what the repo starts as is what "pristine" has to mean, and every file
# asking it separately would be that many answers free to drift.
WIDGET_REPO_PRISTINE=".git src "

# Everything <repo> holds at its top level, one line's worth, in the shape
# WIDGET_REPO_PRISTINE is written in. `ls` rather than `git status`, because
# git tracks no directories: an empty one a run left behind is a trace only
# this can see.
widget_repo_leftovers() { # <repo>
  (cd "$1" && ls -A | sort | tr '\n' ' ')
}

# The question every driver test asks of the repo it was pointed at: is it
# back exactly as make_widget_repo left it? Silent, and answered by exit
# status, for a caller that has to act on the answer rather than report it
# -- fixed_location_conformance.sh drives a deliberately broken driver and
# needs a dirty repo to be its passing case.
widget_repo_is_pristine() { # <repo>
  [ "$(widget_repo_leftovers "$1")" = "$WIDGET_REPO_PRISTINE" ] \
    && [ -z "$(git -C "$1" status --porcelain)" ]
}

# The same question asked as two assertions, which is what a test that
# merely expects a pristine repo wants: a failure that says which half went
# wrong, rather than one bit. <repo> <label>
assert_widget_repo_pristine() {
  local repo="$1" label="$2"
  assert_eq "$(widget_repo_leftovers "$repo")" "$WIDGET_REPO_PRISTINE" \
    "$label: nothing is left in the repo but what it started with"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "$label: the repo's git status is clean"
}

# The signal a test can actually deliver to a driver it starts, for the
# cases that interrupt one mid-run.
#
# SIGINT is the one that matters and the one to prefer: it is Ctrl-C, and it
# is what the drivers' rollback is written against. run-all.sh runs each
# file in the foreground, so the suite itself gets it. But bash sets SIGINT
# to SIG_IGN for a command it starts asynchronously when job control is off,
# and an ignored disposition is inherited by every process that command goes
# on to start -- through `set -m`, through a fork, through an exec. POSIX
# forbids a shell from trapping or restoring a signal that was ignored on
# entry, so nothing downstream can undo it. A test file run as
# `./tests/foo.sh &` -- which is how anyone reaches for concurrency, and how
# the reproduction for this was written -- therefore cannot deliver SIGINT
# to anything at all: `kill -INT` against the driver's whole process group
# is accepted by the kernel and discarded for every process in it, and the
# run continues to an ordinary success.
#
# That is what made the killed-mid-run cases fail whenever they were run
# that way -- not the load, the backgrounding -- and it is worth being exact
# about: the process group `set -m` hands out is the right one. It is the
# signal disposition inside it that no process group can fix.
#
# Falling back to SIGTERM there is not a looser test. The drivers have to
# treat the two identically, and TERM is how a killed process tree, a
# `timeout`, and a cancelled CI job all arrive anyway. What would be looser
# is sending a signal that nobody receives and then reading the driver's
# ordinary success as proof that an interrupt was handled -- which is
# exactly what the old case did on any machine where it was backgrounded.
#
# For one question, though, the fallback is not equivalent, and this is the
# place to learn that rather than to find it out. A driver's rollback hangs
# off its EXIT trap, and its INT/TERM traps are what route an interrupt into
# that. Under SIGTERM the routing is redundant for the repo: the signal at
# its default ends the driver's shell, bash runs that shell's EXIT trap on
# the way out, and the repo comes back whether the driver armed
# exit_on_interrupt or not. Under SIGINT it is not redundant at all -- a
# SIGINT arriving while the shell waits on a session that then exits cleanly
# is dropped, and a driver holding no trap of its own walks on and finishes
# the run with everything still sitting in the repo.
#
# So a case that stops a run and then asks only whether the repo came back
# can tell a driver that kept its interrupt trap from one that dropped it
# under SIGINT, and cannot under SIGTERM. That is the shape 51's bug
# actually took -- exit trap present and correct, interrupt trap missing --
# so it is not a hypothetical gap. It was weighed and left open on purpose
# (issue 67): under SIGTERM the pristine-repo promise is kept either way,
# what goes unchecked is only that the driver *carries* the trap, and
# run-all.sh and CI both run every file in the foreground, where SIGINT is
# available. The reader this paragraph is for is the person who backgrounds
# a file by hand and reads green. The three files this bears on are
# tests/fixed_location_conformance.sh, tests/pocock_driver_run.sh and
# tests/spec_kit_driver_run.sh -- each says the same where it picks its
# signal. tests/interrupted_run.sh stops a run too and is not one of them:
# it asks whether archimedes forwards a signal at all, against a stub driver
# that always arms its traps, so nothing there turns on which signal
# arrives.
#
# `trap -- '' SIGINT` is how bash reports a signal it may not touch, which
# is the whole of what is being asked here. A signal this shell has trapped
# itself reports its own handler instead and is not confused for one; a
# signal this shell has deliberately ignored reports the same empty handler
# and is treated the same way, correctly -- it cannot be delivered either.
deliverable_interrupt() {
  case "$(trap -p INT)" in
    "trap -- '' SIGINT"*) echo TERM ;;
    *) echo INT ;;
  esac
}

# The status a run stopped by <signal> is obliged to report, left at
# $EXPECTED_STATUS.
#
# The two literals are the point. The drivers' convention is 128 + the
# signal's number -- drivers/lib/repo-snapshot.sh arms `interrupted_by INT
# 130` and `interrupted_by TERM 143`, internal/driver/interrupt.go computes
# the sum, template/drivers/README.md states the rule -- so a table here
# that computed it too would be deriving the expected answer the way the
# code under test derives it, and would agree with a changed convention in
# silence. 130 and 143 are the assertion rather than a convenience to it:
# do not "simplify" them into arithmetic.
#
# Shared for the reason this file gives elsewhere about readings that can
# drift apart, which applies harder to an assertion: three copies are three
# chances for one to be quietly relaxed, and the relaxed one is the file
# that stops failing. tests/pocock_driver_run.sh,
# tests/spec_kit_driver_run.sh and tests/interrupted_run.sh each ask this on
# the line above their announce_interrupt_fallback.
# tests/fixed_location_conformance.sh sources this file and does not ask:
# it asserts no exit status on either path, on purpose (issue 67).
#
# Assigns rather than echoes, the way start_run_in_background leaves
# $RUN_PID, so that the branch below reaches the caller's counters: a `fail`
# inside a command substitution increments a subshell's copy of them and the
# suite reads green. <signal>
set_expected_status() {
  case "$1" in
    INT)  EXPECTED_STATUS=130 ;;
    TERM) EXPECTED_STATUS=143 ;;
    *) fail "set_expected_status: no status written down for SIG$1"
       return 1 ;;
  esac
}

# A copy of the shipped drivers tree at <dest>, with <override-shell-code>
# appended to its copy of lib/repo-snapshot.sh. Point archimedes at it with
# ARCHIMEDES_DRIVERS_DIR, or run one of its drivers directly, to see a driver
# meet a helper that cannot do its job.
#
# A copy rather than a function exported into the driver's environment,
# because a driver sources those helpers itself and the file's own definitions
# would land on top of anything a test had exported. Appended for the same
# reason from the other side: the last definition of a bash function is the
# one that stands, so an override written after the source line wins without
# the copy having to be edited in place.
#
# What this reaches is failure-path code with no cheap way to provoke it for
# real -- a fingerprinting that could not run needs a machine that has run out
# of temp files, and a driver's answer to that is worth pinning long before a
# machine like that turns up. Shared by both driver test files rather than
# written twice: they are asking the same question of two drivers that have to
# answer it the same way. <dest> <override-shell-code>
drivers_with_override() {
  local dest="$1" override="$2"
  # Checked, because a dest that survived would have cp nest the tree inside
  # it -- and a driver run out of a tree with no override in it passes every
  # assertion the caller was about to make for the wrong reason.
  rm -rf "$dest" || return 1
  cp -R "$TESTS_REPO_ROOT/drivers" "$dest" || return 1
  printf '\n%s\n' "$override" >> "$dest/lib/repo-snapshot.sh"
}

# Skip <file-name>, printing why, when the bash a *driver* would run under
# is older than 4.
#
# Two things need it and both belong to the drivers rather than to any test:
# every fixed-location driver guards for bash 4+ itself and refuses under an
# older one, and drivers/lib/repo-snapshot.sh needs it for the associative
# arrays its rollback is built on. Under an old bash there is therefore
# nothing left for a test that drives one to hold to anything.
#
# The version that decides is the one the drivers will get -- whatever
# `#!/usr/bin/env bash` finds for them -- and not the caller's own. They are
# usually the same shell, and when they are not it is the test that would be
# wrong: run under an old bash by hand, a file consulting its own shell
# would skip a floor the drivers could have cleared.
#
# Exits 77, the status run-all.sh reads as a skip, rather than returning:
# every caller has the same nothing left to do, and a second spelling of
# that would be the one that drifts. <file-name> <what-needs-bash-4>
skip_without_driver_bash_4() {
  local major
  major="$(env bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
  [ "${major:-0}" -ge 4 ] && return 0
  echo "skip: $1 ($2, and the bash a driver would run under here is $(env bash -c 'echo "$BASH_VERSION"' 2>/dev/null))"
  exit 77
}

# --- Starting a run and catching it in the middle --------------------------
#
# Four files stop a run partway through and all four have to get to the same
# place first: a run that is really under way, with a pid to aim at. Shared
# rather than copied into each, because every piece of the sequence encodes a
# reason that is not visible in the code carrying it, and four copies is four
# chances for one of them to lose a piece -- on the path nobody watches.
#
# What is deliberately not shared is what the four files disagree about on
# purpose: who gets signalled (see abandon_run), how long to wait, and what
# announces that the run is under way (see wait_until_under_way). Those are
# the questions the files ask, and a helper that answered them here would
# delete the distinctions they exist to draw.

# Start <cmd...> in the background with its output at <log-file>, leaving its
# pid at $RUN_PID.
#
# $RUN_PID is this section's one piece of shared state, and it does not exist
# until a run has been started. Everything below that reads it -- and every
# `wait` at a call site -- is only meaningful after this has been called for
# the run being asked about. Under the `set -u` this file runs with, reading
# it before then ends the whole test file rather than failing one assertion,
# which is the right way round: a case that waits on a run nobody started is
# not a case with a wrong answer.
#
# `set -m` is here for the signal disposition and not for the process group:
# a command bash starts asynchronously without job control has SIGINT set to
# SIG_IGN, a disposition inherited through every fork and exec beneath it and
# restorable by none of them -- deliverable_interrupt above says why at
# length -- so a run started without it could not be interrupted at all. The
# process group it also hands out is what two of the callers want and is
# incidental to the other two, which aim at a pid.
#
# <cmd...> is a plain argv, so the environment a run needs goes through `env`
# rather than assignments in front of a command word. That costs nothing that
# matters here: `env` execs what it was handed, so the pid is still the pid of
# the thing that was started, and its process group is still that thing's.
#
# Backgrounded even for a caller that means to wait for the run on the very
# next line: a run that is going to be stopped needs a pid to aim at, and one
# that is not has to be started identically, or the thing being stopped is not
# the thing that was checked.
start_run_in_background() { # <log-file> <cmd...>
  local log="$1"
  shift
  set -m
  "$@" >"$log" 2>&1 &
  RUN_PID=$!
  set +m
}

# Wait until <sentinel> says that run is really under way, up to <bound>
# tenths of a second. 0 once the sentinel is there, 1 if the bound was
# reached first.
#
# What makes a sentinel worth waiting for is when the run announces it: only
# once the run has really written into the repo, so that a test signalling on
# it is signalling a run there is something to undo.
#
# The sentinel is the caller's to name and the caller's to clear, and this
# owns no path of its own, because a path shared between runs is a path an
# abandoned run can still write to: tests/fixed_location_conformance.sh names
# its per driver precisely so a stub left waiting out its own backstop cannot
# drop a marker onto the next driver's verdict.
#
# The bound is the caller's for a related reason. 300 in the per-driver files
# and 600 in the two that go through archimedes are two answers to one
# question, and where the stub being waited for has a backstop of its own that
# is a third number again -- this one bounds the wait for a session to start,
# that one bounds the started session's wait for a signal. They may well be
# the same number; they are not the same bound, and joining them here would
# make them one.
wait_until_under_way() { # <sentinel> <bound>
  local waited=0
  until [ -f "$1" ] || [ "$waited" -ge "$2" ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  [ -f "$1" ]
}

# Stop the run at $RUN_PID for good and reap it. This is for the one outcome
# no caller can carry on from -- a run that never got under way -- so every
# caller says so and gives up; SIGKILL is what stops an abandoned run still
# writing into a fixture the next case is about to use.
#
# <reach> is the question the four files answer differently, and it is not a
# detail of the bail-out: it is the same choice the interrupt itself makes a
# few lines later at the call site. The two are spelled separately, and
# nothing here can hold them together -- so they have to be read together.
# A reach that stopped matching the `kill` below it would abandon a run one
# way and interrupt it another, and since both spellings reach a live
# process, neither would complain.
#
#   process-group  the two per-driver files, which start a driver themselves
#                  and signal it and its session together, the way a terminal
#                  signals its foreground process group.
#   process        tests/interrupted_run.sh and
#                  tests/fixed_location_conformance.sh, which start
#                  `archimedes` and aim at its pid alone, so that a driver
#                  hearing about the signal heard it from archimedes. A group
#                  signal there would hand the driver a copy the test itself
#                  arranged, and those files would be checking a path no
#                  operator takes.
abandon_run() { # <reach>
  case "$1" in
    process-group) kill -KILL -"$RUN_PID" 2>/dev/null ;;
    process)       kill -KILL "$RUN_PID" 2>/dev/null ;;
    # Recorded as a failure, the way start_run records a shape nothing
    # writes, and short of the `wait` below: a reach nothing here recognises
    # has killed nothing, so waiting on a run that is still going would hang
    # where a miscall should be a red suite.
    *) fail "abandon_run: asked for a reach that is neither a process nor its group: $1"
       return 1 ;;
  esac
  wait "$RUN_PID" 2>/dev/null
}

# The notice that goes with deliverable_interrupt having come back with the
# fallback: what the run below is about to be stopped with is not what this
# file says everywhere else, and someone reading the output should not have to
# work that out. Silent when SIGINT is deliverable, which is the ordinary case
# and needs no announcing.
#
# <what-this-file-does-with-it> is the caller's own words, and they differ on
# purpose: three files stop one run at a time and say "interrupting with",
# while tests/fixed_location_conformance.sh stops a run per driver and says
# "stopping runs with". One notice, and the sentence each file was written to
# finish. <signal> <what-this-file-does-with-it>
announce_interrupt_fallback() {
  if [ "$1" != "INT" ]; then
    echo "  (SIGINT is ignored in this shell and cannot be restored; $2 SIG$1)"
  fi
}
