package spawn_test

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/spawn"
	"github.com/blockadence/gh-archimedes/internal/stackref"
	"github.com/blockadence/gh-archimedes/internal/statusfile"
	"github.com/blockadence/gh-archimedes/internal/testrepo"
	"github.com/blockadence/gh-archimedes/internal/workspace"
	"github.com/blockadence/gh-archimedes/internal/worktree"
)

func TestResolveStartPoint(t *testing.T) {
	cases := []struct {
		name                     string
		baseBranch, baseOverride string
		stack                    stackref.Ref
		wantRef, wantNote        string
	}{
		{
			name:       "default uses origin/<base branch>",
			baseBranch: "main",
			wantRef:    "origin/main",
			wantNote:   "based on main",
		},
		{
			name:         "base override wins over default",
			baseBranch:   "main",
			baseOverride: "release/1.2",
			wantRef:      "release/1.2",
			wantNote:     "based on release/1.2",
		},
		{
			name:         "stack ref wins over base override",
			baseBranch:   "main",
			baseOverride: "release/1.2",
			stack:        stackref.Ref{Repo: "target", Slug: "widget-fix"},
			wantRef:      "widget-fix",
			wantNote:     "stacked on target:widget-fix",
		},
		{
			name:       "stack presence is keyed on Repo, not Slug",
			baseBranch: "main",
			stack:      stackref.Ref{Repo: "target"},
			wantRef:    "",
			wantNote:   "stacked on target:",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := spawn.ResolveStartPoint(tc.baseBranch, tc.baseOverride, tc.stack)
			if got.Ref != tc.wantRef || got.Note != tc.wantNote {
				t.Errorf("got {Ref: %q, Note: %q}, want {Ref: %q, Note: %q}", got.Ref, got.Note, tc.wantRef, tc.wantNote)
			}
		})
	}
}

func TestNextStepHint(t *testing.T) {
	if got, want := spawn.NextStepHint("/wt", ""), "cd /wt && claude"; got != want {
		t.Errorf("default agent: got %q, want %q", got, want)
	}
	if got, want := spawn.NextStepHint("/wt", "codex"), "cd /wt && codex"; got != want {
		t.Errorf("configured agent: got %q, want %q", got, want)
	}
}

// run invokes spawn.Run with the given options, failing the test on error
// and returning what it wrote to its result stream.
func run(t *testing.T, opts spawn.Options) string {
	t.Helper()
	var out, progress bytes.Buffer
	if _, err := spawn.Run(opts, &out, &progress); err != nil {
		t.Fatalf("spawn.Run: %v\nprogress:\n%s", err, progress.String())
	}
	return out.String()
}

func TestRunFetchesFirstAndDefaultsToBaseBranch(t *testing.T) {
	inst := newInstance(t)

	// Simulate the local checkout being stale relative to origin: push a
	// new commit straight to origin without updating the clone.
	otherClone := inst.target.Reclone(t, "other-clone").Clone
	mustWriteFile(t, filepath.Join(otherClone, "new-file.txt"), "new")
	testrepo.Git(t, otherClone, "add", "-A")
	testrepo.Git(t, otherClone, "commit", "-q", "-m", "remote-advances")
	testrepo.Git(t, otherClone, "push", "-q", "origin", "main")

	slug := "widget-fix"
	inst.workSlug(t, slug)

	out := run(t, spawn.Options{Root: inst.root, Slug: slug, Repo: "target"})

	wt := worktree.Path(inst.target.Clone, slug)
	if _, err := os.Stat(filepath.Join(wt, "new-file.txt")); err != nil {
		t.Errorf("worktree did not start from freshly-fetched origin/main: %v", err)
	}
	if got := testrepo.GitOut(t, wt, "rev-parse", "--abbrev-ref", "HEAD"); got != slug {
		t.Errorf("branch name = %q, want %q", got, slug)
	}
	if !bytes.Contains([]byte(out), []byte("based on main")) {
		t.Errorf("output missing default resolution note: %s", out)
	}
}

