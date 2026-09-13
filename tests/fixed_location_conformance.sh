#!/usr/bin/env bash
# The floor under every driver that declares output_mode: fixed-location.
#
# That mode's contract is a joint promise, and the half Archimedes cannot
# discharge belongs to the driver: the runner harvests the declared
# fixed_path and prunes the directories that empties, and the driver has to
# leave the target repo otherwise exactly as it found it. Both shipped
# drivers keep that promise by sourcing drivers/lib/repo-snapshot.sh --
# which is optional, invisible from the manifest, and until this file
# nothing failed when it was skipped. A third driver could declare the mode,
# pass manifest validation, harvest successfully, exit zero, and leave an
# operator's repository dirty.
#
# So: find every driver declaring the mode -- by reading the manifests, not
# from a list kept here, so one added tomorrow is covered tomorrow -- point
# each at a throwaway repo, stand a stub in for whatever CLI it runs, have
# that stub write beyond the declared fixed_path the way a real scaffolder
# or a real agent session does, and ask one question afterwards: is the repo
# as it was found?
#
# That question is asked of both ways a run can end, because the promise is
# made about both. A run that succeeds is the easy half. A run that is
# *stopped* -- a Ctrl-C, a `kill`, a supervisor, a cancelled CI job -- is the
# other, and it is the one that has to reach the rollback from a signal
# rather than from the end of the script. It was tested a driver at a time
# until this, and what that cost is on the record: the interrupt was being
# swallowed by both shipped drivers at once, for the same reason, and it
# took a flaky test under load to surface it. A bug present in every
# implementation of a promise is the signature of a promise nothing
# enumerates, which is what this file was written about in the first place.
#
# The ordering the contract asks for -- traps armed before anything writes
# to the target repo -- is checked here rather than trusted, and without
# racing the driver, which would be a test that passes whenever the machine
# is busy. The seam gives it: the stub session runs inside the target repo
# and announces itself only once it has written there, so a signal sent at
# that moment finds a driver that already has something of the run's sitting
# in someone else's repository. A driver that armed its traps first acts on
# it and puts the repo back. One that armed them afterwards never hears
# about it -- the session shuts down politely, and bash drops the copy it
# was holding for traps that were not set yet -- so the run walks on,
# finishes, and keeps the fixed_path back for a harvest that never comes,
# because archimedes harvests nothing out of a run it was told to stop. The
# map is left sitting in the repo, and that is what the one question
# catches.
#
# What the seam cannot see is a driver that writes with its own hands and
# arms only afterwards -- but still before running its session. Neither
# shipped driver writes anything itself, so for them it covers the whole of
# the ordering.
#
# And it is asked, last, of the repo an operator actually has -- a dirty one,
# with the session writing over the part that made it dirty. That is the one
# shape of "as it was found" no driver can deliver, because nothing keeps a
# copy of what an uncommitted file said, so what is required there is the
# nearest thing that can be had: the repo comes back dirty in exactly the way
# it started dirty, and the run says which of the operator's files it wrote
# over. A floor that asked only the first two questions would read stronger
# than any driver standing on it, which is the failure this file exists to
# catch rather than to commit.
#
# Twice, because the dirty path that matters most is the driver's own
# fixed_path. Work an operator had in flight there is replaced by the run and
# then moved out of the repo by the harvest, and every step of that is the run
# succeeding: keeping that file is the contract, so the repo comes back
# pristine rather than dirty and nothing about its state records that anything
# of theirs was there. What is left to ask is whether the run said so, and it
# is asked here rather than a driver at a time for the reason above -- the
# last obligation of this contract left to the per-driver tests was broken by
# both shipped drivers at once.
#
# This is a floor, not a replacement. What each driver does about the
# leftovers it finds is its own business and the two shipped ones answer
# differently on purpose (spec-kit restores and succeeds, pocock restores
# and fails the run naming the files), so nothing here asserts an exit
# status -- not on the success path, and not on the stopped one either,
# where 128 + the signal's number is an obligation every driver carries
# rather than one this mode adds. tests/pocock_driver_run.sh and
# tests/spec_kit_driver_run.sh remain where each driver's own behaviour is
# pinned down in detail, in both shapes an interrupt arrives in.
#
# No network and no billed call: the stubs are what keep this in the suite
# that runs on every push, rather than in the weekly
# ARCHIMEDES_TEST_LIVE_DRIVERS bucket, where a floor is no floor at all.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

# The drivers are driven rather than dissected -- nothing here sources
# repo-snapshot.sh, which would make this the first caller of a bash 4+
# library with no bash 4+ guard in front of it. Nothing in this file needs
# bash 4 either; it skips only because under an older one every
# fixed-location driver refuses at its own guard, and there is then nothing
# to hold to anything. Which bash that question is asked of, and why it is
# not this file's own, is written down once at the helper.
skip_without_driver_bash_4 "fixed_location_conformance.sh" \
  "the fixed-location drivers need bash 4+, so every one of them refuses and there is nothing to check here"

ROOT="$(cd "$HERE/.." && pwd)"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
STUB_BIN="$WORK/bin"
SESSION_LOG="$WORK/session-wrote"
# Where a stub session says it has finished writing and is now waiting to be
# signalled away, for the cases that stop a run halfway. Its `.expired`
# neighbour is how a session that waited the whole way out and gave up says
# so -- see the backstop in the stub.
#
# Exported to every run rather than only to the ones that will be stopped:
# which shape a session is standing in is the session's to know, and a second
# way of telling it -- a variable set for one shape and empty for the rest --
# would be a second answer to that. Only the shape that waits reads this.
#
# Repointed per driver by start_run, and named after it, because the one
# path a run can be abandoned on leaves a stub behind: a session whose
# archimedes was killed for never announcing itself goes on waiting out its
# own backstop, and writes `.expired` a minute later with nobody left to
# read it. Shared between drivers, that write would land on the next
# driver's verdict and fail it for the previous driver's mistake.
SESSION_HANGING="$WORK/hanging"

