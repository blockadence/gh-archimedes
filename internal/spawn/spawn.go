// Package spawn creates the branch+worktree for one unit of work in one
// target repo, including the worktree-context materialization (see
// materialize.go). Kept independent of cobra/CLI concerns so it can be
// unit-tested directly.
package spawn

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/blockadence/gh-archimedes/internal/gitutil"
	"github.com/blockadence/gh-archimedes/internal/manifest"
	"github.com/blockadence/gh-archimedes/internal/stackref"
	"github.com/blockadence/gh-archimedes/internal/statusfile"
	"github.com/blockadence/gh-archimedes/internal/workdir"
	"github.com/blockadence/gh-archimedes/internal/workspace"
	"github.com/blockadence/gh-archimedes/internal/worktree"
)

// DefaultAgentCmd is the next-step hint's fallback when no agent CLI is
// configured.
const DefaultAgentCmd = "claude"

// Options is one spawn request: which unit of work, into which repo, and
// what to base it on.
type Options struct {
	// Root is the instance directory holding repos.yaml and work/.
	Root string
	// Slug names the unit of work; it becomes the branch name.
	Slug string
	// Repo is the target repo's name in repos.yaml.
	Repo string
	// Base, when set, overrides the repo's own base branch.
	Base string
	// Stack, when its Repo is set, stacks this branch on another slug's.
	Stack stackref.Ref
	// AgentCmd is the agent CLI the next-step hint should suggest. Empty
	// falls back to DefaultAgentCmd.
	AgentCmd string
	// Workspace, when set, is the terminal workspace manager handed the
	// finished worktree, so the unit of work lands in a pane already rooted
	// there. Nil — the default — leaves spawn behaving exactly as it did
	// before the integration existed.
	Workspace *workspace.Integration
	// Focus asks that manager to switch to the new workspace rather than
	// opening it in the background. Ignored when Workspace is nil.
	Focus bool
}

// Result is what one spawn created, reported back so a caller doesn't have
// to re-derive it from the manifest or scrape it out of the printed lines.
type Result struct {
	// Slug and Repo echo the request, so a result stands on its own.
	Slug string `json:"slug"`
	Repo string `json:"repo"`
	// Branch is the branch created; spawn names it after the slug.
	Branch string `json:"branch"`
	// Worktree is the checkout the branch was added at, as a path on this
	// machine — what a caller is about to cd into or hand to a tool. The
	// status row records the same worktree relative to the instance root
	// instead; see internal/worktree for why the two differ.
	Worktree string `json:"worktree"`
	// StartRef is the git ref the branch was cut from, and Note the
	// human-readable explanation of that choice recorded in the status file.
	StartRef string `json:"start_ref"`
	Note     string `json:"note"`
}

// StartPoint is the resolved git ref a new branch is created from, plus a
// human-readable note recorded in the status file explaining the choice.
type StartPoint struct {
	Ref  string
	Note string
}

// ResolveStartPoint applies the start-point precedence: a stack ref wins
// over a base override, which wins over the repo's own base branch (fetched
// fresh as origin/<baseBranch>). stack.Repo (not stack.Slug) is the
// presence check, so a --stack-on value with no ":" still stacks.
func ResolveStartPoint(baseBranch, baseOverride string, stack stackref.Ref) StartPoint {
	switch {
	case stack.Repo != "":
		return StartPoint{Ref: stack.Slug, Note: stackref.Note(stack)}
	case baseOverride != "":
		return StartPoint{Ref: baseOverride, Note: fmt.Sprintf("based on %s", baseOverride)}
	default:
		return StartPoint{Ref: "origin/" + baseBranch, Note: fmt.Sprintf("based on %s", baseBranch)}
	}
}

// NextStepHint is the "what to do now" line printed after a successful
// spawn. agentCmd is whatever the operator configured, so no particular
// agent CLI is hardcoded.
func NextStepHint(worktreePath, agentCmd string) string {
	if agentCmd == "" {
		agentCmd = DefaultAgentCmd
	}
	return fmt.Sprintf("cd %s && %s", worktreePath, agentCmd)
}