func TestRunBaseOverride(t *testing.T) {
	inst := newInstance(t)

	testrepo.Git(t, inst.target.Clone, "checkout", "-q", "-b", "release/1.0")
	mustWriteFile(t, filepath.Join(inst.target.Clone, "release-marker.txt"), "r1")
	testrepo.Git(t, inst.target.Clone, "add", "-A")
	testrepo.Git(t, inst.target.Clone, "commit", "-q", "-m", "release branch")
	testrepo.Git(t, inst.target.Clone, "push", "-q", "origin", "release/1.0")
	testrepo.Git(t, inst.target.Clone, "checkout", "-q", "main")

	slug := "hotfix"
	inst.workSlug(t, slug)

	out := run(t, spawn.Options{Root: inst.root, Slug: slug, Repo: "target", Base: "release/1.0"})

	wt := worktree.Path(inst.target.Clone, slug)
	if _, err := os.Stat(filepath.Join(wt, "release-marker.txt")); err != nil {
		t.Errorf("worktree did not start from the base override: %v", err)
	}
	if !bytes.Contains([]byte(out), []byte("based on release/1.0")) {
		t.Errorf("output missing base-override resolution note: %s", out)
	}
}

func TestRunStackedOnAnotherSlug(t *testing.T) {
	inst := newInstance(t)

	base := "widget-fix"
	inst.workSlug(t, base)
	run(t, spawn.Options{Root: inst.root, Slug: base, Repo: "target"})

	baseWT := worktree.Path(inst.target.Clone, base)
	mustWriteFile(t, filepath.Join(baseWT, "base-work.txt"), "base")
	testrepo.Git(t, baseWT, "add", "-A")
	testrepo.Git(t, baseWT, "commit", "-q", "-m", "base slug work")

	stacked := "widget-fix-followup"
	inst.workSlug(t, stacked)
	out := run(t, spawn.Options{
		Root: inst.root, Slug: stacked, Repo: "target",
		Stack: stackref.Ref{Repo: "target", Slug: base},
	})

	stackedWT := worktree.Path(inst.target.Clone, stacked)
	if _, err := os.Stat(filepath.Join(stackedWT, "base-work.txt")); err != nil {
		t.Errorf("stacked worktree did not start from the base slug's branch: %v", err)
	}
	if !bytes.Contains([]byte(out), []byte("stacked on target:widget-fix")) {
		t.Errorf("output missing stacked-branch resolution note: %s", out)
	}
}

func TestRunMaterializesContextAndTracksStatus(t *testing.T) {
	inst := newInstance(t)

	slug := "widget-fix"
	workSlugDir := inst.workSlug(t, slug)
	mustWriteFile(t, filepath.Join(workSlugDir, "ticket.md"), "# Ticket\n")

	out := run(t, spawn.Options{Root: inst.root, Slug: slug, Repo: "target"})

	wt := worktree.Path(inst.target.Clone, slug)
	if _, err := os.Stat(filepath.Join(wt, spawn.ContextDirName, "ticket.md")); err != nil {
		t.Errorf("ticket.md was not materialized: %v", err)
	}
	if status := testrepo.GitOut(t, wt, "status", "--porcelain"); status != "" {
		t.Errorf("git status surfaced the materialized context: %q", status)
	}
	if !bytes.Contains([]byte(out), []byte("Worktree ready: "+wt)) {
		t.Errorf("missing 'Worktree ready' line: %s", out)
	}

	statusContent, err := os.ReadFile(filepath.Join(workSlugDir, statusfile.Name))
	if err != nil {
		t.Fatalf("status.md was not written: %v", err)
	}
	want := "# widget-fix\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n" +
		"| target | widget-fix | ../target-repo-worktrees/widget-fix | based on main |\n"
	if string(statusContent) != want {
		t.Errorf("status.md mismatch\n got: %q\nwant: %q", statusContent, want)
	}

	// A second repo for the same slug appends a row, and must not receive
	// the first spawn's bookkeeping as if it were reference material.
	out2 := run(t, spawn.Options{Root: inst.root, Slug: slug, Repo: "target2", AgentCmd: "codex"})
	if !bytes.Contains([]byte(out2), []byte("codex")) {
		t.Errorf("next-step hint did not respect the configured agent: %s", out2)
	}

	wt2 := worktree.Path(inst.target2.Clone, slug)
	if _, err := os.Stat(filepath.Join(wt2, spawn.ContextDirName, statusfile.Name)); !os.IsNotExist(err) {
		t.Error("status.md (bookkeeping) leaked into the second worktree's materialized context")
	}
	if _, err := os.Stat(filepath.Join(wt2, spawn.ContextDirName, "ticket.md")); err != nil {
		t.Errorf("ticket.md was not materialized into the second worktree: %v", err)
	}

	statusContent, err = os.ReadFile(filepath.Join(workSlugDir, statusfile.Name))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(statusContent, []byte("| target2 |")) {
		t.Errorf("second repo's row was not appended: %s", statusContent)
	}
}

