package notify

import (
	"errors"
	"fmt"
	"io"
	"path/filepath"

	"github.com/blockadence/gh-archimedes/internal/contextmap"
	"github.com/blockadence/gh-archimedes/internal/manifest"
	"github.com/blockadence/gh-archimedes/internal/prune"
	"github.com/blockadence/gh-archimedes/internal/stackref"
)

// DefaultStateFile is where a watch remembers what it has already reported,
// relative to the instance root. It sits beside repos.yaml because it
// describes one instance and is worth nothing anywhere else — delete it and
// the next pass simply reports the current backlog again.
const DefaultStateFile = ".archimedes-notify.json"

// Options is one watch pass.
type Options struct {
	// Root is the instance directory holding repos.yaml and work/.
	Root string
	// ContextFile overrides where each repo's context map lives, relative
	// to that repo's root. Empty means contextmap.DefaultContextFile.
	ContextFile string
	// StatePath overrides where this instance's state file lives. Empty
	// means <Root>/DefaultStateFile.
	StatePath string
	// Command is the operator's notification hook, run once per new
	// event. Empty delivers to out instead.
	Command string
	// Seed records what is true now without delivering any of it — how an
	// operator adopts a notifier on an instance with a backlog they
	// already know about.
	Seed bool
	// PRState looks up a unit of work's pull request state. Required:
	// nothing here can tell a merged branch from an open one on its own.
	PRState prune.PRStateFunc
	// Run executes the hook command. Empty means RunShell.
	Run Runner
}

// Watch reports every condition that has become true since the last pass:
// it collects what holds now, compares that against the state file, hands
// the difference to the operator's notifier, and records what it found for
// next time.
//
// It says nothing when there is no news. A watch is meant to be run by a
// scheduler every few minutes, and a scheduler mails whatever a job
// prints, so a pass that found nothing new prints nothing at all — the
// only mail an operator gets is mail worth reading.
//
// A hook that failed leaves its condition out of the recorded state and
// fails the pass. Both halves matter: the scheduler learns the notifier is
// broken, and the condition is still owed rather than filed away as news
// already broken to someone who never heard it.
func Watch(opts Options, out, progress io.Writer) error {
	if opts.PRState == nil {
		return errors.New("no pull request lookup configured")
	}
	root, err := filepath.Abs(opts.Root)
	if err != nil {
		return fmt.Errorf("resolving instance root %s: %w", opts.Root, err)
	}
	statePath := opts.StatePath
	if statePath == "" {
		statePath = filepath.Join(root, DefaultStateFile)
	}

	previous, err := LoadState(statePath)
	if err != nil {
		return err
	}
	snap, err := Conditions(root, opts.ContextFile, opts.PRState, progress)
	if err != nil {
		return err
	}
	recorded := Record(previous, snap)

	if opts.Seed {
		if err := SaveState(statePath, recorded); err != nil {
			return err
		}
		fmt.Fprintf(out, "Recorded %d open condition(s) in %s without notifying about any of them.\n", len(recorded.Firing), statePath)
		return nil
	}

	deliver := ToWriter(out)
	if opts.Command != "" {
		run := opts.Run
		if run == nil {
			run = RunShell
		}
		deliver = ToCommand(run, opts.Command)
	}

	fired := Since(previous, snap.Firing)
	failures := 0
	for _, e := range fired {
		if err := deliver(e); err != nil {
			// Reported as it happens, and on progress rather than
			// carried in the returned error: one broken hook shouldn't
			// bury the others' detail in a single line, and everything
			// this pass prints reaches the scheduler's log anyway.
			fmt.Fprintf(progress, "warning: %v\n", err)
			recorded.Drop(e.Key())
			failures++
		}
	}

	// Written whatever happened: the conditions that were delivered are
	// news already broken, and holding the whole file back over one
	// failed hook would re-deliver all of them next pass.
	if err := SaveState(statePath, recorded); err != nil {
		return err
	}
	if len(fired) > failures {
		fmt.Fprintf(out, "\n%d new, %d open condition(s) in total.\n", len(fired)-failures, len(recorded.Firing))
	}
	if failures > 0 {
		return fmt.Errorf("%d of %d notifications could not be delivered; they stay unreported and will be retried next pass", failures, len(fired))
	}
	return nil
}

