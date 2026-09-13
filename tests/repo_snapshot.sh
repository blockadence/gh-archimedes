#!/usr/bin/env bash
# Unit tests for the snapshot/restore helpers the drivers share
# (drivers/lib/repo-snapshot.sh). These are what let a driver that cannot
# help writing all over the target repo -- spec-kit unpacking a toolchain
# into it, pocock handing an agent session the run of it -- still honor the
# fixed-location contract's "no trace left behind" guarantee: snapshot the
# repo's state first, then afterwards undo everything the run added or
# changed, keeping only the declared fixed_path for the driver runner to
# harvest.
#
# No network, no CLIs, no spec-kit -- the helpers are exercised directly
# against a throwaway git repo with hand-made "scaffolding", so this runs in
# the normal suite rather than being opt-in like the live e2e tests.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

# The helpers need bash 4 for their associative arrays, and say so; the
# drivers that source them check for it before they touch anybody's repo.
# This file has to make the same check for itself, because the rest of the
# suite is deliberately written to run under the bash 3.2 macOS still ships
# -- and a file that errored out here rather than skipping would report the
# machine's bash as a broken helper.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "skip: repo_snapshot.sh (the snapshot/restore helpers need bash 4+, running ${BASH_VERSION}; the drivers that source them refuse under an older one too)"
  exit 77
fi

ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/drivers/lib/repo-snapshot.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/src"
echo "# readme" > "$REPO/README.md"
echo "console.log('hi')" > "$REPO/src/index.js"
echo "doomed" > "$REPO/src/doomed.js"
make_repo_at "$REPO"

# State that was already there before the driver ran: one untracked file and
# one dirty tracked file. Neither belongs to the driver, so restore must
# leave both exactly as they are.
echo "mine" > "$REPO/scratch-note.md"
echo "# readme, edited by a human" > "$REPO/README.md"

echo "repo snapshot/restore:"

SNAP="$WORK/snapshot"
snapshot_repo_state "$REPO" > "$SNAP"

# Now simulate a spec-kit run: scaffolding written all over the repo, a
# tracked file clobbered, a tracked file deleted, and -- buried inside the
# scaffolding -- the one artifact we actually want to keep.
mkdir -p "$REPO/.specify/memory" "$REPO/.specify/scripts/bash" "$REPO/.claude/skills/speckit-constitution"
echo "the constitution" > "$REPO/.specify/memory/constitution.md"
echo "resolver" > "$REPO/.specify/scripts/bash/resolve-template.sh"
echo "feature.json" > "$REPO/.specify/.gitignore"
echo "skill" > "$REPO/.claude/skills/speckit-constitution/SKILL.md"
echo "clobbered by the toolchain" > "$REPO/src/index.js"
rm "$REPO/src/doomed.js"

restore_repo_state "$REPO" "$SNAP" ".specify/memory/constitution.md"

assert_file_exists "$REPO/.specify/memory/constitution.md" \
  "the kept path survives restore, so the driver runner still has something to harvest"
assert_eq "$(cat "$REPO/.specify/memory/constitution.md" 2>/dev/null)" "the constitution" \
  "the kept path's content is untouched by restore"

assert_file_missing "$REPO/.specify/scripts/bash/resolve-template.sh" \
  "scaffolding the run added is removed"
assert_file_missing "$REPO/.specify/.gitignore" \
  "scaffolding the run added is removed even when it is itself a gitignore file"
assert_file_missing "$REPO/.claude/skills/speckit-constitution/SKILL.md" \
  "scaffolding added outside the kept path's own directory tree is removed too"

assert_dir_missing "$REPO/.claude" "directories left empty by the cleanup are pruned"
assert_dir_missing "$REPO/.specify/scripts" \
  "empty directories are pruned all the way up, not just the leaf"
assert_dir_exists "$REPO/.specify/memory" \
  "a directory still holding the kept path is not pruned"

assert_eq "$(cat "$REPO/src/index.js" 2>/dev/null)" "console.log('hi')" \
  "a tracked file the run clobbered is restored from HEAD"
assert_file_exists "$REPO/src/doomed.js" \
  "a tracked file the run deleted is restored from HEAD"

assert_file_exists "$REPO/scratch-note.md" \
  "an untracked file that predates the run is left alone"
assert_eq "$(cat "$REPO/README.md" 2>/dev/null)" "# readme, edited by a human" \
  "a tracked file already dirty before the run keeps its edits (restore undoes the run's changes, not the human's)"

# The only thing standing between this repo and its pre-run git status is
# the artifact the driver runner is about to move out of it.
assert_eq "$(git -C "$REPO" status --porcelain)" \
  "$(printf ' M README.md\n?? .specify/\n?? scratch-note.md')" \
  "git status after restore shows the pre-run state plus the kept artifact, nothing else"

echo ""
echo "repo snapshot/restore, no kept path:"

REPO2="$WORK/repo2"
mkdir -p "$REPO2"
echo "# readme" > "$REPO2/README.md"
make_repo_at "$REPO2"

SNAP2="$WORK/snapshot2"
snapshot_repo_state "$REPO2" > "$SNAP2"
mkdir -p "$REPO2/.specify/memory"
echo "junk" > "$REPO2/.specify/memory/constitution.md"
restore_repo_state "$REPO2" "$SNAP2"

assert_eq "$(git -C "$REPO2" status --porcelain)" "" \
  "with nothing to keep, restore returns the repo to a completely clean git status"
assert_dir_missing "$REPO2/.specify" \
  "with nothing to keep, the scaffolding's directories are pruned entirely"

echo ""
echo "repo snapshot/restore, directories holding no files:"

# git tracks no directories at all, so an empty one a scaffolder leaves
# behind is invisible to `git status` -- it has to be caught by diffing the
# directory listing, or the "no trace" guarantee quietly isn't one.
REPO3="$WORK/repo3"
mkdir -p "$REPO3/keep-me/nested"
echo "# readme" > "$REPO3/README.md"
make_repo_at "$REPO3"

SNAP3="$WORK/snapshot3"
snapshot_repo_state "$REPO3" > "$SNAP3"
mkdir -p "$REPO3/.specify/extensions" "$REPO3/.specify/workflows/speckit"
restore_repo_state "$REPO3" "$SNAP3"

assert_dir_missing "$REPO3/.specify" \
  "a directory the run created and left holding nothing at all is removed"
assert_dir_exists "$REPO3/keep-me/nested" \
  "an empty directory that predates the run is left alone"
assert_eq "$(git -C "$REPO3" status --porcelain)" "" \
  "the repo is clean afterwards (which git status would have said either way -- hence the directory assertions above)"

echo ""
echo "repo snapshot/restore, naming what the run changed:"

# Restoring silently is right for a driver whose tool was always going to
# scaffold itself in. It is not right for one whose session was asked for a
# single file and wrote four: that driver has to tell the operator what
# happened, which means asking the same diff restore acts on to answer in
# words instead. One diff, two readings -- a second way of working out what
# a run touched would be free to disagree with the one that cleans up.
REPO5="$WORK/repo5"
mkdir -p "$REPO5/src"
echo "# readme" > "$REPO5/README.md"
echo "console.log('hi')" > "$REPO5/src/index.js"
make_repo_at "$REPO5"
echo "mine" > "$REPO5/scratch-note.md"

SNAP5="$WORK/snapshot5"
snapshot_repo_state "$REPO5" > "$SNAP5"

mkdir -p "$REPO5/docs/adr"
echo "the map" > "$REPO5/CONTEXT.md"
echo "an ADR nobody asked for" > "$REPO5/docs/adr/001-widgets.md"
echo "helpfully reformatted" > "$REPO5/src/index.js"
mkdir -p "$REPO5/.claude/skills"

