#!/usr/bin/env bash
# Snapshot/restore helpers for a driver that has to leave the repo it was
# pointed at exactly as it found it.
#
# The fixed-location contract promises the target repo is left with no trace
# of the run apart from the declared fixed_path, which run-driver.sh then
# harvests. Neither driver that declares that mode can promise it by
# construction: `specify init` unpacks templates, scripts and agent skills
# across the repo before spec-kit's constitution can be filled in, and
# pocock hands a headless agent session the run of the repo and asks it, in
# a sentence, to write one file. So both take the same route -- record what
# the repo looked like first, then afterwards find out what the run added or
# changed, and undo it.
#
# "Whatever the run added or changed" is deliberately diffed rather than
# hardcoded to a known layout: what a given version of a CLI unpacks is its
# business, and an agent session in the middle of the run can touch files
# nobody listed. Anything that predates the snapshot is left alone, so a repo
# that was already dirty stays dirty in exactly the same way.
#
# Shared by the drivers rather than owned by one of them -- reached at
# ../lib/ relative to a driver's own directory, whichever layer supplied it.
# A second copy of this would be the one that drifts, and it would drift on
# the failure path, where nobody is watching.
#
# WHAT THE ROLLBACK CANNOT COVER. A driver calls restore_repo_state from an
# exit trap, and reaches that trap on an interrupt by trapping INT and TERM
# and exiting. That covers a Ctrl-C, a killed process tree, a `timeout` and
# a cancelled CI job -- and it covers them however the run was stopped,
# because archimedes now hands the driver every signal aimed at itself
# (internal/driver/interrupt.go) rather than a terminal happening to signal
# a whole foreground group. It leaves a window, and the window is worth
# naming here rather than in either driver, because it is a property of
# undoing a run from the outside rather than of what any one run unpacks:
#
#   * SIGKILL, and a machine that loses power, cannot be trapped at all.
#     The repo is left exactly as the session left it -- scaffolding,
#     half-written map and all -- and nothing announces that.
#
#   * A signal that was ignored when the driver started stays ignored.
#     POSIX forbids a shell from trapping or restoring one, and bash sets
#     SIGINT to SIG_IGN for anything it starts asynchronously without job
#     control, a disposition inherited through forks and execs. So a driver
#     run from a background job in a script -- which is how a harness that
#     runs drivers concurrently would start one -- cannot be Ctrl-C'd. It
#     can still be TERM'd, which is why both are trapped and not just INT.
#
#   * A trapped signal is deferred while the shell waits on the session,
#     and the trap body runs once the session returns. So the rollback
#     begins after the session process is gone, never during it, and a
#     session that ignores the signal and keeps working holds the rollback
#     up for as long as it runs.
#
#   * A second signal arriving while restore_repo_state is partway through
#     stops it partway through. What has been undone stays undone; the
#     rest does not, and the repo is left between the two states.
#     Archimedes will not be the one to send it -- it forwards the first
#     signal only, and answers the rest with a line -- but anything else
#     signalling this process still can.
#
# Each of those ends with an operator's repo dirty and no message saying
# so. Closing them needs something outside the driver process -- a runner
# that keeps the snapshot and re-runs the restore, rather than a shell
# trying to clean up after its own death.
#
# Archimedes is that outside process for the delivering and the waiting: it
# passes the signal on, stays until this rollback has finished, relays what
# the driver said about the repo, and exits with the status the driver
# chose. It is not that outside process for the snapshot, which is what the
# list above would need. A driver that never got to run its trap still
# leaves a repo nobody holds a record of.
#
# WHAT THE ROLLBACK CANNOT PUT BACK, EVEN WHEN IT RUNS TO THE END. The list
# above is about a rollback that never got to finish. This one is about one
# that finished and still left an operator worse off, and it needs saying
# separately because it happens on the ordinary success path.
#
# A repo somebody is working in is normally dirty -- that is the state the
# drivers are pointed at, not an edge case -- and undoing a run must not mean
# undoing the operator too, so everything the snapshot already lists is left
# exactly as it is. That is right until the run writes to one of those paths.
# Nothing here holds a copy of what an uncommitted file said before, and
# keeping one would mean holding the contents of every untracked path in the
# repo, so a run that wrote over the operator's own work leaves it written
# over. That much is unchanged and is not going to change: restoring needs the
# old contents, which is the expensive thing deliberately not kept.
#
# What it no longer does is happen quietly. snapshot_repo_state fingerprints
# the paths the operator has work in flight in (the B records),
# changed_since_snapshot reports the ones whose contents the run moved (the O
# records), and restore_repo_state names them on its way out. Reporting is the
# whole of it -- these are named, never restored -- and the line the
# fingerprinting stops at is drawn, with its reasons, at changed_since_snapshot.
#
# One path is left out of all that on purpose: the driver's own fixed_path,
# which the run exists to write and which reporting as a loss would fail every
# run against a repo that already had one in flight. Left out of the losses,
# not left unsaid -- archimedes moves that file out of the repo afterwards, so
# an operator who had edited it and not committed it loses it end to end on a
# run that succeeded. report_kept_paths_replaced is where the driver's success
# path says so, and why it has to be the success path that does.
#
# Requires bash 4+ for associative arrays, same as the drivers that source
# it. Sourced, not run: `source ../lib/repo-snapshot.sh`.

