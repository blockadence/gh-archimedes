package spawn_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/dossier"
	"github.com/blockadence/gh-archimedes/internal/spawn"
	"github.com/blockadence/gh-archimedes/internal/testrepo"
)

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWriteFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// makeTargetRepo builds the shape spawn needs to be exercised for real: a
// bare "origin" plus a clone with a normal .gitignore and one commit on
// main, so spawn's fetch-first behavior has real remote state to pull, and
// so the repo's own tracked .gitignore is there to be left alone.
func makeTargetRepo(t *testing.T, tmp, name string) testrepo.Repo {
	t.Helper()
	return testrepo.New(t, testrepo.Spec{
		Dir:   tmp,
		Name:  name,
		Files: map[string]string{".gitignore": "*.log\n"},
	})
}

// instance is an Archimedes instance root wired to two target repos, the
// multi-repo shape the worktree pattern exists for.
type instance struct {
	root    string
	target  testrepo.Repo
	target2 testrepo.Repo
}

// newInstance builds an instance whose repos.yaml points at two sibling
// target repos, the "../<name>" layout bootstrap produces.
func newInstance(t *testing.T) instance {
	t.Helper()
	tmp := t.TempDir()

	inst := instance{
		root:    filepath.Join(tmp, "instance"),
		target:  makeTargetRepo(t, tmp, "target-repo"),
		target2: makeTargetRepo(t, tmp, "target-repo2"),
	}

	mustMkdirAll(t, inst.root)
	mustWriteFile(t, filepath.Join(inst.root, "repos.yaml"),
		"repos:\n"+
			"  - name: target\n    path: ../target-repo\n    base_branch: main\n"+
			"  - name: target2\n    path: ../target-repo2\n    base_branch: main\n")

	return inst
}

// workSlug creates work/<slug>/ in the instance and returns its path.
func (i instance) workSlug(t *testing.T, slug string) string {
	t.Helper()
	dir := filepath.Join(i.root, "work", slug)
	mustMkdirAll(t, dir)
	return dir
}

// writeDossier writes repo's dossier into the instance at root with rules
// as its house rules, which is all spawn reads a dossier for.
func writeDossier(t *testing.T, root, repo, rules string) {
	t.Helper()
	mustMkdirAll(t, dossier.Dir(root))
	mustWriteFile(t, dossier.Path(dossier.Dir(root), repo),
		"# "+repo+"\n\n"+dossier.HouseRulesHeading+"\n\n"+rules+"\n\n## Known gotchas\nn/a\n")
}

// assertHouseRules requires the worktree's ephemeral copy to carry exactly
// the rules the dossier recorded -- the delivery being the only thing that
// says the right dossier was read.
func assertHouseRules(t *testing.T, wt, rules string) {
	t.Helper()
	path := filepath.Join(wt, spawn.ContextDirName, dossier.HouseRulesFileName)
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s was not delivered: %v", dossier.HouseRulesFileName, err)
	}
	if string(got) != rules+"\n" {
		t.Errorf("house rules diverged from the dossier\n got: %q\nwant: %q", got, rules+"\n")
	}
}
