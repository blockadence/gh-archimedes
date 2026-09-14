#!/usr/bin/env bash
# Fixed-location driver: `run.sh <repo-path>`.
#
# Produces a context map for <repo-path> with GitHub's Spec Kit
# (https://github.com/github/spec-kit). Spec Kit has no "point at a repo,
# write a report over here" mode: `specify init` unpacks templates, helper
# scripts and agent skills into the repo, and its one whole-repo artifact --
# the constitution -- is always written to .specify/memory/constitution.md
# relative to that repo's root. That makes this a fixed-location driver
# twice over: it can't be told where to write, and it can't even produce
# anything without first scaffolding itself in.
#
# So the run is: snapshot the repo, scaffold, have a headless `claude -p`
# session fill in the scaffolded constitution template from the codebase,
# then restore everything except the constitution itself. run-driver.sh
# harvests that one file (see driver.yaml's fixed_path) and prunes the
# directories it empties, leaving the target repo exactly as it was found.
#
# Exactly as it was found, with one exception this cannot close: work the
# operator had in the repo uncommitted, which the scaffolding or the session
# then wrote over. Nothing holds a copy of what those files said, so the
# rollback names them on stderr and leaves them. The run still succeeds --
# unlike pocock's, scaffolding this repo was always the job here, and failing
# would not un-write anything -- but the operator is told. The reasoning, and
# the one place this still cannot look, are in ../lib/repo-snapshot.sh.
#
# The constitution itself is left out of that report and said separately, on
# the success path only: an uncommitted one is replaced here by design --
# first by the template `specify init` unpacks, then by the session -- and the
# harvest carries the result out of the repo afterwards, so the operator is
# told plainly rather than warned.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: run.sh <repo-path>" >&2; exit 1; }
REPO_PATH="$1"

command -v specify >/dev/null 2>&1 || {
  echo "specify CLI not found on PATH (uv tool install specify-cli --from git+https://github.com/github/spec-kit.git)" >&2
  exit 1
}
command -v claude >/dev/null 2>&1 || {
  echo "claude CLI not found on PATH" >&2
  exit 1
}
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "$REPO_PATH is not a git repo -- the spec-kit driver diffs against git to undo its own scaffolding afterwards" >&2
  exit 1
}
# Checked here rather than left to fail later, because "later" is after the
# scaffolding is already unpacked into someone's repo. This is the driver's
# own requirement — Archimedes itself is a compiled binary and asks nothing
# of the shell — so it is stated where it is owed.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "the spec-kit driver needs bash 4+ (running ${BASH_VERSION}); on macOS, /bin/bash is 3.2 -- install a newer bash and make sure it comes first on PATH" >&2
  exit 1
}

# Sourced once everything it needs has been checked for, rather than at the
# top: an operator who has installed none of this should be told which CLI
# is missing, not handed a command-not-found from inside a helper that was
# loaded before anyone asked whether the run could happen at all.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/repo-snapshot.sh"

CONSTITUTION=".specify/memory/constitution.md"   # must match driver.yaml's fixed_path

# Through the helper rather than into a temp file of this script's own,
# because where the snapshot lands decides who can still act on it if this
# process is killed outright. ../lib/repo-snapshot.sh has that, and what
# releasing it says, beside the functions.
SNAPSHOT="$(take_run_snapshot "$REPO_PATH")"
SCAFFOLDED="$(mktemp)"
# Until the rollback below is armed there is nothing in the repo to undo, so
# the only thing owed on the way out of this window is the snapshot itself.
trap 'release_snapshot "$SNAPSHOT"; rm -f "$SCAFFOLDED"' EXIT

# Everything from here on happens inside someone else's repo, so the
# rollback can't hang off the success path or off hand-placed error
# handling: `set -e` on an unguarded command, a Ctrl-C, a `kill` -- any of
# those would otherwise walk away leaving a whole toolchain unpacked in
# there. So restoring is the exit trap, disarmed only once the run has
# succeeded and done its own restore.
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
  rm -f "$SCAFFOLDED"
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
# contract says a driver that exits non-zero leaves no file behind, and a
# half-finished constitution is worse than none.
abort() { # <message>
  echo "$1" >&2
  exit 1
}

