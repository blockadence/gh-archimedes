package status

import (
	"errors"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/stackref"
	"github.com/blockadence/gh-archimedes/internal/statusfile"
)

func stubRepos(known map[string]string) RepoLookup {
	return func(name string) (RepoRef, error) {
		path, ok := known[name]
		if !ok {
			return RepoRef{}, errors.New("unknown repo: " + name)
		}
		return RepoRef{Path: path, BaseBranch: "main"}, nil
	}
}

func stubLookup(prs map[string]PR) PRLookup {
	return func(repoPath, headBranch string) (PR, error) {
		if pr, ok := prs[repoPath+"@"+headBranch]; ok {
			return pr, nil
		}
		return PR{}, errors.New("no stub for " + repoPath + "@" + headBranch)
	}
}

func TestBuildReportLooksUpEachRow(t *testing.T) {
	rows := []statusfile.Row{
		{Slug: "my-slug", Repo: "service-a", Note: "based on main"},
		{Slug: "my-slug", Repo: "service-b", Note: "stacked on service-a:my-slug"},
	}

	repos := stubRepos(map[string]string{
		"service-a": "/repos/service-a",
		"service-b": "/repos/service-b",
	})
	lookup := stubLookup(map[string]PR{
		"/repos/service-a@my-slug": {Number: "42", State: "OPEN"},
		"/repos/service-b@my-slug": {Number: "-", State: "no PR"},
	})

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: stubRefs{}, Merged: notMerged}, 3)

	want := []Row{
		{Slug: "my-slug", Repo: "service-a", PRNumber: "42", PRState: "OPEN", Note: "based on main"},
		{Slug: "my-slug", Repo: "service-b", PRNumber: "-", PRState: "no PR", Note: "stacked on service-a:my-slug"},
	}
	if len(got.Rows) != len(want) {
		t.Fatalf("expected %d rows, got %d: %#v", len(want), len(got.Rows), got.Rows)
	}
	for i := range want {
		if got.Rows[i] != want[i] {
			t.Errorf("row %d mismatch\n got: %#v\nwant: %#v", i, got.Rows[i], want[i])
		}
	}
	if got.Count != 2 {
		t.Errorf("expected count 2, got %d", got.Count)
	}
	if got.GuardrailHit {
		t.Errorf("expected guardrail not hit at count=2, max=3")
	}
}

func TestBuildReportDegradesFailedLookupsToNoPR(t *testing.T) {
	rows := []statusfile.Row{
		{Slug: "my-slug", Repo: "unknown-repo", Note: "note"},
	}
	repos := stubRepos(map[string]string{})
	lookup := stubLookup(map[string]PR{})

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: stubRefs{}, Merged: notMerged}, 3)

	want := Row{Slug: "my-slug", Repo: "unknown-repo", PRNumber: "-", PRState: "no PR", Note: "note"}
	if got.Rows[0] != want {
		t.Errorf("row mismatch\n got: %#v\nwant: %#v", got.Rows[0], want)
	}
}

func TestBuildReportGuardrail(t *testing.T) {
	rows := make([]statusfile.Row, 4)
	for i := range rows {
		rows[i] = statusfile.Row{Slug: "slug", Repo: "repo"}
	}
	repos := stubRepos(map[string]string{"repo": "/repos/repo"})
	lookup := stubLookup(map[string]PR{"/repos/repo@slug": {Number: "-", State: "no PR"}})

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: stubRefs{}, Merged: notMerged}, 3)

	if got.Count != 4 {
		t.Errorf("expected count 4, got %d", got.Count)
	}
	if !got.GuardrailHit {
		t.Errorf("expected guardrail hit at count=4, max=3")
	}
}

