package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/instance"
	"github.com/blockadence/gh-archimedes/internal/testrepo"
)

// init is the one subcommand that runs before an instance exists, so there
// is no fixture instance to build here — only a parent directory to put one
// in, and a git config of the test's own so the scaffolding commit doesn't
// depend on the machine's identity.
func initParent(t *testing.T) string {
	t.Helper()
	testrepo.IsolateGit(t)
	return t.TempDir()
}

func TestInitScaffoldsAnInstanceFromTheEmbeddedTemplate(t *testing.T) {
	parent := initParent(t)

	out := execute(t, "init", "widgets", parent)

	dest := filepath.Join(parent, "widgets")
	if _, err := os.Stat(filepath.Join(dest, "repos.yaml")); err != nil {
		t.Errorf("no instance at %s: %v", dest, err)
	}
	if !strings.Contains(out, dest) {
		t.Errorf("output does not say where the instance is:\n%s", out)
	}
	// Whoever just ran this has never used the tool before; the one thing
	// they need next is the command that fills the instance in.
	if !strings.Contains(out, "bootstrap") {
		t.Errorf("output does not point at the next step:\n%s", out)
	}
}

func TestInitRefusesToScaffoldOverAnExistingDirectory(t *testing.T) {
	parent := initParent(t)
	dest := filepath.Join(parent, "widgets")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}

	err := executeErr(t, "init", "widgets", parent)

	if !strings.Contains(err.Error(), dest) {
		t.Errorf("error does not name the path in the way: %v", err)
	}
}

func TestInitNeedsBothANameAndAParentDirectory(t *testing.T) {
	parent := initParent(t)

	executeErr(t, "init", "widgets")
	executeErr(t, "init", "widgets", parent, "extra")
}

// init's parting line is the one piece of runtime output that tells an
// operator what to type next, and it is the first thing anybody sees. Under
// a gh extension install `archimedes bootstrap` is not a command they have.
func TestInitPointsAtTheNextCommandInTheFormTheOperatorCanRun(t *testing.T) {
	for _, tc := range []struct{ ghExtension, want string }{
		{"", "&& archimedes bootstrap"},
		{"1", "&& gh archimedes bootstrap"},
	} {
		t.Run(tc.want, func(t *testing.T) {
			t.Setenv("GH_EXTENSION", tc.ghExtension)

			out := execute(t, "init", "widgets", initParent(t))

			if !strings.Contains(out, tc.want) {
				t.Errorf("init's next step does not say %q:\n%s", tc.want, out)
			}
		})
	}
}

// The whole of what an operator on a fresh machine gets. `init` is the first
// command anybody runs, and on a laptop or container where git has never
// been configured it is also the first place the tool could hand them raw
// git output instead of an explanation. What it hands them instead is the
// instance, plus the two commands that make its first commit theirs.
//
// Unconfigured rather than stripped, because that is the machine an operator
// who has never run `git config` is on: on a runner git refuses to commit
// too, but on a developer's box it would guess an author and commit, and
// this path has to be the one taken on both.
func TestInitSaysTheInstanceIsUncommittedAndHowToCommitIt(t *testing.T) {
	testrepo.UnconfigureGitIdentity(t)
	parent := t.TempDir()

	out := execute(t, "init", "widgets", parent)

	dest := filepath.Join(parent, "widgets")
	if !strings.Contains(out, dest) {
		t.Errorf("output does not say where the instance is:\n%s", out)
	}
	for _, want := range []string{
		"git config --global user.name",
		"git config --global user.email",
		"git add -A",
		instance.CommitSubject("widgets"),
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not tell the operator to run %q:\n%s", want, out)
		}
	}
	// And says the part that would otherwise read as a bug. This declines
	// where git itself would have committed, and an operator watching git
	// commit in every other repository on that machine is owed the reason.
	for _, want := range []string{"Not committed", "guess"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not say %q, so a skipped commit reads as a failure:\n%s", want, out)
		}
	}
	// It is still the same next step. Being uncommitted does not stop an
	// instance being usable, and burying `bootstrap` here would make it look
	// like it does.
	if !strings.Contains(out, "bootstrap") {
		t.Errorf("output does not point at the next step:\n%s", out)
	}
}

// The machine the notice above does not fit: an identity configured, correct
// and git's to use, and git refusing the commit all the same — signing set up
// with no key that works here, a hook that says no, a full disk. That once
// ended `init` with git's own wrapped-up stderr as the first thing it said
// and an empty parent directory to show for the run.
//
// What it gets instead is the instance, and a sentence of the tool's own
// about the commit with git's reason quoted underneath it. Not the identity
// advice: nothing is wrong with their identity, and telling them to set one
// would send them to fix the wrong thing.
func TestInitSaysWhyGitRefusedTheCommitAndKeepsTheInstance(t *testing.T) {
	parent := initParent(t)
	testrepo.RefuseCommits(t)

	out := execute(t, "init", "widgets", parent)

	dest := filepath.Join(parent, "widgets")
	for _, path := range []string{"repos.yaml", ".git"} {
		if _, err := os.Stat(filepath.Join(dest, path)); err != nil {
			t.Errorf("a refused commit took the instance with it: no %s (%v)", path, err)
		}
	}
	if out := testrepo.GitOut(t, dest, "rev-list", "--all", "--count"); out != "0" {
		t.Errorf("commit count = %s, want 0: git refused the commit", out)
	}

	for _, want := range []string{
		"Not committed",                   // the tool's own words, first
		"pre-commit hook said no",         // git's, quoted, so they know what to fix
		dest,                              // where the instance they still have is
		"git add -A",                      // and the command that finishes it
		instance.CommitSubject("widgets"), // under the subject init would have used
		"bootstrap",                       // still the next step
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not say %q:\n%s", want, out)
		}
	}
	// Quoted rather than framed: git's words are set in from the tool's
	// own, which is what says whose sentence it is (issue 79).
	if !strings.Contains(out, "\ngit reported:\n\n  "+testrepo.RefusedCommitMessage+"\n") {
		t.Errorf("output does not set git's own words in from the tool's:\n%s", out)
	}
	// Raw git output as the first thing the tool says is the whole of what
	// this replaced, and our own wrapping of it is the tell.
	if strings.Contains(out, "exit status") {
		t.Errorf("output hands back git's failure unframed:\n%s", out)
	}
	// The identity advice belongs to the other machine. Here it is wrong.
	if strings.Contains(out, "git config --global user.name") {
		t.Errorf("output tells an operator with an identity to configure one:\n%s", out)
	}
}

// The other half of that contract, and the one that rots silently: on a
// machine that does have an identity, none of the above is said at all.
func TestInitSaysNothingAboutIdentityWhenItCommitted(t *testing.T) {
	parent := initParent(t)

	out := execute(t, "init", "widgets", parent)

	if strings.Contains(out, "git config") {
		t.Errorf("output tells an operator to configure git after committing for them:\n%s", out)
	}
}
