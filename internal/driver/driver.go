// Package driver invokes a context-mapping driver by name against a target
// repo, writing its output to an exact path. It is the only thing
// orchestration (see internal/contextmap) needs to know about drivers: no
// specific driver's invocation is hardcoded anywhere else, so swapping
// which driver is configured never touches orchestration.
//
// A driver is a directory holding a driver.yaml manifest and the executable
// it names. The manifest's output_mode picks which of two invocation
// contracts it honors — see template/drivers/README.md for the contract as
// drivers see it.
//
// Where that directory comes from is Set's question, and its answer is the
// ownership split: an instance's own drivers/ over the drivers this binary
// ships.
package driver

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// Output modes a driver can declare. Anything else is a misconfiguration.
const (
	// ModePathParameterized drivers accept an explicit output location and
	// write exactly there.
	ModePathParameterized = "path-parameterized"
	// ModeFixedLocation drivers can't be told where to write; they always
	// write to FixedPath relative to the repo they're run in, and we
	// harvest that file afterward.
	ModeFixedLocation = "fixed-location"
)

// manifestName is the file every driver directory must contain. It is what
// makes a directory a driver rather than something else somebody left under
// drivers/, so it answers "is this one?" as well as "where is its manifest?".
const manifestName = "driver.yaml"

// dirName is where an instance keeps its drivers, relative to its root.
const dirName = "drivers"

// libDirName is the directory beside the drivers — not inside any of them —
// holding the bash helpers a driver's command sources. It exists because
// more than one driver has to leave someone else's repository exactly as it
// found it, and a second copy of the code that does that is the one that
// drifts, on the failure path, where nobody is watching. A driver reaches
// it at ../lib/ relative to its own directory, which resolves the same way
// whether the driver is the instance's or was unpacked out of the binary.
//
// It declares no manifest, so it is not a driver and never reads as one.
const libDirName = "lib"

// errNoManifest is what loadManifest reports for a directory that declares
// no driver. Listing a Set walks drivers/ rather than being handed one
// name, and has to tell "not a driver" apart from "a driver that won't
// load"; running one wraps it into the error an operator sees for a name
// nothing supplies.
var errNoManifest = errors.New("unknown driver")

// ErrNotShipped is Adopt refusing a name this binary carries no driver for.
// Exported so the caller can add the pointer to what would have worked:
// only out there is it known that an operator types `archimedes drivers`
// under one install and `gh archimedes drivers` under the other, and this
// package has no business reading its environment to find out.
var ErrNotShipped = errors.New("does not ship with archimedes")

// Manifest is a driver's driver.yaml.
type Manifest struct {
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	OutputMode  string `yaml:"output_mode"`
	// FixedPath is where a fixed-location driver always writes, relative
	// to the repo it's run in. Unused by path-parameterized drivers.
	FixedPath string `yaml:"fixed_path"`
	// Command is the executable to run, relative to the driver directory.
	Command string `yaml:"command"`
}

// readManifest reads the manifest for the driver named name out of fsys, a
// drivers directory — a real one on disk, or the copy of one embedded in
// the binary. One reader serves both layers of a Set because a manifest
// that parsed in a listing and failed in a run, or the reverse, would be a
// disagreement about what a driver even is.
//
// where names the directory for the operator, since an fs.FS cannot say
// where it came from and "no manifest at driver.yaml" helps nobody.
//
// A driver with no manifest there is an unknown driver: naming one that
// doesn't exist is a misconfiguration that fails immediately, rather than
// silently falling back to some other way of mapping. A manifest that
// exists but can't be read is a different problem, and says so rather than
// blaming the name.
func readManifest(fsys fs.FS, where, name string) (Manifest, error) {
	data, err := fs.ReadFile(fsys, path.Join(name, manifestName))
	at := filepath.Join(where, name, manifestName)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Manifest{}, fmt.Errorf("%w: %s (no manifest at %s)", errNoManifest, name, at)
		}
		return Manifest{}, fmt.Errorf("reading %s: %w", at, err)
	}

	var m Manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return Manifest{}, fmt.Errorf("parsing %s: %w", at, err)
	}
	return m, nil
}

