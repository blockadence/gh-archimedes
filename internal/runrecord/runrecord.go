// Package runrecord owns .archimedes-runs/: the note an instance keeps on
// disk for as long as a driver is running inside somebody else's
// repository, and after that only if the driver did not get to put the repo
// back.
//
// The drivers that scaffold into a repo undo it themselves, from an exit
// trap, and that stays the primary — a live driver knows what it wrote and
// is holding the snapshot to prove it (drivers/lib/repo-snapshot.sh). What
// a trap cannot do is run after a SIGKILL, an OOM kill or a machine that
// lost power, and that window is the one this exists for: the repo is left
// exactly as the session left it, and until there was a record of it
// somewhere outside the driver, nothing announced that. The operator found
// out the next time they ran `git status`, if they ever did.
//
// So the record is on disk before the driver starts, not held by the
// process waiting on it. Archimedes can be killed the same way the driver
// can, and a snapshot in the runner's memory closes nothing that forwarding
// the signal (internal/driver's interrupt.go) had not already closed.
//
// WHAT IS IN ONE. A directory per run, holding two things:
//
//   - run.yaml, written here before the driver starts: which repo, which
//     driver, when, and the pid of the archimedes that started it. It is
//     what lets an operator who finds one work out what it is about, and
//     it is the half this package writes.
//   - snapshot, which the *driver* writes, because it is the driver that
//     takes one and a second walk of the tree is the cost this arrangement
//     exists to avoid. Archimedes hands the path over in
//     ARCHIMEDES_RUN_SNAPSHOT and the driver writes there instead of into
//     a temp file of its own.
//
// The snapshot is also the protocol, and it carries the one fact nothing
// else can report: a driver removes it once the repo is back, and only
// then. So a snapshot still sitting there after a run has ended means the
// repo was not put back — whether the driver was killed before its trap, or
// ran the trap and the rollback refused. A driver that was SIGKILL'd cannot
// lie about this, which is the whole reason the signal is "the file is
// still there" rather than anything a dying process has to say.
//
// It is written under a .partial name and renamed into place, so a driver
// killed midway through the walk leaves no half-written snapshot that
// something later would act on: restoring from a truncated one would read
// the untracked paths it never got to as paths the run added, and delete
// the operator's work. A record holding only a partial is kept, not cleared
// — it is either a run under way right now or one that died before it wrote
// anything to the repo — but it is never offered as something to put a repo
// back with.
//
// WHERE IT LIVES. Under the instance root, beside .archimedes-notify.json
// and ignored for the same reasons: it is per-machine, it is disposable,
// and an instance's git history is for what the operator keeps, not for
// what one machine was doing at 3am. template/.gitignore carries both.
//
// WHAT CLEANS UP. A run that ends with archimedes still alive closes its
// own record. What is left over is what outlived an archimedes too, and
// Outstanding both reports those and clears away the ones with nothing in
// them to act on — a run whose driver did put the repo back under an
// archimedes that was killed before it could say so. Nothing else ever
// deletes one: acting on a record is the operator's, because acting means
// writing to a repository on the strength of something that may have
// happened days ago.
package runrecord

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/blockadence/gh-archimedes/internal/invocation"
)

// DirName is the directory an instance keeps records in, relative to its
// root. Exported because template/.gitignore has to name it too, and a
// second spelling of it is the one that would drift.
const DirName = ".archimedes-runs"

// What a record directory holds. SnapshotName is half of a contract with
// bash — drivers/lib/repo-snapshot.sh writes the snapshot at the path
// archimedes hands it, via the partial name below — so the two spellings
// are stated here and cited there rather than each being invented twice.
const (
	recordName   = "run.yaml"
	SnapshotName = "snapshot"
	// PartialSuffix is what a driver appends while it is still writing
	// one. The rename into place is what makes "there is a snapshot" mean
	// "there is a whole snapshot".
	PartialSuffix = ".partial"
)

// SnapshotEnvVar is how the path reaches the driver. A driver that does not
// read it is not broken — it takes no snapshot, or keeps its own in a temp
// file as before — and gets no backstop, which is the state every driver
// was in before this existed.
const SnapshotEnvVar = "ARCHIMEDES_RUN_SNAPSHOT"

// Dir is an instance's records directory.
type Dir string

// For is where the instance at root keeps them. Said once, so the run that
// opens a record and the command that reads one back cannot come to
// different conclusions about where records are.
func For(root string) Dir {
	return Dir(filepath.Join(root, DirName))
}