# The same choice tests/interrupted_run.sh and the two per-driver files
# make, for the reason spelled out at deliverable_interrupt: a test file that
# was itself backgrounded cannot deliver SIGINT to anything, and a driver has
# to treat the two identically anyway.
#
# What is worth adding here, because this is the floor, is what the fallback
# costs, since the two signals do not reach a driver's shell alike. A SIGINT
# arriving while that shell waits on a session the session then handles
# cleanly is dropped, unless the shell holds a trap of its own to be run
# instead -- so a driver missing that trap walks on and finishes the run. A
# SIGTERM at its default ends the shell, and bash runs the shell's EXIT trap
# on the way out -- so a driver whose rollback hangs off EXIT puts the repo
# back under SIGTERM whether it armed the signal or not.
#
# The repo really does come back in that second case, so there is nothing
# here to fail over. But it does mean this is a weaker floor under SIGTERM,
# and weaker in exactly the place that matters most: a driver that kept its
# exit trap and stopped arming its interrupt -- which is the shape 51's bug
# actually took -- is caught by a foreground run of this file and not by a
# backgrounded one. run-all.sh runs every file in the foreground, and so
# does CI, which is where "runs on every push" is cashed; a backgrounded run
# is a person's, and this says which signal it used at the top.
#
# What does not vary is whether this file can tell that it is looking: the
# drivers written below to fail it are written to fail it under either
# signal, so a run that ends green has checked something either way.
INTERRUPT="$(deliverable_interrupt)"
[ "$INTERRUPT" = "INT" ] || echo "  (SIGINT is ignored in this shell and cannot be restored; stopping runs with SIG$INTERRUPT)"

# What the stub session writes besides the driver's fixed_path. Named here
# rather than inside the stub because the assertions below have to ask
# whether these ever reached the repo: a driver that failed before its
# session ran would leave the repo pristine and pass a check that never
# happened.
export CONFORMANCE_LEFTOVER="conformance-leftover.md"
export CONFORMANCE_LEFTOVER_DIR="conformance-leftovers"
export CONFORMANCE_EMPTY_DIR="conformance-empty"

# Work the operator already had in the repo, uncommitted, when the run
# started. Seeded only for the second pass below, and the stub writes over it
# only where it finds it, so the first pass is untouched. A repo somebody is
# working in is normally in this state, which is why it gets a pass of its own
# rather than a line in the one above.
export CONFORMANCE_PRIOR_WORK="operator-uncommitted.md"

# Every driver directory under <drivers-dir> whose manifest declares
# fixed-location, name-ordered. Read from the manifests because that is
# where a driver declares the mode: a list kept here would be a second
# answer to "which drivers promise this", and the whole point is that the
# next driver to make the promise is covered by making it.
fixed_location_drivers() { # <drivers-dir>
  local manifest
  for manifest in "$1"/*/driver.yaml; do
    [ -e "$manifest" ] || continue
    [ "$(manifest_field "$manifest" output_mode)" = "fixed-location" ] || continue
    basename "$(dirname "$manifest")"
  done | sort
}

# The external CLIs a driver's command runs, taken from the `command -v`
# guards it makes before it touches anybody's repo -- the one place a driver
# says out loud what it wraps. Stubbing exactly those is what lets this
# stand a session up for a driver nobody here has read: the seam is the same
# one tests/pocock_driver_run.sh and tests/spec_kit_driver_run.sh use, a
# name earlier on PATH.
#
# A driver that names none is not covered rather than quietly passed over --
# see the refusal below, which exists because the alternative is this file
# making the real, billed call it was written to avoid.
#
# All of them or none of them, and for the same reason: a guard written
# `command -v "$CLI"` names nothing that can be read off the page, and
# answering with the rest would be the worst outcome available -- the driver
# run with some of what it wraps stood in for and the remainder real.
session_clis() { # <driver-command>
  local guards names
  guards="$(grep -c '^[[:space:]]*command -v ' "$1")"
  [ "$guards" -gt 0 ] || return 0
  names="$(sed -n 's/^[[:space:]]*command -v \([A-Za-z0-9_.+-][A-Za-z0-9_.+-]*\).*/\1/p' "$1")"
  [ "$guards" -eq "$(printf '%s\n' "$names" | grep -c .)" ] || return 0

  # git and bash are never stood in for. A driver naming either is naming a
  # dependency rather than the thing it runs, and putting a stub earlier on
  # PATH under one of those names would replace what this check is made of:
  # the fixture repo, the snapshot the drivers diff against, and the stub
  # session itself all go through them. A driver whose guards name nothing
  # else is refused below, which is the safe end of that.
  printf '%s\n' "$names" | sort -u | grep -vxF -e git -e bash
}