// commandPath is where the driver named name keeps the command its
// manifest declares. One place answers it because two callers act on the
// same file for different reasons — running it, and making it runnable
// after unpacking or adopting one — and they must never disagree about
// which file that is.
func commandPath(driversDir, name string, m Manifest) string {
	return filepath.Join(driversDir, name, filepath.FromSlash(m.Command))
}

// job is one driver run, as the thing invoking it needs to see it. A struct
// rather than a growing argument list: what a run takes is now five things,
// and the fifth — where the driver is asked to leave its snapshot — is the
// one a reader would otherwise have to count commas to identify.
type job struct {
	// bin is the driver's command.
	bin string
	// repoPath is the target repo, absolute.
	repoPath string
	// outputPath is where the finished context map has to end up.
	outputPath string
	// snapshotPath is where the driver is asked to leave the snapshot it
	// takes, so that something outside its process holds one if it dies
	// before putting the repo back (see backstop.go). Empty where no
	// record is being kept, which the driver reads as "keep your own".
	snapshotPath string
	// progress is where the driver's own two streams go.
	progress io.Writer
}

// invocation is how one output_mode gets a driver's output to outputPath.
// Picking one up front (see Manifest.plan) is what keeps the output_mode
// decision in a single place rather than re-tested at every step.
type invocation func(j job) error

// plan validates a manifest and returns how to invoke it. Everything a
// mode requires beyond the mode itself — fixed-location's fixed_path — is
// checked here, so a misconfigured manifest is rejected before any driver
// runs rather than partway through one.
func (m Manifest) plan(name string) (invocation, error) {
	switch m.OutputMode {
	case ModePathParameterized:
		return writeWhereTold, nil
	case ModeFixedLocation:
		if m.FixedPath == "" {
			return nil, fmt.Errorf("driver %q declares output_mode %q but has no fixed_path in its manifest", name, ModeFixedLocation)
		}
		return harvestFrom(m.FixedPath), nil
	default:
		return nil, fmt.Errorf("driver %q declares output_mode %q, which archimedes doesn't support (only %s, %s)",
			name, m.OutputMode, ModePathParameterized, ModeFixedLocation)
	}
}

// runIn invokes the driver named name, found in driversDir, against
// repoPath and guarantees the finished context map ends up at exactly
// outputPath, whichever contract the driver declares. The driver's own
// stdout/stderr go to progress. Which drivers/ it is handed is Set's
// question, answered before this is reached.
//
// Every failure mode leaves no output file behind: an unknown driver, an
// output_mode we don't support, a command that isn't executable, a non-zero
// exit, and — the one a driver can't self-report — a zero exit that never
// produced the file it promised.
func runIn(driversDir, name, repoPath, outputPath string, records runrecord.Dir, progress io.Writer) error {
	m, err := readManifest(os.DirFS(driversDir), driversDir, name)
	if err != nil {
		return err
	}
	invoke, err := m.plan(name)
	if err != nil {
		return err
	}

	bin := commandPath(driversDir, name, m)
	if err := executable(bin); err != nil {
		return fmt.Errorf("driver %q command not executable: %s (%w)", name, bin, err)
	}

	// Drivers are run with their working directory left alone and handed
	// the repo as an argument, so it has to be absolute — a relative one
	// would resolve against whatever directory the driver chooses to work
	// in rather than against ours.
	repoPath, err = filepath.Abs(repoPath)
	if err != nil {
		return fmt.Errorf("resolving repo path %s: %w", repoPath, err)
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}

	// Opened before the driver is started and not after, because the
	// window this closes is the one where the driver dies without warning:
	// a record written afterwards is a record for every run except the
	// ones that needed one.
	rec := openRecord(records, name, repoPath, progress)
	j := job{bin: bin, repoPath: repoPath, outputPath: outputPath, progress: progress}
	if rec != nil {
		j.snapshotPath = rec.SnapshotPath()
	}

	err = invoke(j)
	// Whatever the run did, the repo it was working in is answered for
	// before this returns: on the way out of a failed run there is nobody
	// else left to do it.
	settle(rec, driversDir, err, progress)
	if err != nil {
		return fmt.Errorf("driver %q: %w", name, err)
	}
	return nil
}

// writeWhereTold is the path-parameterized contract: the driver is handed
// the output location and writes exactly there.
func writeWhereTold(j job) error {
	if err := run(j, j.repoPath, j.outputPath); err != nil {
		return err
	}
	if !isFile(j.outputPath) {
		return fmt.Errorf("exited 0 but did not write %s", j.outputPath)
	}
	return nil
}