// Snapshot is everything one pass could determine about an instance: the
// conditions that hold, and the subjects it could reach no verdict on at
// all.
//
// The second half exists because a watch reasons from absence — a
// condition that stops being reported is a condition that cleared — and
// absence has two causes. Naming the ones nobody could ask about is what
// keeps an unreachable remote from being read as good news.
type Snapshot struct {
	// Firing is every condition that holds right now.
	Firing []Event
	// Unverified holds the keys of the conditions this pass couldn't
	// decide: a repo whose remote wouldn't answer, a unit of work whose
	// pull request state gh wouldn't report.
	Unverified []string
}

// Conditions collects everything currently worth notifying about in the
// instance at root: every tracked repo whose context map has gone stale,
// and every spawned worktree that is ready to be pruned.
//
// Both are read the way the subcommand that owns them reads it —
// contextmap.Survey and prune.Scan — so a watch can't come to a different
// conclusion than the `context-map` or `prune` run the operator makes in
// response to it.
//
// A repo or a unit of work that couldn't be assessed at all is reported on
// progress and comes back under Unverified rather than failing the pass.
// Carrying on is the right call for something a scheduler runs unattended:
// the alternative is dropping every other repo's news over one bad remote.
func Conditions(root, contextFile string, prState prune.PRStateFunc, progress io.Writer) (Snapshot, error) {
	root, m, err := manifest.LoadInstance(root)
	if err != nil {
		return Snapshot{}, err
	}
	if contextFile == "" {
		contextFile = contextmap.DefaultContextFile
	}

	// FetchedSHA rather than LocalSHA: a watch is the one reader with no
	// human waiting on it, and a map only counts as stale against where
	// the base branch actually is. Reading whatever the checkout last
	// fetched would leave a repo nobody has fetched in weeks looking
	// current, which is exactly the silence this is meant to break.
	states, warning := contextmap.Survey(root, m, contextFile, contextmap.FetchedSHA(progress))
	if warning != "" {
		fmt.Fprintln(progress, warning)
	}

	var snap Snapshot
	for _, s := range states {
		stale := Event{Kind: ContextStale, Subject: s.Name}
		if !s.Cloned {
			continue
		}
		if s.Err != nil {
			fmt.Fprintf(progress, "note: could not assess %s: %v\n", s.Name, s.Err)
			snap.Unverified = append(snap.Unverified, stale.Key())
			continue
		}
		if !s.Stale {
			continue
		}
		stale.Detail = s.Reason
		stale.Remedy = remedyContextMap()
		snap.Firing = append(snap.Firing, stale)
	}

	// prune.Scan folds a failed lookup into "no pull request", which is
	// the safe reading for prune but indistinguishable from a settled one
	// here, so the failures are noted on the way past.
	watched := func(repo, headBranch string) (string, error) {
		state, err := prState(repo, headBranch)
		if err != nil {
			pair := stackref.Ref{Repo: repo, Slug: headBranch}.String()
			fmt.Fprintf(progress, "note: could not look up %s's pull request: %v\n", pair, err)
			snap.Unverified = append(snap.Unverified,
				Event{Kind: PruneEligible, Subject: pair}.Key())
		}
		return state, err
	}

	items, err := prune.Scan(root, "", watched)
	if err != nil {
		return Snapshot{}, err
	}
	for _, it := range items {
		// A merged unit of work something else is still stacked on is not
		// prune-eligible — prune would refuse it — so it isn't news yet.
		// It becomes news once the dependent is rebased or pruned, which
		// is exactly when the operator can act on it.
		if !it.Prunable() {
			continue
		}
		snap.Firing = append(snap.Firing, Event{
			Kind:    PruneEligible,
			Subject: it.Ref().String(),
			Detail:  it.PRState,
			Remedy:  remedyPrune(it.Slug),
		})
	}

	return snap, nil
}
