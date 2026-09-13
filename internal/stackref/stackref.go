// Package stackref owns how a unit of work records that it was stacked on
// another: the "<repo>:<slug>" pair spawn accepts on --stack-on, the
// "stacked on <repo>:<slug>" note it writes into work/<slug>/status.md,
// and the two readers of that note — prune, which refuses to remove a base
// something is still sitting on, and status, which flags a base that has
// merged out from under its dependents. One package so the note's wording
// can't drift between the code that writes it and the code that matches it.
package stackref

import "strings"

// Ref identifies the unit of work a branch is stacked on top of: which
// repo's work it belongs to, and its slug (which is also its branch name).
type Ref struct {
	Repo string
	Slug string
}

// ParseFlag splits a --stack-on value on its first ":": a value with no
// ":" yields a non-empty Repo and an empty Slug rather than an error.
func ParseFlag(value string) Ref {
	if value == "" {
		return Ref{}
	}
	repo, slug, _ := strings.Cut(value, ":")
	return Ref{Repo: repo, Slug: slug}
}

// String is the "<repo>:<slug>" pair itself — what --stack-on takes, what
// a note carries, and how any other reader names one unit of work in one
// repo. Here rather than formatted at each call site for the same reason
// the note's wording is: the pair's shape has one owner.
// That includes the pair inside an English sentence, the one case that
// looked like an exception: an operator who cannot tell one line's
// service-a:widget-fix from the next one's is being told they are the same
// thing by the formatting rather than by anything that holds (issue 78).
func (r Ref) String() string { return r.Repo + ":" + r.Slug }

// notePrefix opens every note describing a stacked branch. Anything else
// ("based on main") describes a branch cut straight from its repo's base
// branch.
const notePrefix = "stacked on "

// Note is the status.md note recording that a branch was stacked on r.
func Note(r Ref) string {
	return notePrefix + r.String()
}

// ParseNote reads back what Note wrote. Every other note — including a
// malformed one missing either half of the pair — reports false, so a unit
// of work that was never stacked is never mistaken for one that was.
func ParseNote(note string) (Ref, bool) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(note), notePrefix)
	if !ok {
		return Ref{}, false
	}

	repo, slug, found := strings.Cut(strings.TrimSpace(rest), ":")
	if !found || repo == "" || slug == "" {
		return Ref{}, false
	}
	return Ref{Repo: repo, Slug: slug}, true
}