changed="$(paths_changed_since_snapshot "$REPO5" "$SNAP5" CONTEXT.md)"

assert_contains "$changed" "docs/adr/001-widgets.md" \
  "a file the run added is named"
assert_contains "$changed" "src/index.js" \
  "a tracked file the run changed is named"
assert_not_contains "$changed" "CONTEXT.md" \
  "the kept path is not named -- writing it is what the run was for"
assert_not_contains "$changed" "scratch-note.md" \
  "an untracked file that predates the run is not named: it is not the run's doing"
assert_eq "$(printf '%s' "$changed" | wc -l | tr -d ' ')" "1" \
  "nothing else is named (two paths, so one newline between them)"

# What restore then does about them, on the same repo and the same
# snapshot: naming and undoing have to agree, because a driver that reports
# one set and cleans up another leaves the operator looking in the wrong
# place.
restore_repo_state "$REPO5" "$SNAP5" CONTEXT.md

assert_file_missing "$REPO5/docs/adr/001-widgets.md" "everything named is put back"
assert_dir_missing "$REPO5/docs" "and the directories it was written into go too"
assert_dir_missing "$REPO5/.claude" \
  "an empty directory the run left is pruned as well, though git status cannot see it and neither can the naming"
assert_eq "$(cat "$REPO5/src/index.js" 2>/dev/null)" "console.log('hi')" \
  "a tracked file the run changed is put back to what HEAD says"
assert_file_exists "$REPO5/CONTEXT.md" "the kept path survives"
assert_file_exists "$REPO5/scratch-note.md" "and so does what predated the run"

assert_eq "$(paths_changed_since_snapshot "$REPO5" "$SNAP5" CONTEXT.md)" "" \
  "after restore there is nothing left to name"

echo ""
echo "repo snapshot/restore, naming what the run changed when HEAD moved:"

# The same refusal restore makes, for the same reason: with HEAD moved, what
# the run added cannot be told apart from what was already committed, so
# there is no honest answer to give. Failing is what lets a driver say the
# repo needs looking at rather than report an empty list as "it wrote
# nothing".
REPO6="$WORK/repo6"
mkdir -p "$REPO6"
echo "# readme" > "$REPO6/README.md"
make_repo_at "$REPO6"
SNAP6="$WORK/snapshot6"
snapshot_repo_state "$REPO6" > "$SNAP6"
echo "an ADR nobody asked for" > "$REPO6/ADR.md"
git -C "$REPO6" add -A
git -C "$REPO6" commit -qm "committed it too"

if err="$(paths_changed_since_snapshot "$REPO6" "$SNAP6" 2>&1)"; then
  fail "naming what changed refuses when HEAD moved, rather than reporting nothing changed"
else
  pass "naming what changed refuses when HEAD moved, rather than reporting nothing changed"
fi
assert_contains "$err" "HEAD moved" "the refusal says what went wrong"
assert_contains "$err" "$REPO6" "the refusal names the repo that needs looking at by hand"

echo ""
echo "repo snapshot/restore, HEAD moved during the run:"

# Every judgement restore makes is relative to the commit HEAD pointed at
# when the snapshot was taken. An agent session that commits has made the
# scaffolding indistinguishable from the repo's own history -- and, worse,
# left `git status` reading clean. Restoring on that basis would be
# guesswork, so it refuses and says so.
REPO4="$WORK/repo4"
mkdir -p "$REPO4"
echo "# readme" > "$REPO4/README.md"
make_repo_at "$REPO4"

SNAP4="$WORK/snapshot4"
snapshot_repo_state "$REPO4" > "$SNAP4"
mkdir -p "$REPO4/.specify/memory"
echo "scaffolding" > "$REPO4/.specify/memory/constitution.md"
git -C "$REPO4" add -A
git -C "$REPO4" commit -qm "committed the scaffolding"

if err="$(restore_repo_state "$REPO4" "$SNAP4" 2>&1)"; then
  fail "restore refuses when HEAD moved during the run"
else
  pass "restore refuses when HEAD moved during the run"
fi
assert_contains "$err" "HEAD moved" \
  "the refusal says what went wrong rather than failing silently"
assert_contains "$err" "$REPO4" \
  "the refusal names the repo that needs looking at by hand"
assert_file_exists "$REPO4/.specify/memory/constitution.md" \
  "the refusal changes nothing -- unwinding a commit is the operator's call, not this helper's"

echo ""
echo "repo snapshot/restore, work the repo already had uncommitted:"

# The hole the record-by-name snapshot could not see. A repo somebody is
# working in is normally dirty -- an untracked note, an edited source file --
# and the drivers are pointed at exactly those repos. Both kinds of path are
# recorded by name, so a run's write to one used to be indistinguishable from
# the state that predated it: the session clobbered the operator's work, the
# cleanup left it alone because leaving it alone is what the name says to do,
# and nothing anywhere said so.
#
# Unrestored it stays -- nothing here keeps a copy of what an uncommitted file
# said, and that is a deliberate cost not paid. Unreported it does not.
REPO7="$WORK/repo7"
mkdir -p "$REPO7/src"
echo "# readme" > "$REPO7/README.md"
echo "console.log('hi')" > "$REPO7/src/index.js"
echo "console.log('bye')" > "$REPO7/src/other.js"
printf 'node_modules/\n' > "$REPO7/.gitignore"
make_repo_at "$REPO7"

# What the operator had in flight when the run started: two untracked files,
# two edits to tracked ones, an older copy of the very file the run is for,
# and something under an ignored directory.
echo "notes to self" > "$REPO7/scratch-note.md"
echo "half a thought" > "$REPO7/half-done.md"
echo "an old map" > "$REPO7/CONTEXT.md"
echo "// mine, uncommitted" >> "$REPO7/src/index.js"
echo "// also mine" >> "$REPO7/src/other.js"
mkdir -p "$REPO7/node_modules/pkg"
echo "module.exports = 1" > "$REPO7/node_modules/pkg/index.js"

SNAP7="$WORK/snapshot7"
snapshot_repo_state "$REPO7" > "$SNAP7"

# The session, having been asked for one file.
echo "the map" > "$REPO7/CONTEXT.md"
echo "helpfully rewritten" > "$REPO7/scratch-note.md"
echo "console.log('reformatted')" > "$REPO7/src/index.js"
rm "$REPO7/half-done.md"
echo "module.exports = 2" > "$REPO7/node_modules/pkg/index.js"

changed7="$(paths_changed_since_snapshot "$REPO7" "$SNAP7" CONTEXT.md)"

assert_contains "$changed7" "scratch-note.md" \
  "an untracked file the operator had not committed, whose contents the run wrote over, is named"
assert_contains "$changed7" "src/index.js" \
  "a tracked file the operator had already edited, whose contents the run wrote over, is named"
assert_contains "$changed7" "half-done.md" \
  "and one the run removed outright is named too -- removing it is the same loss as writing over it"
assert_not_contains "$changed7" "src/other.js" \
  "an uncommitted edit the run left alone is not named: being dirty is not the same as being written to"
assert_not_contains "$changed7" "CONTEXT.md" \
  "the kept path is not named among what the run wrote over, even though the operator had uncommitted work in it: writing that one is what the run was for, and a driver failing over it would fail against every repo that already had one in flight -- it is reported separately, by the section below"
assert_not_contains "$changed7" "node_modules" \
  "a path inside a directory git is ignoring whole is not named: the listing collapses node_modules to one entry and never descends into it, which is the cost this deliberately does not pay -- the ignored files git *does* list one by one have their own section below"