// harvestFrom is the fixed-location contract: the driver can't be told
// where to write, so it's invoked with just the repo path and we harvest
// its manifest-declared fixedPath ourselves — moving rather than copying,
// so the target repo ends up with no trace of the artifact.
func harvestFrom(fixedPath string) invocation {
	return func(j job) error {
		writtenAt := filepath.Join(j.repoPath, fixedPath)
		if err := run(j, j.repoPath); err != nil {
			return err
		}
		if !isFile(writtenAt) {
			return fmt.Errorf("exited 0 but did not write %s", writtenAt)
		}
		if err := move(writtenAt, j.outputPath); err != nil {
			return err
		}
		pruneEmptied(j.repoPath, fixedPath)
		return nil
	}
}

// pruneEmptied removes the directories that moving fixedPath out of
// repoPath left holding nothing, walking up toward — but never reaching —
// repoPath itself.
//
// A fixed_path can be nested, because a driver wrapping a tool that
// scaffolds itself into the repo has no say in where that tool writes (the
// spec-kit driver's is .specify/memory/constitution.md). `git status`
// wouldn't have caught what's left, since git doesn't track directories,
// but it's a trace of the run all the same.
//
// os.Remove refuses a directory that still holds anything, which is exactly
// right for one that predates the run or holds something else; the first
// refusal ends the walk. Failures are otherwise ignored: the artifact is
// already safely harvested by this point, and an undeletable directory
// isn't worth failing a run over.
func pruneEmptied(repoPath, fixedPath string) {
	for dir := filepath.Dir(fixedPath); dir != "." && dir != string(filepath.Separator); dir = filepath.Dir(dir) {
		if err := os.Remove(filepath.Join(repoPath, dir)); err != nil {
			return
		}
	}
}

// run executes the driver, streaming both its streams to progress so
// whatever it reports reaches the operator — including whatever it has to
// say on its way out when a signal aimed at archimedes is passed on to it.
//
// Started and waited for rather than Run, because there is something to do
// in between: a driver is put in a process group of its own and handed the
// interrupts archimedes receives, and archimedes then keeps waiting for the
// rollback that follows. See interrupt.go for the whole of that.
func run(j job, args ...string) error {
	out := &serialized{w: j.progress}

	cmd := exec.Command(j.bin, args...)
	cmd.Stdout = out
	cmd.Stderr = out
	// Where to leave the snapshot, for a driver that takes one. Added to
	// the environment rather than passed as an argument because it is not
	// part of either invocation contract: a driver that reads it gets a
	// backstop, one that does not is unaffected, and neither the argument
	// list nor the output_mode has to grow a case for the difference.
	cmd.Env = os.Environ()
	if j.snapshotPath != "" {
		cmd.Env = append(cmd.Env, runrecord.SnapshotEnvVar+"="+j.snapshotPath)
	}
	isolateProcessGroup(cmd)

	relay := watchForInterrupts(out)
	if err := cmd.Start(); err != nil {
		if sig, ok := relay.release(); ok {
			return stoppedBy(sig, nil)
		}
		return fmt.Errorf("%s: %w", j.bin, err)
	}
	relay.forwardTo(cmd.Process.Pid)
	waitErr := cmd.Wait()

	// Asked before the wait's own error, because a driver that was told to
	// stop exits non-zero by design: reporting that as an ordinary failure
	// would lose both the reason the run ended and the status a caller
	// reads to find out whether the repo was left clean.
	if sig, ok := relay.release(); ok {
		return stoppedBy(sig, cmd.ProcessState)
	}
	if waitErr != nil {
		return fmt.Errorf("%s: %w", j.bin, waitErr)
	}
	return nil
}

// executable reports whether path is a regular file with an execute bit
// set, catching a manifest naming a command that was never shipped or never
// made executable before it produces a confusing exec failure.
func executable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return errors.New("not an executable file")
	}
	return nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// move relocates src to dst, falling back to copy-then-remove when the two
// are on different filesystems (the control repo and a target repo need not
// share one, and os.Rename can't cross that boundary the way mv does). The
// copy carries src's mode, so the harvested map is the file the driver
// wrote either way.
func move(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	info, err := in.Stat()
	if err != nil {
		return err
	}

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Remove(src)
}
