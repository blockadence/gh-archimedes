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
// a recorded worktree column to the instance root and absolutizes the
// join, says at the site that what consumes its answer is `git worktree
// remove` run inside the repo, and so hands back a path that means the
// same thing from anywhere. Before it did, `prune` under a relative
// --root passed git a worktree path relative to the operator's shell and
// removed the right one only because git falls back to matching the
// suffix of what it has registered (issue 46; the rule itself is issue
// 59, which manifest.Path cites from the other side, and which
// workdir.Path restates for work/<slug> — a path an operator reads and
// this process opens, never one a tool is handed).
func loadManifest(root string) (*manifest.Manifest, error) {
	_, m, err := manifest.LoadInstance(root)
	return m, err
}