# Print a snapshot of <repo-path>'s working state as NUL-terminated
# "<kind><TAB><value>" records:
#
#   H  the commit HEAD points at -- everything below is described relative
#      to it, so a run that moves HEAD invalidates the whole snapshot
#   D  a directory that already existed (git tracks none, so they have to
#      be listed explicitly or a scaffolder's leftover empty directories
#      would be invisible to both this and `git status`)
#   U  an untracked path, ignored ones included -- a scaffolder that ships
#      its own .gitignore would otherwise hide its output from us
#   M  a tracked path that already differs from HEAD
#   B  a path the operator already had uncommitted work in, recorded as
#      "<fingerprint><TAB><path>" -- by content, so that a run writing over
#      one can be told apart from the state that predated it
#
# U and B overlap on purpose, and the difference between them is the whole of
# what each is for. U has to name every untracked path, ignored ones included,
# because it is what stops the cleanup deleting node_modules. B has to name
# none of them, because it reads their contents, and reading the contents of
# every untracked path means reading the whole of node_modules on every run --
# the cost that kept this unrecorded for as long as it was. What is left once
# git's own ignore rules have been applied is the work the operator actually
# has in flight, which is small enough to fingerprint and is the only part
# worth being told about: an untracked note, an edited source file. What that
# costs is bounded by how much the operator has going at once rather than by
# how big the checkout is -- which is the whole reason the line is drawn
# here, and is worth re-measuring rather than trusting if it ever moves.
snapshot_repo_state() { # <repo-path>
  local repo="$1" head
  head="$(git -C "$repo" rev-parse --verify -q HEAD || true)"
  printf 'H\t%s\0' "$head"

  list_repo_dirs "$repo" | while IFS= read -r -d '' d; do
    printf 'D\t%s\0' "$d"
  done
  git -C "$repo" ls-files --others -z | while IFS= read -r -d '' p; do
    printf 'U\t%s\0' "$p"
  done
  if [ -n "$head" ]; then
    git -C "$repo" diff --name-only -z HEAD | while IFS= read -r -d '' p; do
      printf 'M\t%s\0' "$p"
    done
  fi

  uncommitted_work_paths "$repo" "$head" \
    | fingerprint_paths "$repo" \
    | while IFS= read -r -d '' record; do
        printf 'B\t%s\0' "$record"
      done
}

# Print, NUL-terminated, the paths in <repo-path> holding work the operator
# has not committed: untracked files git is not ignoring, plus tracked files
# that already differ from HEAD. The two sets cannot overlap -- a path is
# either tracked or it is not -- so nothing is listed twice.
#
# `--exclude-standard` is the whole of the difference between this and the U
# records, and it is deliberate rather than an oversight to fix later. See
# snapshot_repo_state for what each list is for.
#
# <head> is passed in already resolved, empty for a repo with no commits yet,
# rather than asked for again here: the only caller has just worked it out, and
# a second answer to "where is HEAD" is a second answer the two could disagree
# on if anything moved in between.
uncommitted_work_paths() { # <repo-path> <head>
  local repo="$1" head="$2"
  git -C "$repo" ls-files --others --exclude-standard -z
  # An `if` rather than a trailing `&&`, which would hand back a non-zero
  # status for a repo with no commits yet -- and this runs in a pipeline
  # inside a driver with `set -o pipefail`, where that ends the run.
  if [ -n "$head" ]; then
    git -C "$repo" diff --name-only -z HEAD
  fi
}

# One "<fingerprint><TAB><path>" record, NUL-terminated, for a single path.
# Both of fingerprint_paths' ways of not using the batch end here rather than
# each spelling it out: they are the two failure paths of this file's one
# fingerprinting step, and a second copy of a failure path is the copy that
# drifts unwatched.
#
# The `|| h='-'` and the `${h:--}` are not the same guard twice. The first is
# what stops `set -e` -- which every driver sourcing this file has on -- from
# killing the run on a command substitution that exited non-zero; the second
# is what fills in a git that exited zero having said nothing.
hash_one_path() { # <repo-path> <relpath>
  local h
  h="$(git -C "$1" hash-object --no-filters -- "$2" 2>/dev/null </dev/null)" || h='-'
  printf '%s\t%s\0' "${h:--}" "$2"
}

# Split a "<fingerprint><TAB><path>" record into FINGERPRINT_RECORD_HASH and
# FINGERPRINT_RECORD_PATH.
#
# One record shape, one reading of it. Four places take these apart --
# fingerprint_paths' own output, the snapshot's B records in two functions,
# and overwritten_since_snapshot's answer -- and before this they did it with
# three different field expressions, so a change to the shape needed every one
# of them found. Whether a path is quoted, or has a tab in it, is a question
# with one answer here rather than one per caller.
#
# The outer "<kind><TAB><value>" wrapper a snapshot record arrives in is not
# this function's business -- that shape is read the same way for every kind
# there is, B included, wherever a snapshot is walked. This is the inner pair
# only.
#
# Two globals rather than a printed pair, because these run once per path in
# loops as long as the operator's working tree, and a command substitution
# there is a fork each. The names are long for the same reason a global always
# wants a long name: this is sourced into a driver's shell, not a scope of its
# own. Nothing here nests, so the second write cannot land on the first: every
# caller reads its producer out of a file that is complete before the loop
# starts.
read_fingerprint_record() { # <record>
  FINGERPRINT_RECORD_HASH="${1%%$'\t'*}"
  FINGERPRINT_RECORD_PATH="${1#*$'\t'}"
}