func TestFormatHuman(t *testing.T) {
	report := Report{
		Rows: []Row{
			{Slug: "my-slug", Repo: "service-a", PRNumber: "42", PRState: "OPEN", Note: "based on main"},
		},
		Count:        1,
		GuardrailMax: 3,
		GuardrailHit: false,
	}

	got := FormatHuman(report)
	want := "SLUG                 REPO           PR#      STATE      NOTE                          \n" +
		"my-slug              service-a      42       OPEN       based on main                 \n" +
		"\n"

	if got != want {
		t.Errorf("FormatHuman mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestParseGuardrailMax(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want int
	}{
		{"unset defaults to 3", "", 3},
		{"valid override", "5", 5},
		{"non-numeric falls back to default", "not-a-number", 3},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ParseGuardrailMax(tt.raw); got != tt.want {
				t.Errorf("ParseGuardrailMax(%q) = %d, want %d", tt.raw, got, tt.want)
			}
		})
	}
}

func TestFormatHumanIncludesGuardrailWarning(t *testing.T) {
	report := Report{
		Rows:         nil,
		Count:        4,
		GuardrailMax: 3,
		GuardrailHit: true,
	}

	got := FormatHuman(report)
	if !strings.Contains(got, "Warning: 4 active worktree streams open, guardrail is 3. Consider closing some out.") {
		t.Errorf("expected guardrail warning in output, got: %q", got)
	}
}

func TestBuildReportFlagsStackedRowWhoseBaseHasMerged(t *testing.T) {
	rows := []statusfile.Row{
		{Slug: "auth-ui", Repo: "service-a", Branch: "auth-ui", Note: "stacked on service-a:auth-api"},
		{Slug: "auth-ui", Repo: "service-b", Branch: "auth-ui", Note: "based on main"},
	}
	repos := stubRepos(map[string]string{
		"service-a": "/repos/service-a",
		"service-b": "/repos/service-b",
	})
	lookup := stubLookup(map[string]PR{
		"/repos/service-a@auth-ui": {Number: "7", State: "OPEN"},
		"/repos/service-b@auth-ui": {Number: "8", State: "OPEN"},
	})
	// auth-ui still carries auth-api's commits, and origin/main has that
	// work under new SHAs — the state a squash merge leaves.
	refs := stubRefs{
		present: map[string]bool{
			"/repos/service-a@auth-ui":     true,
			"/repos/service-a@auth-api":    true,
			"/repos/service-a@origin/main": true,
			"/repos/service-b@auth-ui":     true,
			"/repos/service-b@origin/main": true,
		},
		ancestors: map[string]bool{"/repos/service-a@auth-api..auth-ui": true},
	}

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: refs, Merged: merged}, 3)

	if !got.Rows[0].NeedsRebase {
		t.Errorf("expected the stacked row to be flagged, got: %#v", got.Rows[0])
	}
	if got.Rows[0].RebaseOnto != "origin/main" {
		t.Errorf("expected rebase target origin/main, got %q", got.Rows[0].RebaseOnto)
	}
	if got.Rows[1].NeedsRebase {
		t.Errorf("expected the never-stacked row to be left alone, got: %#v", got.Rows[1])
	}
}

func TestBuildReportClearsFlagOnceRebased(t *testing.T) {
	rows := []statusfile.Row{
		{Slug: "auth-ui", Repo: "service-a", Branch: "auth-ui", Note: "stacked on service-a:auth-api"},
	}
	repos := stubRepos(map[string]string{"service-a": "/repos/service-a"})
	lookup := stubLookup(map[string]PR{"/repos/service-a@auth-ui": {Number: "7", State: "OPEN"}})
	// The rebase replayed auth-ui's own commits onto origin/main, so
	// auth-api's are no longer in its history.
	refs := stubRefs{present: map[string]bool{
		"/repos/service-a@auth-ui":     true,
		"/repos/service-a@auth-api":    true,
		"/repos/service-a@origin/main": true,
	}}

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: refs, Merged: merged}, 3)

	if got.Rows[0].NeedsRebase {
		t.Errorf("expected no flag after the branch was rebased, got: %#v", got.Rows[0])
	}
	if got.Rows[0].RebaseOnto != "" {
		t.Errorf("expected no rebase target on an unflagged row, got %q", got.Rows[0].RebaseOnto)
	}
}

