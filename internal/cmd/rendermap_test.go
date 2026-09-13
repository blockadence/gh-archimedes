package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRunRenderMapUpdatesExistingFile(t *testing.T) {
	dir := t.TempDir()

	reposYAML := `repos:
  - name: service-a
    path: ../service-a
    base_branch: main
  - name: service-b
    path: ../service-b
    base_branch: develop
`
	if err := os.WriteFile(filepath.Join(dir, "repos.yaml"), []byte(reposYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	existingMap := "# Workspace Map\n\n## Repos\n\n- [stale](../stale) — base: `main`. Dossier: [repos/stale.md](./repos/stale.md)\n\n## Relationships\n\n- hand-written note.\n"
	mapPath := filepath.Join(dir, "WORKSPACE-MAP.md")
	if err := os.WriteFile(mapPath, []byte(existingMap), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := runRenderMap(dir); err != nil {
		t.Fatalf("runRenderMap returned error: %v", err)
	}

	got, err := os.ReadFile(mapPath)
	if err != nil {
		t.Fatal(err)
	}

	want := "# Workspace Map\n\n## Repos\n\n" +
		"- [service-a](../service-a) — base: `main`. Dossier: [repos/service-a.md](./repos/service-a.md)\n" +
		"- [service-b](../service-b) — base: `develop`. Dossier: [repos/service-b.md](./repos/service-b.md)\n" +
		"\n## Relationships\n\n- hand-written note.\n"

	if string(got) != want {
		t.Errorf("WORKSPACE-MAP.md mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestRunRenderMapCreatesMissingMapFile(t *testing.T) {
	dir := t.TempDir()

	reposYAML := "repos:\n  - name: solo\n    path: ../solo\n    base_branch: main\n"
	if err := os.WriteFile(filepath.Join(dir, "repos.yaml"), []byte(reposYAML), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := runRenderMap(dir); err != nil {
		t.Fatalf("runRenderMap returned error: %v", err)
	}

	got, err := os.ReadFile(filepath.Join(dir, "WORKSPACE-MAP.md"))
	if err != nil {
		t.Fatalf("expected WORKSPACE-MAP.md to be created: %v", err)
	}

	want := "# Workspace Map\n\n## Repos\n\n" +
		"- [solo](../solo) — base: `main`. Dossier: [repos/solo.md](./repos/solo.md)\n" +
		"\n## Relationships\n"

	if string(got) != want {
		t.Errorf("WORKSPACE-MAP.md mismatch\n got: %q\nwant: %q", got, want)
	}
}

func TestRunRenderMapMissingManifestErrors(t *testing.T) {
	dir := t.TempDir()

	if err := runRenderMap(dir); err == nil {
		t.Fatal("expected error when repos.yaml is missing, got nil")
	}
}

// Through the flag, from the directory the instance sits in: `--root
// <relative-dir>` is how an operator names an instance they are standing
// next to, and what comes out has to be the same map, with the same
// relative links, that an absolute root produces. The flag's own half of
// what manifest_test.go pins at the seam: nothing between cobra and
// repos.yaml may quietly need the root to be absolute.
func TestRenderMapCommandAcceptsARelativeRoot(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "instance")
	writeFile(t, filepath.Join(root, "repos.yaml"),
		"repos:\n  - name: service-a\n    path: ../service-a\n    base_branch: main\n")

	t.Chdir(parent)

	execute(t, "render-map", "--root", "instance")

	got, err := os.ReadFile(filepath.Join(root, "WORKSPACE-MAP.md"))
	if err != nil {
		t.Fatalf("expected the map to be written under the named instance: %v", err)
	}

	want := "# Workspace Map\n\n## Repos\n\n" +
		"- [service-a](../service-a) — base: `main`. Dossier: [repos/service-a.md](./repos/service-a.md)\n" +
		"\n## Relationships\n"
	if string(got) != want {
		t.Errorf("WORKSPACE-MAP.md mismatch\n got: %q\nwant: %q", got, want)
	}
}