# Read NUL-terminated paths, relative to <repo-path>, on stdin; print one
# NUL-terminated "<fingerprint><TAB><path>" record for each, in no particular
# order. Every path read gets a record, so the caller can compare two runs of
# this by path alone.
#
# The fingerprint is git's own blob hash of the file, or `-` for a path that
# is not there, is not a regular file, or cannot be read. `-` is a value like
# any other rather than an omission: a path the operator had deleted but not
# committed, and a path the run deleted, then compare the same way everything
# else does, and neither needs a special case anywhere upstream.
#
# The hash rather than an mtime because mtime lies in both directions -- a
# write inside the filesystem's timestamp granularity does not show, and a
# tool that puts the mtime back hides one that did. The hash's own blind spot
# is a write that leaves the file byte-for-byte identical, which is not a loss
# to report.
#
# `--no-filters` because the question is what the bytes on disk are, not what
# git would store for them. Without it the answer would move whenever a run
# wrote a .gitattributes -- which a scaffolder does -- and two identical files
# would read as one written over; and a filter that normalized line endings
# would hide one that really was.
#
# One `git hash-object` for the lot of them, because the per-path shape is a
# fork each and the set can be as large as the operator's working tree.
#
# It holds no temporary file of its own, and that is a property to keep rather
# than an accident. Everything downstream of here has to be able to tell "the
# run wrote over nothing of yours" apart from "I could not look", and the
# cheapest way to be sure of that is for the looking to have no way of
# failing: a batch git cannot answer is not an error to plumb out, it is the
# per-path slow path below, and a path git cannot read is the `-` fingerprint,
# which is a real value rather than a failure. So there is no status here for
# a caller to lose. The callers still spool this rather than read it through a
# process substitution -- see changed_since_snapshot -- because that is what
# makes a stand-in, or anything this grows later, unable to pass for silence.
#
# That spooling costs one temp file per reader, so a rollback is still three
# deep in them and a machine with none still fails. What it no longer does is
# fail *here*, innermost, in the one function every reading of the repo passes
# through -- and where it does fail now, it fails with a status somebody
# catches.
fingerprint_paths() { # <repo-path>
  local repo="$1" p h lf=$'\n' cr=$'\r'
  local -a batch=() hashes=()

  # Gathered into an array and answered for in one go afterwards, rather than
  # streamed to a file descriptor: this is a library, and a spare fd opened
  # inside it is one the caller may already be using for something else.
  while IFS= read -r -d '' p; do
    if [ -f "$repo/$p" ] && [ -r "$repo/$p" ]; then
      case "$p" in
        *"$lf"* | *"$cr"* | '"'*)
          # Three shapes `--stdin-paths` cannot be handed, because it reads
          # one path per line: a newline ends the path early, a carriage
          # return is stripped off the end of it, and anything arriving
          # quoted is unquoted. The last two are the dangerous ones -- git
          # answers for the wrong file and exits zero, so the count check
          # below sees a well-formed reply and the wrong hash gets pasted
          # onto the right path. Hashed one at a time instead, where the
          # path is an argument and nothing parses it.
          hash_one_path "$repo" "$p" ;;
        *)
          batch+=("$p") ;;
      esac
    else
      printf -- '-\t%s\0' "$p"
    fi
  done
  [ "${#batch[@]}" -gt 0 ] || return 0

  # `git hash-object` stops at the first path it cannot open, so a shorter
  # answer than the question is not a partial result to be salvaged -- pasted
  # back onto the path list it would attach every hash after the failure to
  # the wrong file, which is worse than no answer at all. Counting the answers
  # is what catches that, and the slow path re-asks one at a time.
  #
  # Taken through a command substitution rather than a process substitution,
  # which is not a style choice in this file of all files: a `< <(...)` would
  # throw git's status away, and this is the function everything downstream
  # trusts to have looked. Here the status is the substitution's own, so a git
  # that fell over is refused outright, and a git that answered short is
  # refused by the count -- the two ways of not being an answer, kept apart
  # from an answer. Neither is a failure to hand back: both mean the slow path.
  local i answers
  answers="$(printf '%s\n' "${batch[@]}" \
    | git -C "$repo" hash-object --no-filters --stdin-paths 2>/dev/null)" || answers=""
  if [ -n "$answers" ]; then
    while IFS= read -r h; do
      hashes+=("$h")
    done <<< "$answers"
  fi

  if [ "${#hashes[@]}" -eq "${#batch[@]}" ]; then
    for (( i = 0; i < ${#batch[@]}; i++ )); do
      printf '%s\t%s\0' "${hashes[i]}" "${batch[i]}"
    done
  else
    for p in "${batch[@]}"; do
      hash_one_path "$repo" "$p"
    done
  fi
}

# What the run did to <repo-path> since <snapshot-file> was taken, as
# NUL-terminated "<kind><TAB><relpath>" records, skipping the optional
# <keep-relpath> arguments (the driver's fixed_path, which the run was for):
#
#   A  a path that has appeared since the snapshot
#   C  a tracked path that has gone dirty since the snapshot -- changed,
#      deleted, or staged
#   O  a path the operator already had uncommitted work in, whose contents
#      the run then overwrote or removed. Nothing can put these back
#   S  a path that predated the run untracked, which the run then staged.
#      The file is the operator's and stays; only the index entry is undone
#
# This is the one reading of what a run touched. Both things a driver does
# about it come through here: undoing it (restore_repo_state) and telling
# the operator about it (paths_changed_since_snapshot). Working it out twice
# would be two answers free to disagree, and the disagreement would surface
# as a driver that reports one set of files and cleans up another.
#
# Empty directories the run created are not reported: nothing was written in
# them, so there is nothing to name. restore_repo_state prunes them anyway.
#
# What this can see and what it still cannot, because a driver relying on it
# must claim neither more nor less. A path the operator had already left
# untracked or already left dirty is recorded by name *and* by content (the
# snapshot's B records), so a run that writes over one is reported as O rather
# than passed over as it once was. Reporting is all that is: putting such a
# path back would need the old contents, which is the expensive thing
# deliberately not kept, so O says what happened and stops.
#
# The line the fingerprinting stops at is git's own ignore rules. A path under
# node_modules -- or anything else `git ls-files --others` lists because it
# lists ignored ones deliberately -- has no B record, and a run's write to one
# is still invisible here. That is the cost judged not worth paying, and it is
# said here so a driver can repeat it rather than discover it.
#
# The comparison is by content, so it does not turn on mtime: a write that
# lands inside the filesystem's timestamp granularity, or a tool that puts the
# mtime back afterwards, is caught anyway. What is not caught is a write that
# leaves the file byte-for-byte as it was, which is not a loss to report.
#
# Returns non-zero, printing why, if HEAD has moved since the snapshot --
# see snapshot_head_unmoved. Returns non-zero, too, if any of the four reads
# behind the records could not be made: the untracked listing behind the A
# records, the tracked-file read behind the C and S ones, or the
# fingerprinting behind the O ones. That is the way this could be wrong in the
# reassuring direction, since an empty answer from here reads as "the run
# touched nothing of yours" and so has to mean that and only that.
#
# Unlike the two helpers below, it does not promise to have printed nothing
# when it fails that way: the A records are out before the C and S ones are
# asked for, and both are out before the O ones. Both callers spool this whole
# answer into a file and throw the file away on a non-zero status, so a
# half-written list is never acted on -- which is the other half of why they
# spool it, and why a third caller has to do the same.
changed_since_snapshot() { # <repo-path> <snapshot-file> [<keep-relpath> ...]
  local repo="$1" snapshot="$2"; shift 2

  snapshot_head_unmoved "$repo" "$snapshot" || return 1

  local -A before=() keep=() fingerprinted=()
  local -a fingerprinted_order=()
  local record value
  while IFS= read -r -d '' record; do
    # B records carry two fields where every other kind carries one, so they
    # are read out here rather than folded into the name-keyed set below.
    # Only the path is taken, because comparing the fingerprints belongs to
    # the helper below and this is the list of paths to ask it about. The
    # order they were written in is kept, so what this reports comes out in
    # the order the snapshot listed it rather than in whatever order a hash
    # table hands back.
    if [ "${record%%$'\t'*}" = "B" ]; then
      read_fingerprint_record "${record#*$'\t'}"
      value="$FINGERPRINT_RECORD_PATH"
      # Added to the order once however many times it was recorded: an
      # unmerged index has `git diff --name-only HEAD` name a path once per
      # stage, and the report is a list for a person to read.
      if [ -z "${fingerprinted["$value"]+set}" ]; then
        fingerprinted_order+=("$value")
      fi
      fingerprinted["$value"]=1
      continue
    fi
    before["${record%%$'\t'*}:${record#*$'\t'}"]=1
  done < "$snapshot"
  for value in "$@"; do keep["$value"]=1; done

  # Piped into the loop rather than read through `< <(...)`, which is this
  # file's one rule about reading a producer. A git that falls over inside a
  # process substitution hands back no paths and no status, and no paths is
  # byte-for-byte "the run added nothing" -- the answer a driver acts on by
  # harvesting and standing down. Neither errexit nor pipefail can see in
  # there to say otherwise.
  #
  # This way git's status is PIPESTATUS[0], which needs no shell option of the
  # caller's to be there, and needs no temp file either: the loop only reads
  # the two sets above and prints, so it can run in a subshell of its own. The
  # check has to be the very next command, since the next pipeline overwrites
  # it.
  git -C "$repo" ls-files --others -z | while IFS= read -r -d '' value; do
    [ -n "${before["U:$value"]:-}" ] && continue
    [ -n "${keep["$value"]:-}" ] && continue
    printf 'A\t%s\0' "$value"
  done
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1

  # Only against a commit: a repo with no commits yet has nothing tracked to
  # have gone dirty. The guard above has already established HEAD is where
  # the snapshot left it, so this asks git rather than re-reading the H
  # record it just compared.
  if git -C "$repo" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$repo" diff --name-only -z HEAD | while IFS= read -r -d '' value; do
      [ -n "${before["M:$value"]:-}" ] && continue
      [ -n "${keep["$value"]:-}" ] && continue
      # git now calls this a change to a tracked file; before the run it was
      # an untracked file of the operator's. Only one thing does that without
      # moving HEAD, which is the run having staged it, and it is reported as
      # its own kind because the obvious reading is destructive: as an
      # ordinary C, restore unstages it and then deletes it, HEAD having never
      # heard of it -- these helpers destroying the very uncommitted work they
      # exist to leave alone.
      if [ -n "${before["U:$value"]:-}" ]; then
        printf 'S\t%s\0' "$value"
        continue
      fi
      printf 'C\t%s\0' "$value"
    done
    # The same check as above, and the one it matters most for. The C records
    # are how a tracked file the run clobbered gets checked back out of HEAD,
    # so losing them is not a thinner report -- it is a rollback that puts
    # nothing back and then says the repo is back as it was found.
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
  fi

  # And the one reading nothing above can reach: the paths recorded by
  # content. Asked by name from the B records rather than by asking git for
  # the untracked set a second time, because a run that wrote a .gitignore --
  # which is exactly what a scaffolder does -- would have git answer that
  # question differently afterwards, and a path that merely became ignored
  # would read as a path that was written over.
  if [ "${#fingerprinted_order[@]}" -gt 0 ]; then
    local -a work=()
    for value in "${fingerprinted_order[@]+"${fingerprinted_order[@]}"}"; do
      [ -n "${keep["$value"]:-}" ] && continue
      work+=("$value")
    done
    if [ "${#work[@]}" -gt 0 ]; then
      # Spooled into a file rather than read through a process substitution,
      # for the reason restore_repo_state gives about this function's own
      # output -- and it matters more here than it does there. A producer that
      # fails inside `< <(...)` hands back no records and no status, and no
      # records is byte-for-byte what "the run wrote over nothing of yours"
      # looks like; `set -euo pipefail`, which every driver sourcing this has
      # on, does not change that, since neither errexit nor pipefail can see
      # inside a process substitution. Read that way, the one place a driver
      # is told nothing of the operator's was written over would be the one
      # place that cannot tell that answer apart from not having been able to
      # look.
      local overwritten
      overwritten="$(mktemp)" || return 1
      overwritten_since_snapshot "$repo" "$snapshot" "${work[@]}" > "$overwritten" \
        || { rm -f "$overwritten"; return 1; }
      while IFS= read -r -d '' record; do
        read_fingerprint_record "$record"
        printf 'O\t%s\0' "$FINGERPRINT_RECORD_PATH"
      done < "$overwritten"
      rm -f "$overwritten"
    fi
  fi
}

# Which of <relpath>... the run has written over since <snapshot-file> was
# taken: the ones the snapshot fingerprinted whose contents no longer match
# what it recorded, as NUL-terminated "<fingerprint-before><TAB><relpath>"
# records.
#
# The one comparison behind both readings of that question -- the O records
# above, which name what a run destroyed, and report_kept_paths_replaced
# below, which names the one path those deliberately skip. They differ in
# which paths they ask about and in what they say afterwards; a second way of
# working out whether a file was written over would be a second answer, and
# the two would disagree exactly where it mattered.
#
# What the path said before is handed back rather than dropped, because that
# is the one thing the two callers read differently. `-` for it means there
# was nothing there at all -- a path the operator had deleted and not
# committed. Written over, that is a loss for an ordinary path, whose deletion
# the rollback leaves undone; it is nothing at all for a kept path, which the
# harvest carries back out of the repo. Each caller says which it is; this
# only reports that the contents moved.
#
# Returns non-zero, having printed nothing, if the fingerprinting could not be
# run. Silence and failure are not the same answer here -- "none of these was
# written over" is the report an operator is entitled to act on -- so the two
# are told apart by status and every caller has to keep them apart.
#
# A path the snapshot did not fingerprint is not reported. There is no record
# of what it said before, so there is nothing to compare and nothing that can
# be claimed either way: a path the run created, and a path git was already
# ignoring, both arrive here as silence rather than as a loss.
#
# The comparison is of contents, so a run that rewrote a file byte for byte is
# not reported. Nothing of the operator's went anywhere in that case, which is
# the blind spot named at fingerprint_paths and is not one worth closing.
overwritten_since_snapshot() { # <repo-path> <snapshot-file> [<relpath> ...]
  local repo="$1" snapshot="$2"; shift 2
  [ "$#" -gt 0 ] || return 0

  local -A fingerprint=()
  local record value
  while IFS= read -r -d '' record; do
    [ "${record%%$'\t'*}" = "B" ] || continue
    read_fingerprint_record "${record#*$'\t'}"
    fingerprint["$FINGERPRINT_RECORD_PATH"]="$FINGERPRINT_RECORD_HASH"
  done < "$snapshot"

  local -a work=()
  for value in "$@"; do
    if [ -n "${fingerprint["$value"]+set}" ]; then work+=("$value"); fi
  done
  [ "${#work[@]}" -gt 0 ] || return 0

  # Spooled, not read through `< <(...)`, and this is the spool the whole of
  # the reporting rests on: both readings of "was this written over" come
  # through here, so a fingerprinting that could not run and was read this way
  # would answer both of them with the reassuring silence. See
  # changed_since_snapshot for the shape of that failure. The pipeline's status
  # is fingerprint_paths' own -- it is the last stage -- so this needs no
  # pipefail of the caller's to catch it.
  local now
  now="$(mktemp)" || return 1
  printf '%s\0' "${work[@]}" | fingerprint_paths "$repo" > "$now" \
    || { rm -f "$now"; return 1; }

  while IFS= read -r -d '' record; do
    read_fingerprint_record "$record"
    value="$FINGERPRINT_RECORD_PATH"
    [ "$FINGERPRINT_RECORD_HASH" = "${fingerprint["$value"]}" ] && continue
    printf '%s\t%s\0' "${fingerprint["$value"]}" "$value"
  done < "$now"
  rm -f "$now"
}

# Say, on stderr, that the run replaced work the operator had uncommitted at
# one of its <keep-relpath> arguments -- the driver's own fixed_path, the one
# file the run exists to write.
#
# Everything else this file reports is a driver apologising: a path it wrote
# over, a repo it could not put back. This one is the driver doing its job, and
# the message reads that way, because failing over it would fail every run
# against a repo that already had a context map in flight -- which is most of
# the repos these are pointed at. The exemption is right; the silence around it
# was not, because the contract does not stop at writing that file. Archimedes
# moves it out of the repo afterwards, so an operator who had edited it and not
# committed it has their version replaced and then carried away, and until this
# every step of that was an ordinary successful run with nothing said anywhere.
#
# For the driver's success path only, and that is not a style note. It needs
# both things restore_repo_state cannot know -- that the run succeeded, and
# that the kept path is therefore being kept -- and restore_repo_state runs
# from the exit trap on the failure path too, where nothing is kept and the
# file has already gone.
#
# It asks nothing about HEAD for the same reason. Called where it is meant to
# be, restore_repo_state has already refused a run that moved HEAD and taken
# the driver down with it, so by here the snapshot is known to still describe
# this repo. Asking again would be a second answer to a question already
# settled, and one this is in no position to act on.
#
# Silent when there is nothing to say, and three different states count as
# nothing. A repo with no file of its own at that path never had one to lose.
# A file the run rewrote byte for byte still says what it said. And a file the
# operator had deleted without committing the deletion is put back where they
# left it: the run writes one, and the harvest moves it straight back out, so
# a run that announced a loss there would be announcing one that did not
# happen. A note printed on every run is a note nobody reads by the time it
# means something.
#
# What it does not claim is that the file is unrecoverable. A tracked
# fixed_path still has whatever HEAD holds; what has gone is the operator's
# uncommitted version of it, which is what nothing here keeps a copy of.
#
# Returns non-zero, having printed nothing, if it could not work the answer
# out. That is a status for the caller to say something about rather than to
# die on -- see the body for why this one, alone among these, must not end a
# run that succeeded.
report_kept_paths_replaced() { # <repo-path> <snapshot-file> [<keep-relpath> ...]
  local repo="$1" snapshot="$2"; shift 2
  [ "$#" -gt 0 ] || return 0

  # Spooled for the reason the two functions above are, and answered for
  # differently, which is the whole of the awkwardness here: this one runs on
  # the success path, after the harvest is a foregone conclusion. A non-zero
  # return under the caller's `set -e` would end a run that genuinely
  # succeeded, over a courtesy note. So the status is handed to the driver
  # rather than acted on, and both drivers answer it with a line saying they
  # could not work out whether they replaced anything -- see pocock's and
  # spec-kit's run.sh. What is not on offer is the third option: printing
  # nothing and returning zero, which is this file's silence-is-a-bug rule
  # broken in the one place the bug reads as good news.
  local records
  records="$(mktemp)" || return 1
  overwritten_since_snapshot "$repo" "$snapshot" "$@" > "$records" \
    || { rm -f "$records"; return 1; }

  local -a replaced=()
  local record
  while IFS= read -r -d '' record; do
    read_fingerprint_record "$record"
    # Nothing was there before, so nothing of theirs was replaced -- see above.
    [ "$FINGERPRINT_RECORD_HASH" = "-" ] && continue
    replaced+=("$FINGERPRINT_RECORD_PATH")
  done < "$records"
  rm -f "$records"
  [ "${#replaced[@]}" -gt 0 ] || return 0

  {
    echo "$repo had uncommitted work at the path this run was for, and the run wrote its own over it:"
    printf '  %s\n' "${replaced[@]}"
    echo "nothing went wrong -- writing that file is the whole of what this run does -- but it is moved out of the repo when the run finishes, and nothing here holds a copy of what your version said. Commit it first if you want to keep it."
  } >&2
}

# The same set, one path per line, for a driver that has to say what a
# session wrote when it was asked for one file. Kinds are dropped: an
# operator being told their repo was written to does not need to know which
# side of git's tracking line each path fell on.
#
# Newlines separate them, so a path with a newline in its name would be
# reported as two. That is a report, not a plan of action -- what actually
# gets undone comes from changed_since_snapshot's NUL-terminated records --
# and a repo holding such a path has a worse problem than this line break.
paths_changed_since_snapshot() { # <repo-path> <snapshot-file> [<keep-relpath> ...]
  local records record
  records="$(mktemp)" || return 1
  changed_since_snapshot "$@" > "$records" || { rm -f "$records"; return 1; }

  while IFS= read -r -d '' record; do
    printf '%s\n' "${record#*$'\t'}"
  done < "$records"
  rm -f "$records"
}

# Undo everything that happened to <repo-path> since <snapshot-file> was
# taken, except for the optional <keep-relpath> arguments (the driver's
# fixed_path, which has to survive for run-driver.sh to harvest).
#
# Paths that appeared since the snapshot are deleted; tracked paths that
# have gone dirty since the snapshot are restored from HEAD; a path the run
# staged that predated it untracked is unstaged and otherwise left alone;
# directories that appeared and are now empty are removed. Anything already
# listed in the snapshot is left exactly as it is.
#
# Except for the one thing this cannot do anything about, which it therefore
# says out loud: uncommitted work the run wrote over. There is no copy of what
# those paths said, so they are left as the run left them and named on stderr.
# Named here, rather than left to the caller, because this is what a driver
# runs from its exit trap -- on that path the caller is a script on its way
# out and nothing else is going to ask.
#
# Returns non-zero, having changed nothing, if HEAD has moved since the
# snapshot, or if working out what the run did failed for any other reason.
# Both drivers answer that with "could not roll <repo> back to how it was
# found -- it needs looking at by hand", which is the honest thing to say: a
# rollback that could not find out what to undo has undone nothing.
#
# The one failure that does not come back as a status is the directory walk
# the prune at the end runs on, which by then has nothing left to decide: it
# is reported on stderr and the rollback stands. The body says why, where it
# happens.
restore_repo_state() { # <repo-path> <snapshot-file> [<keep-relpath> ...]
  local repo="$1" snapshot="$2"

  # Worked out in full, into a file, before anything is touched. Two reasons,
  # and the second is the one that bites: nothing is undone until the whole
  # list is in hand, so removing a scaffolder's own .gitignore mid-walk can't
  # change what the rest of the walk sees -- and a failure in there (the
  # moved-HEAD refusal, an unreadable snapshot, git falling over) is a status
  # this can return. Read through a process substitution instead, it would be
  # a status bash throws away, and this would report a repo put back that it
  # had not touched.
  local records
  records="$(mktemp)" || return 1
  changed_since_snapshot "$@" > "$records" || { rm -f "$records"; return 1; }

  local -a added=() changed=() staged=() overwritten=()
  local kind value record
  while IFS= read -r -d '' record; do
    kind="${record%%$'\t'*}"; value="${record#*$'\t'}"
    case "$kind" in
      A) added+=("$value") ;;
      C) changed+=("$value") ;;
      S) staged+=("$value") ;;
      O) overwritten+=("$value") ;;
    esac
  done < "$records"
  rm -f "$records"

  for value in "${added[@]+"${added[@]}"}"; do
    rm -f "$repo/$value"
  done

  for value in "${changed[@]+"${changed[@]}"}"; do
    if git -C "$repo" cat-file -e "HEAD:$value" 2>/dev/null; then
      git -C "$repo" checkout -q HEAD -- "$value"
    else
      # Staged into the index but absent from HEAD: unstage, then it's
      # just another path the run added.
      git -C "$repo" rm -q --cached --force -- "$value" >/dev/null 2>&1 || true
      rm -f "$repo/$value"
    fi
  done

  # Unstaged, and no further than that. The file predates the run and is the
  # operator's; the index entry is the run's doing and the only part of this
  # there is to undo.
  for value in "${staged[@]+"${staged[@]}"}"; do
    git -C "$repo" rm -q --cached --force -- "$value" >/dev/null 2>&1 || true
  done

  # Directories the run created, now that nothing of the run's is left in
  # them. Read from the snapshot rather than from changed_since_snapshot,
  # which reports no directories: git tracks none, so an empty one a run
  # leaves behind is a trace nothing else can see.
  #
  # list_repo_dirs walks deepest-first, so a nested tree collapses in one
  # pass; rmdir refuses anything that still holds something, which is
  # exactly right for a directory that also holds a kept path or predates
  # the run.
  local -A dirs_before=()
  while IFS= read -r -d '' record; do
    kind="${record%%$'\t'*}"; value="${record#*$'\t'}"
    [ "$kind" = "D" ] && dirs_before["$value"]=1
  done < "$snapshot"
  #
  # The one read here whose failure is not carried out in the return status,
  # and the difference is what it would cost to say it that way. A walk that
  # cannot be made prunes none of the directories it did not get to, which
  # leaves a trace of the run behind -- it does not misreport one, the way
  # losing the C records above would. By here everything else has already been
  # undone, and this function's non-zero status means the opposite: "could not
  # work out what to undo, so nothing was", which both drivers answer with "it
  # needs looking at by hand". Worse, on the success path spec-kit and pocock
  # run this unguarded under `set -e`, so returning non-zero would discard a
  # run that succeeded and everything it produced, over an empty directory. So
  # it is said out loud instead and the run stands -- the same answer
  # report_kept_paths_replaced got, reached the same way. What is not on offer
  # is the third option: pruning nothing and saying nothing, which is this
  # file's silence-is-a-bug rule broken where the bug reads as good news.
  #
  # Which is why the pipeline is inside an `if` rather than standing on its
  # own. Under the `set -euo pipefail` both drivers run, a bare pipeline whose
  # first stage failed ends the shell *at* the pipeline -- so the check below
  # it would never run, the line on stderr would never be printed, and the
  # unguarded success-path call would take the whole run down: every one of
  # the three things this paragraph argues for, lost to the spelling. A
  # condition suspends errexit for the list, and the status is still read out
  # of PIPESTATUS rather than out of the pipeline, so it does not need a
  # pipefail of the caller's either.
  #
  # Said at the end rather than here, so that nothing printed after it can
  # read as a correction of it.
  local dirs_unlisted=0
  if list_repo_dirs "$repo" | while IFS= read -r -d '' value; do
       [ -n "${dirs_before["$value"]:-}" ] && continue
       rmdir "$repo/$value" 2>/dev/null || true
     done
     [ "${PIPESTATUS[0]}" -ne 0 ]
  then
    dirs_unlisted=1
  fi

  # Silent when there is nothing to say, or it would be noise on every run
  # against every repo anybody is working in.
  if [ "${#overwritten[@]}" -gt 0 ]; then
    {
      echo "$repo is back as it was found, apart from uncommitted work the run wrote over, which nothing here holds a copy of:"
      printf '  %s\n' "${overwritten[@]}"
      echo "those paths are as the run left them. What they said before was never committed, so it cannot be put back from here."
      echo "this list covers the paths git was not already ignoring. A run that wrote over an ignored one -- a .env, a local settings file -- is not counted here."
    } >&2
  fi

  if [ "$dirs_unlisted" -eq 1 ]; then
    echo "could not list $repo's directories, so a directory this run created and left empty may still be there. Everything else is back as it was found." >&2
  fi
}

