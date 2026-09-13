// Package prune finds and removes worktrees/branches whose PR has merged
// or closed. Candidate selection is pure (Scan takes PR lookup as an
// injected function so it can be unit-tested without gh or a real git
// checkout); what a status.md row says is internal/statusfile's, the
// gh-facing adapter lives in gh.go, and the git commands that do the
// actual removal come from internal/gitutil.
package prune

import (
	"sort"

	"github.com/blockadence/gh-archimedes/internal/stackref"
	"github.com/blockadence/gh-archimedes/internal/statusfile"
	"github.com/blockadence/gh-archimedes/internal/worktree"
)

// PRStateFunc looks up a head branch's PR state ("MERGED", "CLOSED",
// "OPEN", or "NONE") for repo, the way `gh pr list` does. A returned error
// is treated the same as "NONE" (no PR to act on) — a lookup failure
// (network, auth, no PR) must never be mistaken for permission to prune.
type PRStateFunc func(repo, headBranch string) (string, error)

// Item is one status.md row whose PR has merged or closed: a candidate
// for pruning, unless Blockers is non-empty.
type Item struct {
	Slug string
	Repo string
	// Worktree is where this unit of work's worktree is on this machine,
	// resolved against the instance root — a path to hand git, not the
	// relative one the row carries.
	Worktree   string
	Note       string
	PRState    string
	StatusPath string
	Blockers   []string // status.md paths that still name this repo:slug as a stacked base
}

// Ref is the "<repo>:<slug>" pair naming this candidate, from the package
// that owns that shape. Item keeps the two halves apart because removing a
// worktree needs them apart; naming the candidate goes through here.
func (it Item) Ref() stackref.Ref { return stackref.Ref{Repo: it.Repo, Slug: it.Slug} }

// Prunable reports whether nothing still depends on this repo:slug as a
// stacked base.
func (it Item) Prunable() bool { return len(it.Blockers) == 0 }

// Scan walks the work/*/status.md files of the instance at root
// (optionally filtered to one slug) and returns every row whose PR has
// merged or closed, each with its worktree resolved against root. A row
// that's still named as another unit of work's stacked base comes back
// with Blockers set rather than being silently pruned out from under it.
//
// Every file is read even when one slug was asked for, because whether a
// branch is somebody's base is a question about the other files.
func Scan(root, slugFilter string, prState PRStateFunc) ([]Item, error) {
	files, err := statusfile.Discover(root)
	if err != nil {
		return nil, err
	}

	var items []Item
	for _, f := range files {
		if slugFilter != "" && f.Slug != slugFilter {
			continue
		}

		for _, row := range f.Rows {
			state, err := prState(row.Repo, f.Slug)
			if err != nil {
				state = "NONE"
			}
			if state != "MERGED" && state != "CLOSED" {
				continue
			}

			items = append(items, Item{
				Slug:       f.Slug,
				Repo:       row.Repo,
				Worktree:   worktree.Resolve(root, row.Worktree),
				Note:       row.Note,
				PRState:    state,
				StatusPath: f.Path,
				Blockers:   blockers(files, stackref.Ref{Repo: row.Repo, Slug: f.Slug}),
			})
		}
	}

	return items, nil
}

// blockers is every status.md holding a row stacked on ref: the units of
// work that would lose the branch under them if it were removed.
//
// The question is asked of each row's parsed note rather than of the file
// as text. Scanning for the note's wording in the raw file made the answer
// turn on the row's spacing — a note an editor's table formatter had
// re-spaced named no base, and the base it still named was pruned out from
// under it — and on a prefix, since "stacked on service-a:widget-fix"
// occurs inside "stacked on service-a:widget-fix-2".
func blockers(files []statusfile.File, ref stackref.Ref) []string {
	var paths []string
	for _, f := range files {
		for _, row := range f.Rows {
			if on, ok := stackref.ParseNote(row.Note); ok && on == ref {
				paths = append(paths, f.Path)
				break
			}
		}
	}
	sort.Strings(paths)
	return paths
}

// RemoveStatusRow deletes every row for repo from the status.md at path,
// which is what retiring a unit of work in that repo leaves behind. The
// caller names the file in its own error, so this one doesn't repeat it.
func RemoveStatusRow(path, repo string) error {
	return statusfile.RemoveRows(path, func(r statusfile.Row) bool { return r.Repo == repo })
}
