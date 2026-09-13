package prune_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/prune"
	"github.com/blockadence/gh-archimedes/internal/stackref"
	"github.com/blockadence/gh-archimedes/internal/statusfile"
)

// writeStatus puts one unit of work's status.md where an instance keeps
// it, under root/work/<slug>/, and returns its path.
func writeStatus(t *testing.T, root, slug, body string) string {
	t.Helper()
	slugDir := filepath.Join(root, "work", slug)
	if err := os.MkdirAll(slugDir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(slugDir, "status.md")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// statusBody spells the file's preamble out rather than building it with
// internal/statusfile: a fixture that agrees with whatever produces it
// cannot catch that producer changing.
func statusBody(slug string, rows ...string) string {
	body := "# " + slug + "\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n"
	for _, r := range rows {
		body += r + "\n"
	}
	return body
}

func alwaysMerged(_, _ string) (string, error) { return "MERGED", nil }

func TestScanFindsMergedCandidate(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | ../service-a-worktrees/widget-fix | based on main |",
	))

	items, err := prune.Scan(dir, "", alwaysMerged)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("got %d items, want 1", len(items))
	}
	it := items[0]
	// The worktree git is about to be handed comes back resolved against
	// the instance root, not as the "../" the row carries.
	want := filepath.Join(filepath.Dir(dir), "service-a-worktrees", "widget-fix")
	if it.Slug != "widget-fix" || it.Repo != "service-a" || it.Worktree != want {
		t.Errorf("item = %+v, want its worktree at %q", it, want)
	}
	if !it.Prunable() {
		t.Errorf("expected item to be prunable, got blockers: %v", it.Blockers)
	}
}

// An instance spawned into before the column was relative still prunes on
// the machine that spawned it: its rows name a path that is true there,
// and joining them onto the root would break exactly that case.
func TestScanReadsAnAbsoluteRowAsItStands(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /Users/someone/Code/service-a-worktrees/widget-fix | based on main |",
	))

	items, err := prune.Scan(dir, "", alwaysMerged)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Worktree != "/Users/someone/Code/service-a-worktrees/widget-fix" {
		t.Fatalf("got %+v, want the row's own absolute path", items)
	}
}

func TestScanIgnoresOpenAndUnknownPRs(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/service-a | based on main |",
	))

	open := func(_, _ string) (string, error) { return "OPEN", nil }
	items, err := prune.Scan(dir, "", open)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("got %d items, want 0 for an open PR", len(items))
	}

	none := func(_, _ string) (string, error) { return "NONE", nil }
	items, err = prune.Scan(dir, "", none)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("got %d items, want 0 when there's no PR", len(items))
	}
}

func TestScanTreatsLookupErrorAsNone(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/service-a | based on main |",
	))

	failing := func(_, _ string) (string, error) { return "", errBoom }
	items, err := prune.Scan(dir, "", failing)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("got %d items, want 0 when the PR lookup fails", len(items))
	}
}

func TestScanFiltersBySlug(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/a | based on main |",
	))
	writeStatus(t, dir, "other-fix", statusBody("other-fix",
		"| service-a | other-fix | /wt/b | based on main |",
	))

	items, err := prune.Scan(dir, "widget-fix", alwaysMerged)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Slug != "widget-fix" {
		t.Fatalf("got %+v, want just widget-fix", items)
	}
}

func TestScanRefusesToPruneAStackedBase(t *testing.T) {
	dir := t.TempDir()
	// widget-fix/service-a has merged, but shim-fix stacks on it.
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/widget-fix | based on main |",
	))
	writeStatus(t, dir, "shim-fix", statusBody("shim-fix",
		"| service-a | shim-fix | /wt/shim-fix | stacked on service-a:widget-fix |",
	))

	items, err := prune.Scan(dir, "", alwaysMerged)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("got %d items, want 2 (both merged rows)", len(items))
	}

	byRepo := map[string]prune.Item{}
	for _, it := range items {
		byRepo[it.Slug] = it
	}

	base := byRepo["widget-fix"]
	if base.Prunable() {
		t.Errorf("expected widget-fix:service-a to be blocked, got prunable")
	}
	if len(base.Blockers) != 1 || base.Blockers[0] != filepath.Join(dir, "work", "shim-fix", "status.md") {
		t.Errorf("unexpected blockers: %v", base.Blockers)
	}

	// shim-fix itself has nothing stacked on it, so it stays prunable.
	if !byRepo["shim-fix"].Prunable() {
		t.Errorf("expected shim-fix to remain prunable")
	}
}

func TestRemoveStatusRowDropsOnlyMatchingRepo(t *testing.T) {
	dir := t.TempDir()
	path := writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/a | based on main |",
		"| service-b | widget-fix | /wt/b | stacked on service-a:widget-fix |",
	))

	if err := prune.RemoveStatusRow(path, "service-a"); err != nil {
		t.Fatal(err)
	}

	rows := statusfile.Parse(readFile(t, path), "widget-fix")
	if len(rows) != 1 || rows[0].Repo != "service-b" {
		t.Fatalf("got rows %+v, want only service-b left", rows)
	}
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

type boomErr struct{}

func (boomErr) Error() string { return "boom" }

var errBoom = boomErr{}

// A note the operator has re-spaced — an editor's table formatter, a hand
// alignment — still names the base it names. prune decides whether a
// merged branch is somebody's stacked base, and it is the side that
// destroys work, so it must not read the spacing.
func TestScanRefusesToPruneAStackedBaseWhoseNoteWasRespaced(t *testing.T) {
	dir := t.TempDir()
	writeStatus(t, dir, "widget-fix", statusBody("widget-fix",
		"| service-a | widget-fix | /wt/widget-fix | based on main |",
	))
	writeStatus(t, dir, "shim-fix", statusBody("shim-fix",
		"| service-a | shim-fix | /wt/shim-fix | stacked  on   service-a:widget-fix |",
	))

	items, err := prune.Scan(dir, "", alwaysMerged)
	if err != nil {
		t.Fatal(err)
	}

	for _, it := range items {
		if it.Slug == "widget-fix" && it.Prunable() {
			t.Errorf("widget-fix is still shim-fix's base; got prunable")
		}
	}
}

func TestItemNamesItselfAsTheRepoSlugPair(t *testing.T) {
	it := prune.Item{Repo: "service-a", Slug: "widget-fix"}

	if want := (stackref.Ref{Repo: "service-a", Slug: "widget-fix"}); it.Ref() != want {
		t.Errorf("Item.Ref() = %+v, want %+v", it.Ref(), want)
	}
}