# Arm INT and TERM so that an interrupt takes the caller into its EXIT trap,
# where the rollback above lives. Call it once, after that EXIT trap is set.
#
# A driver's rollback hangs off EXIT, and an interrupt is not reliably
# something that makes a shell exit. The reasoning this replaces was that a
# Ctrl-C signals the whole process group, so the session dies with it and
# the driver's `|| abort` carries the run into the exit trap. That holds
# only when the session is *killed by* the signal. Bash defers a signal
# that arrives while it is waiting on a foreground child, and when the
# child is reaped it decides what to do with the deferred signal from how
# that child ended: died from it, and the shell re-raises it on itself;
# ended any other way, and the shell reads that as the child having handled
# the interrupt, and drops its own copy. So a session that traps SIGINT and
# shuts down cleanly, which is what a well-behaved CLI does, exits zero --
# and the run walks straight past the operator's Ctrl-C, keeps its output,
# disarms the rollback and exits zero with everything the run unpacked
# still sitting in their repo. Same for a signal that reached the driver
# alone and never touched the session.
#
# Trapping them costs the shell nothing it was relying on: a trapped signal
# is still deferred until the foreground session returns, which is the
# order the rollback has to happen in anyway. What changes is that whether
# an interrupt stops the run is no longer the session's to decide.
#
# Which signals arrive at all is likewise no longer a terminal's to decide.
# Archimedes runs a driver in a process group of its own and signals that
# group itself, so these traps fire for a `kill` by pid, a supervisor or a
# `timeout` exactly as they do for a Ctrl-C -- and the driver is handed one
# copy of the interrupt rather than one per way it could have reached the
# group.
#
# Here rather than in each driver for the reason this whole file is here:
# it is failure-path code, and a second copy of it would be the one that
# drifts. What it still does not cover is named at the top of this file.
exit_on_interrupt() { # <repo-path>
  INTERRUPTED_REPO="$1"
  trap 'interrupted_by INT 130' INT
  trap 'interrupted_by TERM 143' TERM
}