// A relative --root must resolve against the caller's working directory,
// not against the target repo git runs in. Getting this wrong nests the
// worktree inside the checkout it should sit beside, and materializes the
// context into a different directory entirely.
func TestRunRelativeRootDoesNotNestWorktreeInsideRepo(t *testing.T) {
	inst := newInstance(t)

	slug := "widget-fix"
	workSlugDir := inst.workSlug(t, slug)
	mustWriteFile(t, filepath.Join(workSlugDir, "ticket.md"), "# Ticket\n")

	t.Chdir(inst.root)
	out := run(t, spawn.Options{Root: ".", Slug: slug, Repo: "target"})

	wt := worktree.Path(inst.target.Clone, slug)
	if _, err := os.Stat(filepath.Join(wt, spawn.ContextDirName, "ticket.md")); err != nil {
		t.Errorf("ticket.md was not materialized into the real worktree: %v", err)
	}
	if status := testrepo.GitOut(t, inst.target.Clone, "status", "--porcelain"); status != "" {
		t.Errorf("worktree was nested inside the target repo, polluting its git status: %q", status)
	}

	// The recorded path is relative to the instance, and resolving it
	// against the root has to land on the real worktree however the root
	// was spelled on the way in.
	statusContent, err := os.ReadFile(filepath.Join(workSlugDir, statusfile.Name))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(statusContent, []byte("../target-repo-worktrees/widget-fix")) {
		t.Errorf("status.md did not record the worktree relative to the instance: %s", statusContent)
	}
	if got := worktree.Resolve(inst.root, "../target-repo-worktrees/widget-fix"); got != wt {
		t.Errorf("the recorded row resolves to %q, not the worktree at %q", got, wt)
	}
	// The hint is printed for this machine and this shell, so it stays a
	// path the operator can paste.
	if !bytes.Contains([]byte(out), []byte(wt)) {
		t.Errorf("next-step hint recorded a non-absolute worktree path: %s", out)
	}
}

// repos.yaml's path is not required to be the "../<name>" sibling layout
// bootstrap happens to produce. A repo checked out *below* the instance
// root is the case where a mis-resolved relative path is worst: the
// worktree lands inside the target checkout and shows up in its git status.
//
// It is also the layout that puts a checkout and a dossier under one name
// — `repos/target/` and `repos/target.md` in the same instance — so the
// dossier is written here too, and its house rules have to arrive in the
// worktree all the same. That is the arrangement issue 76 decided to keep,
// run through the subcommand rather than argued; dossier.Dir carries the
// reason.
func TestRunResolvesRepoPathsBelowInstanceRoot(t *testing.T) {
	tmp := t.TempDir()
	root := filepath.Join(tmp, "instance")
	mustMkdirAll(t, filepath.Join(root, "repos"))

	targetRepo := makeTargetRepo(t, tmp, "target-repo")
	nested := filepath.Join(root, "repos", "target")
	if err := os.Rename(targetRepo.Clone, nested); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(root, "repos.yaml"),
		"repos:\n  - name: target\n    path: repos/target\n    base_branch: main\n")

	rules := "Never rebase a shared branch."
	writeDossier(t, root, "target", rules)

	slug := "widget-fix"
	workSlugDir := filepath.Join(root, "work", slug)
	mustMkdirAll(t, workSlugDir)
	mustWriteFile(t, filepath.Join(workSlugDir, "ticket.md"), "# Ticket\n")

	t.Chdir(root)
	run(t, spawn.Options{Root: ".", Slug: slug, Repo: "target"})

	if status := testrepo.GitOut(t, nested, "status", "--porcelain"); status != "" {
		t.Errorf("worktree was nested inside the target repo, polluting its git status: %q", status)
	}
	wt := worktree.Path(nested, slug)
	if _, err := os.Stat(filepath.Join(wt, spawn.ContextDirName, "ticket.md")); err != nil {
		t.Errorf("ticket.md was not materialized into the real worktree: %v", err)
	}
	// The dossier sitting beside the checkout under the same name is still
	// read as the dossier -- `repos/target.md` delivered, `repos/target/`
	// left as the checkout spawn just worked in.
	assertHouseRules(t, wt, rules)
}

