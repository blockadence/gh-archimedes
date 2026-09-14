// Package workspacemap regenerates WORKSPACE-MAP.md's generated repo list
// from an instance's repos.yaml, leaving everything else in the file (most
// importantly the hand-written "## Relationships" section) untouched.
//
// The rewrite is positional: replace every line between the "## Repos"
// heading and the next "## Relationships" heading.
//
// The region is replaced wholesale rather than filtered line by line, which
// is what makes rendering idempotent: re-running against an already-rendered
// map is a no-op, blank lines included. That matters because bootstrap
// regenerates the map on every run.
package workspacemap

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/blockadence/gh-archimedes/internal/dossier"
	"github.com/blockadence/gh-archimedes/internal/manifest"
)

// FileName is the generated map's filename inside an instance.
const FileName = "WORKSPACE-MAP.md"

// DefaultContent is written when WORKSPACE-MAP.md doesn't exist yet.
const DefaultContent = "# Workspace Map\n\n## Repos\n\n## Relationships\n"

const (
	reposHeading         = "## Repos"
	relationshipsHeading = "## Relationships"
)

// RepoLine renders one repo's line in the generated block.
//
// The dossier's location comes from internal/dossier, which owns it, rather
// than being written out here. This row is a link in a file committed to
// the instance and read by teammates and agents, so a path that disagrees
// with where dossiers actually are would be a dead link in a checked-in
// document rather than a run that fails — and writing the layout out here
// is what kept this package out of the check that holds every other reader
// of it (issue 90). RelPath answers the shape a markdown link needs: a path
// relative to the instance root the map sits in. The leading "./" stays
// here, being about the link and not about where the file is.
func RepoLine(r manifest.Repo) string {
	rel := dossier.RelPath(r.Name)
	return fmt.Sprintf("- [%s](%s) — base: `%s`. Dossier: [%s](./%s)",
		r.Name, r.Path, r.BaseBranch, rel, rel)
}

// Render returns existing with the block between "## Repos" and
// "## Relationships" replaced by one RepoLine per repo, in repos' order.
func Render(existing string, repos []manifest.Repo) string {
	lines := strings.Split(existing, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	blockLines := make([]string, len(repos))
	for i, r := range repos {
		blockLines[i] = RepoLine(r)
	}
	block := strings.Join(blockLines, "\n")

	out := make([]string, 0, len(lines)+3)
	skip := false
	for _, line := range lines {
		if strings.HasPrefix(line, reposHeading) {
			out = append(out, line, "", block, "")
			skip = true
			continue
		}
		if strings.HasPrefix(line, relationshipsHeading) {
			skip = false
		}
		if skip {
			continue
		}
		out = append(out, line)
	}

	return strings.Join(out, "\n") + "\n"
}

// Update rewrites root's WORKSPACE-MAP.md generated repo block from repos,
// creating the file from DefaultContent when the instance doesn't have one
// yet. Everything outside the block — most importantly the hand-written
// "## Relationships" section — is carried over untouched.
func Update(root string, repos []manifest.Repo) error {
	path := filepath.Join(root, FileName)

	existing, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("reading %s: %w", path, err)
		}
		existing = []byte(DefaultContent)
	}

	if err := os.WriteFile(path, []byte(Render(string(existing), repos)), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}

	return nil
}