# The body those two traps run. Separate from exit_on_interrupt, and
# reaching the repo path through a variable rather than an argument,
# because a trap's command is a string evaluated when the signal arrives --
# long after the arguments it was set up with have gone.
interrupted_by() { # <signal-name> <exit-status>
  echo "interrupted by SIG$1 -- rolling $INTERRUPTED_REPO back to how it was found and keeping nothing" >&2
  exit "$2"
}

# Refuse, printing why, if <repo-path>'s HEAD is not the commit
# <snapshot-file> was taken against.
#
# Every judgement the helpers above make is relative to that commit, so a
# run that committed, stashed or switched branches has put the repo
# somewhere neither undoing nor describing the run can reach: what it added
# is now indistinguishable from what was already committed, while `git
# status` reads clean. That's a case for telling the operator, not guessing.
snapshot_head_unmoved() { # <repo-path> <snapshot-file>
  local repo="$1" snapshot="$2" record head_at_snapshot="" head_now

  while IFS= read -r -d '' record; do
    if [ "${record%%$'\t'*}" = "H" ]; then head_at_snapshot="${record#*$'\t'}"; break; fi
  done < "$snapshot"

  head_now="$(git -C "$repo" rev-parse --verify -q HEAD || true)"
  [ "$head_now" = "$head_at_snapshot" ] && return 0

  echo "refusing to touch $repo: HEAD moved from ${head_at_snapshot:-(no commits)} to ${head_now:-(no commits)} during the run, so what the run added can no longer be told apart from what was already committed -- the repo needs looking at by hand" >&2
  return 1
}