// Run creates the branch and worktree described by opts. It always fetches
// first, so new branches start from current remote state rather than a
// possibly-stale local checkout, then materializes the unit of work's
// reference material into the new worktree and records it in the slug's
// status file.
//
// progress receives git's own output; out receives the result lines meant
// for the caller. The Result names what was created; it is only meaningful
// when the returned error is nil.
func Run(opts Options, out, progress io.Writer) (Result, error) {
	// LoadInstance absolutizes the root before reading repos.yaml. Every
	// path below derives from that, and git is run with its working
	// directory set to the target repo — so a relative root would resolve
	// worktree paths against the repo instead of the instance, nesting the
	// worktree inside the checkout it belongs beside.
	root, m, err := manifest.LoadInstance(opts.Root)
	if err != nil {
		return Result{}, err
	}

	// Spawning into a repo nobody has cloned is the same dead end as
	// spawning into one nobody has listed: there is no checkout to branch
	// from, and bootstrap is what produces one either way.
	checkout := m.Checkout(root, opts.Repo)
	if !checkout.Ready() {
		return Result{}, unknownRepoError(opts.Repo)
	}
	repo, repoPath := checkout.Repo, checkout.Path

	if err := gitutil.RunOut(repoPath, progress, "fetch", "origin"); err != nil {
		return Result{}, err
	}
	if err := gitutil.RunOut(repoPath, progress, "checkout", repo.BaseBranch); err != nil {
		return Result{}, err
	}
	if err := gitutil.RunOut(repoPath, progress, "pull", "--ff-only", "origin", repo.BaseBranch); err != nil {
		return Result{}, err
	}

	start := ResolveStartPoint(repo.BaseBranch, opts.Base, opts.Stack)

	wt := worktree.Path(repoPath, opts.Slug)
	if err := os.MkdirAll(filepath.Dir(wt), 0o755); err != nil {
		return Result{}, err
	}
	if err := gitutil.RunOut(repoPath, progress, "worktree", "add", wt, "-b", opts.Slug, start.Ref); err != nil {
		return Result{}, err
	}

	// The unit of work's directory, made whether or not the operator has
	// put anything in it yet: statusfile.Append writes into it below and
	// expects it to be there.
	if err := os.MkdirAll(workdir.Path(root, opts.Slug), 0o755); err != nil {
		return Result{}, err
	}
	if err := Materialize(Context{
		RepoPath: repoPath,
		RepoName: opts.Repo,
		Root:     root,
		Slug:     opts.Slug,
		Worktree: wt,
	}); err != nil {
		return Result{}, fmt.Errorf("materializing worktree context: %w", err)
	}

	// Recorded relative to the instance, not as the path it is on this
	// machine: the row is committed to the instance and read by everyone
	// who has it (see internal/worktree). Result and the printed lines
	// below keep the usable path — they answer for this machine.
	if err := statusfile.Append(root, statusfile.Row{
		Slug:     opts.Slug,
		Repo:     opts.Repo,
		Branch:   opts.Slug,
		Worktree: worktree.Record(root, wt),
		Note:     start.Note,
	}); err != nil {
		return Result{}, fmt.Errorf("recording status: %w", err)
	}

	fmt.Fprintf(out, "Worktree ready: %s (%s)\n", wt, start.Note)
	fmt.Fprintln(out, NextStepHint(wt, opts.AgentCmd))
	openWorkspace(opts, repoPath, wt, out, progress)

	return Result{
		Slug:     opts.Slug,
		Repo:     opts.Repo,
		Branch:   opts.Slug,
		Worktree: wt,
		StartRef: start.Ref,
		Note:     start.Note,
	}, nil
}

// openWorkspace hands the finished worktree to the configured terminal
// workspace manager, if there is one. Any failure is reported on progress
// and dropped: by this point the branch, the worktree, its context, and
// the status row all exist, so a workspace manager that isn't installed —
// or whose server isn't running — must not turn a completed spawn into a
// failed one the operator then has to clean up by hand.
func openWorkspace(opts Options, repoPath, wt string, out, progress io.Writer) {
	if opts.Workspace == nil {
		return
	}

	req := workspace.Request{
		RepoPath: repoPath,
		Path:     wt,
		// One slug can be spawned into several repos, so the repo name is
		// part of the label — the same "<repo>:<slug>" shape --stack-on
		// parses, from the package that owns it rather than joined here.
		Label: stackref.Ref{Repo: opts.Repo, Slug: opts.Slug}.String(),
		Focus: opts.Focus,
	}
	// Not having the tool installed is the expected state on most machines
	// and says nothing is wrong, so it gets a note; a tool that is
	// installed and still refused the call is a real problem and gets a
	// warning. Reporting both the same way trains the operator to ignore
	// the one that matters.
	if err := opts.Workspace.Open(req); err != nil {
		if errors.Is(err, workspace.ErrUnavailable) {
			fmt.Fprintf(progress, "note: skipping the %s workspace: %v\n", opts.Workspace.Name, err)
		} else {
			fmt.Fprintf(progress, "warning: %s workspace not opened: %v\n", opts.Workspace.Name, err)
		}
		return
	}

	fmt.Fprintf(out, "Opened %s workspace: %s\n", opts.Workspace.Name, req.Label)
}

func unknownRepoError(name string) error {
	return fmt.Errorf("unknown repo: %s (run bootstrap first)", name)
}
