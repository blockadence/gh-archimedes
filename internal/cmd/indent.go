package cmd

import "strings"

// indent puts git's own words where a notice quotes them: two spaces in, on
// however many lines git wrote them.
//
// Here rather than in the command that first needed it, because setting
// git's sentence in from the tool's own is one decision two commands make.
// `init` quotes git's refusal of an instance's first commit (issue 39);
// `prune` quotes git's objection to a worktree it will not remove, under
// the candidate it belongs to (issue 47). Both are the same thing seen
// twice — git's words handed over as git's, indented to say so — and
// gitutil.Reason already owns the other half of it: what git said, with
// none of our wrapping around it. This owns where it sits, so a reader
// changing the step can see that both notices change with it.
func indent(text string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if line != "" {
			lines[i] = "  " + line
		}
	}
	return strings.Join(lines, "\n")
}

// indentUnder quotes git under a line that is itself already a step in, for
// a notice nested inside an entry: `prune` prints `  not removed:` against
// the candidate it belongs to, and git's reason has to clear that step as
// well as its own to still read as that entry's rather than the run's.
//
// Two named depths rather than a prefix the caller passes, because a caller
// spelling out spaces is a caller deciding how far in the tool sets git's
// words, and then there is no one place to read what that is. And here
// rather than owned by whatever prints prune's `not removed:` line, because
// what the two commands share is the step itself — the deeper of the two is
// still that step, taken twice, and giving prune's printer the depth would
// put half of it back in the command that happens to need it.
func indentUnder(text string) string {
	return indent(indent(text))
}