# What restore then does about them, on the same repo and the same snapshot.
# It cannot put any of them back, so the only thing left that is worth doing
# is saying which ones -- and saying it here rather than leaving it to the
# caller, because this runs from a driver's exit trap, where the caller is a
# script on its way out and nothing else is going to ask.
restore7="$(restore_repo_state "$REPO7" "$SNAP7" CONTEXT.md 2>&1 >/dev/null)"

assert_contains "$restore7" "scratch-note.md" \
  "restore says which of the operator's uncommitted files it could not put back"
assert_contains "$restore7" "src/index.js" \
  "including the tracked one, which HEAD could only restore by throwing the operator's own edit away as well"
assert_contains "$restore7" "$REPO7" "and names the repo they are in"
assert_eq "$(cat "$REPO7/scratch-note.md" 2>/dev/null)" "helpfully rewritten" \
  "and leaves them as the run left them rather than guessing at what they said"
assert_eq "$(cat "$REPO7/src/index.js" 2>/dev/null)" "console.log('reformatted')" \
  "the tracked one included -- restoring it from HEAD would undo the operator's edit too"
assert_file_missing "$REPO7/half-done.md" \
  "and one the run removed stays removed, for the same reason: there is no copy of it"
assert_eq "$(cat "$REPO7/src/other.js" 2>/dev/null)" \
  "$(printf "console.log('bye')\n// also mine")" \
  "an uncommitted edit the run left alone is still exactly as the operator left it"
assert_file_exists "$REPO7/node_modules/pkg/index.js" \
  "and a path inside a wholly-ignored directory is still there -- unreported, but not deleted either"

# And the one path both of those readings pass over, asked for on its own.
#
# The exemption above is right and stays: the kept path is the file the run
# exists to write, so reporting it as a loss would fail every run against a
# repo that already had one. But the fixed-location contract does not stop at
# writing it -- archimedes then moves it out of the repo -- so an operator who
# had a CONTEXT.md of their own in flight has it replaced and then taken away,
# and every word of that happens on a run that succeeded. Said here, on the
# same repo and the same snapshot as the two readings that skip it, so the
# three cannot drift into three different answers about the same file.
#
# Asked after restore, deliberately: that is where a driver's success path
# asks it, with everything but the kept path already put back.
replaced7="$(report_kept_paths_replaced "$REPO7" "$SNAP7" CONTEXT.md 2>&1 >/dev/null)"

assert_contains "$replaced7" "CONTEXT.md" \
  "the kept path the operator had uncommitted work in, which the run then wrote its own over, is named"
assert_contains "$replaced7" "$REPO7" "and the repo it was in is named"
assert_not_contains "$replaced7" "scratch-note.md" \
  "and nothing else is: what restore already reported is not reported a second time here"

# The other half of the report: a run that touched none of it says nothing,
# so the message means something when it does appear.
REPO9="$WORK/repo9"
mkdir -p "$REPO9"
echo "# readme" > "$REPO9/README.md"
make_repo_at "$REPO9"
echo "notes to self" > "$REPO9/scratch-note.md"
echo "# readme, edited by a human" > "$REPO9/README.md"
SNAP9="$WORK/snapshot9"
snapshot_repo_state "$REPO9" > "$SNAP9"
echo "the map" > "$REPO9/CONTEXT.md"

assert_eq "$(paths_changed_since_snapshot "$REPO9" "$SNAP9" CONTEXT.md)" "" \
  "a run that wrote only what it was asked for names nothing, though the repo was dirty throughout"
assert_eq "$(restore_repo_state "$REPO9" "$SNAP9" CONTEXT.md 2>&1 >/dev/null)" "" \
  "and restore says nothing either -- the report has to be silent when there is nothing to report, or it is noise"
assert_eq "$(report_kept_paths_replaced "$REPO9" "$SNAP9" CONTEXT.md 2>&1 >/dev/null)" "" \
  "and nothing is said about the kept path: this repo had no CONTEXT.md of its own for the run to replace, and a note on every successful run is a note nobody reads"

echo ""
echo "repo snapshot/restore, work the operator keeps out of git:"

# The other half of the same hole, and the half that holds the work worth
# most. `git ls-files --others --exclude-standard` -- the set the section
# above fingerprints -- stops at git's ignore rules, and "ignored" covers two
# populations that have nothing in common. node_modules is regenerable and
# nobody would miss it; a .env, a local settings file, a scratch directory
# somebody keeps out of git precisely because it is theirs, are ignored for
# the opposite reason. Both shipped drivers hand a headless agent write
# access to the repo, so the second population is exactly what a session
# being helpful about configuration writes into.
#
# What separates the two is something git already computes: asked for the
# ignored paths in its normal untracked mode, git collapses a wholly-ignored
# directory to one `node_modules/` entry and never descends into it, while
# listing an ignored *file* by name. So the expensive set and the interesting
# one arrive already told apart -- and which untracked mode it is asked in
# turns out to be the whole of that, which the section below is about.
REPO20="$WORK/repo20"
mkdir -p "$REPO20/src" "$REPO20/.claude"
echo "# readme" > "$REPO20/README.md"
echo "console.log('hi')" > "$REPO20/src/index.js"
echo "{}" > "$REPO20/.claude/settings.json"
printf 'node_modules/\n.env\nsettings.local.json\n*.tmp\n' > "$REPO20/.gitignore"
make_repo_at "$REPO20"

# What the operator had out of git when the run started: a .env holding real
# credentials, a local settings file beside a tracked one, an ignored file the
# run will leave alone, and a wholly-ignored directory nobody would miss.
echo "API_KEY=the-real-one" > "$REPO20/.env"
echo '{"mine":true}' > "$REPO20/.claude/settings.local.json"
echo "scratch" > "$REPO20/notes.tmp"
echo "notes to self" > "$REPO20/scratch-note.md"
mkdir -p "$REPO20/node_modules/pkg"
echo "module.exports = 1" > "$REPO20/node_modules/pkg/index.js"

SNAP20="$WORK/snapshot20"
snapshot_repo_state "$REPO20" > "$SNAP20"

# The session, having been asked for one file and having decided to be
# helpful about configuration on the way.
echo "the map" > "$REPO20/CONTEXT.md"
echo "API_KEY=placeholder" > "$REPO20/.env"
echo '{"helpfully":"rewritten"}' > "$REPO20/.claude/settings.local.json"
echo "helpfully rewritten" > "$REPO20/scratch-note.md"
echo "module.exports = 2" > "$REPO20/node_modules/pkg/index.js"

restore20="$(restore_repo_state "$REPO20" "$SNAP20" CONTEXT.md 2>&1 >/dev/null)"

assert_contains "$restore20" "
  .env
" \
  "an ignored file the operator had real work in, which the run wrote over, is named -- this is the file the reporting existed least usefully without"
assert_contains "$restore20" "
  .claude/settings.local.json
" \
  "and so is a local settings file sitting beside a tracked one, which is how git comes to list it individually rather than collapsing the directory"
assert_contains "$restore20" "
  scratch-note.md
" \
  "alongside the paths git was not ignoring at all, in one list: to the operator it is one loss either way"
assert_not_contains "$restore20" "notes.tmp" \
  "an ignored file the run left alone is not named: being ignored is not the same as being written to"
assert_not_contains "$restore20" "node_modules/pkg" \
  "and nothing inside a wholly-ignored directory is, because the listing collapses it to one entry and never descends -- that is what keeps this affordable"
assert_contains "$restore20" "node_modules/" \
  "the report says so in as many words, so an operator reads the list knowing which half of their repo it covers"
