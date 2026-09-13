# Drivers

A driver is whatever actually produces a repo's context map — an AI coding
agent, a wrapped third-party CLI, a script. `context-map` orchestrates
*which* repos need mapping and in what order; it never knows how any given
driver does its job. That split is the point: swapping the configured driver
never requires touching orchestration.

## Which drivers exist, and who owns them

Two places, and the difference is who maintains what:

- **This directory is yours.** Anything you put here is the instance's.
  Nothing ever overwrites, refreshes or removes it, and no upgrade to
  `archimedes` will touch it. It starts empty.
- **Archimedes ships a few drivers inside the binary** — `openspec`,
  `pocock`, `spec-kit` — and reads them out of it at the moment one runs.
  They are never copied into an instance. That is deliberate: it is what
  lets a bug fixed in one of them reach *your* instance, which already
  exists, the next time you upgrade the tool — however you installed it. A
  driver that scaffolds a third-party toolchain into someone else's
  repository and unwinds it afterwards is not a thing you want a stale copy
  of.

The `drivers` listing shows what this instance can run, and where each one
comes from.

A name in this directory **wins** over a shipped one. So an instance that
writes its own `spec-kit/` gets its own, always, and the listing marks it
`shadows built-in` — a reminder that fixes to the shipped `spec-kit` no
longer reach you, which is the deal you took when you took it over.

### Editing a driver Archimedes ships

Take it over first:

`drivers adopt spec-kit` copies the whole driver — command and manifest —
into `drivers/spec-kit/`, runnable, for you to edit, along with the shared
helpers it sources into `drivers/lib/` (see below). From then on it is yours
by the rule above. To hand the name back to the version Archimedes
maintains, delete `drivers/spec-kit/`.

A `drivers/lib/` you already have is left exactly as it is — it is yours by
the same rule, and adopting a second driver that sources it must not
overwrite an edit you made there. The corollary is that handing a driver
back leaves `drivers/lib/` behind: delete that too, unless another driver of
yours sources it. A stale one left there is a copy no adopt will refresh and
no upgrade will reach.

It is a one-time act, not a subscription: nothing re-syncs an adopted
driver, in either direction, and adopting over one you already have is
refused rather than resolved.

**If your instance predates this arrangement** it may still hold copies of
`openspec/`, `pocock/` and `spec-kit/` that were scaffolded into it. Those
copies still run, and no fix made to the shipped drivers will ever reach
them — the `drivers` listing flags each one as `shadows built-in`. Delete
the ones you never edited; keep (and own) the ones you did.

## Selecting a driver

`repos.yaml`'s top-level `driver` field sets the instance-wide default,
used for any repo that doesn't set one of its own:

```yaml
driver: openspec
repos:
  - name: some-repo
    ...
```

A single repo can override that default for itself alone by setting its own
`driver` field — this takes precedence over the instance-wide default when
both are present:

```yaml
repos:
  - name: some-repo
    driver: openspec       # this repo always uses openspec, regardless of the default above
  - name: other-repo
    driver: null            # falls back to the instance-wide default (or interactive, if unset)
```

If neither is set, `ARCHIMEDES_DRIVER=<name>` (checked when `repos.yaml` has
no top-level `driver`) is a per-invocation way to set the same instance-wide
default without editing the file. Leaving every level unset falls back to an
interactive, human-in-the-loop session.

`ARCHIMEDES_DRIVERS_DIR=<path>` moves *this* directory somewhere else for
one invocation — useful for trying a driver you are writing without putting
it in the instance yet. It moves the instance layer only: the drivers
Archimedes ships stay underneath whatever it names, so pointing it at a
scratch directory holding one driver still leaves the other three
resolvable.

Naming a driver neither this directory nor the binary supplies — at either
level — is a misconfiguration: the run fails immediately with an "unknown
driver" error naming both places it looked, rather than silently falling
back to the interactive session.

## Writing one of your own

A driver lives in its own directory here, named after itself:

```
drivers/
  lib/            # helpers more than one driver sources — not a driver itself
  <name>/
    driver.yaml   # manifest
    <command>     # the executable named in the manifest, run.sh by convention
```

The command has to be executable (`chmod +x`) — Archimedes runs it, it does
not source it. Anything the command *sources* rather than runs should stay
non-executable; `lib/repo-snapshot.sh` is the worked example.