# Print <repo-path>'s directories, relative and NUL-terminated, deepest
# first, skipping .git and the repo root itself.
#
# `find` is pruned at .git rather than filtering its output, so a repo with
# a large object store doesn't get walked for nothing; that leaves the
# results in parent-before-child order, so they're reversed here to get the
# deepest-first order rmdir needs.
#
# Returns non-zero, having printed whatever it got to, if the walk itself
# could not be made. An empty answer from here is "this repo has no
# directories of its own", which is a real answer and a rare one, and both
# callers act on it: the snapshot records no D records, so every directory in
# the repo afterwards reads as one the run created, and the rollback prunes
# the empty ones the operator had. A walk that could not be made has to be
# told apart from that.
#
# The walk is piped into the reversing loop rather than read through
# `< <(...)`, for the reason changed_since_snapshot gives: a process
# substitution would throw find's status away, and a `cd` that failed would
# come back as a repo with no directories in it. The loop needs the whole list
# in hand before it can print any of it, so it holds an array -- in a subshell
# of its own, which costs nothing here because it only prints.
list_repo_dirs() { # <repo-path>
  ( cd "$1" && find . -path './.git' -prune -o -type d ! -name . -print0 ) \
    | {
        local -a dirs=()
        local d i
        while IFS= read -r -d '' d; do
          dirs+=("${d#./}")
        done
        for (( i = ${#dirs[@]} - 1; i >= 0; i-- )); do
          printf '%s\0' "${dirs[i]}"
        done
      }
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
}