// Record is one run's note. The exported fields are what run.yaml carries;
// where the record sits is not among them, because a record moved somewhere
// else is not the same record.
type Record struct {
	// Driver is the driver that was running, which is also whose rollback
	// puts the repo back — see internal/driver's PutBack.
	Driver string `yaml:"driver"`
	// Repo is the absolute path of the repository the run was working in.
	Repo string `yaml:"repo"`
	// Started is when archimedes opened the record, which is just before
	// the driver was started. It is the only thing an operator has to
	// judge staleness by, and staleness is the whole question when
	// deciding whether to act on one.
	Started time.Time `yaml:"started"`
	// Pid is the archimedes that opened it, and RunStillAlive is what
	// reads it: on disk a record whose run is still under way looks
	// exactly like one whose run died, and everything that acts on a
	// record has to tell those apart before it does.
	Pid int `yaml:"archimedes_pid"`

	// Err is why this record could not be read, on a record Outstanding
	// found and could not parse. Carried on the entry rather than failing
	// the listing, the way internal/driver carries a broken manifest: the
	// listing is what an operator reaches for when something is wrong,
	// and one unreadable record must not cost them the report on the
	// others.
	Err error `yaml:"-"`

	dir string
}

// Open writes the record for a run about to start against repoPath, and
// returns it with the snapshot path the driver is to be handed.
//
// Everything it writes is on disk before it returns, because the one thing
// this has to survive is the death of the process calling it.
func (d Dir) Open(driverName, repoPath string) (*Record, error) {
	if err := os.MkdirAll(string(d), 0o755); err != nil {
		return nil, fmt.Errorf("making %s: %w", d, err)
	}
	// Named after the driver so a directory listing means something, and
	// made unique by the same call that creates it: two runs at once must
	// not share a record, and asking whether a name is free before taking
	// it is the version of this that races.
	dir, err := os.MkdirTemp(string(d), driverName+"-")
	if err != nil {
		return nil, fmt.Errorf("making a run record under %s: %w", d, err)
	}

	rec := &Record{
		Driver:  driverName,
		Repo:    repoPath,
		Started: time.Now().UTC(),
		Pid:     os.Getpid(),
		dir:     dir,
	}
	body, err := yaml.Marshal(rec)
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	// A header, because the first reader of one of these is an operator
	// who found a directory they did not create and wants to know whether
	// it is safe to delete.
	body = append([]byte(header), body...)
	if err := os.WriteFile(filepath.Join(dir, recordName), body, 0o644); err != nil {
		_ = os.RemoveAll(dir)
		return nil, fmt.Errorf("writing the run record: %w", err)
	}
	return rec, nil
}

const header = `# A run archimedes had under way in the repo named below. While the run is
# going this is how it is found again; afterwards it is here only if the
# driver did not get to put that repo back.
#
# The snapshot beside this file is what would put it back. Archimedes
# removes the pair when the repo is clean; nothing else ever writes here.
`

// Where is the record's own directory — what an operator is pointed at when
// nothing could be done automatically.
func (r *Record) Where() string { return r.dir }

// ID is what an operator names this record by. It is the directory's name,
// so the id and the thing it names cannot drift apart.
func (r *Record) ID() string { return filepath.Base(r.dir) }

// SnapshotPath is where the driver is asked to leave its snapshot, and
// where anything putting the repo back afterwards reads it from.
func (r *Record) SnapshotPath() string { return filepath.Join(r.dir, SnapshotName) }

// RunStillAlive reports whether the archimedes that opened this record is
// still running — which is as good as saying the run itself is, since that
// process does not outlive the driver it waits on.
//
// It is asked before anything acts on a record, because a run under way
// looks exactly like one that died: the snapshot is there, and it is there
// for the whole run. Restoring from it would delete what a live session is
// still writing, which is the harm this whole arrangement exists to
// prevent, and clearing the record away would take the backstop out from
// under a run that still needs it.
//
// A pid is not a perfect identity — a record can outlive a reboot and the
// number belong to something else by then, which reads as a run that never
// ends. That is why this refuses rather than decides: what it gates is
// acting unprompted, and an operator who can see it is nobody's run says so
// (`restore --force`, `forget`).
func (r *Record) RunStillAlive() bool {
	return processAlive(r.Pid)
}

// Restorable reports whether a finished snapshot is there — the only state
// in which the repo can be put back from outside the driver.
func (r *Record) Restorable() bool {
	info, err := os.Stat(r.SnapshotPath())
	return err == nil && !info.IsDir()
}

// SnapshotUnfinished reports a record holding only a half-written snapshot:
// a run under way right now, or one that died during the walk — which, by
// the ordering every driver that snapshots keeps to, is before it had
// written anything to the repo.
func (r *Record) SnapshotUnfinished() bool {
	_, err := os.Stat(r.SnapshotPath() + PartialSuffix)
	return err == nil
}