`lib/` is where a helper goes once more than one driver needs it. A driver
reaches it at `../lib/` relative to its own directory, which resolves the
same way whether the driver is yours or was read out of the binary. It
declares no manifest, so it is not a driver: it never appears in the
`drivers` listing, and naming it is an unknown driver like any other name
nothing supplies. A helper only one driver uses can just sit beside that
driver's command instead.

A driver is handed its own directory in the sense that files beside its
command are there to be sourced or read — but not as durable storage. A
shipped driver is unpacked somewhere fresh for each run and thrown away
afterwards, so anything written beside the command is gone by the next one.
State that has to survive belongs in the repo being mapped, or in the output
path the driver was given.

That unpacking uses the system temp directory. On a machine that mounts it
`noexec`, the shipped drivers cannot run from it — point `TMPDIR` somewhere
executable. Drivers in this directory are unaffected, so the symptom is that
only the shipped ones fail.

## Manifest (`driver.yaml`)

```yaml
name: <name>              # must match the directory name
description: <string>     # human-readable, one line
output_mode: path-parameterized
command: run.sh            # path to the executable, relative to this directory
```

`output_mode` declares which invocation contract the driver honors. Two
modes are supported:

- **path-parameterized** — the driver accepts an explicit output location and
  writes exactly there. `run-driver <name> <repo-path> <output-path>`
  invokes it as:

  ```
  <driver-dir>/<command> <repo-path> <output-path>
  ```

  `<repo-path>` is an absolute path to the target repo. The driver must
  write its finished context map to exactly `<output-path>` (creating parent
  directories as needed) and exit non-zero — without leaving a file behind —
  on failure. A zero exit with no file at `<output-path>` is treated as an
  error.

