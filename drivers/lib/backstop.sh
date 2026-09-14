#!/usr/bin/env bash
# The drivers' rollback, run from outside a driver process.
#
#   backstop.sh restore <repo-path> <snapshot-file>
#   backstop.sh list    <repo-path> <snapshot-file>
#
# repo-snapshot.sh has asked since it was written for "something outside the
# driver process -- a runner that keeps the snapshot and re-runs the
# restore, rather than a shell trying to clean up after its own death". This
# is the half of that answer written in bash. The other half is archimedes:
# it hands the driver a path to leave its snapshot at, notices when a run
# ends with that snapshot still there, and runs this (internal/driver's
# backstop.go, internal/runrecord).
#
# WHY THIS IS HERE AND NOT IN GO. Rolling a repo back is git work, and the
# git work is already written -- once, in the file next to this one, where
# both shipped drivers reach it and where its failure paths are tested
# (tests/repo_snapshot.sh). A second implementation in the runner would be
# the copy that drifts, and it would drift on the failure path, where nobody
# is watching. So the runner borrows this rather than learning git: it knows
# where a snapshot is and when to act, and nothing about what a snapshot
# says. (Issue 38 turned down moving rollback into the runner for the same
# reason; this leaves it exactly where it was.)
#
# WHAT IT IS NOT. It is not a driver -- no manifest, so nothing resolves it
# by name -- and it is not sourced by one either, which makes it the one
# file in lib/ that is executed rather than read. It carries no execute bit
# for that: archimedes runs it as `bash backstop.sh ...`, so lib/ keeps its
# answer to "which of these is a program?", which is none of them.
#
# `restore` is the same call a driver's own exit trap makes, with no kept
# paths: this only ever runs for a run that did not succeed, and the
# contract says such a run leaves no file behind. `list` is what an operator
# is shown before deciding to run it -- the paths a dead run left sitting in
# the repo, read out of the same diff, writing nothing.
set -uo pipefail

usage() {
  echo "usage: backstop.sh restore|list <repo-path> <snapshot-file>" >&2
}

[ $# -eq 3 ] || { usage; exit 2; }
VERB="$1"
REPO_PATH="$2"
SNAPSHOT="$3"

case "$VERB" in
  restore | list) ;;
  *) usage; exit 2 ;;
esac

# The same check the drivers make, for the same reason and with a different
# ending: repo-snapshot.sh needs associative arrays, and a shell that cannot
# run it must say so rather than fail somewhere inside a rollback. Nothing
# is at stake in the repo here -- this runs before anything is touched, and
# refusing leaves the snapshot where it is for a machine that can.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || {
  echo "putting a repo back needs bash 4+ (running ${BASH_VERSION}); on macOS, /bin/bash is 3.2 -- install a newer bash and make sure it comes first on PATH" >&2
  exit 1
}

[ -f "$SNAPSHOT" ] || {
  echo "no snapshot at $SNAPSHOT -- there is nothing here to put $REPO_PATH back with" >&2
  exit 1
}
# A repo that has been moved or deleted since the run. Checked rather than
# left to git to complain about halfway through, because by then the message
# would be about a path rather than about the thing that is actually wrong:
# the record is about a repository that is no longer where it was.
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "$REPO_PATH is not a git repo any more -- it has been moved, removed or re-created since the run, and what the run left there can no longer be told apart from anything else" >&2
  exit 1
}

# shellcheck source=drivers/lib/repo-snapshot.sh
source "$(dirname "${BASH_SOURCE[0]}")/repo-snapshot.sh"

case "$VERB" in
  restore) restore_repo_state "$REPO_PATH" "$SNAPSHOT" ;;
  list) paths_changed_since_snapshot "$REPO_PATH" "$SNAPSHOT" ;;
esac
