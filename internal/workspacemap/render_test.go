package workspacemap_test

import (
	"testing"

	"github.com/blockadence/gh-archimedes/internal/manifest"
	"github.com/blockadence/gh-archimedes/internal/workspacemap"
)

// Expected outputs below are byte-exact: the "## Repos" block is
// regenerated in place and everything around it, blank lines included, has
// to come back unchanged. See the package doc, and TestRenderIsIdempotent
// below.
//
// They spell `repos/<name>.md` out rather than building it from
// dossier.RelPath, the way bootstrap's, reposync's and spawn's fixtures
// spell the same layout out: a row is what an instance's committed
// WORKSPACE-MAP.md carries, so a test that asks the code where dossiers are
// would agree with any answer it gave. Written out, these are what fails
// when dossier.Dir's join changes without the map's rows changing with it
// -- the check this package was outside of while RepoLine wrote the layout
// itself (issue 90).

func TestRenderReplacesExistingRepoBlock(t *testing.T) {
	existing := "# Workspace Map\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"- [old-repo](../old-repo) — base: `main`. Dossier: [repos/old-repo.md](./repos/old-repo.md)\n" +
		"\n" +
		"## Relationships\n" +
		"\n" +
		"- service-b depends on service-a for its client SDK.\n"

	repos := []manifest.Repo{
		{Name: "service-a", Path: "../service-a", BaseBranch: "main"},
		{Name: "service-b", Path: "../service-b", BaseBranch: "develop"},
	}

	want := "# Workspace Map\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"- [service-a](../service-a) — base: `main`. Dossier: [repos/service-a.md](./repos/service-a.md)\n" +
		"- [service-b](../service-b) — base: `develop`. Dossier: [repos/service-b.md](./repos/service-b.md)\n" +
		"\n" +
		"## Relationships\n" +
		"\n" +
		"- service-b depends on service-a for its client SDK.\n"

	got := workspacemap.Render(existing, repos)
	if got != want {
		t.Errorf("Render() mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestRenderOnDefaultContent(t *testing.T) {
	repos := []manifest.Repo{
		{Name: "service-a", Path: "../service-a", BaseBranch: "main"},
		{Name: "service-b", Path: "../service-b", BaseBranch: "develop"},
	}

	want := "# Workspace Map\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"- [service-a](../service-a) — base: `main`. Dossier: [repos/service-a.md](./repos/service-a.md)\n" +
		"- [service-b](../service-b) — base: `develop`. Dossier: [repos/service-b.md](./repos/service-b.md)\n" +
		"\n" +
		"## Relationships\n"

	got := workspacemap.Render(workspacemap.DefaultContent, repos)
	if got != want {
		t.Errorf("Render() mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestRenderWithNoRepos(t *testing.T) {
	want := "# Workspace Map\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"\n" +
		"\n" +
		"## Relationships\n"

	got := workspacemap.Render(workspacemap.DefaultContent, nil)
	if got != want {
		t.Errorf("Render() mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestRenderLeavesContentBeforeReposUntouched(t *testing.T) {
	existing := "# Workspace Map\n" +
		"\n" +
		"Some hand-written preamble.\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"## Relationships\n" +
		"\n" +
		"hand-written notes\n"

	repos := []manifest.Repo{{Name: "solo", Path: "../solo", BaseBranch: "main"}}

	want := "# Workspace Map\n" +
		"\n" +
		"Some hand-written preamble.\n" +
		"\n" +
		"## Repos\n" +
		"\n" +
		"- [solo](../solo) — base: `main`. Dossier: [repos/solo.md](./repos/solo.md)\n" +
		"\n" +
		"## Relationships\n" +
		"\n" +
		"hand-written notes\n"

	got := workspacemap.Render(existing, repos)
	if got != want {
		t.Errorf("Render() mismatch\n got: %q\nwant: %q", got, want)
	}
}

// Bootstrap regenerates the map on every run, most of which change nothing.
// Rendering an already-rendered map must therefore be a no-op — the shell
// script it replaces grew a blank line before "## Relationships" each time.
func TestRenderIsIdempotent(t *testing.T) {
	repos := []manifest.Repo{{Name: "service-a", Path: "../service-a", BaseBranch: "main"}}

	for _, existing := range []string{
		workspacemap.DefaultContent,
		"# Workspace Map\n\n## Repos\n\n(populated by bootstrap)\n\n## Relationships\n\nhand-written notes\n",
	} {
		once := workspacemap.Render(existing, repos)
		if twice := workspacemap.Render(once, repos); twice != once {
			t.Errorf("re-rendering changed the map\n once: %q\ntwice: %q", once, twice)
		}
	}
}