- **fixed-location** — the driver can't be told where to write; it always
  writes into whatever repo it's run in, at a fixed path relative to that
  repo's root. The manifest must also declare `fixed_path` (e.g.
  `CONTEXT.md`). `run-driver <name> <repo-path> <output-path>` invokes it
  as:

  ```
  <driver-dir>/<command> <repo-path>
  ```

  The driver must write to exactly `<repo-path>/<fixed_path>` and exit
  non-zero — without leaving a file behind — on failure. Archimedes then
  harvests that file itself: it moves (not copies)
  `<repo-path>/<fixed_path>` to `<output-path>`, so the canonical copy ends
  up wherever the caller asked and the target repo is left with no trace of
  it. A zero exit with no file at `<repo-path>/<fixed_path>` is treated as
  an error, same as path-parameterized.

  `fixed_path` may be nested (`.specify/memory/constitution.md`); after
  moving the file out, the directories that move emptied are removed too,
  stopping at the first one that still holds something. `git
  status` wouldn't have caught those — git doesn't track directories — but
  they're a trace of the run all the same.

  "No trace" is a joint obligation, and the half Archimedes can't
  discharge belongs to the driver: it must leave the target repo exactly as
  it found it apart from `<fixed_path>`. Neither shipped driver in this mode
  gets that for free. `spec-kit` has to scaffold a whole toolchain into the
  repo before it can produce anything; `pocock` writes only one file itself,
  but what it *runs* is an agent session with write access to the repo, and
  a sentence in a prompt is not a guarantee. Both take the same route:
  snapshot the repo, then put back whatever the run added or changed, on
  every exit path including the interrupt. `lib/repo-snapshot.sh` is that
  route written down, and it generalizes to any driver in this position
  (`drivers adopt spec-kit` puts a copy here to read).

  **One thing that route cannot put back, and no driver should claim it
  can.** The repos you point these at are repos you are working in, so they
  are normally dirty, and undoing a run must not mean undoing you: anything
  already in the working tree when the run starts is left exactly as it is.
  That is right until the run *writes* to one of those paths. Nothing keeps
  a copy of what an uncommitted file said — keeping one would mean holding
  the contents of every untracked path in the repo, `node_modules` included
  — so a session that rewrote your uncommitted `src/index.js` leaves it
  rewritten, and `git checkout` would only make it worse by throwing your
  edit away too.

  What `lib/repo-snapshot.sh` does instead is notice and say so. It records
  a hash of each path you have work in flight in, compares afterwards, and
  names on stderr the ones the run wrote over or removed — so the run tells
  you, once, at the moment it happens, rather than leaving you to find the
  file rewritten some other day. `pocock` fails the run on top of that;
  `spec-kit` succeeds and still says it.

  That covers what you keep in git and what you keep beside it, because
  "ignored" is two populations and not one. `node_modules` is ignored because
  it is regenerable and nobody would miss it; a `.env`, a
  `.claude/settings.local.json`, a local config you keep out of git on purpose
  are ignored for the opposite reason — not because they do not matter, but
  because they are not the repo's to carry. Those are exactly what a session
  being helpful about configuration writes into, so they are fingerprinted
  like anything else, and a run that writes over one says so.

  Says so, and stops there. `pocock` refuses a run that wrote anything beyond
  its map, and it works that refusal out from the same diff — so making the
  ignored files count as "wrote something" would have made them count as
  "failed", and a driver that throws away a billed session because an agent
  touched a log file has been made worse rather than better.
  `paths_changed_since_snapshot`, which is the list a driver fails on, leaves
  them out; `restore_repo_state`, which only tells you, names them. An ignored
  file the run *created* is a different matter and always has been: it is new,
  nothing of yours was in it, and it has always failed the run.

  What keeps that affordable is that git already separates the two:
  `git status --porcelain --untracked-files=normal --ignored=traditional`
  collapses a directory every entry of which is ignored to a single
  `node_modules/` line and never descends into it, while listing an ignored
  *file* by name. On a 113 MB, 28,971-file `node_modules` beside one `.env`,
  the whole listing is two lines and exactly one path gets hashed. The
  untracked mode is spelled out because it, not `--ignored`, is what does the
  collapsing — and it is a config setting, so a repo with
  `status.showUntrackedFiles = all` would otherwise list all 28,971 of them
  and one with `no` would report nothing ignored at all.

  **The line it stops at**, then, is the inside of a wholly-ignored directory,
  plus a cap. Nothing under `node_modules/` is looked at, so a run that
  rewrites something in there is not reported — which is the cost judged worth
  keeping. And because tidy ignore rules are an assumption rather than a
  guarantee — a `*.log` pattern matching files that sit among tracked ones has
  git list every one of them individually — the fingerprinting stops after
  **500** of those ignored files. On 20,001 of them totalling 78 MB, hashing
  the lot takes 1.5s against 0.08s for the first 500. A repo that trips that
  cap is told so on every run, whether or not anything was written over —
  because on such a repo the usual silence does not mean *nothing of yours was
  written over*, it means *nothing among the part I looked at*, and those are
  not the same sentence.

  One more path is exempt from *that* report, for a different reason: the
  driver's own `fixed_path`. Writing that file is what the run is *for*, so
  counting it as a loss would fail every `pocock` run against a repo that
  already had a `CONTEXT.md` in flight — which is most of the repos worth
  pointing it at.

  Exempt from the losses is not the same as unmentioned, though, because
  Archimedes then *moves* that file out of the repo by contract. So if you
  had uncommitted work sitting at `CONTEXT.md` when a `pocock` run started,
  the run replaced it and the harvest carried the result away, and both of
  those are the run succeeding. `report_kept_paths_replaced` says so on the
  driver's success path — an ordinary note naming the file, not a warning —
  and the success path is the only place that can: on a failure the
  `fixed_path` is not kept, and by the time the rollback runs it has already
  gone. Commit it first if you want to keep it.

  **Every one of those answers can also come back as "I could not find
  out", and a driver has to keep that apart from "there was nothing to
  find".** They are lists of paths, so the answer meaning *the run touched
  nothing of yours* is an empty list — which is exactly what a helper that
  could not do its job at all would otherwise hand you. So each of them
  returns non-zero instead, and a driver that reads the list without reading
  the status will one day tell you your repo came through clean on the
  strength of a question nobody managed to ask.

  Two of them you answer by failing. `restore_repo_state` and
  `paths_changed_since_snapshot` returning non-zero mean the run cannot
  promise what it was going to promise about your repo, and both shipped
  drivers say so: `could not roll <repo> back to how it was found -- it
  needs looking at by hand`. `report_kept_paths_replaced` is the one that
  must not: it runs on the success path, after the harvest is settled, so a
  bare call under `set -e` would fail a run that genuinely succeeded over a
  courtesy note. Guard it the way the shipped drivers do, and say the note
  could not be worked out rather than saying nothing:

  ```bash
  report_kept_paths_replaced "$REPO_PATH" "$SNAPSHOT" "$FIXED_PATH" \
    || echo "could not work out whether this run replaced uncommitted work at $REPO_PATH/$FIXED_PATH" >&2
  ```

  For the drivers Archimedes ships, all of that is checked rather than taken
  on trust: `tests/fixed_location_conformance.sh` in the Archimedes
  repository finds every driver declaring this mode by reading the manifests
  — no list to add one to — points each at a throwaway repo with a stub
  standing in for the CLI it runs, has that stub write past the declared
  `fixed_path` the way a real scaffolder or a real agent session does, and
  asks the one question the contract turns on: did the repo come back as it
  was found? It asks it of both ways a run can end — one allowed to finish,
  and one stopped by a signal while its session is still writing (see *Being
  stopped* below).

  Then it asks the same question of a repo that was already dirty, with the
  session writing over the part that made it dirty — the case above, the one
  no driver can undo. What it requires there is the nearest thing that can be
  had: the repo comes back dirty in exactly the way it started dirty, and the
  run *names* the file it wrote over. A driver that tidied up silently around
  it fails, the same as one that left files behind.

  And last it does that again with the uncommitted work sitting at your own
  declared `fixed_path`, which is the case the repo afterwards cannot answer:
  keeping that file is the contract, the harvest then moves it out, and what
  comes back is pristine — indistinguishable from a run against a repo that
  never had one. So what is required there is the note: the run has to name
  the `fixed_path` it replaced. A driver that replaced an operator's
  half-written map, harvested it away and said nothing fails there, having
  passed everything above it. All four checks run on every push and cost
  nothing, and a driver added there needs no test of its own to be held to
  them.

  A driver *you* write here is outside that suite's reach — it runs in the
  Archimedes repository, over the drivers that ship from there — so this
  half of the promise is yours to keep. `lib/repo-snapshot.sh` is the route,
  and `drivers adopt spec-kit` puts a worked example beside it.

  What a driver does about the leftovers it finds is its own call, and the
  two shipped ones answer differently on purpose. `spec-kit`'s scaffolding
  was always going to be there, so putting it back is routine and the run
  succeeds. `pocock`'s session was asked for one file, so anything else is
  the prompt having lost an argument with a non-deterministic agent: it puts
  the files back, names them, and fails the run rather than harvesting a map
  from a session that would not keep to what it was told.