assert_eq "$(cat "$REPO20/.env")" "API_KEY=placeholder" \
  "reporting is the whole of it: the file is left as the run left it, because nothing here holds a copy of what it said"
assert_file_exists "$REPO20/node_modules/pkg/index.js" \
  "and the ignored path nobody is told about is still there -- unreported, but not deleted either"

# And the half that must not move. pocock fails a run that wrote anything
# beyond its map, and it works that list out from this same diff. Widening
# what gets *reported* to the ignored files must not widen what a driver
# *fails* on, or a session touching a log file has made the driver worse.
extras20="$(paths_changed_since_snapshot "$REPO20" "$SNAP20" CONTEXT.md)"

assert_contains "$extras20" "scratch-note.md" \
  "the list a driver fails on still names what it named before"
assert_not_contains "$extras20" ".env" \
  "and does not name the ignored file the run wrote over: that loss is reported, not failed on, so a driver does not start rejecting runs over a file git was already ignoring"
assert_not_contains "$extras20" "settings.local.json" \
  "nor the local settings file, for the same reason"

# The one ignored path that was already failing runs, and still is: a file the
# run *created*. That has never needed a fingerprint -- it is simply not in
# the snapshot -- and nothing here changes what a driver does about it.
REPO21="$WORK/repo21"
mkdir -p "$REPO21"
echo "# readme" > "$REPO21/README.md"
printf '*.log\n' > "$REPO21/.gitignore"
make_repo_at "$REPO21"
SNAP21="$WORK/snapshot21"
snapshot_repo_state "$REPO21" > "$SNAP21"
echo "the map" > "$REPO21/CONTEXT.md"
echo "chatter" > "$REPO21/session.log"

assert_contains "$(paths_changed_since_snapshot "$REPO21" "$SNAP21" CONTEXT.md)" "session.log" \
  "an ignored file the run created is named where it always was: it is new, so there is nothing of the operator's in it, and the failure condition it feeds is unchanged"

# The one entry in that listing that is not "<status> <path>": a rename or
# copy is followed by a second record holding the path it came from, with no
# status in front of it. Nothing ignored is ever a rename, so this only bites
# through a filename -- but a repo is allowed to hold a file called `!! x`,
# and read as a status that bare record is an ignored path that was never
# ignored and is not even there.
REPO23="$WORK/repo23"
mkdir -p "$REPO23"
echo "# readme" > "$REPO23/README.md"
printf '.env\n' > "$REPO23/.gitignore"
echo "decoy" > "$REPO23/!! decoy.md"
make_repo_at "$REPO23"
git -C "$REPO23" mv "!! decoy.md" moved.md
echo "API_KEY=the-real-one" > "$REPO23/.env"

SNAP23="$WORK/snapshot23"
snapshot_repo_state "$REPO23" > "$SNAP23"

echo "API_KEY=placeholder" > "$REPO23/.env"
echo "decoy, put back by the run" > "$REPO23/!! decoy.md"
echo "the map" > "$REPO23/CONTEXT.md"

restore23="$(restore_repo_state "$REPO23" "$SNAP23" CONTEXT.md 2>&1 >/dev/null)"

assert_eq "$(ignored_file_paths "$REPO23" | tr '\0' '\n')" ".env" \
  "the ignored file is the whole of what the listing yields: the rename's other half is a bare path that reads exactly like an ignored entry for decoy.md, and stepping over it is the difference between that and a path this repo has never had"
assert_contains "$restore23" "
  .env
" \
  "and the run's write to the real one is still reported"
assert_not_contains "$restore23" "decoy" \
  "while the path that was never ignored and was never there is claimed nowhere"

# And the setting that would otherwise decide all of this from outside the
# repo. The collapse the G records are affordable because of is the untracked
# mode's doing, not `--ignored`'s, and the untracked mode has a config knob:
# `status.showUntrackedFiles = all` lists every file under node_modules
# individually, and `no` lists nothing ignored at all. Either one and the
# reporting is settled by an operator's .gitconfig rather than by this file.
REPO24="$WORK/repo24"
mkdir -p "$REPO24/node_modules/pkg"
echo "# readme" > "$REPO24/README.md"
printf 'node_modules/\n.env\n' > "$REPO24/.gitignore"
make_repo_at "$REPO24"
echo "API_KEY=the-real-one" > "$REPO24/.env"
echo "module.exports = 1" > "$REPO24/node_modules/pkg/index.js"

git -C "$REPO24" config status.showUntrackedFiles all
assert_eq "$(ignored_file_paths "$REPO24" | tr '\0' '\n')" ".env" \
  "a repo configured to show every untracked file still gets one entry for node_modules and one path fingerprinted: the collapse is asked for outright rather than inherited from a setting"

git -C "$REPO24" config status.showUntrackedFiles no
assert_eq "$(ignored_file_paths "$REPO24" | tr '\0' '\n')" ".env" \
  "and one configured to show none of them still finds the .env, rather than reporting a repo with nothing ignored worth watching"

git -C "$REPO24" config --unset status.showUntrackedFiles

# The kept path, when the kept path is one of these. A repo is allowed to
# gitignore the very file the driver is run to produce -- somebody who does
# not want a generated CONTEXT.md in their history -- and before the ignored
# files were fingerprinted at all, that operator's uncommitted version of it
# was replaced and harvested away with nothing said anywhere. The exemption
# stays what it was: not a loss, because writing that file is the run's job;
# and now a note, because one answer to "was this written over" serves both
# readings rather than two that could disagree.
REPO25="$WORK/repo25"
mkdir -p "$REPO25"
echo "# readme" > "$REPO25/README.md"
printf 'CONTEXT.md\n' > "$REPO25/.gitignore"
make_repo_at "$REPO25"
echo "an old map of mine" > "$REPO25/CONTEXT.md"

SNAP25="$WORK/snapshot25"
snapshot_repo_state "$REPO25" > "$SNAP25"
echo "the map this run wrote" > "$REPO25/CONTEXT.md"

assert_eq "$(paths_changed_since_snapshot "$REPO25" "$SNAP25" CONTEXT.md)" "" \
  "an ignored kept path is exempt from the losses exactly as a non-ignored one is: writing that file is what the run was for, so a driver does not fail over it"
assert_eq "$(restore_repo_state "$REPO25" "$SNAP25" CONTEXT.md 2>&1 >/dev/null)" "" \
  "and the rollback says nothing about it either, for the same reason"
assert_contains "$(report_kept_paths_replaced "$REPO25" "$SNAP25" CONTEXT.md 2>&1 >/dev/null)" "CONTEXT.md" \
  "but the success path says so, which is the whole of what the exemption is exempt from -- archimedes moves that file out of the repo afterwards, and being gitignored was never a reason to be told about it last"

echo ""
echo "repo snapshot, a repo whose ignore rules list thousands of files one by one:"

# The assumption the cheapness rests on is tidy ignore rules, and it is an
# assumption rather than a guarantee. A `*.log` pattern matching files that
# sit among tracked ones has git list every one of them individually -- the
# shape that breaks the collapse above. Measured rather than reasoned about:
# on 20,001 such files totalling 78 MB, fingerprinting the lot took 1.5s
# against 0.08s for the first 500, so the cap is 500 and the number is stated
# rather than guessed at.
#
# An honest "there were more than this" beats both an unbounded walk and a
# silent truncation, so the report says which it was.
REPO22="$WORK/repo22"
mkdir -p "$REPO22/logs"
echo "# readme" > "$REPO22/README.md"
echo "kept" > "$REPO22/logs/keep.txt"
printf '*.log\n' > "$REPO22/.gitignore"
make_repo_at "$REPO22"

