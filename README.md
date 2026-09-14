# Archimedes

A "control repo" / repo-of-repos pattern for planning and executing agentic
coding work that spans multiple independent git repositories.

## The problem

Once you're working across more than one or two related repos (a client SDK
and the CLI that depends on it, a core library and its several consumers),
two things get easy to lose track of:

- **Which repos does this specific unit of work actually touch?** A change
  that looks self-contained in one repo can have a silent dependent that
  needs a follow-up PR (a library release that a downstream CLI needs to
  pick up, for example).
- **Managing several of these in flight at once.** Git worktrees are the
  right primitive for parallel branches, but they're scoped to one repo at a
  time. Nothing tracks which worktrees exist across a whole family of repos,
  what their PR status is, or which ones are safe to prune.

## The pattern

A generated instance of this template becomes a sibling directory next to
your actual repo checkouts:

```
your-workspace/
├── your-instance/          # generated from this template
│   ├── WORKSPACE-MAP.md    # which repos exist, how they relate
│   ├── repos.yaml           # machine-readable source of truth
│   ├── repos/*.md           # per-repo dossier: branching, release procedure,
│   │                        # house rules, known gotchas
│   ├── work/<slug>/          # one folder per active unit of work
│   ├── drivers/              # context-mapping drivers this instance owns
│   ├── convention-packs/     # shared build/lint conventions repos declare
│   └── scaffolding/          # canonical PR/issue templates to push out
├── service-a/
├── service-b/
└── ...
```

An instance is data. It holds no tooling of its own: the `archimedes`
binary is installed once per machine and every instance on it is acted on
by that one install, so there is nothing in an instance to keep in step
with this repo. That includes the context-mapping drivers — the three that
ship ride in the binary and are read out of it when one runs, which is what
lets a fix to one reach instances that already exist. An instance's own
`drivers/` starts empty and holds only what its operator puts there, where
it takes precedence (see
[`template/drivers/README.md`](./template/drivers/README.md)).

The instance never contains the repos themselves (no submodules, no vendored
copies) — it references sibling checkouts by relative path. It also never
duplicates a repo's own domain-model/glossary docs if you keep those (e.g. a
`CONTEXT.md`), it only links to them. What it owns is the layer that has no
single-repo home: cross-repo relationships, and orchestration of worktrees
across repos for one logical change.

### Plan here, execute there

Root a planning/scoping session (a `wayfinder`/`grill-with-docs`-style pass,
or your own equivalent) inside `work/<slug>/` to answer "which repos does
this touch," using `WORKSPACE-MAP.md` and the repo dossiers for context.
Once that's answered, hand off actual implementation to a worktree spawned
in each target repo, so that session's context isn't cluttered with every
other repo in the workspace.

### Stacked work within one repo

