package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// These drive the command an operator reaches for after a run died with
// their repository still full of what it left there. The drivers here are
// stubs with a lib/ of their own, because what the command is answering for
// is what it says and what it clears away — what a rollback does to a repo
// is drivers/lib/repo-snapshot.sh's, tested in bash.

// leftARun puts a record under root as a killed run would have left one:
// the note, the snapshot the driver never got to release, and — the part
// that takes arranging — a pid nobody is using.
//
// Open records the pid of whatever opened it, which here is the test
// process, and a record whose run is still alive is reported as a run still
// under way and never acted on. So the note is rewritten with the pid of a
// process that has been started and reaped, which is what an archimedes
// that died looks like from out here. internal/runrecord's own tests do the
// same thing for the same reason.
func leftARun(t *testing.T, root, driverName, repo string) *runrecord.Record {
	t.Helper()
	rec, err := runrecord.For(root).Open(driverName, repo)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rec.SnapshotPath(), []byte("H\tabc\x00"), 0o644); err != nil {
		t.Fatal(err)
	}
	note := filepath.Join(rec.Where(), "run.yaml")
	body := string(readFile(t, note))
	rewritten := strings.Replace(body,
		fmt.Sprintf("archimedes_pid: %d", os.Getpid()),
		fmt.Sprintf("archimedes_pid: %d", reapedPid(t)), 1)
	if rewritten == body {
		t.Fatalf("the note does not carry this process's pid to replace:\n%s", body)
	}
	writeFile(t, note, rewritten)
	return rec
}

// reapedPid is a pid that answers nothing, because the process that had it
// has exited and been waited for.
func reapedPid(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("sh", "-c", "exit 0")
	if err := cmd.Run(); err != nil {
		t.Fatalf("starting a process to reap: %v", err)
	}
	return cmd.ProcessState.Pid()
}

// stubDriverWithLib installs a driver under root's own drivers/ plus the
// lib/backstop.sh archimedes runs to put a repo back, whose body the case
// supplies: these tests are about what the command does with the answer.
func stubDriverWithLib(t *testing.T, root, name, backstop string) {
	t.Helper()
	writeFile(t, filepath.Join(root, "drivers", name, "driver.yaml"),
		"name: "+name+"\ndescription: a stub\noutput_mode: fixed-location\nfixed_path: OUT.md\ncommand: run.sh\n")
	writeExecutable(t, filepath.Join(root, "drivers", name, "run.sh"), "#!/usr/bin/env bash\nexit 0\n")
	writeFile(t, filepath.Join(root, "drivers", "lib", "backstop.sh"), backstop)
}

func TestUnfinishedRunsSaysSoWhenThereAreNone(t *testing.T) {
	out := execute(t, "unfinished-runs", "--root", t.TempDir())

	if !strings.Contains(out, "No ") {
		t.Errorf("an instance that has lost nothing is not told so plainly:\n%s", out)
	}
}

func TestUnfinishedRunsNamesTheRepoAndWhatIsInIt(t *testing.T) {
	root := t.TempDir()
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\nprintf '.stub/scaffolding\\nNOTES.md\\n'\n")
	rec := leftARun(t, root, "stub", "/somewhere/a-repo")

	out := execute(t, "unfinished-runs", "--root", root)

	for _, want := range []string{rec.ID(), "/somewhere/a-repo", "stub", ".stub/scaffolding", "NOTES.md"} {
		if !strings.Contains(out, want) {
			t.Errorf("the report does not name %q:\n%s", want, out)
		}
	}
}

func TestUnfinishedRunsStillReportsARepoItCannotReadTheLeftoversOf(t *testing.T) {
	root := t.TempDir()
	// The shape repo-snapshot.sh refuses in, and the one an operator most
	// needs to hear about: the repo has moved on since the run, so what it
	// left there can no longer be worked out. A report that fell silent
	// here would be silent about the worst case it has.
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\necho 'refusing to touch it: HEAD moved' >&2\nexit 1\n")
	leftARun(t, root, "stub", "/somewhere/a-repo")

	out := execute(t, "unfinished-runs", "--root", root)

	if !strings.Contains(out, "/somewhere/a-repo") {
		t.Errorf("the report does not name the repo it could not read:\n%s", out)
	}
	if !strings.Contains(out, "could not work out") {
		t.Errorf("the report does not say that what the run left could not be worked out:\n%s", out)
	}
}

