package cmd

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/blockadence/gh-archimedes/internal/driver"
	"github.com/blockadence/gh-archimedes/internal/invocation"
	"github.com/blockadence/gh-archimedes/internal/runrecord"
)

// The command for the state nothing else can report: a run that died
// outright, taking with it the process that was going to put the target
// repo back, under an archimedes that was killed too and could not step in
// (internal/driver's backstop.go does that where it is still alive).
//
// What is left is a record on disk, and acting on one is deliberate rather
// than automatic. By the time an operator reads this the run may be days
// old: putting a repo back means writing to a repository on the strength of
// something that happened in another session, and the rollback itself
// refuses outright where the repo has moved on since. So this reports, and
// does nothing at all until asked — and what it reports first is the thing
// nobody had before, which is that the repo is in that state and which
// paths are sitting in it.

func newUnfinishedRunsCmd() *cobra.Command {
	var root string

	cmd := &cobra.Command{
		Use:   "unfinished-runs",
		Short: "Repos a driver run left dirty and never put back",
		Long: fmt.Sprintf(`Lists the target repos a context-mapping run was still working in when it
died — and, for each one, what the run left sitting in there.

A driver that scaffolds into someone's repository undoes it on its way out,
whether the run succeeded, failed or was interrupted. What it cannot undo is
a death it gets no warning of: a SIGKILL, an OOM kill, a machine that loses
power. Archimedes notes every run down before it starts for exactly that
case, and where it is still running when a driver dies it puts the repo back
itself. A record still here is one that outlived archimedes as well.

Nothing is written to any repo by this listing. "%[1]s unfinished-runs
restore <id>" is what acts on one, and it re-runs that driver's own
rollback: it refuses where the repo's HEAD has moved since the run, because
what the run added can no longer be told from what was committed.
"%[1]s unfinished-runs forget <id>" drops a record you have dealt with
yourself.

A record for a run that is still going is reported as that and left alone:
it is that run's, and goes when the run ends.`, invocation.Name()),
		Args: cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			return reportUnfinishedRuns(driverSet(root), runrecord.For(root), c.OutOrStdout())
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root whose records are read")
	cmd.AddCommand(newUnfinishedRunsRestoreCmd(), newUnfinishedRunsForgetCmd())

	return cmd
}

func newUnfinishedRunsRestoreCmd() *cobra.Command {
	var root string
	var force bool

	cmd := &cobra.Command{
		Use:   "restore <id>",
		Short: "Put one of those repos back as the run found it",
		Long: `Re-runs the rollback of the driver that died, over the repo named in the
record, from the snapshot it took before it started.

It is the same rollback the driver would have run itself, so it undoes what
the run added or changed and leaves everything that predates it alone —
including work you had uncommitted, which it names rather than touches. It
refuses, changing nothing, if that repo's HEAD has moved since the run:
every judgement in there is relative to the commit the snapshot was taken
against, so a repo that has been committed to since is one only you can
sort out.

The record is cleared once the repo is back, and kept if anything went
wrong.

A record whose run still looks like it is running is refused, because
restoring one would delete what that session is still writing. --force says
you know better — which you do after a reboot, where the pid in the record
may have been handed to something else entirely.`,
		Args: cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			return restoreUnfinishedRun(driverSet(root), runrecord.For(root), args[0], force, c.OutOrStdout())
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root whose records are read")
	cmd.Flags().BoolVar(&force, "force", false, "restore even though the run that left this record still looks like it is running")

	return cmd
}

func newUnfinishedRunsForgetCmd() *cobra.Command {
	var root string

	cmd := &cobra.Command{
		Use:   "forget <id>",
		Short: "Drop a record, leaving the repo exactly as it is",
		Long: `Removes one record and nothing else. The repo it names is left exactly as
the run left it.

This is for the ones nothing can do anything about: a repo you have sorted
out by hand, one that has been committed to since, one you no longer have.
Without it they would be reported before every mapping pass forever.`,
		Args: cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			return forgetUnfinishedRun(runrecord.For(root), args[0], c.OutOrStdout())
		},
	}

	cmd.Flags().StringVar(&root, "root", ".", "instance root whose records are read")

	return cmd
}

// noticeUnfinishedRuns is the one line that makes a record something an
// operator hears about rather than something they would have to go looking
// for. It goes before a run that is about to use a driver, because that is
// where somebody is already thinking about these repos, and it is the same
// place a pass would otherwise silently add another record to the pile.
//
// It names the repos and stops there: nothing is written to any of them.
// Acting is `unfinished-runs restore`, deliberately, for the reasons at the
// top of this file. What it does do besides naming them is what reading the
// records does anywhere — Outstanding clears away the ones holding nothing,
// which is where that tidying actually happens for most operators, since
// this runs before every pass and the listing runs when somebody thinks of
// it.
//
// A run that is still going is somebody else's pass, not a leftover, and is
// left out: naming a repo that is being worked in right now as one nobody
// put back would be a notice about a run that has not finished happening.
//
// A records directory that cannot be read says nothing here. This is a
// courtesy ahead of the real work, and the run itself says so loudly enough
// when it comes to write its own record into the same place.
func noticeUnfinishedRuns(dir runrecord.Dir, out io.Writer) {
	left, err := dir.Outstanding()
	if err != nil {
		return
	}
	repos := make([]string, 0, len(left))
	for _, rec := range left {
		if rec.RunStillAlive() {
			continue
		}
		if rec.Repo != "" {
			repos = append(repos, rec.Repo)
			continue
		}
		repos = append(repos, rec.ID())
	}
	if len(repos) == 0 {
		return
	}
	fmt.Fprintf(out, "%s here earlier did not put the repo they were working in back: %s\nThey are not this run's doing, and nothing has been written to them. `%s unfinished-runs` says what is in each.\n\n",
		runsPlural(len(repos)), strings.Join(repos, ", "), invocation.Name())
}

// reportUnfinishedRuns is the listing: every record still outstanding, what
// the run left in that repo, and what to type about it.
func reportUnfinishedRuns(drivers driver.Set, dir runrecord.Dir, out io.Writer) error {
	left, err := dir.Outstanding()
	if err != nil {
		return err
	}
	if len(left) == 0 {
		fmt.Fprintf(out, "No runs left a repo unaccounted for.\n")
		return nil
	}

	fmt.Fprintf(out, "%s did not put the repo they were working in back:\n", runsPlural(len(left)))
	for _, rec := range left {
		fmt.Fprintf(out, "\n%s\n", rec.ID())
		if rec.Err != nil {
			// A directory that is a record by being there, and unreadable
			// by everything else. Named anyway: an operator who is told
			// where it is can read it themselves, and told nothing can
			// do nothing.
			fmt.Fprintf(out, "%s\n", indent(fmt.Sprintf("could not be read: %v", rec.Err)))
			continue
		}
		fmt.Fprintf(out, "%s\n", indent(fmt.Sprintf("repo:    %s", rec.Repo)))
		fmt.Fprintf(out, "%s\n", indent(fmt.Sprintf("driver:  %s, started %s", rec.Driver, rec.Started.Format(time.RFC3339))))
		if rec.RunStillAlive() {
			// Not a leftover: process %d is still there, so this is a run
			// happening now. What it has put in the repo so far is a
			// moving target and is not listed — it is not something to be
			// acted on, it is something to wait for.
			fmt.Fprintf(out, "%s\n", indent(fmt.Sprintf("that run is still going (pid %d) — it will take this record away when it ends. Nothing to do.", rec.Pid)))
			continue
		}
		reportLeftovers(drivers, rec, out)
	}
	fmt.Fprintf(out, "\nNothing above has been written to. `%s unfinished-runs restore <id>` puts one back;\n`%s unfinished-runs forget <id>` drops a record you have dealt with yourself.\n",
		invocation.Name(), invocation.Name())
	return nil
}

// reportLeftovers says what the run left in the repo, which is the part an
// operator cannot get any other way: `git status` in there shows it mixed in
// with their own work and says nothing about which is which.
//
// A record with no finished snapshot has nothing to compare against, and
// that is its own answer rather than an error: the run was still taking the
// snapshot, so either it is under way now or it died before it had written
// anything into the repo at all.
func reportLeftovers(drivers driver.Set, rec *runrecord.Record, out io.Writer) {
	if !rec.Restorable() {
		fmt.Fprintf(out, "%s\n", indent("the run had not finished taking its snapshot: either it is still under way, or it died before it wrote anything to that repo. Nothing here can put it back; forget it once you are sure which."))
		return
	}
	paths, err := drivers.Leftovers(rec)
	if err != nil {
		fmt.Fprintf(out, "%s\n", indent(fmt.Sprintf("could not work out what the run left in there: %v", err)))
		return
	}
	if len(paths) == 0 {
		fmt.Fprintf(out, "%s\n", indent("left nothing in there that git can see — an empty directory the run made is still possible, and restoring removes those too"))
		return
	}
	fmt.Fprintf(out, "%s\n", indent("left in that repo:"))
	for _, p := range paths {
		fmt.Fprintf(out, "%s\n", indentUnder(p))
	}
}

// restoreUnfinishedRun is the deliberate half of the backstop: the rollback
// archimedes would have run on the spot, run later by somebody who has read
// what the record says.
func restoreUnfinishedRun(drivers driver.Set, dir runrecord.Dir, id string, force bool, out io.Writer) error {
	rec, err := dir.Find(id)
	if err != nil {
		return err
	}
	if !rec.Restorable() {
		return fmt.Errorf("run record %s holds no finished snapshot, so there is nothing here to put %s back with", id, rec.Repo)
	}
	// Refused rather than raced. The rollback deletes what the run added,
	// and a run still under way is still adding — so this is the one case
	// where acting on a record does the exact harm the record exists to
	// prevent. The way out is named, because a pid outlives its process
	// as a number: after a reboot it may belong to something else, and
	// only the operator can see that.
	if rec.RunStillAlive() && !force {
		return fmt.Errorf("the run that left %s still looks like it is running (pid %d), and putting %s back would delete what it is writing. Wait for it to finish, or pass --force if that pid is not that run — a record can outlive a reboot",
			id, rec.Pid, rec.Repo)
	}

	if err := drivers.PutBack(rec, out); err != nil {
		// Kept, not cleared. A rollback that could not be made has undone
		// nothing, and the record is the only thing standing between that
		// repo and being forgotten about.
		return fmt.Errorf("could not put %s back: %w", rec.Repo, err)
	}
	fmt.Fprintf(out, "%s is back as the run found it.\n", rec.Repo)
	if err := rec.Close(); err != nil {
		return fmt.Errorf("the repo is back, but the record at %s could not be cleared away: %w", rec.Where(), err)
	}
	return nil
}

func forgetUnfinishedRun(dir runrecord.Dir, id string, out io.Writer) error {
	rec, err := dir.Find(id)
	if err != nil {
		return err
	}
	if err := rec.Close(); err != nil {
		return err
	}
	fmt.Fprintf(out, "Forgot %s. %s is left exactly as the run left it.\n", id, rec.Repo)
	return nil
}

// runsPlural keeps the count and the noun in one place, since the sentence
// reads as a headline and "1 runs" in it is the whole report looking
// unfinished.
func runsPlural(n int) string {
	if n == 1 {
		return "1 run"
	}
	return fmt.Sprintf("%d runs", n)
}
