package driver

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// The backstop is what happens to a target repo when the driver that was
// going to put it back is not there to do it.
//
// A driver that scaffolds into somebody's repository undoes it from its own
// exit trap, and that stays the primary: it holds the snapshot, it knows
// what it wrote, and it is already running. interrupt.go is what makes that
// reachable however a run is stopped. What neither can cover is a trap that
// never runs at all — a SIGKILL, an OOM kill, a machine that loses power —
// and drivers/lib/repo-snapshot.sh has asked since it was written for the
// one thing a shell cannot do for itself: something outside the process
// that keeps the snapshot and re-runs the restore.
//
// This is that something, and it is deliberately only a backstop. Two rules
// keep it one:
//
//   - It acts only on a run that did not end well. A run that succeeded has
//     said what it has to say about the repo, and its fixed_path is about
//     to be harvested out of there — a rollback over the top of that would
//     delete the very file the run was for.
//   - It acts only on a snapshot the driver left behind. The driver removes
//     that file once the repo is back, so its absence is the driver saying
//     "done" and its presence is the one report a process that was
//     SIGKILL'd is still able to make. Where the driver did clean up, this
//     does nothing at all.
//
// What it cannot do is run after archimedes has been killed too, which is
// why the record outlives this process as well (internal/runrecord). What
// is left there is for `unfinished-runs` and an operator who decides to act
// on it — deliberately, because by then the run may be days old and writing
// to somebody's repository on the strength of that is not a thing to do on
// their behalf.

// backstopName is the helper beside the drivers that re-runs one's rollback
// from out here. It sits in lib/ because that is where a driver's shared
// bash lives and because it is the same rollback: a second implementation
// of it in Go would be the one that drifts, and it would drift on the
// failure path, where nobody is watching. 38 rejected moving rollback into
// this package and the reasoning holds — the runner has no git knowledge.
// It borrows the drivers'.
const backstopName = "backstop.sh"

// backstopVerbs are what the helper answers to.
const (
	verbRestore = "restore"
	verbList    = "list"
)

// PutBack re-runs the rollback of the driver a record names, over the repo
// it names, from the snapshot it holds. It is the deliberate half of the
// backstop: the same act archimedes makes on the spot for a driver that
// died under it, made later, by an operator who has read what the record
// says.
//
// A record rather than three arguments off one, because which driver, which
// repo and which snapshot are not three facts: they are one run, and a
// caller free to pair a driver with another run's snapshot is a caller free
// to roll a repo back to a state it was never in.
func (s Set) PutBack(rec *runrecord.Record, progress io.Writer) error {
	dir, release, err := s.resolve(rec.Driver)
	if err != nil {
		return err
	}
	defer release()
	return putBack(dir, rec.Repo, rec.SnapshotPath(), progress)
}

// Leftovers is what a run left in the repo its record names, as the
// driver's own diff sees it: the paths that appeared or changed since its
// snapshot. It is how a record turns into something an operator can read —
// "this repo, and this is what is sitting in it" — without anything being
// written to that repo to find out. Taking the record for the reason
// PutBack does.
func (s Set) Leftovers(rec *runrecord.Record) ([]string, error) {
	dir, release, err := s.resolve(rec.Driver)
	if err != nil {
		return nil, err
	}
	defer release()

	var out bytes.Buffer
	if err := backstop(dir, verbList, rec.Repo, rec.SnapshotPath(), &out, io.Discard); err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(out.String(), "\n") {
		if line != "" {
			paths = append(paths, line)
		}
	}
	return paths, nil
}

// openRecord notes a run about to start, so that a repo it leaves dirty is
// one something holds a record of.
//
// A record that cannot be written does not stop the run. The driver's own
// rollback is the primary and is unaffected by any of this, so failing here
// would cost an operator a mapping pass over bookkeeping — but it is said
// out loud rather than swallowed, because what they lose is the backstop
// and the state they are in is the one this whole arrangement is about.
func openRecord(records runrecord.Dir, name, repoPath string, progress io.Writer) *runrecord.Record {
	if records == "" {
		return nil
	}
	rec, err := records.Open(name, repoPath)
	if err != nil {
		fmt.Fprintf(progress, "could not record this run under %s: %v — the run goes ahead, but if it is killed outright nothing out here will know which repo it was in\n", records, err)
		return nil
	}
	return rec
}