## Being stopped

A driver runs in a process group of its own, and every `SIGINT` or `SIGTERM`
that reaches Archimedes is passed on to that group — the command, and
anything it started. Archimedes then goes back to waiting: it does not exit
until the driver has, so whatever the driver writes on its way out reaches
the operator.

Two things follow for a driver you write:

- **You are the only thing that can put the target repo back.** The signal
  is delivered so that your cleanup gets to run, and Archimedes waits so
  that it has time to. Nothing outside your process undoes what a run left
  in someone else's repository. `lib/repo-snapshot.sh` is the route, and its
  `exit_on_interrupt` is what turns the signal into a trip through your exit
  trap.
- **Exit `128 +` the signal's number** — 130 for a `SIGINT`, 143 for a
  `SIGTERM`. Archimedes passes that straight through to whoever ran it
  rather than inventing a status of its own, so it is the only thing a
  supervisor, a `timeout(1)` or a parent harness has to read to find out how
  a run ended and whether the repo was left clean.
- **Arm the traps before anything writes to the target repo.** A run can be
  stopped in its first milliseconds, and a signal that arrives before your
  traps are set is one your shell takes the default action on — no exit
  trap, no rollback. Archimedes cannot close that window for you: there is
  nothing to forward to before there is a process. What makes it harmless is
  ordering. Snapshot and arm first, scaffold second, and a signal that beats
  your traps also beats anything there would have been to undo. Both shipped
  drivers that put a repo back — `pocock` and `spec-kit` — are written that
  way, and for the drivers Archimedes ships that is checked rather than
  trusted: the conformance check above stops a run at the moment its stub
  session is writing in the repo, which is a moment a driver that armed
  first can act on and one that armed afterwards cannot. `openspec` is not
  written that way, and does not need to be: it is path-parameterized, so it
  never promised the repo back and rolls nothing back on any exit path.

