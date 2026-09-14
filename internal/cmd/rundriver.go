package cmd

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/blockadence/gh-archimedes/internal/driver"
	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

func newRunDriverCmd() *cobra.Command {
	var root string

	cmd := &cobra.Command{
		Use:   "run-driver <driver> <repo-path> <output-path>",
		Short: "Invoke one context-mapping driver directly",
		Long: `Invokes a single driver against one repo and writes its context map to
exactly <output-path>, whichever invocation contract the driver declares —
the same call a context-mapping pass makes, without the pass around it.

For exercising a driver you are writing or debugging: nothing is read from
or recorded in repos.yaml, so the repo need not be one this instance
tracks. See drivers/README.md for the contract a driver honors.`,
		Args: cobra.ExactArgs(3),
		RunE: func(c *cobra.Command, args []string) error {
			// Where earlier runs left a repo nothing put back. On the
			// progress stream with the driver's own chatter, since it is
			// about runs rather than about where this map landed.
			noticeUnfinishedRuns(runrecord.For(root), c.ErrOrStderr())
			return runDriver(driverSet(root), args[0], args[1], args[2], c.OutOrStdout(), c.ErrOrStderr())
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root whose drivers/ is searched before the ones archimedes ships")

	return cmd
}

// runDriver sends the driver's own output to progress and reports only
// where the finished map landed on out, matching the split a mapping pass
// makes between what happened and the driver's chatter along the way.
func runDriver(drivers driver.Set, name, repoPath, outputPath string, out, progress io.Writer) error {
	if err := drivers.Run(name, repoPath, outputPath, progress); err != nil {
		return err
	}
	fmt.Fprintf(out, "Context map written to %s\n", outputPath)
	return nil
}