func TestBuildReportFallsBackToSlugWhenBranchColumnIsEmpty(t *testing.T) {
	rows := []statusfile.Row{
		{Slug: "auth-ui", Repo: "service-a", Note: "stacked on service-a:auth-api"},
	}
	repos := stubRepos(map[string]string{"service-a": "/repos/service-a"})
	lookup := stubLookup(map[string]PR{"/repos/service-a@auth-ui": {Number: "7", State: "OPEN"}})
	refs := stubRefs{
		present: map[string]bool{
			"/repos/service-a@auth-ui":     true,
			"/repos/service-a@auth-api":    true,
			"/repos/service-a@origin/main": true,
		},
		ancestors: map[string]bool{"/repos/service-a@auth-api..auth-ui": true},
	}

	got := BuildReport(rows, Sources{Repos: repos, PR: lookup, Refs: refs, Merged: merged}, 3)

	if !got.Rows[0].NeedsRebase {
		t.Errorf("expected the slug to stand in for a missing branch column, got: %#v", got.Rows[0])
	}
}

func TestFormatHumanListsRebaseNeededRows(t *testing.T) {
	report := Report{
		Rows: []Row{
			{Slug: "auth-ui", Repo: "service-a", PRNumber: "7", PRState: "OPEN", Note: "stacked on service-a:auth-api", NeedsRebase: true, RebaseOnto: "origin/main"},
			{Slug: "auth-ui", Repo: "service-b", PRNumber: "8", PRState: "OPEN", Note: "based on main"},
		},
		Count:        2,
		GuardrailMax: 3,
	}

	got := FormatHuman(report)
	if !strings.Contains(got, "Rebase needed") {
		t.Errorf("expected a rebase-needed section, got:\n%s", got)
	}
	if !strings.Contains(got, "service-a:auth-ui (stacked on service-a:auth-api) — rebase onto origin/main") {
		t.Errorf("expected the flagged row spelled out, got:\n%s", got)
	}
	if strings.Contains(got, "service-b (based on main)") {
		t.Errorf("expected unflagged rows left out of the section, got:\n%s", got)
	}
}

func TestRebaseNeededNamesTheDependentTheSameWayAsItsBase(t *testing.T) {
	report := Report{Rows: []Row{{
		Slug: "auth-ui", Repo: "service-a",
		Note:        stackref.Note(stackref.Ref{Repo: "service-a", Slug: "auth-api"}),
		NeedsRebase: true, RebaseOnto: "origin/main",
	}}}

	flagged := report.RebaseNeeded()
	if len(flagged) != 1 {
		t.Fatalf("RebaseNeeded() returned %d rebases, want 1", len(flagged))
	}

	want := "service-a:auth-ui (stacked on service-a:auth-api) — rebase onto origin/main"
	if got := flagged[0].Line(); got != want {
		t.Errorf("Line() = %q, want %q", got, want)
	}
}

// A flagged row whose note names no base can't happen out of BuildReport,
// which only flags a row stackref could read a base out of. It can happen
// to any other hand on Row, whose fields are all settable — and what used
// to come of it was the sentence with its middle missing.
func TestRebaseNeededLeavesOutAFlaggedRowThatNamesNoBase(t *testing.T) {
	report := Report{Rows: []Row{
		{Slug: "auth-ui", Repo: "service-a", Note: "based on main", NeedsRebase: true},
		{Slug: "widget", Repo: "service-b", NeedsRebase: true, RebaseOnto: "origin/main"},
	}}

	if flagged := report.RebaseNeeded(); len(flagged) != 0 {
		t.Errorf("RebaseNeeded() = %+v, want nothing for rows with no base", flagged)
	}
	if got := FormatHuman(report); strings.Contains(got, "Rebase needed") {
		t.Errorf("expected no rebase-needed block without a base to name, got:\n%s", got)
	}
}
