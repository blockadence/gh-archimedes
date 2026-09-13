package notify_test

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/manifest"
	"github.com/blockadence/gh-archimedes/internal/notify"
	"github.com/blockadence/gh-archimedes/internal/prune"
	"github.com/blockadence/gh-archimedes/internal/testrepo"
)

// instance is a watchable Archimedes instance: a repos.yaml pointing at
// one sibling target repo with a real origin, plus the work/<slug>/
// status.md a spawn would have left behind.
type instance struct {
	root string
	tmp  string
	repo string
}

func newInstance(t *testing.T) instance {
	t.Helper()
	tmp := t.TempDir()
	inst := instance{root: filepath.Join(tmp, "instance"), tmp: tmp}
	inst.repo = testrepo.New(t, testrepo.Spec{Dir: tmp, Name: "app"}).Clone

	write(t, filepath.Join(inst.root, "repos.yaml"),
		"repos:\n  - name: app\n    path: ../app\n    base_branch: main\n    context_modeled_sha: null\n")
	return inst
}

// commit adds one commit on main and pushes it, moving the base branch a
// context map would be measured against.
func (i instance) commit(t *testing.T, name, content string) {
	t.Helper()
	write(t, filepath.Join(i.repo, name), content)
	testrepo.Git(t, i.repo, "add", "-A")
	testrepo.Git(t, i.repo, "commit", "-q", "-m", "change")
	testrepo.Git(t, i.repo, "push", "-q", "origin", "main")
}

// spawned writes the status.md row spawn records for one unit of work.
func (i instance) spawned(t *testing.T, slug, note string) {
	t.Helper()
	write(t, filepath.Join(i.root, "work", slug, "status.md"),
		"# "+slug+"\n\n| repo | branch | worktree | note |\n|---|---|---|---|\n"+
			"| app | "+slug+" | "+filepath.Join(i.tmp, "app-worktrees", slug)+" | "+note+" |\n")
}

// mapped records app as having been context-mapped at its base branch's
// current commit, and writes the map that pass would have produced.
func (i instance) mapped(t *testing.T) {
	t.Helper()
	sha := testrepo.GitOut(t, i.repo, "rev-parse", "origin/main")
	if err := manifest.SetRepoField(filepath.Join(i.root, "repos.yaml"), "app", manifest.FieldContextModeledSHA, sha); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(i.repo, "CONTEXT.md"), "# app\n")
}

// prState answers PR lookups from a fixed slug -> state table; anything
// unlisted has no PR.
func prState(states map[string]string) prune.PRStateFunc {
	return func(_, headBranch string) (string, error) {
		if s, ok := states[headBranch]; ok {
			return s, nil
		}
		return "NONE", nil
	}
}

// watch runs one pass and returns everything the operator would see.
func (i instance) watch(t *testing.T, opts notify.Options) (string, error) {
	t.Helper()
	opts.Root = i.root
	if opts.PRState == nil {
		opts.PRState = prState(nil)
	}
	var out bytes.Buffer
	err := notify.Watch(opts, &out, io.Discard)
	return out.String(), err
}

func TestWatchReportsAStaleMapAndAPruneEligibleWorktreeOnce(t *testing.T) {
	inst := newInstance(t)
	inst.spawned(t, "widget-fix", "based on main")
	opts := notify.Options{PRState: prState(map[string]string{"widget-fix": "MERGED"})}

	first, err := inst.watch(t, opts)
	if err != nil {
		t.Fatalf("first pass: %v\n%s", err, first)
	}
	for _, want := range []string{"Context map stale: app", "never mapped", "Ready to prune: app:widget-fix", "MERGED"} {
		if !strings.Contains(first, want) {
			t.Errorf("first pass missing %q:\n%s", want, first)
		}
	}

	second, err := inst.watch(t, opts)
	if err != nil {
		t.Fatalf("second pass: %v\n%s", err, second)
	}
	if second != "" {
		t.Errorf("second pass said %q, want silence: nothing about the instance changed", second)
	}
}

