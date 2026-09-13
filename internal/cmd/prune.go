package cmd

import (
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"github.com/blockadence/gh-archimedes/internal/gitutil"
	"github.com/blockadence/gh-archimedes/internal/manifest"
	"github.com/blockadence/gh-archimedes/internal/prune"
	"github.com/blockadence/gh-archimedes/internal/stackref"
)

func newPruneCmd() *cobra.Command {
	var root string
	var force bool

	cmd := &cobra.Command{
		Use:   "prune [slug]",
		Short: "Remove worktrees/branches whose PR merged or closed",
		Long: `Removes worktrees, branches, and status.md entries for units of work whose
PR has merged or closed. Refuses to remove a branch that's still acting as
another unit of work's stacked base — rebase that one onto the real base
branch first.

Dry run by default: lists candidates without touching anything. Pass
--force to actually remove them.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			slugFilter := ""
			if len(args) == 1 {
				slugFilter = args[0]
			}

			return runPrune(c.OutOrStdout(), root, slugFilter, force, prune.LookupPRState)
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root containing repos.yaml and work/")
	cmd.Flags().BoolVar(&force, "force", false, "actually remove candidates instead of just listing them")

	return cmd
}

// runPrune scans root/work for merged/closed-PR candidates and, when
// force is set, removes them. ghState looks up a PR's state by "owner/repo"
// slug and head branch (production callers pass prune.LookupPRState; tests
// inject a fake so they don't need a real gh session).
func runPrune(out io.Writer, root, slugFilter string, force bool, ghState prune.PRStateFunc) error {
	if err := requireBins("git", "gh"); err != nil {
		return err
	}

	m, err := loadManifest(root)
	if err != nil {
		return err
	}

	items, err := prune.Scan(root, slugFilter, repoPRState(root, m, ghState))
	if err != nil {
		return err
	}

	// A candidate this run cannot retire does not stop the ones after it.
	// Each is its own worktree, branch and row, and none of them is any
	// less prunable for a locked worktree three entries back. Stopping at
	// the first failure left the operator with `removed.` behind it,
	// silence ahead of it, and a second run to find out which was which;
	// the run goes through instead, so every candidate carries an outcome
	// by the time it ends (issue 47).
	var failed []string

	for _, it := range items {
		if !it.Prunable() {
			fmt.Fprintf(out, "SKIP %s:%s (%s), still a base for: %s. Rebase that one first.\n",
				it.Repo, it.Slug, it.PRState, strings.Join(it.Blockers, ", "))
			continue
		}

		fmt.Fprintf(out, "PRUNE CANDIDATE: %s:%s (%s) at %s\n", it.Repo, it.Slug, it.PRState, it.Worktree)
		if !force {
			continue
		}

		if err := pruneItem(root, m, it); err != nil {
			// Under the candidate it belongs to, since by the end there
			// may be several: what git said stands where the operator can
			// see which entry it is about, rather than being carried to
			// the bottom of the run and run together with the others. A
			// step in from the line that introduces it, so a reason
			// running to several lines still reads as one entry's — which
			// is the nesting indentUnder holds.
			failed = append(failed, stackref.Ref{Repo: it.Repo, Slug: it.Slug}.String())
			fmt.Fprintf(out, "  not removed:\n%s\n", indentUnder(err.Error()))
			continue
		}
		fmt.Fprintln(out, "  removed.")
	}

	if !force {
		fmt.Fprintln(out)
		fmt.Fprintln(out, "Dry run. Re-run with --force to actually remove the above.")
	}

	// The reasons are above, against the entries they belong to, so what is
	// left to say is which entries they were: the run failed, and a caller
	// reading nothing but this still learns what it has to come back for.
	if len(failed) > 0 {
		return fmt.Errorf("not removed: %s", strings.Join(failed, ", "))
	}
	return nil
}

// pruneItem retires one candidate: its worktree, its branch, and its row in
// the status.md it came from, in that order. A step that fails leaves the
// steps after it undone, so a worktree git would not remove keeps the
// branch and the row that still name it rather than being written out of
// the instance while it is still on disk.
func pruneItem(root string, m *manifest.Manifest, it prune.Item) error {
	repo, err := m.Resolve(root, it.Repo)
	if err != nil {
		return err
	}
	// Git's own sentence goes back as it stands, and that is a decision
	// about this call site rather than a general rule about gitutil's
	// errors — every one of those names the command it ran, including the
	// ones `init` decided were not enough (issue 39). What differs here is
	// who is reading: an operator who typed a git-shaped command with
	// --force in it, against their own checkout, and got git's objection to
	// exactly that — a locked worktree, a dirty one, a path already gone.
	// What they typed is the context that makes git's sentence readable
	// (issue 47; docs/cli.md, under `prune`, has the whole of it).
	if err := gitutil.RemoveWorktree(repo.Path, it.Worktree); err != nil {
		return err
	}
	if err := gitutil.RemoveBranch(repo.Path, it.Slug); err != nil {
		return err
	}
	if err := prune.RemoveStatusRow(it.StatusPath, it.Repo); err != nil {
		return fmt.Errorf("updating %s: %w", it.StatusPath, err)
	}
	return nil
}
