package driver_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/driver"
	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// backstopped is a Set whose drivers are written per case, keeping records
// under an instance root of its own: what these cases are about is what
// archimedes does with the snapshot a run leaves behind, so each one needs
// its own driver and its own records to read back.
type backstopped struct {
	drivers driver.Set
	dir     string
	root    string
	ran     string // the marker the stub backstop touches when it is asked to restore
}

func withBackstop(t *testing.T) *backstopped {
	t.Helper()
	b := &backstopped{dir: t.TempDir(), root: t.TempDir()}
	b.ran = filepath.Join(t.TempDir(), "backstop-ran")
	b.drivers = driver.SetFor(b.root, b.dir, nil)
	return b
}

// writeBackstop stands in for drivers/lib/backstop.sh, which is where a
// driver's own rollback is re-run from outside its process. What the real
// one does is repo-snapshot.sh's and is covered in bash (tests/
// dead_run_record.sh); what these cases need from it is only whether
// archimedes ran it, over which repo, and what it does with the answer.
func (b *backstopped) writeBackstop(t *testing.T, body string) {
	t.Helper()
	dir := filepath.Join(b.dir, "lib")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "backstop.sh"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// records is what is left under the instance root once a run has ended.
func (b *backstopped) records(t *testing.T) []*runrecord.Record {
	t.Helper()
	left, err := runrecord.For(b.root).Outstanding()
	if err != nil {
		t.Fatalf("reading the records back: %v", err)
	}
	return left
}

// progress collects what a run says on its way, which for these cases is
// the operator's whole account of what happened to their repo.
type progress struct{ strings.Builder }

func (b *backstopped) run(t *testing.T, name, repo string) (string, error) {
	t.Helper()
	var said progress
	err := b.drivers.Run(name, repo, filepath.Join(t.TempDir(), "out.md"), &said)
	return said.String(), err
}

// scaffoldsThenDies is a fixed-location driver that writes a snapshot where
// it was told, scaffolds, and exits without removing it — the shape of
// every run this whole arrangement is for: the repo is left as the session
// left it and the driver is in no position to say so.
const scaffoldsThenDies = `#!/usr/bin/env bash
set -uo pipefail
printf 'a snapshot\n' > "$ARCHIMEDES_RUN_SNAPSHOT"
mkdir -p "$1/.scaffolded"
exit 1
`

func TestTheDriverIsToldWhereToLeaveItsSnapshot(t *testing.T) {
	b := withBackstop(t)
	writeDriver(t, b.dir, "stub-tells", "name: stub-tells\noutput_mode: path-parameterized\ncommand: run.sh\n",
		"#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"${ARCHIMEDES_RUN_SNAPSHOT:-unset}\" > \"$2\"\n")
	repo, out := repoDir(t), filepath.Join(t.TempDir(), "out.md")

	if err := b.drivers.Run("stub-tells", repo, out, &progress{}); err != nil {
		t.Fatalf("Run: %v", err)
	}

	told := strings.TrimSpace(readFile(t, out))
	if !strings.HasPrefix(told, filepath.Join(b.root, runrecord.DirName)) {
		t.Errorf("the driver was told to snapshot at %s, which is not under this instance's records", told)
	}
	if filepath.Base(told) != runrecord.SnapshotName {
		t.Errorf("the driver was told to snapshot at %s, not at the name anything reading one back looks for", told)
	}
}

func TestARunThatEndedWellLeavesNoRecord(t *testing.T) {
	b := withBackstop(t)
	writeDriver(t, b.dir, "stub-ok", "name: stub-ok\noutput_mode: path-parameterized\ncommand: run.sh\n",
		"#!/usr/bin/env bash\nset -euo pipefail\necho map > \"$2\"\n")

	if _, err := b.run(t, "stub-ok", repoDir(t)); err != nil {
		t.Fatalf("Run: %v", err)
	}

	if left := b.records(t); len(left) != 0 {
		t.Errorf("a run that ended well left %d records behind", len(left))
	}
}

func TestASnapshotLeftByAFailedRunIsActedOnFromOutside(t *testing.T) {
	b := withBackstop(t)
	writeDriver(t, b.dir, "stub-dies", "name: stub-dies\noutput_mode: fixed-location\nfixed_path: OUT.md\ncommand: run.sh\n", scaffoldsThenDies)
	b.writeBackstop(t, "#!/usr/bin/env bash\nprintf '%s\\n' \"$1 $2 $3\" > \""+b.ran+"\"\nrmdir \"$2/.scaffolded\"\n")
	repo := repoDir(t)

	said, err := b.run(t, "stub-dies", repo)
	if err == nil {
		t.Fatal("a driver that exited 1 is reported as a run that worked")
	}

	asked := strings.TrimSpace(readFile(t, b.ran))
	if !strings.HasPrefix(asked, "restore "+repo+" ") {
		t.Errorf("the rollback was asked for as %q, not a restore of the repo the run was in", asked)
	}
	if _, err := os.Stat(filepath.Join(repo, ".scaffolded")); err == nil {
		t.Error("what the dead run left in the repo is still there")
	}
	if !strings.Contains(said, repo) {
		t.Errorf("the operator is not told which repo was put back:\n%s", said)
	}
	if left := b.records(t); len(left) != 0 {
		t.Errorf("the record is still there after the repo was put back: %d left", len(left))
	}
}

func TestARepoThatCouldNotBePutBackKeepsItsRecord(t *testing.T) {
	b := withBackstop(t)
	writeDriver(t, b.dir, "stub-dies", "name: stub-dies\noutput_mode: fixed-location\nfixed_path: OUT.md\ncommand: run.sh\n", scaffoldsThenDies)
	// The shape repo-snapshot.sh refuses in: HEAD moved, so what the run
	// added can no longer be told from what was committed.
	b.writeBackstop(t, "#!/usr/bin/env bash\necho 'refusing to touch it: HEAD moved' >&2\nexit 1\n")
	repo := repoDir(t)

	said, _ := b.run(t, "stub-dies", repo)

	left := b.records(t)
	if len(left) != 1 {
		t.Fatalf("%d records left, want the one nothing could be done about", len(left))
	}
	if left[0].Repo != repo {
		t.Errorf("the record names %q, not the repo the run was left in", left[0].Repo)
	}
	if !left[0].Restorable() {
		t.Error("the record was kept without the snapshot that is the only thing that could put the repo back")
	}
	for _, want := range []string{repo, "HEAD moved", left[0].ID()} {
		if !strings.Contains(said, want) {
			t.Errorf("the operator is not told %q:\n%s", want, said)
		}
	}
}

func TestADriverThatPutTheRepoBackItselfIsNotSecondGuessed(t *testing.T) {
	b := withBackstop(t)
	// The ordinary failure path: the driver's own trap ran, rolled the
	// repo back, and released the snapshot to say so. Anything out here
	// running a second rollback over the top of that is a backstop that
	// has stopped being one.
	writeDriver(t, b.dir, "stub-tidy", "name: stub-tidy\noutput_mode: fixed-location\nfixed_path: OUT.md\ncommand: run.sh\n",
		"#!/usr/bin/env bash\nset -uo pipefail\nprintf 'a snapshot\\n' > \"$ARCHIMEDES_RUN_SNAPSHOT\"\nrm -f \"$ARCHIMEDES_RUN_SNAPSHOT\"\nexit 1\n")
	b.writeBackstop(t, "#!/usr/bin/env bash\ntouch \""+b.ran+"\"\n")

	if _, err := b.run(t, "stub-tidy", repoDir(t)); err == nil {
		t.Fatal("a driver that exited 1 is reported as a run that worked")
	}

	if _, err := os.Stat(b.ran); err == nil {
		t.Error("archimedes ran its own rollback over the top of the driver's")
	}
	if left := b.records(t); len(left) != 0 {
		t.Errorf("%d records left behind by a run that put its own repo back", len(left))
	}
}

func TestASetKeepingNoRecordsRunsAsItAlwaysDid(t *testing.T) {
	// A Set built by hand — every caller in this package's own tests, and
	// anything else that has no instance to keep records under. The
	// backstop is what it loses; the run is not.
	dir := t.TempDir()
	writeDriver(t, dir, "stub-tells", "name: stub-tells\noutput_mode: path-parameterized\ncommand: run.sh\n",
		"#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"${ARCHIMEDES_RUN_SNAPSHOT:-unset}\" > \"$2\"\n")
	out := filepath.Join(t.TempDir(), "out.md")

	if err := (driver.Set{Dir: dir}).Run("stub-tells", repoDir(t), out, &progress{}); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := strings.TrimSpace(readFile(t, out)); got != "unset" {
		t.Errorf("the driver was told to snapshot at %q by a Set that keeps no records", got)
	}
}