# --non-interactive is Spec Kit's own flag for exactly this situation: an
# agent harness with no one to answer prompts. --force skips the "directory
# isn't empty" confirmation, and --integration claude is what installs the
# speckit-* skills the session below reaches for.
(
  cd "$REPO_PATH"
  specify init --here --force --non-interactive \
    --integration claude --script sh --ignore-agent-tools
) >&2 || abort "specify init failed in $REPO_PATH"

[ -f "$REPO_PATH/$CONSTITUTION" ] || abort "specify init did not scaffold $REPO_PATH/$CONSTITUTION"
cp "$REPO_PATH/$CONSTITUTION" "$SCAFFOLDED" \
  || abort "could not take a copy of the scaffolded $CONSTITUTION to compare against later"

PROMPT="Use the speckit-constitution skill to fill in this repo's constitution at $CONSTITUTION, deriving every principle from the codebase you can read here rather than from generic best practice: the languages and frameworks actually in use, the testing and review conventions the existing code and config already follow, the boundaries between its modules, and the constraints its dependencies impose. Do not ask questions, since no one is here to answer them -- where the skill would normally prompt, infer from the code and say so. Replace every bracketed placeholder token. Write only $CONSTITUTION -- this repo is harvested by moving exactly that one file elsewhere, so do not create or modify any other file, and put the Sync Impact Report inside the constitution as the skill directs rather than in a file of its own. Do not run any git command that changes this repo's state -- no commit, add, stash, checkout, branch or reset. Everything this run touched is rolled back afterwards by diffing against the commit HEAD points at right now, so moving HEAD makes that impossible and strands the scaffolding here permanently. When the constitution is complete, stop."

(
  cd "$REPO_PATH"
  claude -p \
    --tools "Read,Glob,Grep,Write,Edit,Bash,Skill" \
    --permission-mode bypassPermissions \
    "$PROMPT"
) >&2 || abort "claude session failed while filling in $REPO_PATH/$CONSTITUTION"

[ -f "$REPO_PATH/$CONSTITUTION" ] || abort "the claude session removed $REPO_PATH/$CONSTITUTION instead of filling it in"
# Compared against the scaffolded copy rather than scanned for placeholder
# tokens: which tokens a constitution template carries is Spec Kit's
# business and changes between versions, but "the session left the template
# exactly as `specify init` unpacked it" always means it did nothing.
if cmp -s "$REPO_PATH/$CONSTITUTION" "$SCAFFOLDED"; then
  abort "the claude session left $CONSTITUTION as the unfilled template specify init scaffolded"
fi

# Everything but the constitution goes back, and the trap stands down --
# but only once this has actually succeeded. If it fails (the session moved
# HEAD, say), the trap gets its turn and tries again keeping nothing, which
# is the right end state for a run that is about to exit non-zero.
restore_repo_state "$REPO_PATH" "$SNAPSHOT" "$CONSTITUTION"

# And the one thing the rollback cannot say, because only this line knows the
# run succeeded: an operator who had a constitution of their own uncommitted
# has just had it replaced -- by `specify init`'s template, then by the
# session -- and the harvest is about to move the result out of the repo. Not
# a failure and not an apology; writing that file is the job. Here rather than
# in the trap: on the failure path the constitution is not kept, and by the
# time the trap runs it has already gone.
#
# Guarded the same way the rollback above is, and for a reason spelled out
# where the helper is: alone among these, its status must not end a run that
# succeeded. So the run stands and this says which of the two happened.
report_kept_paths_replaced "$REPO_PATH" "$SNAPSHOT" "$CONSTITUTION" \
  || echo "could not work out whether this run replaced uncommitted work at $REPO_PATH/$CONSTITUTION -- if you had a version of your own there that you had not committed, the constitution this run harvests is not it" >&2
RESTORE_ON_EXIT=0