# Stands in for whatever CLI a driver runs inside the target repo. One stub
# serves every driver because every driver in this mode is in the same
# position: something it does not control writes into someone else's
# repository, and the driver has to answer for what that something wrote.
make_session_stub() { # <bin-dir> <cli-name>
  cat > "$1/$2" <<'STUB'
#!/usr/bin/env bash
# A session that did what it was asked and then some -- `specify init`
# unpacking a toolchain, an agent handed the run of a repo and asked in a
# sentence for one file. It writes the driver's declared fixed_path, and
# then writes past it in every shape a cleanup can miss.
#
# That is one of three shapes, and the caller says which it wants by name in
# $CONFORMANCE_SESSION_SHAPE. The other two write the fixed_path and stop
# there: one waits to be signalled away, for a run this file stops halfway,
# and one simply returns, for the run that asks what a driver says about the
# operator's own copy of the file it was run for. Why neither of them writes
# past the map is at the branch that divides them.
#
# Everything is written through $CONFORMANCE_REPO rather than into $PWD, so
# a driver that runs its session from somewhere other than the repo is
# still given a repo to answer for.
set -uo pipefail

repo="$CONFORMANCE_REPO"
fixed="$CONFORMANCE_FIXED_PATH"

# Each call writes something different at the fixed path: a driver may
# compare what its session produced against what was there before it --
# spec-kit's does, to catch a session that did nothing -- and two identical
# writes would read as exactly that.
calls=$(( $(cat "$CONFORMANCE_LOG.calls" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$calls" > "$CONFORMANCE_LOG.calls"

# Recorded outside the repo, because if the driver is doing its job every
# one of these is gone by the time anything looks: the log is the only
# evidence left that the session ran at all.
wrote() { printf '%s\n' "$1" >> "$CONFORMANCE_LOG"; }

write_file() { # <relpath> <content>
  # Never the fixed path, whatever a driver declares it to be. That one the
  # driver is allowed to keep, so writing junk there would be asking it to
  # fail a promise it never made.
  case "$fixed" in "$1" | "$1"/*) return 0 ;; esac
  mkdir -p "$(dirname "$repo/$1")"
  printf '%s\n' "$2" > "$repo/$1"
  wrote "$1"
}

mkdir -p "$(dirname "$repo/$fixed")"
printf '# the one file the driver was run for (write %s)\n' "$calls" > "$repo/$fixed"
wrote "$fixed"

# And then whatever the shape it was asked for calls for. Two of the three
# stop here, and neither writes a thing past the map. That is deliberate in
# both: leftovers would hand the driver a second reason to end its run badly
# -- pocock fails a run for them by design -- and each case would then come
# out the way it was expected to for that reason, while the thing it meant
# to ask went unasked.
case "$CONFORMANCE_SESSION_SHAPE" in
  # The ordinary one, which goes on to the leftovers below. Named rather
  # than reached by falling out of the bottom of this, so that the refusal
  # at the end of it can exist at all: a shape nobody wrote is a mistake in
  # this file, and left unnamed it would arrive as the misbehaving session
  # and be read as an answer about one.
  writes-past) ;;
  waits)
    # For a run that is going to be stopped rather than allowed to finish:
    # say that the map really is in the repo, and then wait. This is where a
    # real session spends its minutes, and it is the moment the driver
    # running it has the most to answer for -- something of the run's is in
    # the repo, and on a stopped run nothing will harvest it out. What the
    # silence above buys here is that a driver which shrugged the signal off
    # entirely cannot go unnoticed behind a run failed over leftovers;
    # tests/pocock_driver_run.sh made the same correction to its own
    # interrupted case.
    #
    # Caught and shut down cleanly, which is what a well-behaved CLI does
    # with a Ctrl-C -- and it is the only shape of interrupted session that
    # asks the driver anything. Bash reads a child that ended any way other
    # than killed-by-the-signal as having handled the interrupt, and drops
    # the copy it was holding for its own traps; a driver with none of its
    # own then walks straight past the operator's signal and finishes the
    # run. Let the session be killed by the signal instead and it takes the
    # driver's shell with it, and bash runs that shell's EXIT trap on the
    # way out -- so every driver would put the repo back whether it had
    # armed anything or not, and this would be checking nothing.
    #
    # This is also the shape the bug came in: both shipped drivers swallowed
    # the interrupt at once, and what they were being handed was a session
    # that shut down politely. tests/pocock_driver_run.sh and
    # tests/spec_kit_driver_run.sh drive both shapes; a floor needs the one
    # that can tell two drivers apart.
    trap 'exit 0' INT TERM
    touch "$CONFORMANCE_HANG_SENTINEL"

    # Nothing releases this but the signal, and the bound is a backstop for
    # one that never arrives. Reaching it is recorded, because a session
    # that returns on its own hands the driver an ordinary run to finish:
    # the conformant ones then put the repo back on their success path and
    # the broken ones leave it dirty on theirs, both for reasons that have
    # nothing to do with an interrupt. Every verdict on a stopped run checks
    # this first, so that neither can be read as an answer about being
    # stopped.
    waited=0
    while [ "$waited" -lt 600 ]; do sleep 0.1; waited=$((waited + 1)); done
    touch "$CONFORMANCE_HANG_SENTINEL.expired"
    exit 0
    ;;
  stops)
    # For the run that asks whether a driver says anything about the
    # operator's own copy of the file it was run for: that file has just
    # been replaced, and nothing else has happened. The note being asked
    # about is printed on the driver's success path, so this shape has to
    # reach one -- a session that wrote past the map hands pocock a run to
    # fail, and a failed run never gets there.
    exit 0
    ;;
  *)
    echo "the stub session was asked for a shape it does not have: $CONFORMANCE_SESSION_SHAPE" >&2
    exit 1
    ;;
esac

write_file "$CONFORMANCE_LEFTOVER" "an untracked file at the root of the repo"
write_file "$CONFORMANCE_LEFTOVER_DIR/notes/left-behind.md" "a file under directories the run created"
# A scaffolder shipping its own .gitignore, and something for it to hide: a
# cleanup that asked git which paths were untracked without asking for the
# ignored ones too walks straight past this.
write_file "$CONFORMANCE_LEFTOVER_DIR/.gitignore" "hidden/"
write_file "$CONFORMANCE_LEFTOVER_DIR/hidden/quiet.txt" "an ignored file"

# An edit to a file that was already tracked -- a change rather than a
# leftover, and the one a cleanup written as "delete whatever appeared"
# leaves sitting in the operator's working tree.
tracked="$(git -C "$repo" ls-files | head -1)"
if [ -n "$tracked" ] && [ "$tracked" != "$fixed" ]; then
  printf '// tidied up while I was here\n' >> "$repo/$tracked"
  wrote "$tracked"
fi

# Work that was already in the repo, uncommitted, before this run started --
# the shape no cleanup can undo, because nothing kept a copy of what it said.
# Written directly rather than through write_file: that one refuses to touch
# the fixed path and logs a path the driver is expected to have removed, and
# neither is true here.
if [ -n "${CONFORMANCE_PRIOR_WORK:-}" ] && [ -f "$repo/$CONFORMANCE_PRIOR_WORK" ]; then
  printf '%s\n' "written over by the session" > "$repo/$CONFORMANCE_PRIOR_WORK"
  wrote "$CONFORMANCE_PRIOR_WORK"
fi

# A directory the run created and left empty. git tracks no directories, so
# a driver that asked `git status` whether it had finished cleaning up would
# be told yes.
case "$fixed" in
  "$CONFORMANCE_EMPTY_DIR" | "$CONFORMANCE_EMPTY_DIR"/*) ;;
  *)
    mkdir -p "$repo/$CONFORMANCE_EMPTY_DIR/inner"
    wrote "$CONFORMANCE_EMPTY_DIR/"
    ;;
esac

exit 0
STUB
  chmod +x "$1/$2"
}

# Point <driver-name>, resolved out of <drivers-dir>, at a fresh throwaway
# repo with a stub standing in for every CLI it runs, and start the run in
# one of the shapes below -- what the repo starts as, and what the session
# does once it has written the map. The shape is named rather than reached
# by which of several flags were left empty: they do not compose, and an
# empty string standing in for one of them reads like a mistake.
#
# Started in the background, always. Not because either case wants it that
# way -- the one that lets a run finish just waits for it on the next line
# -- but because the one that stops a run needs a pid to aim at, and both
# have to be started identically or the thing being stopped is not the thing
# that was checked. `set -m` comes with that: a command bash starts
# asynchronously without job control has SIGINT set to SIG_IGN, a
# disposition inherited through every fork and exec beneath it and
# restorable by none of them, so a run started without it could not be
# interrupted at all. The process group `set -m` also hands out is
# incidental here -- archimedes puts the driver in one of its own and
# forwards to that.
#
# Leaves the run at $ARCHIMEDES_PID, the repo at $REPO and the session's
# account of itself at $SESSION_LOG for the caller to judge -- what counts
# as a pass differs between the drivers this holds to the contract and the
# deliberately broken ones that prove it can tell.
#
# Two of the four shapes seed the repo with work the operator had left
# uncommitted, which the stub session then writes over, and neither can share
# the verdict above -- one is meant to come back dirty in exactly the way it
# started dirty, and the other is about what the run *said* rather than what
# it left. Each has a verdict of its own below.
#
# Returns non-zero, silently, only when the check cannot be carried out at
# all -- the driver names no CLI to stand in for.
start_run() { # <drivers-dir> <driver-name> <shape>
  local dir="$1" name="$2" shape="$3" manifest driver_command fixed clis cli
  local session
  # What each shape asks of the session. Two vocabularies and not one: these
  # are the cases this file is about, and the values on the right are what a
  # stub in another process does about them, which is a smaller set -- two of
  # the four want the same session.
  case "$shape" in
    # A session that writes past the map, against the repo as the fixture
    # builds it.
    misbehaving-session) session=writes-past ;;
    # The same session, against a run that will be signalled while it is
    # still inside the repo.
    stopped-mid-session) session=waits ;;
    # The same session again, against a repo that already held work the
    # operator had not committed, at a path of the suite's own.
    over-prior-work)     session=writes-past ;;
    # And the one where that work is at the driver's *own* fixed_path, which
    # the session replaces and the harvest then carries out of the repo. An
    # obedient session, for the reason given at the stub's branch.
    over-the-fixed-path) session=stops ;;
    *) fail "start_run: asked for a shape nothing writes, $shape"; return 1 ;;
  esac
  SESSION_HANGING="$WORK/hanging-$name"
  manifest="$dir/$name/driver.yaml"
  driver_command="$dir/$name/$(manifest_field "$manifest" command)"
  fixed="$(manifest_field "$manifest" fixed_path)"

  # Refused rather than run: with nothing stubbed the driver would reach
  # whatever it actually wraps, and for both drivers here that is a real,
  # billed, minutes-long `claude -p` inside the suite that runs on every
  # push. The caller says so; this only declines.
  clis="$(session_clis "$driver_command")"
  [ -n "$clis" ] || return 1

  rm -rf "$STUB_BIN"
  mkdir -p "$STUB_BIN"
  # Read rather than expanded, the way tests/run-all.sh reads its names: an
  # unquoted expansion would split and glob whatever a driver happened to
  # have written on that line.
  while IFS= read -r cli; do
    [ -n "$cli" ] && make_session_stub "$STUB_BIN" "$cli"
  done <<< "$clis"

  rm -rf "$REPO"
  make_widget_repo "$REPO"
  # And what each shape asks of the repo, which is the other half of the
  # table above and is here rather than in it because $fixed is not known
  # until the manifest has been read. Two of the four want the repo the
  # fixture builds and say nothing.
  #
  # The fixed_path is seeded through a `mkdir -p`, because a driver is free
  # to declare a nested one -- spec-kit's is .specify/memory/constitution.md
  # -- and the floor is where this has to work without knowing which driver
  # it is asking. The directories that makes are the operator's, made before
  # the run: the driver's rollback leaves them alone, and what removes them
  # afterwards is archimedes pruning what the harvest emptied.
  case "$shape" in
    over-prior-work)
      printf '%s\n' "notes the operator had not committed" > "$REPO/$CONFORMANCE_PRIOR_WORK"
      ;;
    over-the-fixed-path)
      mkdir -p "$(dirname "$REPO/$fixed")"
      printf '%s\n' "the map I was half way through writing" > "$REPO/$fixed"
      ;;
  esac
  rm -f "$SESSION_LOG" "$SESSION_LOG.calls" "$WORK/harvested.md" \
    "$SESSION_HANGING" "$SESSION_HANGING.expired"

  # ARCHIMEDES_DRIVERS_DIR rather than the copy inside the binary, so the
  # drivers this runs are the same files the discovery above read. Which
  # layer supplies a driver is tests/driver_ownership.sh's question.
  set -m
  PATH="$STUB_BIN:$PATH" \
  ARCHIMEDES_DRIVERS_DIR="$dir" \
  CONFORMANCE_REPO="$REPO" \
  CONFORMANCE_FIXED_PATH="$fixed" \
  CONFORMANCE_LOG="$SESSION_LOG" \
  CONFORMANCE_SESSION_SHAPE="$session" \
  CONFORMANCE_HANG_SENTINEL="$SESSION_HANGING" \
    "$ARCHIMEDES_BIN" run-driver "$name" "$REPO" "$WORK/harvested.md" \
    >"$WORK/run.log" 2>&1 &
  ARCHIMEDES_PID=$!
  set +m
  return 0
}

# The three shapes a run is allowed to finish in, one wrapper each. Still
# wrappers now that the shape is one named argument, because a call site
# reading `run_over_prior_work "$ROOT/drivers" "$name"` says which case is
# being asked about, and because there is then one place that knows a run
# started here has to be waited for -- the fourth shape, below, does not wait
# but signals, and it is the only one that differs in more than a word.
#
# A run allowed to finish against the repo as the fixture builds it: the
# shape the success half of the contract is checked in.
# <drivers-dir> <driver-name>
run_with_misbehaving_session() {
  start_run "$1" "$2" misbehaving-session || return 1
  wait "$ARCHIMEDES_PID" 2>/dev/null
  return 0
}

# The same run, against a repo that already held work the operator had not
# committed, at a path the suite chose. <drivers-dir> <driver-name>
run_over_prior_work() {
  start_run "$1" "$2" over-prior-work || return 1
  wait "$ARCHIMEDES_PID" 2>/dev/null
  return 0
}

# And the same run against a repo whose uncommitted work is at the one path
# the driver itself declared it would write -- the operator's own context
# map, half written, when the run they asked for starts.
#
# The one shape of that the rollback is not allowed to undo, because keeping
# the fixed_path is the contract: the run replaces it, archimedes moves the
# result out of the repo, and the operator's version is gone in a sequence
# where every step was a success. The session obeys here, which no other
# shape asks of it -- see the stub's branch for why it has to.
# <drivers-dir> <driver-name>
run_over_work_at_the_fixed_path() {
  start_run "$1" "$2" over-the-fixed-path || return 1
  wait "$ARCHIMEDES_PID" 2>/dev/null
  return 0
}

# The same run, stopped the way an operator stops one: signalled once the
# session says it is really writing inside the repo, and then waited out.
#
# The signal goes to the archimedes process, by pid and never to a group,
# because that is how every way of stopping a run other than a terminal's
# Ctrl-C arrives -- and archimedes forwarding it to the driver's own group
# is what tests/interrupted_run.sh holds it to. Signalling the group here
# instead would hand the driver a copy this file arranged, and then this
# would be checking a path no operator takes.
#
# 0 once the run has ended, 1 when the driver names no CLI to stand in for,
# 2 when the session never got as far as announcing itself -- which no
# caller can carry on from, since a run that never wrote anything leaves a
# pristine repo and would pass for the wrong reason.
# <drivers-dir> <driver-name>
stop_the_run_halfway() {
  local waited=0
  start_run "$1" "$2" stopped-mid-session || return 1

  # The same minute the stub's own backstop allows, and for the same reason
  # -- reaching either is a broken test rather than a slow machine -- but
  # they are independent bounds: this one waits for a session to start, and
  # that one waits, once it has, for a signal.
  until [ -f "$SESSION_HANGING" ] || [ "$waited" -ge 600 ]; do
    sleep 0.1; waited=$((waited + 1))
  done
  if [ ! -f "$SESSION_HANGING" ]; then
    kill -KILL "$ARCHIMEDES_PID" 2>/dev/null
    wait "$ARCHIMEDES_PID" 2>/dev/null
    return 2
  fi

  kill -"$INTERRUPT" "$ARCHIMEDES_PID" 2>/dev/null
  wait "$ARCHIMEDES_PID" 2>/dev/null
  return 0
}

# Whether the stub session got far enough to write <relpath> into the repo.
# Asked before the repo is judged, because a driver that refused at its
# first dependency check leaves a pristine repo too, and would pass a check
# that never took place. Read from the log rather than from the repo: if the
# driver is doing its job, none of it is still there by the time anything
# looks.
session_wrote() { # <relpath>
  grep -qxF "$1" "$SESSION_LOG" 2>/dev/null
}

# The same question for a run allowed to finish, where what makes the check
# a check is the session having written past the fixed path.
session_wrote_beyond_the_fixed_path() {
  session_wrote "$CONFORMANCE_LEFTOVER"
}

# The same question for the second pass: did the session get as far as writing
# over the work the repo already had? Asked for the same reason -- a driver
# that never reached a session leaves that file untouched too.
session_wrote_over_the_prior_work() {
  grep -qxF "$CONFORMANCE_PRIOR_WORK" "$SESSION_LOG" 2>/dev/null
}

# The verdict on a run that has just happened, for a driver expected to keep
# the contract: did the session get far enough for there to be anything to
# keep, and did the repo come back as it was found? Written once because the
# shipped drivers and the third one written to pass are asked exactly the
# same thing, and two spellings of it would be two floors.
# <driver-name> <fixed-path>
assert_kept_the_repo_as_it_found_it() {
  if session_wrote_beyond_the_fixed_path; then
    pass "$1: the run reached a session, and the session wrote into the repo beyond $2"
  else
    fail "$1: the run reached a session, and the session wrote into the repo beyond $2"
    cat "$WORK/run.log" >&2
  fi
  assert_widget_repo_pristine "$REPO" "$1"
}

# What every verdict on a stopped run has to establish before anything else:
# that the run ended because it was signalled. The alternative is the
# session's backstop expiring and handing the driver an ordinary run to
# finish -- and a conformant driver puts the repo back on that path while a
# broken one leaves it dirty on that path, so both verdicts below would
# still come out the way they were expected to, having checked nothing.
# <label>
assert_the_run_was_stopped() {
  assert_file_missing "$SESSION_HANGING.expired" \
    "$1: the run ended because it was signalled, rather than because the session gave up waiting and let it finish"
}

# The verdict on a run that has just been stopped, for a driver expected to
# keep the contract. The same question as above, deliberately -- it is the
# same promise, and what differs is only how the run ended. What makes it a
# question about the ordering as well is when it is asked: the session had
# already written into the repo before it announced itself, so a driver that
# had not set its rollback up by then had nothing standing by for the whole
# time someone else's repository was being written to.
# <driver-name> <fixed-path>
assert_kept_the_repo_when_stopped() {
  assert_the_run_was_stopped "$1, stopped mid-session"
  if session_wrote "$2"; then
    pass "$1, stopped mid-session: the session had written $2 into the repo by the time the signal went, and a stopped run leaves nothing to harvest it"
  else
    fail "$1, stopped mid-session: the session had written $2 into the repo by the time the signal went, and a stopped run leaves nothing to harvest it"
    cat "$WORK/run.log" >&2
  fi
  assert_widget_repo_pristine "$REPO" "$1, stopped mid-session"
}

# The verdict on a stopped run for a driver written to fail it: the repo has
# to come back dirty, and dirty because the session really wrote there.
# Written once because two different mistakes -- never putting the repo back
# at all, and setting the rollback up only once the session has already
# written -- have to be caught by one check, or this is two floors again.
# <driver-name> <fixed-path> <what-is-wrong-with-it>
assert_caught_when_stopped() {
  assert_the_run_was_stopped "$1, stopped mid-session"
  if session_wrote "$2" && ! widget_repo_is_pristine "$REPO"; then
    pass "$1: $3 is caught by stopping the run"
  else
    fail "$1: $3 is caught by stopping the run (the repo came back pristine, so this check cannot tell)"
    cat "$WORK/run.log" >&2
  fi
}

# The verdict on the second pass, where the repo was already dirty and the
# session wrote over the part that made it dirty. Two different things are
# being asked, and the contract turns on both:
#
#   the repo comes back dirty in exactly the way it started dirty -- the
#   driver's cleanup did not take the operator's file with it, which is the
#   easy half and the one the shipped drivers already got right; and
#
#   the run said so. Nothing can put those contents back, so a driver that
#   tidied up silently would leave an operator with a file they will find
#   rewritten one day with no record of when or by what. Saying it is the
#   whole of what is available here, so saying it is required.
# <driver-name>
assert_named_the_work_it_wrote_over() {
  if session_wrote_over_the_prior_work; then
    pass "$1: the run reached a session, and the session wrote over work the repo already had uncommitted"
  else
    fail "$1: the run reached a session, and the session wrote over work the repo already had uncommitted"
    cat "$WORK/run.log" >&2
  fi

  # WIDGET_REPO_PRISTINE plus the operator's own file, which sorts between the
  # two entries it already names.
  assert_eq "$(widget_repo_leftovers "$REPO")" ".git $CONFORMANCE_PRIOR_WORK src " \
    "$1: nothing is left in the repo but what it started with and the operator's own file"
  assert_eq "$(git -C "$REPO" status --porcelain)" "?? $CONFORMANCE_PRIOR_WORK" \
    "$1: the repo is dirty in exactly the way it was dirty before, and no other"

  if grep -qF "$CONFORMANCE_PRIOR_WORK" "$WORK/run.log" 2>/dev/null; then
    pass "$1: the run names the uncommitted file it wrote over rather than tidying up around it in silence"
  else
    fail "$1: the run names the uncommitted file it wrote over rather than tidying up around it in silence"
    cat "$WORK/run.log" >&2
  fi
}

# The verdict on the fourth pass, where the work the repo already had was at
# the one path the driver declared it would write. The repo cannot answer this
# one: the rollback keeps the fixed_path by contract, the harvest then moves
# it out, and what comes back is pristine -- the same repo a run against a
# clean one leaves, with nothing in it to say the operator ever had a version
# of their own. That much is checked anyway: a driver that walked off with the
# operator's directories, or left its own behind, is wrong here in the
# ordinary way. So is the harvest, because a run that failed has nothing to
# say on a success path it never reached, and its silence below would be read
# as an answer to a question it was never asked.
#
# What can only be asked of the run is whether it said so. Nothing holds a
# copy of what that file said, and unlike every other path the run wrote over
# this one is not even left sitting there rewritten -- it is carried out of
# the repo -- so an operator who is not told at the moment it happens has no
# way of finding out later that it did. Which is why naming it is required
# here, of every driver declaring the mode, rather than left to each driver's
# own tests to remember. <driver-name> <fixed-path>
assert_named_the_file_it_was_run_for() {
  if session_wrote "$2"; then
    pass "$1: the run reached a session, and the session wrote its own $2 over the one the repo already had uncommitted"
  else
    fail "$1: the run reached a session, and the session wrote its own $2 over the one the repo already had uncommitted"
    cat "$WORK/run.log" >&2
  fi

  # WIDGET_REPO_PRISTINE exactly, and not the prior-work pass's "pristine plus
  # the operator's own file": that file was the fixed_path, so the harvest
  # took it, and for a nested one archimedes then prunes the directories the
  # seeding made.
  assert_widget_repo_pristine "$REPO" "$1, over work at $2"
  assert_file_exists "$WORK/harvested.md" \
    "$1: the run succeeded and the map was harvested -- which is what makes the operator's version gone rather than merely overwritten"

  if grep -qF "$2" "$WORK/run.log" 2>/dev/null; then
    pass "$1: the run names $2 as work of the operator's it replaced, rather than replacing it and carrying it away in silence"
  else
    fail "$1: the run names $2 as work of the operator's it replaced, rather than replacing it and carrying it away in silence"
    cat "$WORK/run.log" >&2
  fi
}

# Stop a run and say so if it could not be stopped, leaving the caller to
# judge only the runs there is something to judge. Every caller is in the
# same position by the time it gets here -- a refusal cannot arise, since
# each driver has already had a session stood up out of its own guards --
# so the only outcome to tell apart is a session that never announced
# itself, and a second spelling of that bail-out would be the one that
# stops matching. <drivers-dir> <driver-name>
stopped_run_or_fail() {
  local stopped
  stop_the_run_halfway "$1" "$2"; stopped=$?
  case "$stopped" in
    0) return 0 ;;
    2) fail "$2, stopped mid-session: the run got as far as a session writing in the repo (timed out waiting for one)" ;;
    *) fail "$2, stopped mid-session: names the CLI it runs, so a session can be stood up for it" ;;
  esac
  cat "$WORK/run.log" >&2
  return 1
}
echo "which drivers this covers:"

SHIPPED="$(fixed_location_drivers "$ROOT/drivers")"
if [ -n "$SHIPPED" ]; then
  pass "the drivers declaring fixed-location are found by reading the manifests: $(echo "$SHIPPED" | tr '\n' ' ')"
else
  fail "the drivers declaring fixed-location are found by reading the manifests (found none, so everything below would pass vacuously)"
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  fixed_path="$(manifest_field "$ROOT/drivers/$name/driver.yaml" fixed_path)"

  echo ""
  echo "$name, run against a session that writes beyond its fixed_path:"

  if ! run_with_misbehaving_session "$ROOT/drivers" "$name"; then
    fail "$name: names every CLI it runs in a \`command -v <name>\` guard, so a stub session can be stood up for it -- without one this check would have to run whatever the driver really wraps, which in this mode is a billed call"
    continue
  fi

  assert_kept_the_repo_as_it_found_it "$name" "$fixed_path"

  echo ""
  echo "$name, stopped while that session was still writing:"

  stopped_run_or_fail "$ROOT/drivers" "$name" || continue
  assert_kept_the_repo_when_stopped "$name" "$fixed_path"

  echo ""
  echo "$name, run against a session that writes over work the repo already had:"

  run_over_prior_work "$ROOT/drivers" "$name" \
    || fail "$name: names every CLI it runs, so a stub session can be stood up for it"
  assert_named_the_work_it_wrote_over "$name"

  echo ""
  echo "$name, run against a repo whose uncommitted work was at $fixed_path:"

  run_over_work_at_the_fixed_path "$ROOT/drivers" "$name" \
    || fail "$name: names every CLI it runs, so a stub session can be stood up for it"
  assert_named_the_file_it_was_run_for "$name" "$fixed_path"
done <<< "$SHIPPED"

echo ""
echo "the check itself, against drivers written to fail it and to pass it:"

# A drivers directory of its own, holding a third driver that keeps the
# contract and a third driver that does not. Both are what this file exists
# for: neither has a test of its own anywhere, and the point is that neither
# needs one.
SCRATCH="$WORK/drivers"
mkdir -p "$SCRATCH"
cp -R "$ROOT/drivers/lib" "$SCRATCH/lib"

# Keeps the contract, and gets there the documented way: guard for bash 4,
# source the shared helpers at ../lib/, snapshot before anything runs, arm
# the interrupt before anything writes, put the repo back on every exit
# path, keep only the declared fixed_path, and say on the way out if the
# operator had a version of that path of their own. Nothing here is copied
# from either shipped driver's specifics -- it is the route
# drivers/README.md describes, written out by someone reading it, which is
# why it has to hold to the whole of this file: a documented route that
# failed the floor would be a worse bug than a driver that did.
mkdir -p "$SCRATCH/conformant"
cat > "$SCRATCH/conformant/driver.yaml" <<'YAML'
name: conformant
description: A third fixed-location driver that keeps the pristine-repo contract.
output_mode: fixed-location
fixed_path: THIRD.md
command: run.sh
YAML
cat > "$SCRATCH/conformant/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: run.sh <repo-path>" >&2; exit 1; }
REPO_PATH="$1"
FIXED="THIRD.md"

command -v conformance-session >/dev/null 2>&1 || {
  echo "conformance-session CLI not found on PATH" >&2; exit 1; }
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "this driver needs bash 4+ (running ${BASH_VERSION})" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

SNAPSHOT="$(mktemp)"
snapshot_repo_state "$REPO_PATH" > "$SNAPSHOT"

RESTORE_ON_EXIT=1
cleanup() {
  local status=$?
  if [ "$RESTORE_ON_EXIT" -eq 1 ]; then
    restore_repo_state "$REPO_PATH" "$SNAPSHOT" \
      || echo "could not roll $REPO_PATH back to how it was found" >&2
  fi
  rm -f "$SNAPSHOT"
  exit "$status"
}
trap cleanup EXIT

# Before the session, which is the only thing here that writes to the repo.
exit_on_interrupt "$REPO_PATH"

( cd "$REPO_PATH" && conformance-session ) >&2 || {
  echo "the session failed" >&2; exit 1; }
[ -f "$REPO_PATH/$FIXED" ] || { echo "the session did not write $FIXED" >&2; exit 1; }

restore_repo_state "$REPO_PATH" "$SNAPSHOT" "$FIXED"
report_kept_paths_replaced "$REPO_PATH" "$SNAPSHOT" "$FIXED" \
  || echo "could not work out whether this run replaced uncommitted work at $REPO_PATH/$FIXED" >&2
RESTORE_ON_EXIT=0
DRIVER

# Keeps the contract on the way a run ends normally, and loses it on the way
# a run is stopped: everything the conformant one does, with the whole
# rollback -- the exit trap and the interrupt that reaches it -- set up
# after the session instead of before it. This is the driver 62 left
# reachable, and it is a shape somebody writes on purpose: the restore reads
# as an end-of-run step, and the trap as a safety net over the lines that
# follow it.
#
# It passes the success case above, which is the point of having it. A run
# that finishes reaches the restore either way, so nothing anybody could
# read off a successful run tells it apart from the conformant one. What
# tells it apart is a signal arriving while its session is writing, and it
# is worth being exact about how, because the two signals get there
# differently and both have to catch it or a floor that fell back to
# SIGTERM would be a weaker floor:
#
#   SIGINT   dropped, because the session ended any way other than killed
#            by it and this shell holds no trap to be run instead -- so the
#            run walks on, finishes, and keeps the fixed_path for a harvest
#            that a stopped run never gets
#   SIGTERM  taken at its default, which ends the shell -- and there is no
#            exit trap yet for bash to run on the way out
mkdir -p "$SCRATCH/arms-late"
cat > "$SCRATCH/arms-late/driver.yaml" <<'YAML'
name: arms-late
description: A fixed-location driver that sets its rollback up only after its session has run.
output_mode: fixed-location
fixed_path: LATE.md
command: run.sh
YAML
cat > "$SCRATCH/arms-late/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: run.sh <repo-path>" >&2; exit 1; }
REPO_PATH="$1"
FIXED="LATE.md"

command -v conformance-session >/dev/null 2>&1 || {
  echo "conformance-session CLI not found on PATH" >&2; exit 1; }
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "this driver needs bash 4+ (running ${BASH_VERSION})" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

SNAPSHOT="$(mktemp)"
snapshot_repo_state "$REPO_PATH" > "$SNAPSHOT"

( cd "$REPO_PATH" && conformance-session ) >&2 || {
  echo "the session failed" >&2; exit 1; }

# The one thing wrong with this driver, and the whole of it: by here the
# session has already had the run of the repo, and nothing was standing by
# to undo what it wrote for the entire time it was writing.
RESTORE_ON_EXIT=1
cleanup() {
  local status=$?
  if [ "$RESTORE_ON_EXIT" -eq 1 ]; then
    restore_repo_state "$REPO_PATH" "$SNAPSHOT" \
      || echo "could not roll $REPO_PATH back to how it was found" >&2
  fi
  rm -f "$SNAPSHOT"
  exit "$status"
}
trap cleanup EXIT
exit_on_interrupt "$REPO_PATH"

[ -f "$REPO_PATH/$FIXED" ] || { echo "the session did not write $FIXED" >&2; exit 1; }

restore_repo_state "$REPO_PATH" "$SNAPSHOT" "$FIXED"
RESTORE_ON_EXIT=0
DRIVER

# Does not keep the contract, and does not have to try: it declares the
# mode, runs its session, and walks away. This is precisely the driver 38
# left reachable -- valid manifest, successful harvest, zero exit, dirty
# repository -- and having it here is what stops this file passing because
# it never really looked.
mkdir -p "$SCRATCH/leaky"
cat > "$SCRATCH/leaky/driver.yaml" <<'YAML'
name: leaky
description: A third fixed-location driver that never puts the repo back.
output_mode: fixed-location
fixed_path: LEAKY.md
command: run.sh
YAML
cat > "$SCRATCH/leaky/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: run.sh <repo-path>" >&2; exit 1; }
command -v conformance-session >/dev/null 2>&1 || {
  echo "conformance-session CLI not found on PATH" >&2; exit 1; }
( cd "$1" && conformance-session ) >&2
DRIVER

# Declares the other mode, so it must not be picked up: the check is on the
# promise, and this driver never made it.
mkdir -p "$SCRATCH/elsewhere"
cat > "$SCRATCH/elsewhere/driver.yaml" <<'YAML'
name: elsewhere
description: A path-parameterized driver, which promises nothing about the repo.
output_mode: path-parameterized
command: run.sh
YAML
cat > "$SCRATCH/elsewhere/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
echo "elsewhere saw repo $1" > "$2"
DRIVER

# Declares the mode and says nothing about what it wraps, so nothing can be
# stood in for it. The danger this guards is specific: unstubbed, both
# shipped drivers reach a real `claude -p`, and a check that quietly ran one
# would cost money on every push and take minutes doing it.
mkdir -p "$SCRATCH/undeclared"
cat > "$SCRATCH/undeclared/driver.yaml" <<'YAML'
name: undeclared
description: A fixed-location driver that never says which CLI it runs.
output_mode: fixed-location
fixed_path: UNDECLARED.md
command: run.sh
YAML
cat > "$SCRATCH/undeclared/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
( cd "$1" && some-cli-nobody-declared ) >&2
DRIVER

# The same danger in its likelier shape: one guard naming a CLI plainly and
# one naming it through a variable. Reading the first and stopping there
# would leave the second unstubbed, which is the billed call arriving by the
# side door -- so this is refused as squarely as the one above.
mkdir -p "$SCRATCH/partly-declared"
cat > "$SCRATCH/partly-declared/driver.yaml" <<'YAML'
name: partly-declared
description: A fixed-location driver naming only some of the CLIs it runs.
output_mode: fixed-location
fixed_path: PARTLY.md
command: run.sh
YAML
cat > "$SCRATCH/partly-declared/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
SESSION_CLI="${SESSION_CLI:-conformance-session}"
command -v conformance-session >/dev/null 2>&1 || {
  echo "conformance-session CLI not found on PATH" >&2; exit 1; }
command -v "$SESSION_CLI" >/dev/null 2>&1 || {
  echo "$SESSION_CLI not found on PATH" >&2; exit 1; }
( cd "$1" && "$SESSION_CLI" ) >&2
DRIVER

# Guards for git, which every driver in this mode depends on and none of
# them runs a session through. Standing a stub in under that name would take
# out the fixture repo, the snapshot the driver diffs against, and the stub
# session itself -- so git is never stood in for, and a driver naming
# nothing else is refused rather than sabotaged.
mkdir -p "$SCRATCH/git-guarded"
cat > "$SCRATCH/git-guarded/driver.yaml" <<'YAML'
name: git-guarded
description: A fixed-location driver whose only named dependency is git itself.
output_mode: fixed-location
fixed_path: GIT-GUARDED.md
command: run.sh
YAML
cat > "$SCRATCH/git-guarded/run.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
command -v git >/dev/null 2>&1 || { echo "git not found on PATH" >&2; exit 1; }
git -C "$1" rev-parse --git-dir >/dev/null
echo "# a map" > "$1/GIT-GUARDED.md"
DRIVER

chmod +x "$SCRATCH"/*/run.sh

assert_eq "$(fixed_location_drivers "$SCRATCH" | tr '\n' ' ')" "arms-late conformant git-guarded leaky partly-declared undeclared " \
  "the drivers declaring fixed-location are the ones picked up -- not the one declaring another mode, and not the lib/ beside them"

# Nothing below reads $REPO or $SESSION_LOG without this having succeeded:
# a refusal returns before either is made afresh, so an unchecked call would
# quietly hand the previous driver's repo to the next driver's verdict.
run_with_misbehaving_session "$SCRATCH" "conformant" \
  || fail "conformant: names the CLI it runs, so a session can be stood up for it"
assert_kept_the_repo_as_it_found_it "conformant" "THIRD.md"
assert_file_exists "$WORK/harvested.md" \
  "a third driver written the documented way passes this check, with no test of its own to prove it"

run_with_misbehaving_session "$SCRATCH" "leaky" \
  || fail "leaky: names the CLI it runs, so a session can be stood up for it"
if session_wrote_beyond_the_fixed_path && ! widget_repo_is_pristine "$REPO"; then
  pass "a fixed-location driver that leaves files behind is caught -- which is what makes the passes above mean anything"
else
  fail "a fixed-location driver that leaves files behind is caught (the repo came back pristine, so this check cannot tell)"
  cat "$WORK/run.log" >&2
fi
assert_file_exists "$WORK/harvested.md" \
  "and it is caught having otherwise succeeded: valid manifest, harvested map, zero exit"

run_with_misbehaving_session "$SCRATCH" "arms-late" \
  || fail "arms-late: names the CLI it runs, so a session can be stood up for it"
assert_kept_the_repo_as_it_found_it "arms-late" "LATE.md"
assert_file_exists "$WORK/harvested.md" \
  "a driver that sets its rollback up too late passes everything above, which is why the run that is stopped below has to exist"

echo ""
echo "the same three drivers, against a run stopped while the session is writing:"

# The floor's other half, asked of the same three drivers so that the two
# questions are answered about one set rather than about two.
if stopped_run_or_fail "$SCRATCH" "conformant"; then
  assert_kept_the_repo_when_stopped "conformant" "THIRD.md"
fi

if stopped_run_or_fail "$SCRATCH" "leaky"; then
  assert_caught_when_stopped "leaky" "LEAKY.md" "a driver that never puts the repo back"
fi

if stopped_run_or_fail "$SCRATCH" "arms-late"; then
  assert_caught_when_stopped "arms-late" "LATE.md" \
    "a driver that sets its rollback up only after its session has had the run of the repo"
fi

echo ""
echo "the same drivers, against a session that writes over work the repo already had:"

# The floor's third question, asked of the two drivers whose answers to it
# differ: one names what it could not put back, and one has nothing to say
# because it puts nothing back at all. arms-late is left out on purpose --
# what it gets wrong is when it arms, which is the stopped run's question,
# and asking it here would be a second answer to one already given.
run_over_prior_work "$SCRATCH" "conformant" \
  || fail "conformant: names the CLI it runs, so a session can be stood up for it"
assert_named_the_work_it_wrote_over "conformant"

# Caught on this question as well, and it is the one a driver can fail while
# passing the first two: nothing here rolls anything back, so nothing here
# has anything to say about what the session wrote over.
run_over_prior_work "$SCRATCH" "leaky" \
  || fail "leaky: names the CLI it runs, so a session can be stood up for it"
if session_wrote_over_the_prior_work && ! grep -qF "$CONFORMANCE_PRIOR_WORK" "$WORK/run.log" 2>/dev/null; then
  pass "a fixed-location driver that writes over an operator's uncommitted work and says nothing is caught -- which is what makes the passes above mean anything"
else
  fail "a fixed-location driver that writes over an operator's uncommitted work and says nothing is caught (it named the file, so this check cannot tell)"
  cat "$WORK/run.log" >&2
fi

echo ""
echo "the same two drivers, against a repo whose uncommitted work was at the path they were run for:"

run_over_work_at_the_fixed_path "$SCRATCH" "conformant" \
  || fail "conformant: names the CLI it runs, so a session can be stood up for it"
assert_named_the_file_it_was_run_for "conformant" "THIRD.md"

# And caught here too, on the one question whose answer leaves no trace in
# the repo either way: this run replaced a map the operator was half way
# through and harvested it away, and the repo it hands back is pristine --
# the same repo a conformant run leaves. All that separates them is that one
# of them said so.
run_over_work_at_the_fixed_path "$SCRATCH" "leaky" \
  || fail "leaky: names the CLI it runs, so a session can be stood up for it"
if session_wrote "LEAKY.md" && ! grep -qF "LEAKY.md" "$WORK/run.log" 2>/dev/null; then
  pass "a fixed-location driver that replaces an operator's own copy of the file it was run for and says nothing is caught -- which is what makes the pass above mean anything"
else
  fail "a fixed-location driver that replaces an operator's own copy of the file it was run for and says nothing is caught (it named the file, so this check cannot tell)"
  cat "$WORK/run.log" >&2
fi

echo ""
echo "drivers whose session cannot be stood in for:"


for refused in undeclared partly-declared git-guarded; do
  if run_with_misbehaving_session "$SCRATCH" "$refused"; then
    fail "$refused: a driver whose session cannot be stood in for whole is refused rather than run for real"
  else
    pass "$refused: a driver whose session cannot be stood in for whole is refused rather than run for real"
  fi
done

report