# Zero-padded so the order git lists them in -- which is the order the cap
# takes the first N from -- is the order the names read in.
i=1
while [ "$i" -le 600 ]; do
  printf 'run %s\n' "$i" > "$(printf '%s/logs/a%04d.log' "$REPO22" "$i")"
  i=$((i + 1))
done

SNAP22="$WORK/snapshot22"
snapshot_repo_state "$REPO22" > "$SNAP22"

echo "written over, inside the cap" > "$REPO22/logs/a0001.log"
echo "written over, past the cap" > "$REPO22/logs/a0600.log"
echo "the map" > "$REPO22/CONTEXT.md"

restore22="$(restore_repo_state "$REPO22" "$SNAP22" CONTEXT.md 2>&1 >/dev/null)"

assert_contains "$restore22" "
  logs/a0001.log
" \
  "an ignored file inside the cap that the run wrote over is named"
assert_not_contains "$restore22" "
  logs/a0600.log
" \
  "one past it is not: there is no record of what it said, so there is nothing that can be claimed either way"
assert_contains "$restore22" "only the first 500 were fingerprinted" \
  "and the cap is stated, so the list is read as the bounded thing it is"
assert_contains "$restore22" "lists 600 ignored files individually" \
  "along with how many there actually were, which is the difference between an honest bound and a silent truncation"

# And the case the note exists for, which is the one where there is no list
# for it to bound. A run whose only loss was an ignored file past the cap
# reports nothing at all -- and read on its own, that silence says "nothing of
# yours was written over" when what happened is "nothing among the part I
# looked at". So the note is printed whether or not anything else is.
echo "written over, past the cap, and nothing else" > "$REPO22/logs/a0599.log"
SNAP22B="$WORK/snapshot22b"
snapshot_repo_state "$REPO22" > "$SNAP22B"
echo "written over again, past the cap" > "$REPO22/logs/a0600.log"

restore22b="$(restore_repo_state "$REPO22" "$SNAP22B" CONTEXT.md 2>&1 >/dev/null)"

assert_not_contains "$restore22b" "back as it was found, apart from" \
  "a run whose only write was past the cap has no losses to list, because there is no record of what that file said"
assert_contains "$restore22b" "only the first 500 were fingerprinted" \
  "but the bound is still said, so the silence is read as the bounded thing it is rather than as a repo that came through clean"

# The other half of that, or the note would be a line on every run everywhere.
assert_not_contains "$restore20" "were fingerprinted" \
  "a repo whose ignore rules stay under the cap is told nothing about it: there is no bound to say, so saying one would be the noise this is otherwise silent to avoid"

echo ""
echo "repo snapshot, a kept path the run rewrote without changing it:"

# The write that is not a loss. A CONTEXT.md the operator had uncommitted and
# the run rewrote byte for byte says exactly what it said before, so there is
# nothing to tell them about -- and the fingerprint already knows, because it
# is the contents that are compared and not the fact of a write.
REPO14="$WORK/repo14"
mkdir -p "$REPO14"
echo "# readme" > "$REPO14/README.md"
make_repo_at "$REPO14"
echo "the map, as it already was" > "$REPO14/CONTEXT.md"
SNAP14="$WORK/snapshot14"
snapshot_repo_state "$REPO14" > "$SNAP14"
echo "the map, as it already was" > "$REPO14/CONTEXT.md"

assert_eq "$(report_kept_paths_replaced "$REPO14" "$SNAP14" CONTEXT.md 2>&1 >/dev/null)" "" \
  "a kept path the run rewrote identically is not reported: the operator's version and the run's say the same thing, so nothing of theirs went anywhere"

echo ""
echo "repo snapshot, a kept path the operator had deleted:"

# The other write that is not a loss, and the one the fingerprint alone gets
# wrong. A tracked CONTEXT.md the operator deleted without committing the
# deletion is recorded as `-`, and a run that writes a new one moves that
# fingerprint -- which for any other path is a real loss, since the rollback
# leaves the operator's deletion undone. Not here: the harvest carries the
# run's file straight back out, so the repo ends with no CONTEXT.md, which is
# exactly where the operator left it. Reporting it would be announcing a loss
# that did not happen.
REPO16="$WORK/repo16"
mkdir -p "$REPO16"
echo "# readme" > "$REPO16/README.md"
echo "the map as it was committed" > "$REPO16/CONTEXT.md"
make_repo_at "$REPO16"
rm "$REPO16/CONTEXT.md"
SNAP16="$WORK/snapshot16"
snapshot_repo_state "$REPO16" > "$SNAP16"
echo "the map the run wrote" > "$REPO16/CONTEXT.md"

assert_eq "$(report_kept_paths_replaced "$REPO16" "$SNAP16" CONTEXT.md 2>&1 >/dev/null)" "" \
  "a kept path the operator had deleted and not committed is not reported: the harvest takes the run's copy away again, leaving the repo as they left it"

echo ""
echo "repo snapshot, a kept path nested inside the repo:"

# The same mechanism for the other shipped driver's fixed_path. spec-kit's is
# .specify/memory/constitution.md, an operator is much less likely to have one
# of those in flight than a hand-edited CONTEXT.md, and none of that is a
# reason for this to know which driver it is answering for.
REPO15="$WORK/repo15"
mkdir -p "$REPO15/.specify/memory"
echo "# readme" > "$REPO15/README.md"
make_repo_at "$REPO15"
echo "the constitution I was drafting" > "$REPO15/.specify/memory/constitution.md"
SNAP15="$WORK/snapshot15"
snapshot_repo_state "$REPO15" > "$SNAP15"
echo "the constitution the run wrote" > "$REPO15/.specify/memory/constitution.md"

assert_contains "$(report_kept_paths_replaced "$REPO15" "$SNAP15" .specify/memory/constitution.md 2>&1 >/dev/null)" \
  ".specify/memory/constitution.md" \
  "a kept path several directories down is reported the same way as one at the root"

echo ""
echo "repo snapshot/restore, a run that staged what the repo already had:"

# A session running the one git command that does not move HEAD, so nothing
# above refuses. Before this, the staged path read as a tracked file gone
# dirty, HEAD had never heard of it, and restore's answer to that is to
# unstage it and delete it -- these helpers destroying the very uncommitted
# work they exist to leave alone.
REPO10="$WORK/repo10"
mkdir -p "$REPO10"
echo "# readme" > "$REPO10/README.md"
make_repo_at "$REPO10"
echo "notes to self" > "$REPO10/scratch-note.md"
SNAP10="$WORK/snapshot10"
snapshot_repo_state "$REPO10" > "$SNAP10"
echo "the map" > "$REPO10/CONTEXT.md"
git -C "$REPO10" add scratch-note.md

changed10="$(paths_changed_since_snapshot "$REPO10" "$SNAP10" CONTEXT.md)"
assert_contains "$changed10" "scratch-note.md" \
  "a file the run staged is named: the run was told to run no git command that changes the repo"

restore_repo_state "$REPO10" "$SNAP10" CONTEXT.md

assert_file_exists "$REPO10/scratch-note.md" \
  "restore does not delete a file that predated the run just because the run staged it"
assert_eq "$(cat "$REPO10/scratch-note.md" 2>/dev/null)" "notes to self" \
  "and leaves its contents alone -- the file is the operator's, only the index entry was the run's doing"
assert_eq "$(git -C "$REPO10" status --porcelain)" "$(printf '?? CONTEXT.md\n?? scratch-note.md')" \
  "the index entry the run added is undone, so the repo is dirty in exactly the way it was, plus the kept path"