// Pointer is the sentence that turns a record nothing could act on into
// something the operator can: where it is, and what to type about it.
//
// Here rather than at the places that print it, because only this package
// knows both halves — where a record lives, and that a record is a thing
// `unfinished-runs` reads. What it does not know is what this program is
// called where an operator types it, which depends on which of the two
// installs they have, so that comes from internal/invocation the way
// internal/notify's does.
func (r *Record) Pointer() string {
	return fmt.Sprintf("the record is kept at %s — `%s unfinished-runs` says what the run left in there, and `%s unfinished-runs restore %s` tries again",
		r.dir, invocation.Name(), invocation.Name(), r.ID())
}

// Close removes the record, which is what a run does when the repo it was
// working in is known to be clean.
//
// The records directory around it stays once it has been made, empty or
// not. Removing it here would race the next run, which creates that
// directory and then a record inside it in two steps — and an instance
// holding one empty, ignored directory is a smaller thing than a run that
// intermittently ends up with no record because another one tidied up
// underneath it.
func (r *Record) Close() error {
	return os.RemoveAll(r.dir)
}

// Outstanding reports the records worth an operator's attention, oldest
// first, and clears away the ones with nothing left in them to act on.
//
// A query that also tidies, which is deliberate rather than overlooked: a
// record holding nothing is not outstanding, and removing it is how that is
// made true on disk rather than only in the answer. Nothing else would ever
// do it — such a record is one whose driver did put the repo back under an
// archimedes that was killed before it could close it, and that run is not
// coming back to tidy up. Left there it would be reported before every
// mapping pass forever, about a repo that is fine.
//
// Three states are never cleared, and each is a thing owed to somebody:
//
//   - a record this cannot read, which is a directory an operator can read
//     themselves once they are told where it is;
//   - a record holding a snapshot, where deciding what to do about the repo
//     is theirs;
//   - a record whose run is still alive, which is not a leftover at all.
//     It is reported as what it is rather than hidden, because it is on
//     disk and an operator who finds it deserves to be told which of the
//     two it is — but nothing here touches it, including the one narrow
//     window where it holds nothing yet: between a record being opened and
//     the driver renaming its snapshot into place, a second archimedes
//     doing the tidying would take the record out from under a live run.
func (d Dir) Outstanding() ([]*Record, error) {
	entries, err := os.ReadDir(string(d))
	if errors.Is(err, os.ErrNotExist) {
		// Every instance until its first run, and every machine that has
		// never lost one.
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", d, err)
	}

	var left []*Record
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		rec := read(filepath.Join(string(d), e.Name()))
		if rec.Err == nil && !rec.Restorable() && !rec.SnapshotUnfinished() && !rec.RunStillAlive() {
			_ = os.RemoveAll(rec.dir)
			continue
		}
		left = append(left, rec)
	}
	slices.SortFunc(left, func(a, b *Record) int { return a.Started.Compare(b.Started) })
	return left, nil
}

// Find answers the one record named id, for a command acting on a single
// one.
//
// The id arrives off a command line and is joined onto a path, so it is
// checked for being a record's name rather than a route somewhere else: a
// record is one directory directly under this one, and anything else is
// refused rather than resolved.
func (d Dir) Find(id string) (*Record, error) {
	// Both separators, because on the platform where they differ, both
	// separate: a Windows path takes either, so testing only
	// filepath.Separator there would let "../elsewhere" through.
	if id == "" || id == "." || id == ".." || strings.ContainsRune(id, filepath.Separator) || strings.Contains(id, "/") {
		return nil, fmt.Errorf("%q is not a run record id — ids are the directory names under %s", id, d)
	}
	dir := filepath.Join(string(d), id)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("no run record %q under %s", id, d)
	}
	rec := read(dir)
	if rec.Err != nil {
		return nil, rec.Err
	}
	return rec, nil
}

// read loads one record directory, reporting a failure on the record rather
// than instead of it: the directory is the fact, and what run.yaml says
// about it is detail an operator can do without when the alternative is
// hearing nothing.
func read(dir string) *Record {
	rec := &Record{dir: dir}
	body, err := os.ReadFile(filepath.Join(dir, recordName))
	if err != nil {
		rec.Err = fmt.Errorf("reading the run record at %s: %w", dir, err)
		return rec
	}
	if err := yaml.Unmarshal(body, rec); err != nil {
		rec.Err = fmt.Errorf("parsing the run record at %s: %w", dir, err)
	}
	// Unmarshal writes into rec, and dir is not its to set.
	rec.dir = dir
	return rec
}
