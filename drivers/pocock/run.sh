#!/usr/bin/env bash
# Fixed-location driver: `run.sh <repo-path>`.
#
# Runs a headless `claude -p` session inside <repo-path>, instructed to use
# the domain-modeling skill (https://github.com/mattpocock/skills) to build
# or refresh that repo's CONTEXT.md from its codebase. The skill always
# writes CONTEXT.md at the root of whatever repo it's invoked in and can't
# be pointed at an explicit output path -- run-driver.sh harvests
# <repo-path>/CONTEXT.md after this exits (see driver.yaml's fixed_path).
#
# The prompt asks the session to write that one file and nothing else. It
# has to ask, because the skill's own criteria call for ADRs, so the prompt
# is arguing with the thing it invokes -- and the argument is with a
# non-deterministic agent, on every run, forever. So the run is bracketed
# the way spec-kit's is: snapshot the repo first, and on every exit path put
# back whatever the session wrote beyond the map. A session that wrote more
# than it was asked for fails the run and is told what it wrote, because a
# context map is not worth the operator finding out later that we let
# something loose in their repository.
#
# "Put back" has one exception, and it is named here rather than left to be
# discovered: work the operator had in the repo uncommitted, which the session
# then wrote over. Nothing holds a copy of what those files said, so they stay
# as the session left them -- the run fails naming them, and the rollback says
# separately which ones it could not undo. ../lib/repo-snapshot.sh has the
# reasoning, and the one place it still cannot look (paths git is ignoring).
#
# CONTEXT.md itself is the exception to that exception. Replacing an
# uncommitted one is this run doing its job, not disobeying, and failing over
# it would refuse every repo that already had a map in flight -- which is many
# of the repos this is pointed at. So the run succeeds, and says so on its way
# out instead: the operator's version was replaced, and the harvest then moves
# the result out of the repo.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: run.sh <repo-path>" >&2; exit 1; }
REPO_PATH="$1"

command -v claude >/dev/null 2>&1 || {
  echo "claude CLI not found on PATH" >&2
  exit 1
}
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "$REPO_PATH is not a git repo -- the pocock driver diffs against git to put back whatever the session writes beyond CONTEXT.md" >&2
  exit 1
}
# Checked here rather than left to fail later, because "later" is after a
# billed session has already written into someone's repo with nothing
# standing by to undo it. This is the driver's own requirement — Archimedes
# itself is a compiled binary and asks nothing of the shell — so it is
# stated where it is owed.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "the pocock driver needs bash 4+ (running ${BASH_VERSION}); on macOS, /bin/bash is 3.2 -- install a newer bash and make sure it comes first on PATH" >&2
  exit 1
}

# Sourced once everything it needs has been checked for, rather than at the
# top: an operator who has installed none of this should be told which CLI
# is missing, not handed a command-not-found from inside a helper that was
# loaded before anyone asked whether the run could happen at all.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

CONTEXT_MAP="CONTEXT.md"   # must match driver.yaml's fixed_path

# Through the helper rather than into a temp file of this script's own,
# because where the snapshot lands decides who can still act on it if this
# process is killed outright. ../lib/repo-snapshot.sh has that, and what
# releasing it says, beside the functions.
SNAPSHOT="$(take_run_snapshot "$REPO_PATH")"
# Until the rollback below is armed there is nothing in the repo to undo, so
# the only thing owed on the way out of this window is the snapshot itself.
trap 'release_snapshot "$SNAPSHOT"' EXIT

# Everything from here on happens inside someone else's repo, so the
# rollback can't hang off the success path or off hand-placed error
# handling: `set -e` on an unguarded command, a Ctrl-C, a `kill` -- any of
# those would otherwise walk away leaving whatever the session had written
# by then sitting in there. So restoring is the exit trap, disarmed only
# once the run has succeeded and done its own restore.
#
# What it says on its way out, it says by what it does with the snapshot:
# released means the repo is back, handed over means it is not.
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
#
# Hung off EXIT so that every way out of this script goes through it, rather
# than off the handful of failures anyone thought to write an `|| abort`
# for.
trap cleanup EXIT

