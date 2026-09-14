package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/status"
)

func writeInstanceFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()

	reposYAML := "repos:\n" +
		"  - name: service-a\n" +
		"    path: ../service-a\n" +
		"    base_branch: main\n" +
		"  - name: service-b\n" +
		"    path: ../service-b\n" +
		"    base_branch: main\n"
	if err := os.WriteFile(filepath.Join(dir, "repos.yaml"), []byte(reposYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	slugDir := filepath.Join(dir, "work", "my-slug")
	if err := os.MkdirAll(slugDir, 0o755); err != nil {
		t.Fatal(err)
	}
	statusMD := "# my-slug\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n" +
		"| service-a | my-slug | /wt/service-a | based on main |\n" +
		"| service-b | my-slug | /wt/service-b | stacked on service-a:auth-api |\n"
	if err := os.WriteFile(filepath.Join(slugDir, "status.md"), []byte(statusMD), 0o644); err != nil {
		t.Fatal(err)
	}

	return dir
}

// plainSources reports no rebase state at all, for the tests that only
// care about the table and the guardrail.
func plainSources() status.Sources {
	return status.Sources{
		PR:     fixtureLookup,
		Refs:   noRefs{},
		Merged: func(repoPath, headBranch string) bool { return false },
	}
}

type noRefs struct{}

func (noRefs) HasRef(repoPath, ref string) bool                      { return false }
func (noRefs) IsAncestor(repoPath, ancestor, descendant string) bool { return false }

func fixtureLookup(repoPath, headBranch string) (status.PR, error) {
	if filepath.Base(repoPath) == "service-a" {
		return status.PR{Number: "42", State: "OPEN"}, nil
	}
	return status.PR{Number: "-", State: "no PR"}, nil
}

func TestRunStatusHumanTable(t *testing.T) {
	dir := writeInstanceFixture(t)

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", false, plainSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	got := buf.String()
	for _, want := range []string{
		"SLUG", "REPO", "PR#", "STATE", "NOTE",
		"my-slug              service-a      42       OPEN       based on main",
		"my-slug              service-b      -        no PR      stacked on service-a:auth-api",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("expected output to contain %q, got:\n%s", want, got)
		}
	}
}

// An instance spawned before the pr column was dropped has rows with a
// fifth cell in them, committed to a git repository this one does not own.
// They go on reporting as the rows they are, and the state reported is the
// live one either way — the cell was never where it came from.
func TestRunStatusReadsAFileWrittenBeforeTheColumnWentAway(t *testing.T) {
	dir := writeInstanceFixture(t)

	legacy := "# my-slug\n\n| repo | branch | worktree | note | pr |\n|---|---|---|---|---|\n" +
		"| service-a | my-slug | /wt/service-a | based on main | - |\n" +
		"| service-b | my-slug | /wt/service-b | stacked on service-a:auth-api | 7 |\n"
	if err := os.WriteFile(filepath.Join(dir, "work", "my-slug", "status.md"), []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", false, plainSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	got := buf.String()
	for _, want := range []string{
		"my-slug              service-a      42       OPEN       based on main",
		"my-slug              service-b      -        no PR      stacked on service-a:auth-api",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("expected output to contain %q, got:\n%s", want, got)
		}
	}
}

func TestRunStatusFiltersBySlug(t *testing.T) {
	dir := writeInstanceFixture(t)

	slugDir := filepath.Join(dir, "work", "other-slug")
	if err := os.MkdirAll(slugDir, 0o755); err != nil {
		t.Fatal(err)
	}
	statusMD := "# other-slug\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n" +
		"| service-a | other-slug | /wt/service-a-2 | based on main |\n"
	if err := os.WriteFile(filepath.Join(slugDir, "status.md"), []byte(statusMD), 0o644); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "my-slug", false, plainSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	got := buf.String()
	if strings.Contains(got, "other-slug") {
		t.Errorf("expected other-slug to be filtered out, got:\n%s", got)
	}
	if !strings.Contains(got, "my-slug") {
		t.Errorf("expected my-slug in output, got:\n%s", got)
	}
}

func TestRunStatusJSON(t *testing.T) {
	dir := writeInstanceFixture(t)

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", true, plainSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	var report status.Report
	if err := json.Unmarshal(buf.Bytes(), &report); err != nil {
		t.Fatalf("output isn't valid JSON: %v\n%s", err, buf.String())
	}

	if report.Count != 2 {
		t.Errorf("expected count 2, got %d", report.Count)
	}
	want := status.Row{Slug: "my-slug", Repo: "service-a", PRNumber: "42", PRState: "OPEN", Note: "based on main"}
	if report.Rows[0] != want {
		t.Errorf("row mismatch\n got: %#v\nwant: %#v", report.Rows[0], want)
	}
}

func TestRunStatusMissingManifestErrors(t *testing.T) {
	dir := t.TempDir()

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", false, plainSources()); err == nil {
		t.Fatal("expected error when repos.yaml is missing, got nil")
	}
}

func TestRunStatusGuardrailWarning(t *testing.T) {
	dir := writeInstanceFixture(t)
	t.Setenv("ARCHIMEDES_MAX_STREAMS", "1")

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", false, plainSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	got := buf.String()
	if !strings.Contains(got, "Warning: 2 active worktree streams open, guardrail is 1. Consider closing some out.") {
		t.Errorf("expected guardrail warning, got:\n%s", got)
	}
}

// squashedBaseRefs stands in for the repo checkouts after service-b's
// stacked base was squash-merged: my-slug still carries auth-api's
// commits, and origin/main has that work under new SHAs.
type squashedBaseRefs struct{}

func (squashedBaseRefs) HasRef(repoPath, ref string) bool { return true }

func (squashedBaseRefs) IsAncestor(repoPath, ancestor, descendant string) bool {
	return ancestor == "auth-api" && descendant == "my-slug"
}

func mergedBaseSources() status.Sources {
	return status.Sources{
		PR:     fixtureLookup,
		Refs:   squashedBaseRefs{},
		Merged: func(repoPath, headBranch string) bool { return true },
	}
}

func TestRunStatusFlagsStackedRebase(t *testing.T) {
	dir := writeInstanceFixture(t)

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", false, mergedBaseSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	got := buf.String()
	if !strings.Contains(got, "service-b:my-slug (stacked on service-a:auth-api) — rebase onto origin/main") {
		t.Errorf("expected the stacked row flagged for rebase, got:\n%s", got)
	}
	if strings.Contains(got, "service-a (based on main)") {
		t.Errorf("expected the never-stacked row left unflagged, got:\n%s", got)
	}
}

func TestRunStatusJSONCarriesRebaseFlag(t *testing.T) {
	dir := writeInstanceFixture(t)

	var buf bytes.Buffer
	if err := runStatus(&buf, dir, "", true, mergedBaseSources()); err != nil {
		t.Fatalf("runStatus returned error: %v", err)
	}

	var report status.Report
	if err := json.Unmarshal(buf.Bytes(), &report); err != nil {
		t.Fatalf("output isn't valid JSON: %v\n%s", err, buf.String())
	}

	if report.Rows[0].NeedsRebase {
		t.Errorf("expected service-a unflagged, got: %#v", report.Rows[0])
	}
	if !report.Rows[1].NeedsRebase || report.Rows[1].RebaseOnto != "origin/main" {
		t.Errorf("expected service-b flagged onto origin/main, got: %#v", report.Rows[1])
	}
}
