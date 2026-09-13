package cmd

import (
	"github.com/blockadence/gh-archimedes/internal/manifest"
)

// loadManifest loads root's repos.yaml, the manifest every subcommand
// operating on an instance needs.
//
// The absolute root manifest.LoadInstance resolves is dropped on purpose:
// these subcommands go on resolving repo paths against the root the
// operator typed, so that a relative --root keeps producing the relative
// paths their output and their git invocations have always used. That is
// right for a repo path, which git receives as the working directory it
// runs *in* — relative to the operator's shell is exactly what it should
// mean there, and a `--root .` that printed absolute paths back would be
// answering a question nobody asked.
//
// It stops being right the moment a path resolved against this root is
// handed to a tool as an *argument*, because the tool is by then running
// somewhere else: git inside the target repo, a driver inside a worktree.
// A path that named the right thing in the operator's shell names
// something else there, or nothing. So the rule is not "resolve against
// the typed root", full stop; it is that a resolved path is absolutized
// at the point of resolution whenever the result is going to be passed
// rather than entered — by whatever resolves it, not by each caller in
// turn.
//
// worktree.Resolve is the worked example and the place to copy: it joins
// a recorded worktree column to this root and absolutizes the join,
// because what consumes its answer is `git worktree remove`, run inside
// the repo. The reasoning is at that site and the bug that made it
// necessary is issue 46; what belongs here is that the next
// instance-relative path somebody resolves has the same question to ask
// and the same answer — as manifest.Path says from the other side, and as
// workdir.Path restates for work/<slug>, a path an operator reads and
// this process opens rather than one a tool is handed (issue 59).
func loadManifest(root string) (*manifest.Manifest, error) {
	_, m, err := manifest.LoadInstance(root)
	return m, err
}
