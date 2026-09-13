package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

// The root manifest.LoadInstance absolutized is dropped, and what that
// buys is a repo path that stays relative: what consumes one is git, run
// *in* the checkout, so relative to the working directory the operator
// typed the root in is exactly what it should mean. Every other test in
// this package hands a subcommand an absolute t.TempDir, which is why the
// suite said nothing while 46's bug was live (issue 59).
func TestLoadManifestLeavesRepoPathsToResolveAgainstTheTypedRoot(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "instance")
	writeFile(t, filepath.Join(root, "repos.yaml"),
		"repos:\n  - name: service-a\n    path: ./service-a\n    base_branch: main\n")
	if err := os.MkdirAll(filepath.Join(root, "service-a"), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Chdir(parent)

	m, err := loadManifest("instance")
	if err != nil {
		t.Fatalf("loadManifest: %v", err)
	}

	repo, err := m.Resolve("instance", "service-a")
	if err != nil {
		t.Fatalf("resolving service-a: %v", err)
	}
	if want := filepath.Join("instance", "service-a"); repo.Path != want {
		t.Errorf("Path = %q, want %q -- the typed root, not the absolute one", repo.Path, want)
	}
	// And usable as it stands from the shell the root was typed in, which
	// is the whole of what a checkout path is for: git receives it as the
	// directory to run in.
	info, err := os.Stat(repo.Path)
	if err != nil || !info.IsDir() {
		t.Errorf("stat %q: %v -- a checkout path has to name the checkout from here", repo.Path, err)
	}
}
