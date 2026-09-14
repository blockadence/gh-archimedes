package dashboard

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/blockadence/gh-archimedes/internal/contextmap"
	"github.com/blockadence/gh-archimedes/internal/status"
)

// ansiRE matches the escape sequences lipgloss wraps styled text in.
// Assertions are about what the dashboard says, not how it colours it, so
// frames are compared with the styling taken back off.
var ansiRE = regexp.MustCompile("\x1b\\[[0-9;]*m")

func plain(s string) string { return ansiRE.ReplaceAllString(s, "") }

// writeInstance builds an instance root: a repos.yaml naming two sibling
// repos, and one spawned unit of work recorded across both of them.
func writeInstance(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	reposYAML := "repos:\n" +
		"  - name: service-a\n    path: ../service-a\n    base_branch: main\n" +
		"    context_modeled_sha: aaaaaaaabbbbbbbb\n" +
		"  - name: service-b\n    path: ../service-b\n    base_branch: main\n"
	write(t, filepath.Join(dir, "repos.yaml"), reposYAML)

	statusMD := "# widget\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n" +
		"| service-a | widget | /wt/a | based on main |\n" +
		"| service-b | widget | /wt/b | stacked on service-a:auth |\n"
	write(t, filepath.Join(dir, "work", "widget", "status.md"), statusMD)

	// Both checkouts exist, so neither repo reports as uncloned; only
	// service-a carries a context map.
	for _, name := range []string{"service-a", "service-b"} {
		if err := os.MkdirAll(filepath.Join(dir, "..", name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write(t, filepath.Join(dir, "..", "service-a", "CONTEXT.md"), "# service-a\n")

	return dir
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// testOptions reads the fixture instance with git and gh stood in for.
func testOptions(root string) Options {
	return Options{
		Root:         root,
		GuardrailMax: 3,
		Sources: status.Sources{
			PR: func(repoPath, headBranch string) (status.PR, error) {
				if filepath.Base(repoPath) == "service-a" {
					return status.PR{Number: "42", State: "OPEN"}, nil
				}
				return status.PR{Number: "-", State: "no PR"}, nil
			},
			Refs:   noRefs{},
			Merged: func(string, string) bool { return false },
		},
		SHA: func(string, string) (string, error) { return "aaaaaaaabbbbbbbb", nil },
	}
}

type noRefs struct{}

func (noRefs) HasRef(string, string) bool             { return false }
func (noRefs) IsAncestor(string, string, string) bool { return false }

func TestCollectReadsWorktreesAndContextMapsFromTheSameInstance(t *testing.T) {
	root := writeInstance(t)

	snap, err := Collect(testOptions(root))
	if err != nil {
		t.Fatal(err)
	}

	if len(snap.Report.Rows) != 2 {
		t.Fatalf("got %d worktree rows, want 2", len(snap.Report.Rows))
	}
	if snap.Report.Rows[0].PRNumber != "42" || snap.Report.Rows[0].PRState != "OPEN" {
		t.Errorf("row 0 PR = %s/%s, want 42/OPEN", snap.Report.Rows[0].PRNumber, snap.Report.Rows[0].PRState)
	}
	if snap.Report.GuardrailMax != 3 || snap.Report.GuardrailHit {
		t.Errorf("guardrail = %d, hit=%v; want 3, not hit", snap.Report.GuardrailMax, snap.Report.GuardrailHit)
	}

	if len(snap.Repos) != 2 {
		t.Fatalf("got %d repo states, want 2", len(snap.Repos))
	}
	if snap.Repos[0].Stale {
		t.Errorf("service-a should be current: %q", snap.Repos[0].Reason)
	}
	if snap.Repos[1].Reason != "never mapped" {
		t.Errorf("service-b = %q, want \"never mapped\"", snap.Repos[1].Reason)
	}
}

func TestCollectFailsOnlyOnAnUnreadableInstance(t *testing.T) {
	_, err := Collect(testOptions(t.TempDir()))
	if err == nil {
		t.Fatal("expected an error with no repos.yaml to read")
	}
	if !strings.Contains(err.Error(), "repos.yaml") {
		t.Errorf("error = %v, want it to name repos.yaml", err)
	}
}

func TestCollectDegradesAPRLookupFailureToOneRowRatherThanTheWholeReading(t *testing.T) {
	root := writeInstance(t)
	opts := testOptions(root)
	opts.Sources.PR = func(string, string) (status.PR, error) { return status.PR{}, errors.New("gh is not logged in") }

	snap, err := Collect(opts)
	if err != nil {
		t.Fatalf("one unreachable gh must not fail the reading: %v", err)
	}
	for _, row := range snap.Report.Rows {
		if row.PRState != "no PR" {
			t.Errorf("row %s PRState = %q, want the no-PR fallback", row.Slug, row.PRState)
		}
	}
}

func TestCollectDefaultsToAnOfflineLocalReading(t *testing.T) {
	// No SHA lookup configured and no git checkouts behind the paths, so
	// the default LocalSHA is what fails — proving it, not a fetch, is
	// what a reading reaches for.
	root := writeInstance(t)
	opts := testOptions(root)
	opts.SHA = nil

	snap, err := Collect(opts)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range snap.Repos {
		if r.Err == nil {
			t.Errorf("%s: expected a git error from the default local lookup", r.Name)
		}
	}
}

func TestRenderShowsWorktreesAndContextMapsTogether(t *testing.T) {
	root := writeInstance(t)
	snap, err := Collect(testOptions(root))
	if err != nil {
		t.Fatal(err)
	}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 120, Age: 4 * time.Second}))

	for _, want := range []string{
		"WORKTREES", "widget", "service-a", "42", "OPEN", "stacked on service-a:auth",
		"CONTEXT MAPS", "aaaaaaaa", "current", "never mapped",
		"2 streams · guardrail 3", "updated 4s ago", "r refresh · q quit",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("frame is missing %q:\n%s", want, got)
		}
	}
}