Only the *first* signal is forwarded. An operator who hits Ctrl-C again
because the first appeared to do nothing is told what is being waited for
instead, because a second copy would land in a rollback already running and
leave the repo between two states. So a driver gets one interrupt and as
long as it needs to act on it.

What no arrangement here can cover is `SIGKILL`, which can neither be
forwarded nor trapped: a driver killed that way leaves the target repo
exactly as its session left it. `lib/repo-snapshot.sh` names that window and
the others beside it.

## Trying one directly

Every driver can be exercised outside of a mapping pass, with
`run-driver <name> <path-to-a-repo> <path-to-write-the-map-to>`.

## The drivers Archimedes ships

These come from the binary, not from this directory (see the ownership rule
above). The `drivers` listing shows whichever ones your install carries.

- `openspec` — wraps the [OpenSpec CLI](https://github.com/Fission-AI/OpenSpec)
  (`npm install -g @fission-ai/openspec`). Initializes OpenSpec in the target
  repo if needed, then captures `openspec context`'s working-context report
  as the context map.
- `pocock` — wraps [Matt Pocock's `domain-modeling`
  skill](https://github.com/mattpocock/skills) via a headless `claude -p`
  session. The skill always writes `CONTEXT.md` at the root of whatever repo
  it's run in, so this is a `fixed-location` driver (`fixed_path:
  CONTEXT.md`) — requires the `claude` CLI and the `domain-modeling` skill
  installed, plus bash 4+ and a target that is a git repo (both checked
  before the session starts, so a machine that cannot support the rollback
  fails the run rather than paying for one it cannot clean up after).

  Its prompt asks the session to write that one file and nothing else, at
  length, because the skill's own criteria call for ADRs — so the prompt is
  arguing with the thing it invokes, on every run, and will sometimes lose.
  The driver assumes it will: it snapshots the repo first, puts back
  everything the session wrote beyond `CONTEXT.md`, and fails the run naming
  those files. That throws away a billed session's usable map, deliberately.
  A run that quietly deleted an agent's work in your repository and reported
  success would leave you with no way to know the prompt had stopped
  working.

  Where the session wrote over work *you* had left uncommitted, the run
  fails naming those files too — but they stay written over, because nothing
  holds a copy of what they said. That is the one part of "put back" the
  driver does not deliver, and the failure says so rather than implying
  otherwise.
- `spec-kit` — wraps [GitHub's Spec Kit](https://github.com/github/spec-kit)
  (`uv tool install specify-cli --from
  git+https://github.com/github/spec-kit.git`), also via a headless `claude
  -p` session. Requires both the `specify` and `claude` CLIs, and bash 4+
  (checked before anything is written, so an old bash fails the run rather
  than stranding a half-unpacked toolchain in the target repo).

  Spec Kit is the awkward case the `fixed-location` mode exists for. It has
  no "point at a repo, write a report over here" mode at all: `specify init`
  unpacks templates, helper scripts and agent skills into the repo, and its
  one whole-repo artifact — the constitution — is always written to
  `.specify/memory/constitution.md`. So the driver snapshots the repo,
  scaffolds, has the `speckit-constitution` skill fill the constitution in
  from the codebase, then restores everything except the constitution
  itself, which Archimedes harvests. Rollback is the driver's exit
  trap, not something on its success path, so a failed `specify init`, a
  session that does nothing, and a Ctrl-C halfway through all leave the repo
  as it was found.

  With the same exception, answered differently: where the scaffolding or
  the session wrote over work you had left uncommitted, the rollback names
  those files and the run still succeeds. Scaffolding this repo was always
  the job here, unlike `pocock`'s one-file promise, and failing the run would
  not un-write anything — so what you get is the constitution and a line
  telling you which of your own files was written over.

  The one thing that defeats it is a session that commits: everything the
  rollback reasons about is relative to the commit `HEAD` pointed at when
  the run started, so moving `HEAD` makes the scaffolding indistinguishable
  from the repo's own history — while leaving `git status` reading clean.
  The driver checks for that and fails loudly rather than reporting a
  context map for a repo it quietly left a toolchain in.

  What you get is a different shape of context map from the other two: a
  repo's *principles and constraints* — the conventions its existing code
  already follows, the boundaries between its modules, what its dependencies
  rule out — rather than `openspec`'s structural report or `pocock`'s domain
  vocabulary. Which of the three is the useful one is a per-repo judgment,
  which is why the driver is a per-repo setting.