func TestUnfinishedRunsRestorePutsTheRepoBackAndClearsTheRecord(t *testing.T) {
	root := t.TempDir()
	ran := filepath.Join(t.TempDir(), "asked")
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\nprintf '%s %s\\n' \"$1\" \"$2\" > \""+ran+"\"\n")
	rec := leftARun(t, root, "stub", "/somewhere/a-repo")

	out := execute(t, "unfinished-runs", "restore", "--root", root, rec.ID())

	asked := strings.TrimSpace(string(readFile(t, ran)))
	if asked != "restore /somewhere/a-repo" {
		t.Errorf("the rollback was asked for as %q", asked)
	}
	if !strings.Contains(out, "/somewhere/a-repo") {
		t.Errorf("the operator is not told which repo was put back:\n%s", out)
	}
	if _, err := os.Stat(rec.Where()); err == nil {
		t.Error("the record is still there after the repo was put back")
	}
}

func TestUnfinishedRunsRestoreKeepsTheRecordWhenItCouldNotBeDone(t *testing.T) {
	root := t.TempDir()
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\necho 'refusing to touch it: HEAD moved' >&2\nexit 1\n")
	rec := leftARun(t, root, "stub", "/somewhere/a-repo")

	err := executeErr(t, "unfinished-runs", "restore", "--root", root, rec.ID())

	if !strings.Contains(err.Error(), "/somewhere/a-repo") {
		t.Errorf("the refusal does not name the repo: %v", err)
	}
	if _, statErr := os.Stat(rec.SnapshotPath()); statErr != nil {
		t.Error("the snapshot was cleared away by a restore that did not happen")
	}
}

func TestUnfinishedRunsForgetDropsARecordWithoutTouchingTheRepo(t *testing.T) {
	root := t.TempDir()
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\necho 'should not have been asked' >&2\nexit 1\n")
	rec := leftARun(t, root, "stub", "/somewhere/a-repo")

	out := execute(t, "unfinished-runs", "forget", "--root", root, rec.ID())

	if _, err := os.Stat(rec.Where()); err == nil {
		t.Error("the record is still there after being forgotten")
	}
	if !strings.Contains(out, "/somewhere/a-repo") {
		t.Errorf("forgetting a record does not say which repo is being left as it is:\n%s", out)
	}
}

func TestUnfinishedRunsRefusesAnIdNothingLeft(t *testing.T) {
	err := executeErr(t, "unfinished-runs", "restore", "--root", t.TempDir(), "no-such-run")

	if !strings.Contains(err.Error(), "no-such-run") {
		t.Errorf("the error does not name the id: %v", err)
	}
}

func TestUnfinishedRunsWillNotActOnARunThatIsStillGoing(t *testing.T) {
	root := t.TempDir()
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\ntouch "+filepath.Join(t.TempDir(), "asked")+"\n")
	// Opened and left alone, so the pid in it is this process's: from any
	// other archimedes, that is exactly what a pass running in the next
	// terminal looks like. Restoring it would delete what that run is
	// still writing, which is the harm the record exists to prevent.
	rec, err := runrecord.For(root).Open("stub", "/somewhere/a-repo")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rec.SnapshotPath(), []byte("H\tabc\x00"), 0o644); err != nil {
		t.Fatal(err)
	}

	out := execute(t, "unfinished-runs", "--root", root)
	if !strings.Contains(out, "still going") {
		t.Errorf("the listing does not say the run is still under way:\n%s", out)
	}

	err = executeErr(t, "unfinished-runs", "restore", "--root", root, rec.ID())
	if !strings.Contains(err.Error(), "still looks like it is running") {
		t.Errorf("restore does not refuse a run that is still going: %v", err)
	}
	if !strings.Contains(err.Error(), "--force") {
		t.Errorf("the refusal does not say how to act on it anyway, which is what an operator whose machine rebooted needs: %v", err)
	}
	if _, statErr := os.Stat(rec.Where()); statErr != nil {
		t.Error("the live run's record was cleared away by a listing")
	}
}

func TestUnfinishedRunsForcedPastARunThatLooksAlive(t *testing.T) {
	root := t.TempDir()
	ran := filepath.Join(t.TempDir(), "asked")
	stubDriverWithLib(t, root, "stub", "#!/usr/bin/env bash\ntouch \""+ran+"\"\n")
	rec, err := runrecord.For(root).Open("stub", "/somewhere/a-repo")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rec.SnapshotPath(), []byte("H\tabc\x00"), 0o644); err != nil {
		t.Fatal(err)
	}

	execute(t, "unfinished-runs", "restore", "--root", root, "--force", rec.ID())

	if _, statErr := os.Stat(ran); statErr != nil {
		t.Error("--force did not get past the liveness check, so a record left by a reboot could never be acted on")
	}
}