func TestRenderFlagsAStackedBranchWhoseBaseHasMerged(t *testing.T) {
	snap := Snapshot{
		Report: status.Report{
			Rows: []status.Row{{
				Slug: "widget", Repo: "service-b", PRNumber: "-", PRState: "no PR",
				Note: "stacked on service-a:auth", NeedsRebase: true, RebaseOnto: "origin/main",
			}},
			Count: 1, GuardrailMax: 3,
		},
	}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 120}))
	// The sentence status owns — "service-b:widget (stacked on
	// service-a:auth) — rebase onto origin/main", note and all — rather
	// than a differently-shaped line for the same condition. Asked of the
	// report rather than spelled out here, so a renderer that goes back to
	// formatting its own fails this even if the wording later changes.
	want := snap.Report.RebaseNeeded()[0].Line()
	if !strings.Contains(got, "Rebase needed") || !strings.Contains(got, want) {
		t.Errorf("expected the rebase list the CLI prints, %q:\n%s", want, got)
	}
}

func TestRenderWarnsWhenTheGuardrailIsExceeded(t *testing.T) {
	var rows []status.Row
	for i := range 5 {
		rows = append(rows, status.Row{Slug: fmt.Sprintf("slug-%d", i), Repo: "service-a", PRNumber: "-", PRState: "no PR"})
	}
	snap := Snapshot{Report: status.Report{Rows: rows, Count: len(rows), GuardrailMax: 3, GuardrailHit: true}}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 120}))
	if !strings.Contains(got, "5 streams · guardrail 3") {
		t.Errorf("expected the guardrail counts in the header:\n%s", got)
	}
	if !strings.Contains(got, "Warning: 5 active worktree streams open, guardrail is 3.") {
		t.Errorf("expected the same warning the CLI prints:\n%s", got)
	}
}

func TestRenderNamesTheThreeUnmappedCasesApart(t *testing.T) {
	snap := Snapshot{Repos: []contextmap.RepoState{
		{Name: "never", Cloned: true, Assessment: contextmap.Assessment{Stale: true, Reason: "never mapped"}},
		{Name: "absent", Cloned: false},
		{Name: "unreadable", Cloned: true, BaseBranch: "main", Err: errors.New("boom")},
	}}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 120}))
	for _, want := range []string{"never mapped", "not cloned yet", "origin/main unreadable"} {
		if !strings.Contains(got, want) {
			t.Errorf("frame is missing %q:\n%s", want, got)
		}
	}
}

func TestRenderKeepsTheLastReadingOnScreenUnderAnError(t *testing.T) {
	snap := Snapshot{Report: status.Report{
		Rows:  []status.Row{{Slug: "widget", Repo: "service-a", PRNumber: "42", PRState: "OPEN"}},
		Count: 1, GuardrailMax: 3,
	}}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 120, Err: errors.New("repos.yaml vanished")}))
	if !strings.Contains(got, "repos.yaml vanished") {
		t.Errorf("expected the error to be shown:\n%s", got)
	}
	if !strings.Contains(got, "widget") {
		t.Errorf("expected the last good reading to survive the error:\n%s", got)
	}
}

func TestRenderSaysSoBeforeTheFirstReadingArrives(t *testing.T) {
	got := plain(Render(Frame{Refreshing: true, Width: 120}))
	if !strings.Contains(got, "Reading the instance") || !strings.Contains(got, "reading...") {
		t.Errorf("expected a loading frame:\n%s", got)
	}
}

