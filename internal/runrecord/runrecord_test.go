package runrecord_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// opened is a record for a run about to start, with the directory it landed
// in. Every case below needs both, and a helper that fails the test on the
// spot keeps each one about what it is checking.
func opened(t *testing.T, dir runrecord.Dir, driver, repo string) *runrecord.Record {
	t.Helper()
	rec, err := dir.Open(driver, repo)
	if err != nil {
		t.Fatalf("Open(%s, %s): %v", driver, repo, err)
	}
	return rec
}

// deadPid is a pid that answers nothing: a process started, waited for and
// reaped, so the number is a real one that was really used and really is
// not any more. Invented numbers are no good here — a high one may be
// nobody's today and somebody's on the machine that runs this next.
func deadPid(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("sh", "-c", "exit 0")
	if err := cmd.Run(); err != nil {
		t.Fatalf("starting a process to reap: %v", err)
	}
	return cmd.ProcessState.Pid()
}

// died rewrites rec's note as the archimedes that opened it having since
// gone, which is the state every case below but one is about. Open writes
// this process's own pid, and this process is very much alive: without
// this, every record a test makes reads as a run still under way and
// nothing is ever reported or cleared.
//
// The rewrite goes through Open's own output rather than hand-writing a
// note, so the format still has exactly one writer.
func died(t *testing.T, rec *runrecord.Record) {
	t.Helper()
	note := filepath.Join(rec.Where(), "run.yaml")
	body, err := os.ReadFile(note)
	if err != nil {
		t.Fatal(err)
	}
	was := fmt.Sprintf("archimedes_pid: %d", os.Getpid())
	now := fmt.Sprintf("archimedes_pid: %d", deadPid(t))
	rewritten := strings.Replace(string(body), was, now, 1)
	if rewritten == string(body) {
		t.Fatalf("the note does not carry this process's pid to replace:\n%s", body)
	}
	if err := os.WriteFile(note, []byte(rewritten), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeSnapshot stands in for the driver writing its snapshot where it was
// told to. What it writes does not matter to this package: what the record
// holds is a file, and what is in it is drivers/lib/repo-snapshot.sh's.
func writeSnapshot(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("H\tabc123\x00"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestARecordIsOnDiskBeforeTheRunStarts(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	rec := opened(t, dir, "pocock", "/somewhere/a-repo")

	// The whole point of the record: it is a file, not something held in
	// the memory of a process that can be killed as easily as the driver.
	body, err := os.ReadFile(filepath.Join(rec.Where(), "run.yaml"))
	if err != nil {
		t.Fatalf("reading the record back: %v", err)
	}
	for _, want := range []string{"pocock", "/somewhere/a-repo"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("the record does not name %q:\n%s", want, body)
		}
	}
	if _, err := os.Stat(rec.SnapshotPath()); err == nil {
		t.Error("the snapshot path exists already; it is the driver's to write, not ours")
	}
	if filepath.Dir(rec.SnapshotPath()) != rec.Where() {
		t.Errorf("the snapshot is asked for at %s, outside the record at %s", rec.SnapshotPath(), rec.Where())
	}
}

func TestTwoRunsAtOnceKeepSeparateRecords(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	first := opened(t, dir, "pocock", "/somewhere/one")
	second := opened(t, dir, "pocock", "/somewhere/two")

	if first.Where() == second.Where() {
		t.Fatalf("both runs were given the same record at %s", first.Where())
	}
	if first.ID() == second.ID() {
		t.Errorf("both runs were given the same id %q", first.ID())
	}
}

func TestClosingARecordLeavesNothingBehind(t *testing.T) {
	root := t.TempDir()
	dir := runrecord.For(root)

	rec := opened(t, dir, "pocock", "/somewhere/a-repo")
	writeSnapshot(t, rec.SnapshotPath())
	died(t, rec)
	if err := rec.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	if _, err := os.Stat(rec.Where()); err == nil {
		t.Errorf("%s is still there after the run that owned it ended", rec.Where())
	}
	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 0 {
		t.Errorf("Outstanding reports %d records after the only run closed its own", len(left))
	}
}

func TestOutstandingReportsARunThatLeftItsSnapshot(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	rec := opened(t, dir, "spec-kit", "/somewhere/a-repo")
	writeSnapshot(t, rec.SnapshotPath())
	died(t, rec)

	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 1 {
		t.Fatalf("Outstanding reports %d records, want the one the killed run left", len(left))
	}
	got := left[0]
	if got.Repo != "/somewhere/a-repo" || got.Driver != "spec-kit" {
		t.Errorf("the record reports driver %q in %q, want spec-kit in /somewhere/a-repo", got.Driver, got.Repo)
	}
	if !got.Restorable() {
		t.Error("a record holding a finished snapshot reports nothing to put the repo back with")
	}
	if got.ID() != rec.ID() {
		t.Errorf("read back as %q, written as %q", got.ID(), rec.ID())
	}
	if got.Started.IsZero() {
		t.Error("the record carries no start time, so nobody can tell a run from a moment ago from one from last week")
	}
}

func TestOutstandingClearsAwayARunThatPutTheRepoBack(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	// A driver that rolled back and removed the snapshot, under an
	// archimedes that was killed before it could close the record. The
	// repo is fine; the record is litter, and cleaning it up is what
	// keeps a notice about it from crying wolf forever.
	rec := opened(t, dir, "pocock", "/somewhere/a-repo")
	died(t, rec)

	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 0 {
		t.Fatalf("Outstanding reports %d records, want none: the driver put the repo back", len(left))
	}
	if _, err := os.Stat(rec.Where()); err == nil {
		t.Errorf("%s is still there, and nothing else will ever clear it away", rec.Where())
	}
}

func TestOutstandingKeepsARunStillTakingItsSnapshot(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	rec := opened(t, dir, "pocock", "/somewhere/a-repo")
	writeSnapshot(t, rec.SnapshotPath()+".partial")
	died(t, rec)

	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 1 {
		t.Fatalf("Outstanding reports %d records, want the half-taken one kept", len(left))
	}
	if left[0].Restorable() {
		t.Error("a half-written snapshot is offered as something to put a repo back with")
	}
}

func TestOutstandingSurvivesARecordItCannotRead(t *testing.T) {
	root := t.TempDir()
	dir := runrecord.For(root)

	good := opened(t, dir, "pocock", "/somewhere/a-repo")
	writeSnapshot(t, good.SnapshotPath())
	died(t, good)

	broken := filepath.Join(string(dir), "broken-1")
	if err := os.MkdirAll(broken, 0o755); err != nil {
		t.Fatal(err)
	}
	writeSnapshot(t, filepath.Join(broken, "snapshot"))
	if err := os.WriteFile(filepath.Join(broken, "run.yaml"), []byte("\tnot: [yaml"), 0o644); err != nil {
		t.Fatal(err)
	}

	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 2 {
		t.Fatalf("Outstanding reports %d records, want both: one unreadable record must not cost the operator the other", len(left))
	}
	var reported *runrecord.Record
	for _, r := range left {
		if r.ID() == "broken-1" {
			reported = r
		}
	}
	if reported == nil {
		t.Fatal("the unreadable record is not reported at all")
	}
	if reported.Err == nil {
		t.Error("the unreadable record is reported as if it were fine")
	}
}

func TestNoRecordsDirectoryIsNoRecords(t *testing.T) {
	// Every instance is in this state until the first run, and a machine
	// that has never lost one stays in it forever.
	left, err := runrecord.For(t.TempDir()).Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 0 {
		t.Errorf("Outstanding reports %d records where nothing has ever run", len(left))
	}
}

func TestFindAnswersOneRecordByID(t *testing.T) {
	dir := runrecord.For(t.TempDir())
	rec := opened(t, dir, "pocock", "/somewhere/a-repo")
	writeSnapshot(t, rec.SnapshotPath())

	got, err := dir.Find(rec.ID())
	if err != nil {
		t.Fatalf("Find(%s): %v", rec.ID(), err)
	}
	if got.Repo != "/somewhere/a-repo" {
		t.Errorf("Find answered a record for %q", got.Repo)
	}

	if _, err := dir.Find("no-such-record"); err == nil {
		t.Error("Find answered a record for an id nothing left")
	}
}

func TestFindRefusesToLeaveTheRecordsDirectory(t *testing.T) {
	// The id comes off a command line, and it is joined onto a path. A
	// record is one directory under .archimedes-runs/ and nothing else,
	// so "../../../etc" is not a record that cannot be found — it is a
	// question this package will not answer at all.
	dir := runrecord.For(t.TempDir())
	for _, id := range []string{"../elsewhere", "nested/deeper", "/absolute", "."} {
		if _, err := dir.Find(id); err == nil {
			t.Errorf("Find(%q) answered rather than refusing", id)
		}
	}
}

func TestARunStillUnderWayIsReportedAsThatRatherThanClearedAway(t *testing.T) {
	dir := runrecord.For(t.TempDir())

	// Opened by this process, which is still running: the shape a second
	// archimedes sees while a mapping pass is going on next to it.
	rec := opened(t, dir, "pocock", "/somewhere/a-repo")

	left, err := dir.Outstanding()
	if err != nil {
		t.Fatalf("Outstanding: %v", err)
	}
	if len(left) != 1 {
		t.Fatalf("Outstanding reports %d records, want the live one kept: clearing it takes the backstop out from under a run that still needs it", len(left))
	}
	if !left[0].RunStillAlive() {
		t.Error("a record opened by this very process does not read as a run still under way")
	}
	if _, err := os.Stat(rec.Where()); err != nil {
		t.Errorf("the live run's record was cleared away: %v", err)
	}
}

func TestARecordOutlivingItsRunReadsAsOneNobodyIsRunning(t *testing.T) {
	dir := runrecord.For(t.TempDir())
	rec := opened(t, dir, "pocock", "/somewhere/a-repo")
	writeSnapshot(t, rec.SnapshotPath())
	died(t, rec)

	found, err := dir.Find(rec.ID())
	if err != nil {
		t.Fatal(err)
	}
	if found.RunStillAlive() {
		t.Error("a record whose archimedes is gone still reads as a run under way, so nothing will ever act on it")
	}
}