// Spawning delivers the target repo's house rules even when the slug has
// no reference material of its own.
func TestRunDeliversHouseRules(t *testing.T) {
	inst := newInstance(t)

	rules := "Never rebase a shared branch.\nAll schema changes go through the migration tool, no exceptions."
	writeDossier(t, inst.root, "target", rules)

	slug := "quiet-fix"
	inst.workSlug(t, slug)

	run(t, spawn.Options{Root: inst.root, Slug: slug, Repo: "target"})

	wt := worktree.Path(inst.target.Clone, slug)
	assertHouseRules(t, wt, rules)
	if status := testrepo.GitOut(t, wt, "status", "--porcelain"); status != "" {
		t.Errorf("the ephemeral house-rules copy surfaced in git status: %q", status)
	}

	// A repo with no dossier at all gets no house rules, and with no
	// reference material either, no context directory at all.
	other := "another-fix"
	inst.workSlug(t, other)
	run(t, spawn.Options{Root: inst.root, Slug: other, Repo: "target2"})

	wt2 := worktree.Path(inst.target2.Clone, other)
	if _, err := os.Stat(filepath.Join(wt2, spawn.ContextDirName)); !os.IsNotExist(err) {
		t.Error("an empty context dir was created for a repo with no house rules and no reference material")
	}
}

func TestRunUnknownRepoErrors(t *testing.T) {
	inst := newInstance(t)
	inst.workSlug(t, "widget-fix")

	var out, progress bytes.Buffer
	_, err := spawn.Run(spawn.Options{Root: inst.root, Slug: "widget-fix", Repo: "does-not-exist"}, &out, &progress)
	if err == nil {
		t.Fatal("expected an error for an unknown repo, got nil")
	}
}

func TestRunGitProgressStaysOffResultStream(t *testing.T) {
	inst := newInstance(t)
	slug := "widget-fix"
	inst.workSlug(t, slug)

	var out, progress bytes.Buffer
	if _, err := spawn.Run(spawn.Options{Root: inst.root, Slug: slug, Repo: "target"}, &out, &progress); err != nil {
		t.Fatalf("spawn.Run: %v", err)
	}

	// The result stream carries exactly the two caller-facing lines; git's
	// own chatter belongs on the progress stream.
	if lines := bytes.Count(out.Bytes(), []byte("\n")); lines != 2 {
		t.Errorf("expected 2 result lines, got %d:\n%s", lines, out.String())
	}
	if bytes.Contains(out.Bytes(), []byte("Preparing worktree")) {
		t.Errorf("git progress leaked onto the result stream:\n%s", out.String())
	}
}

// recordingIntegration is a stand-in for a real terminal workspace
// manager: it captures what spawn asked for and returns openErr.
func recordingIntegration(openErr error, got *workspace.Request) *workspace.Integration {
	return &workspace.Integration{
		Name: "fake",
		Open: func(req workspace.Request) error {
			*got = req
			return openErr
		},
	}
}

func TestRunOpensAWorkspaceRootedAtTheNewWorktree(t *testing.T) {
	inst := newInstance(t)
	slug := "widget-fix"
	inst.workSlug(t, slug)

	var got workspace.Request
	out := run(t, spawn.Options{
		Root: inst.root, Slug: slug, Repo: "target",
		Workspace: recordingIntegration(nil, &got),
	})

	wt := worktree.Path(inst.target.Clone, slug)
	want := workspace.Request{RepoPath: inst.target.Clone, Path: wt, Label: "target:" + slug}
	if got != want {
		t.Errorf("workspace request\n got: %+v\nwant: %+v", got, want)
	}
	if !bytes.Contains([]byte(out), []byte("Opened fake workspace: target:"+slug)) {
		t.Errorf("output did not report the opened workspace: %s", out)
	}
}

