package cmd

import (
	"os"

	"github.com/spf13/cobra"

	"github.com/blockadence/gh-archimedes"
	"github.com/blockadence/gh-archimedes/internal/contextmap"
	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// Environment variables a context-mapping pass honors, so an operator can
// point it at their own harness, skill, or driver without editing anything.
// agentCmdEnvVar (shared with spawn) names the agent CLI to suggest.
const (
	contextFileEnvVar   = "ARCHIMEDES_CONTEXT_FILE"
	contextPromptEnvVar = "ARCHIMEDES_CONTEXT_PROMPT"
	driverEnvVar        = "ARCHIMEDES_DRIVER"
	driversDirEnvVar    = "ARCHIMEDES_DRIVERS_DIR"
)

func newContextMapCmd() *cobra.Command {
	var root string
	var dryRun bool

	cmd := &cobra.Command{
		Use:   "context-map",
		Short: "Sequence a context-mapping pass across every repo, dependencies first",
		Long: `Sequences a context-mapping pass across every repo in repos.yaml,
dependency/base repos first, skipping any repo whose context map is already
current for its base branch's latest commit — so re-runs stay incremental as
repos are added or merged into.

Orchestration only: it never assumes a particular coding agent, skill, or
driver. By default each repo's map is an interactive, human-in-the-loop
session (ARCHIMEDES_AGENT_CMD, ARCHIMEDES_CONTEXT_PROMPT and
ARCHIMEDES_CONTEXT_FILE tune what it suggests). Set repos.yaml's top-level
"driver" field — or ARCHIMEDES_DRIVER, checked when that's unset — to a name
under drivers/ to build every map unattended instead; a single repo can
override that default with a "driver" field of its own.`,
		Args: cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			// Before the pass rather than after it: these are repos an
			// earlier run left dirty, and a pass about to run drivers
			// against a family of repos is exactly when that matters.
			noticeUnfinishedRuns(runrecord.For(root), c.ErrOrStderr())
			opts := contextMapOptions(root, dryRun, os.Getenv)
			return contextmap.Run(opts, c.OutOrStdout(), c.ErrOrStderr(), c.InOrStdin())
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root containing repos.yaml and drivers/")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show the planned order and each repo's staleness without invoking any driver or session")

	return cmd
}

// contextMapOptions assembles a pass from the flags plus the environment
// overrides, over the drivers this binary ships. Anything unset is left
// empty for internal/contextmap to apply its own default to, so the
// defaults live in one place.
func contextMapOptions(root string, dryRun bool, env func(string) string) contextmap.Options {
	return contextmap.Options{
		Root:          root,
		DryRun:        dryRun,
		AgentCmd:      env(agentCmdEnvVar),
		ContextFile:   env(contextFileEnvVar),
		ContextPrompt: env(contextPromptEnvVar),
		Driver:        env(driverEnvVar),
		DriversDir:    env(driversDirEnvVar),
		Builtin:       archimedes.Drivers(),
	}
}
