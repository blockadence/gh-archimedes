// Package cmd wires up the archimedes CLI's command tree. Add a new
// subcommand by adding a newXCmd() constructor here and registering it in
// newRootCmd.
package cmd

import (
	"context"

	"github.com/blockadence/gh-archimedes/internal/invocation"
	"github.com/blockadence/gh-archimedes/internal/version"
	"github.com/charmbracelet/fang"
	"github.com/spf13/cobra"
)

func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use: "archimedes",
		// What this program is called where an operator reads it back --
		// `archimedes`, or `gh archimedes` under a gh extension install.
		// See internal/invocation for how the two are told apart.
		//
		// It goes to cobra as an annotation rather than as Use, because
		// Use's first word is the command's *name*: a two-word Use would
		// make every subcommand a child of something called "gh". As an
		// annotation it rewrites the whole tree's usage lines at once,
		// which is every usage line there is -- the prose around them, and
		// anything printed at runtime, is formatted from
		// invocation.Name() at each site instead.
		Annotations: map[string]string{cobra.CommandDisplayNameAnnotation: invocation.Name()},
		Short:       "Cross-repo planning and worktree lifecycle orchestration",
		Long: `Archimedes orchestrates planning and git-worktree lifecycle across a
family of related repos: which repos a unit of work touches, and
tracking/spawning/pruning the worktrees used to execute it.`,
		SilenceUsage: true,
	}

	root.AddCommand(newInitCmd())
	root.AddCommand(newBootstrapCmd())
	root.AddCommand(newRenderMapCmd())
	root.AddCommand(newContextMapCmd())
	root.AddCommand(newRunDriverCmd())
	root.AddCommand(newDriversCmd())
	root.AddCommand(newUnfinishedRunsCmd())
	root.AddCommand(newSpawnCmd())
	root.AddCommand(newStatusCmd())
	root.AddCommand(newPruneCmd())
	root.AddCommand(newNotifyCmd())
	root.AddCommand(newDashboardCmd())
	root.AddCommand(newServeMCPCmd())
	root.AddCommand(newSyncTemplatesCmd())
	root.AddCommand(newSyncHouseRulesCmd())
	root.AddCommand(newApplyConventionPackCmd())

	return root
}

// Execute runs the archimedes CLI, styled and augmented by fang (help,
// --version, shell completion, and man pages).
func Execute(ctx context.Context) error {
	return fang.Execute(ctx, newRootCmd(), fang.WithVersion(version.Current()))
}