func TestRunPassesFocusThroughToTheIntegration(t *testing.T) {
	inst := newInstance(t)
	slug := "widget-fix"
	inst.workSlug(t, slug)

	var got workspace.Request
	run(t, spawn.Options{
		Root: inst.root, Slug: slug, Repo: "target", Focus: true,
		Workspace: recordingIntegration(nil, &got),
	})

	if !got.Focus {
		t.Errorf("spawn --focus did not reach the integration: %+v", got)
	}
}

// The worktree, its branch, and its materialized context all exist by the
// time the integration is called. A missing or unhappy workspace manager
// must therefore degrade to a warning, never turn a completed spawn into a
// failed one that leaves the operator with half-built state.
func TestRunSurvivesAWorkspaceThatCannotOpen(t *testing.T) {
	inst := newInstance(t)
	slug := "widget-fix"
	inst.workSlug(t, slug)

	var got workspace.Request
	var out, progress bytes.Buffer
	_, err := spawn.Run(spawn.Options{
		Root: inst.root, Slug: slug, Repo: "target",
		Workspace: recordingIntegration(errors.New("herdr is not on PATH"), &got),
	}, &out, &progress)
	if err != nil {
		t.Fatalf("a failing workspace integration failed the spawn: %v", err)
	}

	wt := worktree.Path(inst.target.Clone, slug)
	if _, statErr := os.Stat(wt); statErr != nil {
		t.Errorf("worktree was not created: %v", statErr)
	}
	if !bytes.Contains(progress.Bytes(), []byte("herdr is not on PATH")) {
		t.Errorf("the failure was swallowed instead of warned about: %s", progress.String())
	}
	if bytes.Contains(out.Bytes(), []byte("Opened")) {
		t.Errorf("a failed open was reported as a success: %s", out.String())
	}
}

// Not having the tool installed is the expected state on most machines and
// says nothing is wrong; a tool that *is* installed and still refused the
// call is a real problem worth a louder word. Reporting both identically
// trains the operator to ignore the one that matters.
func TestRunDistinguishesAnUninstalledToolFromAFailingOne(t *testing.T) {
	inst := newInstance(t)

	report := func(t *testing.T, slug string, openErr error) string {
		t.Helper()
		inst.workSlug(t, slug)
		var got workspace.Request
		var out, progress bytes.Buffer
		if _, err := spawn.Run(spawn.Options{
			Root: inst.root, Slug: slug, Repo: "target",
			Workspace: recordingIntegration(openErr, &got),
		}, &out, &progress); err != nil {
			t.Fatalf("spawn.Run: %v", err)
		}
		return progress.String()
	}

	absent := report(t, "absent-tool", fmt.Errorf("%w: fake is not on PATH", workspace.ErrUnavailable))
	if !strings.Contains(absent, "skipping") || strings.Contains(absent, "warning:") {
		t.Errorf("an uninstalled tool should be a note, not a warning: %s", absent)
	}

	broken := report(t, "broken-tool", errors.New("server_not_running"))
	if !strings.Contains(broken, "warning:") {
		t.Errorf("an installed tool that refused the call should warn: %s", broken)
	}
}

func TestRunReportsWhatItCreated(t *testing.T) {
	inst := newInstance(t)
	slug := "widget-fix"
	inst.workSlug(t, slug)

	var out, progress bytes.Buffer
	got, err := spawn.Run(spawn.Options{Root: inst.root, Slug: slug, Repo: "target"}, &out, &progress)
	if err != nil {
		t.Fatalf("spawn.Run: %v\nprogress:\n%s", err, progress.String())
	}

	want := spawn.Result{
		Slug:     slug,
		Repo:     "target",
		Branch:   slug,
		Worktree: worktree.Path(inst.target.Clone, slug),
		StartRef: "origin/main",
		Note:     "based on main",
	}
	if got != want {
		t.Errorf("result mismatch\n got: %#v\nwant: %#v", got, want)
	}
	// Whatever the result reports must be what's on disk, not a guess.
	if !strings.Contains(out.String(), got.Worktree) {
		t.Errorf("result worktree %q absent from the printed output:\n%s", got.Worktree, out.String())
	}
}