When a unit of work needs two dependent PRs in the same repo (the second
can't land until the first merges), `archimedes spawn` supports branching a
new worktree off another in-flight worktree's branch instead of off trunk —
the "stacked branches" pattern. The stack relationship is tracked explicitly, so
tooling can prompt a rebase once the base PR merges instead of assuming the
dependent branch is still current.

### House rules

A dossier's `## House rules` section (distinct from `## Known gotchas`) is
for mandated decisions that must be respected even if unusual — the kind of
thing good judgment alone would get wrong. It's the one place they're
edited, and it's delivered two ways from there: `archimedes sync-house-rules`
pushes a durable, committed `HOUSE_RULES.md` into the target repo (so humans
browsing it on GitHub see it too), and `archimedes spawn` injects an
ephemeral copy into every worktree it spawns for that repo, automatically.

## Getting started

Install the tool once, globally (needs a Go toolchain, and `$GOBIN` —
`~/go/bin` by default — on your `PATH`):

```
go install github.com/blockadence/gh-archimedes/cmd/archimedes@latest
```

Or, if you would rather not install a Go toolchain to get it, take the same
binary out of a release as a `gh` extension:

```
gh extension install blockadence/gh-archimedes
```

That is the same program either way, and the two installs are
interchangeable — a `gh archimedes` prefix in place of `archimedes` is the
whole of the difference, and every command below works under either. (The
`gh-` on the repository name is gh's requirement of anything installable
that way, not a claim about which install is the real one.) See
[`docs/cli.md`](./docs/cli.md#the-two-installs) for what a release carries
and how to cut one.

That install downloads a binary and runs it, and TLS to github.com is the
whole of what it checks — it says the bytes came from GitHub, not that they
are the bytes this repository built. Every release asset is attested to by
the workflow run that produced it, so that binding is checkable against this
repository from the asset alone:

```
gh release download --repo blockadence/gh-archimedes --pattern '*darwin-arm64'
gh attestation verify gh-archimedes_*_darwin-arm64 --repo blockadence/gh-archimedes
```

Substitute the `<os>-<arch>` you actually run — asset names end with it,
and on Windows with a `.exe` after that, so match the pattern accordingly.
The command prints the repository and the workflow that produced the file,
and fails on anything a release run of this repository did not build — which
is what a swapped asset cannot fake, the signing identity being minted per
run rather than a key somebody holds. Add `--format json` for the commit and
the run behind it.

Check the asset you downloaded, not the copy `gh extension install` left in
`~/.local/share/gh/extensions/`. On an Apple Silicon Mac, `gh` ad-hoc
codesigns what it installs, which rewrites the file — so verifying that copy
reports no attestation for a binary that is perfectly genuine.

All of this is optional and nothing installs differently without it. There
is no GPG signature to check instead;
[`docs/cli.md`](./docs/cli.md#cutting-a-release) says why.

If you installed before the repository was renamed, the old
`go install github.com/blockadence/archimedes/...` path no longer resolves.
GitHub's redirect does not cover it — the module it serves now declares the
new path, and Go refuses a module whose declared path isn't the one asked
for. Re-run either install above. Nothing else moves: an existing binary
keeps working until you replace it, and no instance is touched either way.

Then scaffold an instance and point it at your org:

```
archimedes init <instance-name> <parent-dir-for-your-repos>
cd <parent-dir-for-your-repos>/<instance-name>
archimedes bootstrap <github-org>      # discovers + clones repos via `gh`
archimedes context-map --dry-run       # see the planned + stale/fresh order
```

Nothing here needs a clone of this repo. `init` carries the template's
starting data inside the binary and gives the new instance its own git
history, so instance-specific content never shares a history with
Archimedes; everything after that is the same install acting on that data.
An instance is never refreshed from here, and a second instance on the same
machine uses the same install.

On a machine where nobody has configured git an identity — a new laptop, a
container, a devcontainer, or simply never having got round to it — `init`
writes the instance and leaves its first commit for you, printing the two
`git config` commands to set and the commit to run. It does that even where
git would guess an author from your account and commit under it quite
happily: the instance is your repository, that commit is in its history for
good, and the name in it should be one you chose.

Where git has an identity and still refuses the commit — commit signing
configured with no key that works on that machine is the usual one — the
instance is written and kept just the same, and what `init` prints is its own
account of what happened with git's reason quoted underneath and the command
that finishes the job. It does not get past the refusal by committing
unsigned: that would put something in your history that contradicts what you
configured, which is the same objection as an author you never chose.

Running it requires `git` and `gh` (authenticated). `sync-templates`
additionally requires
[`multi-gitter`](https://github.com/lindell/multi-gitter).

### Instances made before the scripts were retired

Earlier instances carry a vendored `scripts/` directory and were refreshed
from a checkout of this repo with `update-from-archimedes.sh`. Both are
gone, as is the `scripts/init.sh` that scaffolded an instance — `archimedes
init` above is that step now. Install the binary as above, then delete the copy:

```
cd <your-instance> && git rm -r scripts && git commit -m "Retire vendored scripts"
```

Nothing else has to move: `repos.yaml`, `repos/`, `work/`, `drivers/` and
`scaffolding/` are the data the subcommands already read, and each
subcommand takes the same arguments its script did. From then on the
instance is data only, and upgrading means upgrading the binary.

An instance old enough to have had `openspec/`, `pocock/` and `spec-kit/`
copied into its `drivers/` still runs those copies, and no fix made here
reaches them. `archimedes drivers` flags each as `shadows built-in`; delete
the ones you never edited to go back to the versions the binary carries, and
keep the ones you did.

## Commands

Run from inside an instance, or from anywhere with `--root <instance>`.
`archimedes <subcommand> --help` for the full flag list; the design notes
behind each one are in [`docs/cli.md`](./docs/cli.md).

- `init <instance-name> <dest-parent-dir>` — scaffold a new instance from
  the template carried in the binary, on its own fresh git history. The one
  command that runs before an instance exists, and the only one that needs
  no instance to point at.
- `bootstrap <github-org>` — discover org repos via `gh repo list`, clone
  what's missing, scaffold `repos.yaml` and per-repo dossier stubs.
- `render-map` — regenerate `WORKSPACE-MAP.md`'s repo list from
  `repos.yaml` (the `## Relationships` section stays hand-written).
- `context-map [--dry-run]` — sequence a context-mapping pass across every
  repo, dependency/base repos first, priming each session with already-mapped
  dependencies and skipping any repo whose map is already current for its
  base branch's latest commit (tracked via `context_modeled_sha` in
  `repos.yaml`), so re-runs after new repos or merges are incremental.
  Orchestration only — it doesn't assume any particular coding agent, skill,
  or driver. By default the mapping itself is an interactive, human-in-the-
  loop session per repo (`ARCHIMEDES_AGENT_CMD`/`ARCHIMEDES_CONTEXT_PROMPT`/
  `ARCHIMEDES_CONTEXT_FILE` override the defaults); set `repos.yaml`'s
  `driver` field — or `ARCHIMEDES_DRIVER` — to a driver's name to build the
  map unattended instead (see `drivers/README.md`).
- `run-driver <driver-name> <repo-path> <output-path>` — invoke one
  driver's context-mapping contract directly, without a pass around it. A
  driver declares, in its `driver.yaml` manifest, whether it accepts an
  explicit output path (`output_mode: path-parameterized`) or always writes
  into whatever repo it's run in (`output_mode: fixed-location`, harvested
  afterward so the target repo ends up clean). Three drivers ship in the
  binary as working examples: an `openspec` driver wrapping the
  [OpenSpec CLI](https://github.com/Fission-AI/OpenSpec) for the first mode,
  and — for the second — a `pocock` driver wrapping Matt Pocock's
  `domain-modeling` skill and a `spec-kit` driver wrapping
  [GitHub's Spec Kit](https://github.com/github/spec-kit), which has to
  scaffold itself into the target repo and strip that back out again.
- `unfinished-runs` / `unfinished-runs restore <id>` / `... forget <id>` —
  the target repos a driver run was still working in when it died. A driver
  that scaffolds into someone's repository undoes it on its way out, and
  where the driver is killed outright — a `SIGKILL`, an OOM kill, a machine
  losing power — `archimedes` re-runs that rollback itself from the snapshot
  it was handed before the run started. This is what is left when
  `archimedes` was killed too: a record on disk naming the repo, what the
  run left sitting in it, and `restore` to put it back when you say so.
  Reporting only until then — acting means writing to a repository on the
  strength of a run that may be days old.
- `drivers` / `drivers adopt <name>` — list every driver this instance can
  run and which of the two places it comes from: the instance's own
  `drivers/`, which nothing ever refreshes, or the binary, where a fix
  arrives with the next upgrade. `adopt` copies a shipped driver into the
  instance to edit, taking it over — an instance driver wins over a shipped
  one of the same name, and the listing says so.
- `spawn <slug> <repo> [--base <branch>|--stack-on <repo>:<slug>]` —
  fetch-first worktree creation for one unit of work in one repo. Also
  materializes `work/<slug>/`'s contents (a ticket, a spec, whatever
  reference material the planning session left behind), plus the target
  repo's house rules (see above), into the new worktree at `.archimedes/`,
  and makes sure that directory can never show up in `git status`/`git add
  -A` or get committed there — no `.gitignore` edit needed in the target
  repo, and removing the worktree removes the copy with it.
- `status [<slug>] [--json]` — live PR/branch status across every spawned
  worktree, with a warning past a configurable concurrent-stream cap. Also
  flags stacked branches whose base merged by squash or rebase, where the
  dependent branch would otherwise re-propose work that has already landed.
- `prune [<slug>] [--force]` — list (or, with `--force`, remove)
  worktrees/branches whose PR has merged or closed. Refuses to remove a
  branch still acting as another worktree's stack base.
- `sync-templates [--dry-run] [<repo-name>]` — push the canonical PR/issue
  templates (`scaffolding/`) into every tracked repo's `.github/` as a pull
  request, via `multi-gitter`. `--dry-run` shows which repos would receive
  changes without pushing or opening anything; an optional repo name limits
  the run to one repo. Requires `multi-gitter` and `gh auth login`.
- `sync-house-rules <repo> [--dry-run]` — push one repo's house rules
  (the `## House rules` section of its dossier, `repos/<repo>.md`) into that
  repo as a durably committed `HOUSE_RULES.md`, via a pull request. Content
  is per-repo rather than identical across every tracked repo, so — unlike
  `sync-templates` — this isn't a `multi-gitter` fan-out; it opens the PR
  itself via `gh`. `--dry-run` shows the pending diff without committing,
  pushing, or opening anything. A no-op once the target repo's copy already
  matches the dossier.
- `apply-convention-pack <repo>` — one-time scaffold: add whatever
  dependency/plugin reference a repo's declared `convention_pack` (see
  `repos.yaml` and `convention-packs/`) needs to start pulling in its shared
  build/lint/static-analysis config. Idempotent; not an ongoing sync.
- `notify`, `dashboard`, `serve-mcp` — three ways to look at an instance
  rather than act on one; see below.

`dashboard` is a live, interactive view of the whole instance — every
spawned worktree with its PR state and any rebase it's owed, alongside each
repo's context-map staleness — refreshing in place instead of printing once.
It is purely additive, a second way to look at what `status` and
`context-map --dry-run` already report, reading the same code they do. See
[`docs/cli.md`](./docs/cli.md#dashboard-optional).

`notify` reports the two things you would otherwise have to remember to go
and check — a repo whose context map has gone stale, a worktree whose PR has
merged and is ready to prune — once each, when they become true. It keeps no
background process of its own: each pass compares what holds now against a
state file beside `repos.yaml` and exits, so a cron or launchd entry is the
whole mechanism, and a pass with nothing new prints nothing.
`ARCHIMEDES_NOTIFY_CMD` hands each notification to whatever notifier you
already run; with it unset they are printed, which is all cron needs to
turn them into mail. See [`docs/cli.md`](./docs/cli.md).

`spawn` can additionally open the new worktree as a workspace in a
terminal workspace manager ([herdr](https://herdr.dev) today), so a unit of
work arrives in a pane already rooted at its own checkout. It is off unless
you opt in with `ARCHIMEDES_WORKSPACE=herdr` or `--workspace herdr`
(`--focus` to switch to the new workspace rather than open it in the
background), and a workspace manager that isn't installed or isn't running
degrades to a note — the worktree is created either way. See
[`docs/cli.md`](./docs/cli.md#terminal-workspace-integration-opt-in).

`serve-mcp` serves one instance over the Model Context Protocol, so an
MCP-capable agent tool can list tracked repos, read worktree and PR status,
check context-map staleness, and spawn a unit of work as structured tool
calls rather than shelling out to the CLI and parsing its tables. It is a
second way in, not a replacement: every tool delegates to the same code the
equivalent subcommand does. See
[`docs/cli.md`](./docs/cli.md#mcp-server).

## Language-tooling convention packs

A repo can declare, via `convention_pack` in `repos.yaml`, which shared
build-tooling convention it's meant to follow — e.g. a Java repo pointing at
a shared Gradle convention plugin for Checkstyle/Spotless/JaCoCo. The pack
itself (language, build tool, and the shared artifact + version that carries
the config) is defined once in `convention-packs/<pack-name>.yaml` and
referenced by name from any repo that follows it. This is documentation
plus a one-time scaffold, not ongoing config-file distribution — see
`template/convention-packs/README.md` for the shape and how to add a pack
for another language/build tool.

## Status

Personal tool. Unfinished edges are called out as TODOs rather than papered
over. Use at your own judgment.

## License

MIT, see [LICENSE](./LICENSE).