func TestRenderNarrowTerminalKeepsRowsOnOneLine(t *testing.T) {
	root := writeInstance(t)
	snap, err := Collect(testOptions(root))
	if err != nil {
		t.Fatal(err)
	}

	got := plain(Render(Frame{Snapshot: snap, Loaded: true, Width: 40}))
	for _, line := range strings.Split(got, "\n") {
		if len([]rune(line)) > DefaultWidth {
			t.Errorf("line runs past the clamped width: %q", line)
		}
	}
}

// clockedModel is a model whose clock the test drives, so a reading can be
// aged without waiting for one.
func clockedModel(t *testing.T, refresh time.Duration, at *time.Time) Model {
	t.Helper()
	m := New(testOptions(writeInstance(t)), refresh)
	m.now = func() time.Time { return *at }
	return m
}

func TestModelShowsAReadingOnceItArrives(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, DefaultRefresh, &at)

	next, _ := m.Update(snapshotMsg{snapshot: Snapshot{Root: "/instance"}})
	frame := next.(Model).Frame()

	if !frame.Loaded || frame.Refreshing {
		t.Fatalf("frame loaded=%v refreshing=%v, want loaded and settled", frame.Loaded, frame.Refreshing)
	}
	at = at.Add(7 * time.Second)
	if age := next.(Model).Frame().Age; age != 7*time.Second {
		t.Errorf("Age = %v, want 7s", age)
	}
}

func TestModelRetakesTheReadingOnceItIsDue(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, 30*time.Second, &at)
	settled, _ := m.Update(snapshotMsg{snapshot: Snapshot{}})

	at = at.Add(29 * time.Second)
	early, _ := settled.(Model).Update(tickMsg(at))
	if early.(Model).refreshing {
		t.Error("a reading was retaken before it was due")
	}

	at = at.Add(2 * time.Second)
	late, _ := early.(Model).Update(tickMsg(at))
	if !late.(Model).refreshing {
		t.Error("a reading past the refresh interval was not retaken")
	}
}

func TestModelNeverStartsASecondReadingOverAnInFlightOne(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, time.Second, &at) // in flight from New

	next, cmd := m.Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if cmd != nil {
		t.Error("expected no second reading while one is in flight")
	}
	if !next.(Model).refreshing {
		t.Error("the in-flight reading was forgotten")
	}
}

func TestModelRefreshesOnDemand(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, 0, &at) // automatic refreshing off
	settled, _ := m.Update(snapshotMsg{snapshot: Snapshot{}})

	if tick, _ := settled.(Model).Update(tickMsg(at.Add(time.Hour))); tick.(Model).refreshing {
		t.Error("--refresh 0 must not retake a reading on its own")
	}

	next, cmd := settled.(Model).Update(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if cmd == nil || !next.(Model).refreshing {
		t.Error("\"r\" did not start a reading")
	}
}

func TestModelRetriesAFailedReadingOnTheRefreshIntervalNotEveryTick(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, 30*time.Second, &at)
	failed, _ := m.Update(snapshotMsg{err: errors.New("gh exploded")})

	at = at.Add(time.Second)
	soon, _ := failed.(Model).Update(tickMsg(at))
	if soon.(Model).refreshing {
		t.Error("a failed reading was retried a second later")
	}

	at = at.Add(30 * time.Second)
	later, _ := soon.(Model).Update(tickMsg(at))
	if !later.(Model).refreshing {
		t.Error("a failed reading was never retried")
	}
}

func TestModelQuitsOnTheUsualKeys(t *testing.T) {
	at := time.Unix(1000, 0)
	for _, key := range []tea.KeyPressMsg{
		{Code: 'q', Text: "q"},
		{Code: tea.KeyEscape},
		{Code: 'c', Mod: tea.ModCtrl},
	} {
		m := clockedModel(t, DefaultRefresh, &at)
		if _, cmd := m.Update(key); cmd == nil {
			t.Errorf("%q did not quit", key.Keystroke())
		} else if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Errorf("%q returned %T, want a quit", key.Keystroke(), cmd())
		}
	}
}

func TestModelDrawsAtTheTerminalWidthItIsToldAbout(t *testing.T) {
	at := time.Unix(1000, 0)
	m := clockedModel(t, DefaultRefresh, &at)

	next, _ := m.Update(tea.WindowSizeMsg{Width: 180, Height: 50})
	if got := next.(Model).Frame().Width; got != 180 {
		t.Errorf("Width = %d, want 180", got)
	}
}
