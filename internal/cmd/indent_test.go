package cmd

import "testing"

// These pin the two depths the notices are written against, because that is
// the whole of what this helper decides. The commands' own tests pin what
// reaches the operator; these pin the step itself, so a change to it is a
// failing test here rather than a notice that reads differently.

// One step in is what a quote takes from the line that introduces it, and
// git's words arrive as however many lines git wrote them on.
func TestIndentSetsEveryLineOneStepIn(t *testing.T) {
	got := indent("fatal: cannot remove a locked working tree\nUse --force twice")
	want := "  fatal: cannot remove a locked working tree\n  Use --force twice"
	if got != want {
		t.Errorf("indent = %q, want %q", got, want)
	}
}

// A blank line stays blank: trailing whitespace on an otherwise empty line
// is invisible to the operator and visible to everything that diffs output.
func TestIndentLeavesBlankLinesAlone(t *testing.T) {
	got := indent("first\n\nsecond")
	want := "  first\n\n  second"
	if got != want {
		t.Errorf("indent = %q, want %q", got, want)
	}
}

// `prune`'s quote sits under a line that is itself under a candidate, so it
// clears both steps rather than the one.
func TestIndentUnderClearsTheStepItSitsUnderAsWell(t *testing.T) {
	got := indentUnder("fatal: cannot remove a locked working tree")
	want := "    fatal: cannot remove a locked working tree"
	if got != want {
		t.Errorf("indentUnder = %q, want %q", got, want)
	}
}