func TestWatchNotifiesAgainOnlyOnceAConditionHasClearedAndReturned(t *testing.T) {
	inst := newInstance(t)
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatal(err)
	}

	// Mapped: the condition clears, so the pass has nothing to say.
	inst.mapped(t)
	cleared, err := inst.watch(t, notify.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if cleared != "" {
		t.Errorf("a freshly mapped repo said %q, want silence", cleared)
	}

	// The base branch moves on: stale again, and news again.
	inst.commit(t, "feature.go", "package app\n")
	again, err := inst.watch(t, notify.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(again, "Context map stale: app") {
		t.Errorf("output = %q, want the repo reported stale a second time", again)
	}
}

func TestWatchDoesNotRenotifyAMapThatIsMerelyStalerThanBefore(t *testing.T) {
	inst := newInstance(t)
	inst.mapped(t)
	inst.commit(t, "one.go", "package app\n")
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatal(err)
	}

	// Still stale, now against a newer commit: the same unaddressed
	// condition, not news.
	inst.commit(t, "two.go", "package app\n")
	out, err := inst.watch(t, notify.Options{})
	if err != nil {
		t.Fatal(err)
	}

	if out != "" {
		t.Errorf("output = %q, want silence: the operator already knows app's map is stale", out)
	}
}

func TestWatchSeedRecordsTheBacklogWithoutDeliveringIt(t *testing.T) {
	inst := newInstance(t)
	inst.spawned(t, "widget-fix", "based on main")
	opts := notify.Options{PRState: prState(map[string]string{"widget-fix": "MERGED"})}

	seeded, err := inst.watch(t, notify.Options{Seed: true, PRState: opts.PRState})
	if err != nil {
		t.Fatalf("seed pass: %v", err)
	}
	if strings.Contains(seeded, "Context map stale") || strings.Contains(seeded, "Ready to prune") {
		t.Errorf("seeding delivered notifications:\n%s", seeded)
	}

	after, err := inst.watch(t, opts)
	if err != nil {
		t.Fatal(err)
	}
	if after != "" {
		t.Errorf("output = %q, want silence: seeding accepted the backlog as already known", after)
	}
}

func TestWatchDeliversThroughTheConfiguredHook(t *testing.T) {
	inst := newInstance(t)
	var titles []string
	opts := notify.Options{
		Command: "notify-send",
		Run: func(_ string, env []string, _ string) error {
			for _, kv := range env {
				if k, v, _ := strings.Cut(kv, "="); k == notify.EnvTitle {
					titles = append(titles, v)
				}
			}
			return nil
		},
	}

	out, err := inst.watch(t, opts)
	if err != nil {
		t.Fatalf("watch: %v\n%s", err, out)
	}

	if len(titles) != 1 || !strings.Contains(titles[0], "app") {
		t.Errorf("hook saw %v, want the one stale repo", titles)
	}
	if strings.Contains(out, "Context map stale: app —") {
		t.Errorf("a configured hook took delivery, so stdout should not print the event too:\n%s", out)
	}
}

func TestWatchRedeliversAConditionWhoseHookFailed(t *testing.T) {
	inst := newInstance(t)
	failing := notify.Options{
		Command: "notify-send",
		Run:     func(string, []string, string) error { return os.ErrPermission },
	}

	if _, err := inst.watch(t, failing); err == nil {
		t.Error("a pass whose hook failed should report it, so the scheduler notices")
	}

	var delivered int
	working := notify.Options{
		Command: "notify-send",
		Run:     func(string, []string, string) error { delivered++; return nil },
	}
	if _, err := inst.watch(t, working); err != nil {
		t.Fatalf("second pass: %v", err)
	}
	if delivered != 1 {
		t.Errorf("delivered %d events, want the one the failed hook never received", delivered)
	}
}

func TestConditionsLeavesOutAWorktreeStillActingAsAStackBase(t *testing.T) {
	inst := newInstance(t)
	inst.spawned(t, "widget-fix", "based on main")
	inst.spawned(t, "widget-followup", "stacked on app:widget-fix")

	snap, err := notify.Conditions(inst.root, "", prState(map[string]string{"widget-fix": "MERGED"}), io.Discard)
	if err != nil {
		t.Fatalf("Conditions: %v", err)
	}

	for _, e := range snap.Firing {
		if e.Kind == notify.PruneEligible {
			t.Errorf("reported %s as prune-eligible, but prune would refuse to remove a branch still stacked on", e.Subject)
		}
	}
}

func TestWatchWritesItsStateWhereItIsTold(t *testing.T) {
	inst := newInstance(t)
	statePath := filepath.Join(t.TempDir(), "elsewhere", "notify.json")
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatal(err)
	}

	if _, err := inst.watch(t, notify.Options{StatePath: statePath}); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(statePath); err != nil {
		t.Errorf("stat %s: %v", statePath, err)
	}
	if _, err := os.Stat(filepath.Join(inst.root, notify.DefaultStateFile)); err == nil {
		t.Error("an explicit state path was overridden by the default one")
	}
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