# And an interrupt turned into an exit, so it goes through that same trap
# rather than being decided by what the session did with its own copy of
# the signal. Both the reasoning and the window it leaves are in
# ../lib/repo-snapshot.sh, beside the rollback itself.
exit_on_interrupt "$REPO_PATH"

# Fail, leaving the trap above to put the repo back. Nothing is kept -- the
# contract says a driver that exits non-zero leaves no file behind.
abort() { # <message>
  echo "$1" >&2
  exit 1
}

PROMPT="Use the domain-modeling skill to build or refresh this repo's CONTEXT.md by reading the codebase. Resolve every term you can directly from the code; do not ask questions, since no one is here to answer them. Write only CONTEXT.md -- this repo is harvested by moving exactly that one file elsewhere, so do not create or modify any other file (no ADRs, no docs/adr/, nothing else), even if the skill's own criteria would otherwise call for one. Do not run any git command that changes this repo's state -- no commit, add, stash, checkout, branch or reset. Everything this run touched beyond CONTEXT.md is put back afterwards by diffing against the commit HEAD points at right now, so moving HEAD makes that impossible. When CONTEXT.md is up to date, stop."

(
  cd "$REPO_PATH"
  claude -p \
    --tools "Read,Glob,Grep,Write,Edit" \
    --permission-mode bypassPermissions \
    "$PROMPT"
) >&2 || abort "claude session failed while writing $REPO_PATH/$CONTEXT_MAP"

[ -f "$REPO_PATH/$CONTEXT_MAP" ] || abort "domain-modeling skill did not produce $REPO_PATH/$CONTEXT_MAP"

# What the session wrote besides the map, asked of the same diff the
# rollback acts on so the two can't disagree. Named rather than counted:
# the operator's next question is which files, and by the time they read
# this the repo has already been tidied, so this message is the only record
# there will be.
#
# A run that gets here is discarded rather than harvested. That costs a
# billed session's usable output, which is the price of not being the tool
# that quietly deletes an agent's work in somebody's repository and reports
# success -- and of the disobedience being visible at all, since a rollback
# that succeeded silently would leave the prompt losing this argument
# forever with nobody the wiser.
EXTRAS="$(paths_changed_since_snapshot "$REPO_PATH" "$SNAPSHOT" "$CONTEXT_MAP")" \
  || abort "could not work out what the session wrote in $REPO_PATH"
if [ -n "$EXTRAS" ]; then
  abort "the session wrote more than $CONTEXT_MAP in $REPO_PATH, which it was asked not to:
$(printf '%s\n' "$EXTRAS" | sed 's/^/  /')
everything it wrote that can be put back is put back as this run exits -- if any of it was work this repo already had uncommitted, the rollback names those separately and cannot undo them -- and no context map is harvested from a run that would not keep to the one file it was asked for"
fi

# The map stays for run-driver.sh to harvest; anything else the run left --
# an empty directory, say, which git cannot see and the naming above does
# not report -- goes. Then the trap stands down, but only once this has
# actually succeeded: if it fails, the trap gets its turn and tries again
# keeping nothing, which is the right end state for a run about to exit
# non-zero.
restore_repo_state "$REPO_PATH" "$SNAPSHOT" "$CONTEXT_MAP"

# And the one thing neither the naming above nor the rollback can say, because
# only this line knows the run succeeded: an operator who had a CONTEXT.md of
# their own uncommitted has just had it replaced by this run's, and the
# harvest is about to move the result out of the repo. Not a failure and not
# an apology -- writing that file is the job -- but not silence either. Here
# rather than in the trap: on the failure path the map is not kept, and by the
# time the trap runs it has already gone.
#
# Guarded the same way the rollback above is, and for a reason spelled out
# where the helper is: alone among these, its status must not end a run that
# succeeded. So the run stands and this says which of the two happened.
report_kept_paths_replaced "$REPO_PATH" "$SNAPSHOT" "$CONTEXT_MAP" \
  || echo "could not work out whether this run replaced uncommitted work at $REPO_PATH/$CONTEXT_MAP -- if you had a version of your own there that you had not committed, the map this run harvests is not it" >&2
RESTORE_ON_EXIT=0
