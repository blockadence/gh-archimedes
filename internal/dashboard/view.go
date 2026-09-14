package dashboard

import (
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/blockadence/gh-archimedes/internal/contextmap"
	"github.com/blockadence/gh-archimedes/internal/invocation"
)

// DefaultWidth is what a frame is drawn at before the terminal has told us
// how wide it is, and the floor a very narrow terminal is clamped to —
// below it the columns stop being a table at all, and a little horizontal
// overflow beats a shredded one.
const DefaultWidth = 100

// Frame is one screen: a snapshot plus the state around it that isn't part
// of the instance — how old the reading is, whether the next one is already
// in flight, and what went wrong if it did.
//
// Age rather than a timestamp, so rendering stays a pure function of its
// input and needs no clock of its own.
type Frame struct {
	Snapshot Snapshot
	Width    int
	// Loaded is false until the first reading arrives.
	Loaded bool
	// Refreshing reports that a reading is in flight. The previous one
	// stays on screen while it is, so the dashboard never blanks.
	Refreshing bool
	// Age is how long ago Snapshot was collected.
	Age time.Duration
	// Err is the last collection failure. It's shown alongside the last
	// good snapshot rather than replacing it, since a stale reading plus a
	// visible error beats an empty screen.
	Err error
}

// Colours are the terminal's own ANSI 0-7, not fixed hex, so the dashboard
// inherits whatever palette the operator's theme already establishes for
// "wrong", "attention" and "fine" instead of fighting it.
var (
	styleTitle   = lipgloss.NewStyle().Bold(true)
	styleHeading = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	styleDim     = lipgloss.NewStyle().Faint(true)
	styleGood    = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleWarn    = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styleBad     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleMerged  = lipgloss.NewStyle().Foreground(lipgloss.Color("5"))
)

// Render draws one frame. It is a plain function over data: no terminal, no
// clock, no I/O — everything it needs is in f.
func Render(f Frame) string {
	width := f.Width
	if width < DefaultWidth {
		width = DefaultWidth
	}

	var b strings.Builder
	b.WriteString(header(f, width))
	b.WriteString("\n\n")

	if !f.Loaded && f.Err == nil {
		b.WriteString(indent(styleDim.Render("Reading the instance...")))
		b.WriteString("\n\n")
		b.WriteString(footer())
		return b.String()
	}

	if f.Err != nil {
		b.WriteString(indent(styleBad.Render("Could not read the instance: " + f.Err.Error())))
		b.WriteString("\n\n")
	}
	if !f.Loaded {
		b.WriteString(footer())
		return b.String()
	}

	b.WriteString(worktrees(f.Snapshot, width))
	b.WriteString("\n")
	b.WriteString(contextMaps(f.Snapshot, width))
	b.WriteString("\n")
	if f.Snapshot.OrderWarning != "" {
		b.WriteString(indent(styleWarn.Render(f.Snapshot.OrderWarning)))
		b.WriteString("\n\n")
	}
	b.WriteString(footer())

	return b.String()
}

// header is the title bar: which instance is on screen, on the left, and
// how it's doing overall plus how fresh the reading is, on the right.
func header(f Frame, width int) string {
	var right string
	if f.Loaded {
		r := f.Snapshot.Report
		streams := fmt.Sprintf("%d streams · guardrail %d · ", r.Count, r.GuardrailMax)
		if r.GuardrailHit {
			right = styleWarn.Render(streams)
		} else {
			right = styleDim.Render(streams)
		}
	}
	right += styleDim.Render(freshness(f))

	// The instance path is the only part of the header with no bound on
	// its length, so it's what gives way on a narrow terminal — from the
	// front, since the tail is the instance's own directory name.
	name := styleTitle.Render("archimedes")
	left := name
	if room := width - 1 - lipgloss.Width(name) - 2 - lipgloss.Width(right) - 1; room > 0 {
		left += styleDim.Render("  " + tail(f.Snapshot.Root, room))
	}

	gap := width - 1 - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return " " + left + strings.Repeat(" ", gap) + right
}

// tail keeps the last w columns of s, marking anything dropped off the
// front with an ellipsis.
func tail(s string, w int) string {
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	if w <= 1 {
		return string(r[len(r)-w:])
	}
	return "…" + string(r[len(r)-(w-1):])
}

// freshness describes the reading's age, and says so even while the next
// one is in flight — a refresh that hangs on an unreachable gh should read
// as "refreshing, and what you're looking at is a minute old", not as a
// spinner with no history behind it.
func freshness(f Frame) string {
	switch {
	case f.Refreshing && !f.Loaded:
		return "reading..."
	case f.Refreshing:
		return "refreshing, showing " + formatAge(f.Age)
	case !f.Loaded:
		return ""
	default:
		return "updated " + formatAge(f.Age)
	}
}