// settle decides what the run's record means now that the driver has
// finished, and is the only place that decides it. runErr is how the run
// ended — the error invoking it returned, or nil.
//
// Told how the run ended rather than whether it went well, because "well"
// is the question being answered here and not one to be handed the answer
// to: a flag at the call site would put half this decision back in runIn.
func settle(rec *runrecord.Record, driversDir string, runErr error, progress io.Writer) {
	if rec == nil {
		return
	}
	// Two ways to have nothing to do, and they are worth reading as one:
	// the driver put the repo back and released the snapshot to say so, or
	// the run succeeded, which says the same thing on its own authority
	// and has a harvest riding on it. Either way the record has done its
	// job by not being needed.
	if runErr == nil || !rec.Restorable() {
		closeRecord(rec, progress)
		return
	}

	// What is left is a failed run whose driver did not give the snapshot
	// up, and that is two shapes rather than one: a driver that never
	// reached its trap, and a driver that reached it and whose rollback
	// failed or refused. They are treated alike on purpose. The second
	// will usually fail again here and say the same thing twice — a
	// HEAD that moved has not moved back — and that is a better trade
	// than a rule that reads the difference out of a dead process's
	// intentions. A rollback that failed on a full disk or a lock that
	// has since gone is worth the second attempt.

	fmt.Fprintf(progress, "the driver did not put %s back: it left the snapshot it took at the start, so archimedes is running that rollback from out here\n", rec.Repo)
	if err := putBack(driversDir, rec.Repo, rec.SnapshotPath(), progress); err != nil {
		fmt.Fprintf(progress, "could not put %s back: %v\n%s\n", rec.Repo, err, rec.Pointer())
		return
	}
	fmt.Fprintf(progress, "%s is back as it was found\n", rec.Repo)
	closeRecord(rec, progress)
}

// closeRecord clears a record away, and says so if it cannot. A record left
// where nothing needs one is not a broken run — the next `unfinished-runs`
// clears it, having found nothing in it — but it is litter nobody asked
// for, and an instance root that has stopped being writable is worth
// hearing about at the moment it is noticed.
func closeRecord(rec *runrecord.Record, progress io.Writer) {
	if err := rec.Close(); err != nil {
		fmt.Fprintf(progress, "could not clear away %s: %v\n", rec.Where(), err)
	}
}

// putBack runs the drivers' own rollback over repoPath, streaming what it
// says to progress — which is where the account of what could and could not
// be undone is written, and the reason this is not run for its status
// alone.
func putBack(driversDir, repoPath, snapshotPath string, progress io.Writer) error {
	fmt.Fprintf(progress, "rolling %s back from the snapshot at %s\n", repoPath, snapshotPath)
	return backstop(driversDir, verbRestore, repoPath, snapshotPath, progress, progress)
}

// backstop runs lib/backstop.sh out of driversDir.
//
// The two streams are kept apart by the caller rather than merged here,
// because what they carry differs by verb: `list` answers on stdout and
// anything on its stderr is a complaint about the reading, so folding the
// two together would one day report a warning as a path the run left in
// somebody's repo. `restore` has both go to the operator, which is where
// the account of what could and could not be undone belongs.
//
// Run with bash named explicitly rather than executed. Nothing in lib/ is a
// program a driver runs — the shipped copy is unpacked without an execute
// bit on purpose, since a driver *sources* what is in there — and the
// alternative, making one file in lib/ executable, would put the question
// "which of these is runnable?" into a directory whose whole answer today
// is "none of them".
func backstop(driversDir, verb, repoPath, snapshotPath string, out, errOut io.Writer) error {
	script := filepath.Join(driversDir, libDirName, backstopName)
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("no rollback helper at %s: %w", script, err)
	}
	if _, err := os.Stat(snapshotPath); err != nil {
		return fmt.Errorf("no snapshot at %s: %w", snapshotPath, err)
	}

	// Its own stderr is the report — which paths could not be put back,
	// and the refusal when HEAD has moved — so it is carried out to the
	// caller rather than kept for a status line. What comes back in the
	// error is a tail of it, for a caller that prints the error somewhere
	// else than the stream this wrote to, or that discarded it.
	var said bytes.Buffer
	cmd := exec.Command("bash", script, verb, repoPath, snapshotPath)
	cmd.Stdout = out
	cmd.Stderr = io.MultiWriter(errOut, &said)
	if err := cmd.Run(); err != nil {
		if reason := lastLine(said.String()); reason != "" {
			return fmt.Errorf("%s: %s", err, reason)
		}
		return err
	}
	return nil
}

// lastLine is the sentence a failed rollback ended on, which is the one
// that says why. The rest of what it printed has already gone to the
// operator's own stream.
func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}
