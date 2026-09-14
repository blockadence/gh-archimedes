package dossier_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/dossier"
)

// The layout spelled out rather than built from the code under test: this
// is the one place that says where an instance's dossiers are, so the test
// that holds it has to state the answer itself.
func TestDirIsTheReposDirectoryUnderTheInstanceRoot(t *testing.T) {
	got := dossier.Dir("/Users/someone/Code/widgets")
	want := "/Users/someone/Code/widgets/repos"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// The root is taken as the operator typed it, as in workdir.Path: `--root
// .` is the ordinary way to name an instance and every caller reads the
// answer from the directory the operator typed it in.
func TestDirKeepsARelativeRootRelative(t *testing.T) {
	if got := dossier.Dir("instance"); got != "instance/repos" {
		t.Errorf("got %q, want %q", got, "instance/repos")
	}
}

// Dir is where root is named, and the only place: everything else in this
// package answers for whatever directory it is handed, which is what lets
// stub_test.go and houserules_test.go run against a bare t.TempDir() with
// no instance around them.
func TestPathIsTheRepoDossierUnderWhateverDirectoryItIsGiven(t *testing.T) {
	if got := dossier.Path("/tmp/scratch", "service-a"); got != "/tmp/scratch/service-a.md" {
		t.Errorf("got %q, want %q", got, "/tmp/scratch/service-a.md")
	}
}

// The decision issue 76 reached, held with both things present rather than
// argued in prose alone: an instance can carry `repos/service-a.md` and
// `repos/service-a/` at the same time — the dossier, and a checkout of the
// repository that dossier is about, which repos.yaml is free to put below
// the root. This package's half of that is what is held here: a dossier is
// looked up by name, so a checkout sharing the name is not something this
// package can reach or be stopped by. The other half — that the checkout
// goes on being found, through the manifest entry that records it — belongs
// to a caller that has both, and spawn's
// TestRunResolvesRepoPathsBelowInstanceRoot holds it there.
func TestADossierAndACheckoutShareANameWithoutSharingAPath(t *testing.T) {
	dir := dossier.Dir(t.TempDir())

	// The checkout below the root: the layout internal/worktree's own
	// test exercises, and the one that puts the two under one name.
	checkout := filepath.Join(dir, "service-a")
	if err := os.MkdirAll(checkout, 0o755); err != nil {
		t.Fatal(err)
	}

	written, err := dossier.WriteStub(dir, dossier.Stub{
		Name:       "service-a",
		Path:       "repos/service-a",
		BaseBranch: "main",
	})
	if err != nil {
		t.Fatalf("WriteStub returned error: %v", err)
	}
	if !written {
		t.Fatal("no dossier was written -- the checkout directory was taken for one")
	}

	if path := dossier.Path(dir, "service-a"); path == checkout {
		t.Fatalf("dossier and checkout resolved to the same path %q", path)
	}
	if body := readDossier(t, dir, "service-a"); !strings.Contains(body, "# service-a") {
		t.Errorf("the dossier does not hold its own prose:\n%s", body)
	}

	// And the checkout is still a checkout: nothing here wrote over it.
	if info, err := os.Stat(checkout); err != nil {
		t.Errorf("stat %q: %v -- the checkout has to survive the dossier beside it", checkout, err)
	} else if !info.IsDir() {
		t.Errorf("%q is no longer a directory -- the dossier landed on the checkout", checkout)
	}
}

// The layout spelled out rather than built from the code under test, for
// the same reason TestDirIsTheReposDirectoryUnderTheInstanceRoot does it:
// this is the answer a committed document links to, so the test that holds
// it has to state the answer itself.
func TestRelPathIsTheDossierRelativeToTheInstanceRoot(t *testing.T) {
	if got := dossier.RelPath("service-a"); got != "repos/service-a.md" {
		t.Errorf("got %q, want %q", got, "repos/service-a.md")
	}
}

// RelPath answers a document, not a filesystem: a link in a committed
// WORKSPACE-MAP.md is read on whatever machine has the instance checked
// out, so the separator cannot be the one the renderer happens to run on.
func TestRelPathIsSlashSeparatedOnEveryPlatform(t *testing.T) {
	if got := dossier.RelPath("service-a"); strings.ContainsRune(got, '\\') {
		t.Errorf("got %q, which no markdown renderer resolves", got)
	}
}