echo ""
echo "repo snapshot/restore, paths git cannot be handed a line at a time:"

# The fingerprinting asks git for every path in one go, which means handing it
# a list one path per line -- and git reads that list the way it reads any
# line: a newline ends a path early, a trailing carriage return is stripped off
# it, and anything arriving quoted is unquoted. The last two are the ones worth
# a test, because git then answers for a *different* file and exits zero, so
# nothing downstream has any reason to doubt it. Given a sibling with the name
# git resolves to, the wrong hash lands on the right path and the report is
# quietly wrong in both directions at once.
REPO11="$WORK/repo11"
mkdir -p "$REPO11"
echo "# readme" > "$REPO11/README.md"
make_repo_at "$REPO11"

CR_NAME="$(printf 'note\r')"
printf 'the one with the carriage return\n' > "$REPO11/$CR_NAME"
printf 'the sibling git resolves that name to\n' > "$REPO11/note"
printf 'the one that looks quoted\n' > "$REPO11/\"quoted\".md"
printf 'the one with a newline in it\n' > "$REPO11/$(printf 'two\nlines.md')"

SNAP11="$WORK/snapshot11"
snapshot_repo_state "$REPO11" > "$SNAP11"

# Only the carriage-return one is written to. Its plain sibling is left alone,
# so a fingerprint that had been taken from the sibling reports the reverse of
# what happened: the file that changed looks untouched and the one that did not
# looks written over.
printf 'rewritten by the session\n' > "$REPO11/$CR_NAME"

changed11="$(changed_since_snapshot "$REPO11" "$SNAP11" | tr '\0' '\n')"

assert_contains "$changed11" "$CR_NAME" \
  "a path whose name ends in a carriage return is fingerprinted as itself, so a write to it is reported"
# Line-exact, because the record for the carriage-return path *starts* with
# the sibling's whole name -- which is the entire trouble -- so anything less
# than a whole-line match would be satisfied by the very record under test.
if printf '%s\n' "$changed11" | grep -qxF "$(printf 'O\tnote')"; then
  fail "its plain-named sibling is not reported in its place, which is the name git resolves when it reads the path a line at a time"
else
  pass "its plain-named sibling is not reported in its place, which is the name git resolves when it reads the path a line at a time"
fi
assert_eq "$(printf '%s\n' "$changed11" | grep -c "^O$(printf '\t')")" "1" \
  "exactly one path is reported written over, so no second record was invented for a name that only looked like one"
assert_not_contains "$changed11" '"quoted".md' \
  "a path that arrives looking quoted is left alone when it is left alone, rather than answered for by the name inside the quotes"
assert_not_contains "$changed11" "lines.md" \
  "and one with a newline in its name is not reported either"

echo ""
echo "repo snapshot, a repo with no commits yet, under a driver's shell options:"

# Every driver that sources this file runs under `set -euo pipefail`, and the
# fingerprinting happens inside a pipeline. A helper in there that hands back a
# non-zero status because there is no HEAD to diff against would not be a
# missing record -- pipefail and errexit would take the whole run down before
# the session ever started, on nothing worse than a repo whose first commit has
# not been made.
REPO12="$WORK/repo12"
mkdir -p "$REPO12"
git init -q "$REPO12"
echo "started, not committed" > "$REPO12/scratch-note.md"

# A statement of its own with the status read afterwards, rather than asked
# for in an `if`: bash ignores errexit inside a subshell that is a condition,
# so the `if` spelling of this runs under options no driver has and passes
# against a function that walked straight past a failure. Every check in this
# file that says "under a driver's shell options" is spelled this way.
( set -euo pipefail; snapshot_repo_state "$REPO12" > "$WORK/snapshot12" )
snap12=$?
if [ "$snap12" -eq 0 ]; then
  pass "snapshotting a repo with no commits yet succeeds under the shell options every driver sets"
else
  fail "snapshotting a repo with no commits yet succeeds under the shell options every driver sets"
fi
assert_contains "$(tr '\0' '\n' < "$WORK/snapshot12")" "scratch-note.md" \
  "and it still fingerprints the work already sitting there, HEAD or no HEAD"

echo ""
echo "repo snapshot, a batch answer that does not line up with the question:"

# `git hash-object --stdin-paths` stops at the first path it cannot open, so a
# short answer is not a partial result to be salvaged: paired back onto the
# paths that were asked about, every hash after the failure lands on the wrong
# file -- which is worse than no answer, because each one is a claim about a
# file nobody looked at. Counting the answers is what catches it, and the slow
# path re-asks one at a time.
#
# Reachable only with a stand-in git, because provoking it for real needs a
# file that passes the readable test and then refuses to open. The stand-in
# answers for the first path and stops, which is the shape of the real thing.
REPO18="$WORK/repo18"
mkdir -p "$REPO18"
echo "# readme" > "$REPO18/README.md"
make_repo_at "$REPO18"
echo "one" > "$REPO18/one.md"
echo "two" > "$REPO18/two.md"
echo "three" > "$REPO18/three.md"

git() { # <arg>...
  local a
  for a in "$@"; do
    if [ "$a" = "--stdin-paths" ]; then
      command git "$@" | head -1
      return
    fi
  done
  command git "$@"
}
short18="$(printf 'one.md\0two.md\0three.md\0' | fingerprint_paths "$REPO18" | tr '\0' '\n')"
unset -f git

assert_eq "$short18" \
  "$(cd "$REPO18" && git hash-object --no-filters -- one.md two.md three.md \
     | paste - <(printf '%s\n' one.md two.md three.md))" \
  "a batch answer shorter than the question is thrown away and every path re-asked, rather than each hash being paired with whichever path it lands beside"

echo ""
echo "repo snapshot, a fingerprinting that could not run:"

# The one way this report can be wrong in the reassuring direction. Everything
# above asks whether the run wrote over work the operator had in flight, and
# the answer comes back through a fingerprinting step. A fingerprinting that
# could not run hands back no records -- which, read as records, is
# byte-for-byte "the run wrote over nothing of yours". So each of the three
# functions that read one is asked here to tell the two apart, with a stand-in
# fingerprinter that does nothing but fail.
#
# A stand-in rather than a machine with no temp space, because it is the
# readers that are under test and not the fingerprinter: what has to hold is
# that a producer failing anywhere down there cannot pass for an all-clear,
# whatever made it fail. The real fingerprint_paths is put back afterwards, so
# nothing below this section inherits it.
REPO17="$WORK/repo17"
mkdir -p "$REPO17"
echo "# readme" > "$REPO17/README.md"
make_repo_at "$REPO17"
echo "notes to self" > "$REPO17/scratch-note.md"
echo "the map I was drafting" > "$REPO17/CONTEXT.md"
SNAP17="$WORK/snapshot17"
snapshot_repo_state "$REPO17" > "$SNAP17"

# The run: an ADR nobody asked for, the operator's note written over, and
# their draft map replaced. Everything the sections above report on.
echo "an ADR nobody asked for" > "$REPO17/ADR.md"
echo "helpfully rewritten" > "$REPO17/scratch-note.md"
echo "the map" > "$REPO17/CONTEXT.md"

# Kept before it is stood on, and checked: an empty capture here would put
# nothing back at the end of the section, and everything after it would run
# against the stand-in while reading as though it had not.
FINGERPRINT_PATHS_REAL="$(declare -f fingerprint_paths)"
[ -n "$FINGERPRINT_PATHS_REAL" ] || { echo "could not capture the real fingerprint_paths to put back" >&2; exit 1; }
fingerprint_paths() { return 1; }