// failedLookup is a PR lookup that can't answer at all — an expired gh
// session, a rate limit, no network. It reports "NONE" like every other
// failure path, but says why, which is the whole difference between "this
// has no pull request" and "nobody could tell".
func failedLookup(_, _ string) (string, error) {
	return "NONE", errors.New("gh: could not authenticate")
}

func TestConditionsNamesAnUnanswerableLookupTheWayItNamesTheCondition(t *testing.T) {
	inst := newInstance(t)
	inst.spawned(t, "widget-fix", "based on main")

	var progress bytes.Buffer
	snap, err := notify.Conditions(inst.root, "", failedLookup, &progress)
	if err != nil {
		t.Fatalf("Conditions: %v", err)
	}

	// The note the operator reads and the key the pass carries forward are
	// the same unit of work, so they name it the same way.
	if !strings.Contains(progress.String(), "note: could not look up app:widget-fix's pull request: ") {
		t.Errorf("progress does not name app:widget-fix the way a condition is named:\n%s", progress.String())
	}
	want := notify.Event{Kind: notify.PruneEligible, Subject: "app:widget-fix"}.Key()
	if len(snap.Unverified) != 1 || snap.Unverified[0] != want {
		t.Errorf("Unverified = %q, want [%q]", snap.Unverified, want)
	}
}

func TestWatchDoesNotRebreakPruneNewsAPassCouldNotVerify(t *testing.T) {
	inst := newInstance(t)
	inst.spawned(t, "widget-fix", "based on main")
	merged := notify.Options{PRState: prState(map[string]string{"widget-fix": "MERGED"})}

	first, err := inst.watch(t, merged)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(first, "Ready to prune: app:widget-fix") {
		t.Fatalf("first pass:\n%s", first)
	}

	// gh can't answer: the condition is neither confirmed nor cleared.
	if _, err := inst.watch(t, notify.Options{PRState: failedLookup}); err != nil {
		t.Fatalf("a pass that couldn't reach gh: %v", err)
	}

	// gh answers again. The worktree has been prune-eligible the whole
	// time and the operator was already told.
	again, err := inst.watch(t, merged)
	if err != nil {
		t.Fatal(err)
	}
	if again != "" {
		t.Errorf("output = %q, want silence: an unanswerable lookup is not the condition clearing", again)
	}
}

func TestWatchDoesNotRebreakStaleNewsAPassCouldNotVerify(t *testing.T) {
	inst := newInstance(t)
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatal(err)
	}

	// The checkout stops being a git repo mid-life: fetch and rev-parse
	// have nothing to answer with.
	hidden := filepath.Join(inst.repo, ".git")
	if err := os.Rename(hidden, hidden+"-away"); err != nil {
		t.Fatal(err)
	}
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatalf("a pass that couldn't assess a repo: %v", err)
	}
	if err := os.Rename(hidden+"-away", hidden); err != nil {
		t.Fatal(err)
	}

	again, err := inst.watch(t, notify.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if again != "" {
		t.Errorf("output = %q, want silence: the map has been stale and reported the whole time", again)
	}
}

func TestWatchStillClearsAConditionAPassPositivelyResolved(t *testing.T) {
	inst := newInstance(t)
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatal(err)
	}

	// Carrying unverified conditions forward must not turn into never
	// forgetting anything: a repo that was mapped really has cleared.
	inst.mapped(t)
	if _, err := inst.watch(t, notify.Options{}); err != nil {
		t.Fatal(err)
	}
	inst.commit(t, "feature.go", "package app\n")

	again, err := inst.watch(t, notify.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(again, "Context map stale: app") {
		t.Errorf("output = %q, want the repo to notify again once it is genuinely stale again", again)
	}
}

// A notification is read long after the pass that produced it, often out of
// a mailbox, so the command it names has to be one the operator can paste.
// Which of the two installs sent it is the only thing that decides that.
func TestWatchNamesARemedyTheOperatorsInstallCanRun(t *testing.T) {
	for ghExtension, want := range map[string]string{
		"":  "Run: archimedes context-map",
		"1": "Run: gh archimedes context-map",
	} {
		t.Run(want, func(t *testing.T) {
			t.Setenv("GH_EXTENSION", ghExtension)
			inst := newInstance(t)

			out, err := inst.watch(t, notify.Options{})
			if err != nil {
				t.Fatalf("watch: %v\n%s", err, out)
			}
			if !strings.Contains(out, want) {
				t.Errorf("notification does not say %q:\n%s", want, out)
			}
		})
	}
}