func formatAge(d time.Duration) string {
	switch {
	case d < 2*time.Second:
		return "just now"
	case d < time.Minute:
		return fmt.Sprintf("%ds ago", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	default:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
}

// worktrees is the same table `archimedes status` prints, plus the same
// rebase-needed list under it — read from the same status.Report, so the
// two can't drift apart.
func worktrees(s Snapshot, width int) string {
	var b strings.Builder
	b.WriteString(section("WORKTREES"))

	if len(s.Report.Rows) == 0 {
		b.WriteString(indent(styleDim.Render("Nothing spawned yet — " + invocation.Name() + " spawn <slug> <repo>.")))
		b.WriteString("\n")
		return b.String()
	}

	// The note is the widest and least structured field, so it takes
	// whatever the fixed columns leave and is truncated rather than
	// wrapped: a row stays one line however long a stack note gets.
	noteW := width - 1 - (20 + 1 + 14 + 1 + 6 + 1 + 9 + 1)
	if noteW < 10 {
		noteW = 10
	}

	b.WriteString(indent(styleDim.Render(row(
		cell("SLUG", 20), cell("REPO", 14), cell("PR#", 6), cell("STATE", 9), cell("NOTE", noteW)))))
	b.WriteString("\n")

	for _, r := range s.Report.Rows {
		note := cell(r.Note, noteW)
		if r.NeedsRebase {
			note = styleWarn.Render(note)
		}
		b.WriteString(indent(row(
			cell(r.Slug, 20),
			styleDim.Render(cell(r.Repo, 14)),
			cell(r.PRNumber, 6),
			prStyle(r.PRState).Render(cell(r.PRState, 9)),
			note)))
		b.WriteString("\n")
	}

	if s.Report.GuardrailHit {
		b.WriteString("\n")
		b.WriteString(indent(styleWarn.Render(fmt.Sprintf(
			"Warning: %d active worktree streams open, guardrail is %d. Consider closing some out.",
			s.Report.Count, s.Report.GuardrailMax))))
		b.WriteString("\n")
	}

	flagged := s.Report.RebaseNeeded()
	if len(flagged) == 0 {
		return b.String()
	}

	b.WriteString("\n")
	b.WriteString(indent(styleWarn.Render("Rebase needed — these branches are stacked on a base that has since merged:")))
	b.WriteString("\n")
	for _, r := range flagged {
		b.WriteString(indent("  " + styleWarn.Render(r.Line())))
		b.WriteString("\n")
	}

	return b.String()
}

// prStyle colours a PR state by what it asks of the operator: nothing for
// a state that's simply true (merged, closed), attention for one still
// live, and none at all where there's no PR to have a state.
func prStyle(state string) lipgloss.Style {
	switch strings.ToUpper(state) {
	case "OPEN":
		return styleGood
	case "MERGED":
		return styleMerged
	case "CLOSED":
		return styleDim
	default:
		return styleDim
	}
}

// contextMaps is the per-repo staleness `archimedes context-map --dry-run`
// reports, read from the same contextmap.Assess — the difference is only
// that this one doesn't fetch, so looking never costs a round trip.
func contextMaps(s Snapshot, width int) string {
	var b strings.Builder
	b.WriteString(section("CONTEXT MAPS"))

	if len(s.Repos) == 0 {
		b.WriteString(indent(styleDim.Render("No repos in repos.yaml — " + invocation.Name() + " bootstrap <org>.")))
		b.WriteString("\n")
		return b.String()
	}

	stateW := width - 1 - (20 + 1 + 10 + 1)
	if stateW < 10 {
		stateW = 10
	}

	b.WriteString(indent(styleDim.Render(row(cell("REPO", 20), cell("MAPPED", 10), cell("STATE", stateW)))))
	b.WriteString("\n")

	for _, r := range s.Repos {
		label, style := mapState(r)
		mapped := contextmap.Short(r.MappedSHA)
		if mapped == "" {
			mapped = "-"
		}
		b.WriteString(indent(row(
			cell(r.Name, 20),
			styleDim.Render(cell(mapped, 10)),
			style.Render(cell(label, stateW)))))
		b.WriteString("\n")
	}

	return b.String()
}

// mapState reduces one repo's context-map state to the label its row shows
// and how much it should stand out.
//
// The two unassessable cases are kept apart from staleness on purpose:
// they're not "this map is old", they're "nobody can tell", and they call
// for different fixes — a bootstrap and a fetch respectively, neither of
// which a mapping pass would do for you.
func mapState(r contextmap.RepoState) (string, lipgloss.Style) {
	switch {
	case !r.Cloned:
		return "not cloned yet", styleBad
	case r.Err != nil:
		return "origin/" + r.BaseBranch + " unreadable", styleBad
	case r.Stale:
		return r.Reason, styleWarn
	default:
		return "current", styleGood
	}
}

func footer() string {
	return indent(styleDim.Render("r refresh · q quit"))
}

func section(title string) string {
	return indent(styleHeading.Render(title)) + "\n"
}

// indent gives every line the one-column left margin the frame is drawn
// with, so content never starts hard against the terminal edge.
func indent(s string) string { return " " + s }

// row joins already-padded cells with the single space between columns.
func row(cells ...string) string { return strings.Join(cells, " ") }

// cell fits s into exactly w columns: padded with spaces if short,
// truncated with an ellipsis if long. Called before styling, so the padding
// is plain text and can't smear a colour across the gap between columns.
func cell(s string, w int) string {
	r := []rune(s)
	switch {
	case len(r) == w:
		return s
	case len(r) < w:
		return s + strings.Repeat(" ", w-len(r))
	case w <= 1:
		return string(r[:w])
	default:
		return string(r[:w-1]) + "…"
	}
}