if out="$(overwritten_since_snapshot "$REPO17" "$SNAP17" scratch-note.md 2>&1)"; then
  fail "asking what the run wrote over fails when the fingerprinting cannot run"
else
  pass "asking what the run wrote over fails when the fingerprinting cannot run"
fi
assert_eq "$out" "" \
  "and names nothing while it fails: a path named here is one the caller reports as lost"

if changed_since_snapshot "$REPO17" "$SNAP17" CONTEXT.md >/dev/null 2>&1; then
  fail "reading what the run did fails rather than reporting the paths it could still see"
else
  pass "reading what the run did fails rather than reporting the paths it could still see"
fi

# The reading pocock acts on. It aborts the run on a non-zero status here, and
# an empty answer is the run reporting that the session kept to the one file
# it was asked for -- so these two are the same list of files told apart by
# status alone, and the status is the whole of the difference.
if out="$(paths_changed_since_snapshot "$REPO17" "$SNAP17" CONTEXT.md 2>&1)"; then
  fail "naming what the run changed fails rather than coming back empty, which is what a clean repo looks like"
else
  pass "naming what the run changed fails rather than coming back empty, which is what a clean repo looks like"
fi
assert_eq "$out" "" "and names nothing while it fails"

# And the rollback, which is where an operator is told the repo was put back.
# It has to have found out what to undo before it can claim to have undone it.
if out="$(restore_repo_state "$REPO17" "$SNAP17" CONTEXT.md 2>&1)"; then
  fail "restore refuses when it cannot find out what the run did, rather than reporting a repo put back that it never touched"
else
  pass "restore refuses when it cannot find out what the run did, rather than reporting a repo put back that it never touched"
fi
assert_file_exists "$REPO17/ADR.md" \
  "and it really did leave the repo alone -- a rollback that could not work out what to undo has undone nothing"
assert_not_contains "$out" "back as it was found" \
  "and says nothing about a repo it put back"

# The one that runs on the success path, where the harvest has already
# happened. It fails the same way; what differs is what the drivers do with
# the status, which is the section in each driver's test file.
if out="$(report_kept_paths_replaced "$REPO17" "$SNAP17" CONTEXT.md 2>&1)"; then
  fail "the note about a replaced kept path fails rather than staying silent, which is how it reports there was nothing to replace"
else
  pass "the note about a replaced kept path fails rather than staying silent, which is how it reports there was nothing to replace"
fi
assert_eq "$out" "" "and says nothing while it fails, so nothing reads as a report"

# The half that was already right, pinned so it stays that way: the
# fingerprinting in snapshot_repo_state is the last pipeline of the function,
# so pipefail carries its status out and a driver's `set -e` ends the run
# before a session ever starts.
( set -euo pipefail; snapshot_repo_state "$REPO17" > "$WORK/snapshot17-failed" )
snap17=$?
if [ "$snap17" -eq 0 ]; then
  fail "snapshotting fails under a driver's shell options when the fingerprinting cannot run"
else
  pass "snapshotting fails under a driver's shell options when the fingerprinting cannot run"
fi

eval "$FINGERPRINT_PATHS_REAL"

# And the fingerprinter itself, which no longer has anything to fail at. It
# used to want two temp files of its own -- three deep by the time a rollback
# reached it -- and failing to get one was the whole of how it could fail.
#
# That is not the same as a machine with no temp files now getting an answer:
# the callers above spool this, so such a machine still fails, and the section
# above is what makes it fail loudly. What has gone is the deepest place it
# could fail, in the one function every reading of the repo goes through.
#
# A stand-in mktemp rather than a hostile TMPDIR, because macOS's mktemp
# ignores a TMPDIR it cannot use and falls back to the per-user temp directory
# -- so the hostile-TMPDIR spelling of this passed against the version that
# did use temp files, which is no test at all.
mktemp() { return 1; }
assert_eq "$(printf 'scratch-note.md\0' | fingerprint_paths "$REPO17" | tr '\0' '\n')" \
  "$(printf '%s\t%s' "$(git -C "$REPO17" hash-object --no-filters -- scratch-note.md)" scratch-note.md)" \
  "the fingerprinting itself needs no temp file, so it has nothing left to fail at on a machine that has run out of them"
unset -f mktemp

echo ""
echo "repo snapshot, a machine that has run out of temp files:"

# The spool the sentence above turns on, held to by every helper that does it.
#
# `mktemp`, redirect a producer into it, carry a failure out, read it back,
# remove it: that idiom is written out six times in repo-snapshot.sh, once per
# helper that reads a producer, and six copies of a failure path is the shape
# that file's own header warns about -- "a second copy of this would be the
# one that drifts, and it would drift on the failure path, where nobody is
# watching". The drift that matters is a seventh copy written without the
# `|| return 1`, which is the silent-success bug 74, 77 and 82 were each filed
# against, reintroduced one function at a time.
#
# Sharing the idiom is not the answer. Bash cannot be handed a loop body, so
# what could be extracted is the two lines either side of the part that
# differs -- and moving those away from the comment explaining why *that*
# particular read must not be a process substitution costs more than the
# repetition does. So the property is held to instead of the code being
# shared, and a seventh helper is one more line here.
#
# Asked of every one of them in a loop rather than six blocks, because "every
# one of them, including the next" is the whole of what this checks.
REPO26="$WORK/repo26"
mkdir -p "$REPO26"
echo "# readme" > "$REPO26/README.md"
printf '.env\n' > "$REPO26/.gitignore"
make_repo_at "$REPO26"

# Uncommitted work of both kinds, and the snapshot taken while mktemp still
# works. Two of these helpers reach their mktemp only when the snapshot gave
# them something to fingerprint, so a repo with nothing in flight would pass
# this without ever having got as far as the line under test: a B record for
# the untracked note, a G one for the .env.
echo "notes to self" > "$REPO26/scratch-note.md"
echo "API_KEY=the-real-one" > "$REPO26/.env"
SNAP26="$WORK/snapshot26"
snapshot_repo_state "$REPO26" > "$SNAP26"

# And a run, so there is something for each of them to have to report.
echo "the map" > "$REPO26/CONTEXT.md"
echo "helpfully rewritten" > "$REPO26/scratch-note.md"

mktemp() { return 1; }
for fn in snapshot_repo_state changed_since_snapshot overwritten_since_snapshot \
          paths_changed_since_snapshot report_kept_paths_replaced \
          restore_repo_state; do
  case "$fn" in
    # The one that is handed a repo rather than a snapshot of one.
    snapshot_repo_state) "$fn" "$REPO26" ;;
    # And the one whose arguments are the paths to ask about rather than the
    # paths to skip -- handed a fingerprinted one, or it would return zero
    # having found nothing to compare and never reached its mktemp at all.
    overwritten_since_snapshot) "$fn" "$REPO26" "$SNAP26" scratch-note.md ;;
    *) "$fn" "$REPO26" "$SNAP26" CONTEXT.md ;;
  esac >/dev/null 2>&1
  mktemp_status=$?
  if [ "$mktemp_status" -eq 0 ]; then
    fail "$fn carries a temp file it could not get out as a status, rather than as the short answer that reads as good news"
  else
    pass "$fn carries a temp file it could not get out as a status, rather than as the short answer that reads as good news"
  fi
done
unset -f mktemp

echo ""
echo "repo snapshot, a read of the repo that could not be made:"

# The other three producers read the same way the fingerprinting was, and with
# the same consequence: `git ls-files --others`, `git diff --name-only` and the
# directory walk each hand back nothing when they fall over, and nothing is
# byte-for-byte what a repo the run did not touch looks like. The worst of them
# is the tracked-file read, because the C records are how a clobbered tracked
# file gets checked back out of HEAD -- so a rollback that loses them puts
# nothing back and then says the repo is back as it was found.
#
# A stand-in git that fails for one flag and delegates the rest, so each read is
# broken on its own while everything around it -- the HEAD check, the checkout,
# the unstaging -- still works. Provoking these for real would need a repo git
# itself could not read, which is not a state a test can leave lying around.
GIT_STAND_IN_FLAG=""
git() { # <arg>...
  local a
  for a in "$@"; do
    if [ "$a" = "$GIT_STAND_IN_FLAG" ]; then return 1; fi
  done
  command git "$@"
}

REPO19="$WORK/repo19"
mkdir -p "$REPO19/src"
echo "# readme" > "$REPO19/README.md"
echo "console.log('hi')" > "$REPO19/src/index.js"
make_repo_at "$REPO19"
echo "notes to self" > "$REPO19/scratch-note.md"
SNAP19="$WORK/snapshot19"
snapshot_repo_state "$REPO19" > "$SNAP19"

# The run: a file of its own, a tracked file clobbered, the operator's note
# written over, and a directory left behind. One of each thing a rollback has
# to undo or report.
echo "an ADR nobody asked for" > "$REPO19/ADR.md"
echo "clobbered by the run" > "$REPO19/src/index.js"
echo "helpfully rewritten" > "$REPO19/scratch-note.md"
mkdir -p "$REPO19/.specify/memory"

GIT_STAND_IN_FLAG="--others"
if changed_since_snapshot "$REPO19" "$SNAP19" >/dev/null 2>&1; then
  fail "reading what the run did fails when the untracked listing cannot be made, rather than reading as a run that added nothing"
else
  pass "reading what the run did fails when the untracked listing cannot be made, rather than reading as a run that added nothing"
fi

if out="$(paths_changed_since_snapshot "$REPO19" "$SNAP19" 2>&1)"; then
  fail "naming what the run changed carries that failure out rather than coming back empty"
else
  pass "naming what the run changed carries that failure out rather than coming back empty"
fi
assert_eq "$out" "" "and names nothing while it fails"

# The rollback reads the same answer, so it refuses too rather than deleting
# what it could still see and calling the repo restored.
if out="$(restore_repo_state "$REPO19" "$SNAP19" 2>&1)"; then
  fail "restore refuses when the untracked listing cannot be made, rather than reporting a repo put back"
else
  pass "restore refuses when the untracked listing cannot be made, rather than reporting a repo put back"
fi
assert_file_exists "$REPO19/ADR.md" \
  "and it really did leave the repo alone -- a rollback that could not work out what to undo has undone nothing"

GIT_STAND_IN_FLAG="--name-only"
if changed_since_snapshot "$REPO19" "$SNAP19" >/dev/null 2>&1; then
  fail "reading what the run did fails when the tracked-file read cannot be made, rather than reading as a run that changed nothing tracked"
else
  pass "reading what the run did fails when the tracked-file read cannot be made, rather than reading as a run that changed nothing tracked"
fi

if out="$(paths_changed_since_snapshot "$REPO19" "$SNAP19" 2>&1)"; then
  fail "and naming what the run changed carries that one out too"
else
  pass "and naming what the run changed carries that one out too"
fi
assert_eq "$out" "" "and names nothing while it fails"

# The one this issue is named for. No C records means nothing is checked out of
# HEAD, and no C records is indistinguishable from a run that touched no
# tracked file -- so read that way the rollback puts the clobbered file back
# nowhere and announces a repo it has not touched.
if out="$(restore_repo_state "$REPO19" "$SNAP19" 2>&1)"; then
  fail "restore refuses when the tracked-file read cannot be made, rather than reporting a repo put back"
else
  pass "restore refuses when the tracked-file read cannot be made, rather than reporting a repo put back"
fi
assert_not_contains "$out" "back as it was found" \
  "and does not say the repo is back as it was found"
assert_eq "$(cat "$REPO19/src/index.js")" "clobbered by the run" \
  "and the tracked file the run wrote over is still as the run left it, which is what the refusal is about"

# And the read the snapshot half added, which fails in the direction that
# reads best of all: no ignored listing means no G records, and no G records
# is byte-for-byte a repo whose ignore rules hold nothing but node_modules --
# so a run that wrote over the operator's .env would be reported nowhere, on
# the strength of a question nobody managed to ask. Taken under a driver's
# shell options, as a statement of its own, because that is where the status
# has to land.
GIT_STAND_IN_FLAG="--ignored=traditional"
( set -euo pipefail; snapshot_repo_state "$REPO19" > "$WORK/snapshot19-ignored" )
snap19_ignored=$?
if [ "$snap19_ignored" -eq 0 ]; then
  fail "snapshotting fails when the ignored listing cannot be made, rather than recording a repo with nothing ignored worth watching"
else
  pass "snapshotting fails when the ignored listing cannot be made, rather than recording a repo with nothing ignored worth watching"
fi

unset -f git
GIT_STAND_IN_FLAG=""

echo ""
echo "repo snapshot, a directory walk that could not be made:"

# The odd one of the four, and answered differently on purpose. The walk feeds
# the snapshot's D records and the prune at the end of a rollback, and its
# failure leaves a directory behind rather than misreporting one -- so the
# snapshot half refuses outright, while the rollback, which by then has already
# undone everything else, says what it could not do and lets the run stand.
find() { return 1; }

if list_repo_dirs "$REPO19" >/dev/null 2>&1; then
  fail "listing a repo's directories fails when the walk cannot be made, rather than reading as a repo with no directories"
else
  pass "listing a repo's directories fails when the walk cannot be made, rather than reading as a repo with no directories"
fi

# A snapshot with no D records is not a harmless one: every directory in the
# repo then reads as one the run created, and the rollback prunes the empty
# ones the operator had.
#
# The walk is not the last pipeline of the function -- the fingerprinting is
# -- so it is errexit rather than pipefail alone that has to end the run here,
# which is why the spelling above matters more for this one than for any other
# check in this file.
( set -euo pipefail; snapshot_repo_state "$REPO19" > "$WORK/snapshot19-failed" )
snap19=$?
if [ "$snap19" -eq 0 ]; then
  fail "snapshotting fails under a driver's shell options when the directory walk cannot be made"
else
  pass "snapshotting fails under a driver's shell options when the directory walk cannot be made"
fi

# Under `set -euo pipefail`, the options both drivers set, and as a statement
# of its own so that errexit is really on inside it -- the two halves of
# calling this the way a driver's success path does, where the call is
# unguarded. Neither half is optional: a bare call from a test shell with no
# errexit passes against a rollback that would end the driver at the first
# pipeline whose producer failed, having said none of what it says below.
out="$( set -euo pipefail; restore_repo_state "$REPO19" "$SNAP19" 2>&1 )"
ok19=$?
assert_eq "$ok19" "0" \
  "a rollback whose directory walk failed still stands: everything it undoes had already been undone by then, and an empty directory left behind is a trace rather than a repo reported back as it was not"
assert_contains "$out" "could not list" \
  "and says so, rather than being silent about the one thing it did not do"
assert_file_missing "$REPO19/ADR.md" \
  "and everything the walk is not needed for is still undone"
assert_eq "$(cat "$REPO19/src/index.js")" "console.log('hi')" \
  "including the tracked file the run clobbered, checked back out of HEAD"
assert_dir_exists "$REPO19/.specify/memory" \
  "the directory the run left behind is what is still there, which is what the line on stderr is for"
assert_contains "$out" "scratch-note.md" \
  "and the work the run wrote over is still named, which is the report nothing else will make"

unset -f find

report
