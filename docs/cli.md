# archimedes (CLI)

The tool, installed once per machine and independent of any instance. An
instance is pure data (`repos.yaml`, `repos/*.md`, `work/`, `drivers/`,
`scaffolding/`) — this binary is the only thing that acts on it, so every
instance on a machine is served by one install and none of them carry a
copy of anything. Not one file of an instance is a program: the drivers
ship in here too (see "Two embedded trees" below).

## Build / install

```
go build ./cmd/archimedes            # local binary at ./archimedes
go install ./cmd/archimedes          # installs `archimedes` to $GOBIN
```

From anywhere, with no checkout:

```
go install github.com/blockadence/gh-archimedes/cmd/archimedes@latest
gh extension install blockadence/gh-archimedes
```

Requires `git` and `gh` (authenticated); `sync-templates` additionally
requires `multi-gitter`. Each subcommand checks for what it needs before it
starts.

## The two installs

The tool is installed either as a standalone `archimedes` on `$PATH` or as
a gh extension invoked `gh archimedes`. The second is additive and came
later; what makes it cheap is that it is not a second build, a second entry
point, or a second code path. gh installs an extension by downloading one
binary out of a GitHub release and running it with the subcommand and flags
forwarded verbatim, so the artifact a release carries is the same artifact
`go install` would have produced, and by the time `main` runs the two are
indistinguishable.

Three things had to be true for that, and each is guarded by
`tests/gh_extension_packaging.sh`, which drives the real release build
rather than a copy of its recipe.

**Every subcommand works with no checkout beside it.** An extension install
is a lone binary in `~/.local/share/gh/extensions/`; there is no clone of
this repository anywhere near it. That is not a packaging concern so much
as the thing that had to be settled first — it is why the instance template
and the drivers are carried inside the binary (see "Two embedded trees"
above) rather than copied out of a checkout.

**The name in the help is the name that was typed.** The one thing gh
cannot forward is what it was called: an operator who typed `gh archimedes`
and is answered with `archimedes spawn <slug> <repo>` has been handed a
command they have not got. gh announces itself by setting `GH_EXTENSION=1`
(documented in `gh help environment` for exactly this); `internal/invocation`
is the one place that reads it, and `Name()` is what every operator-facing
string is built from.

`newRootCmd` feeds it to cobra as the display-name annotation, which
rewrites the whole tree's usage lines at once — as an annotation rather
than as `Use`, because the first word of `Use` is the command's *name*, and
a two-word `Use` would make every subcommand a child of something called
`gh`. The prose around those usage lines gets no such sweep, and neither
does runtime output: `init`'s "run this next" line, the dashboard's empty
states, the command a notification says to run about a condition. Those are
ordinary strings and are formatted with `invocation.Name()` one at a time,
which is the part that rots quietly — so a test walks the command tree
under `GH_EXTENSION=1` looking for any `archimedes <subcommand>` that
should have been `gh archimedes <subcommand>`.

Two kinds of mention deliberately stay fixed, and the test is scoped to
`archimedes <subcommand>` so that they can:

- Prose naming the program as a thing rather than as something to type —
  "the drivers archimedes ships", "inside the archimedes binary" — which is
  the same program under either install.
- Anything this tool writes into somebody else's repository: the
  `HOUSE_RULES.md` `sync-house-rules` commits into a target repo, the PR
  templates `sync-templates` pushes. Keying a committed file's content to
  how the operator who generated it happened to install would put a
  spurious diff in every such repo the first time somebody with the other
  install ran the sync. The MCP tool descriptions stay fixed for the same
  reason: they document which subcommand a tool is equivalent to, to an
  agent that is not going to type either.

What the tool writes into the operator's *own* instance — the template
`init` scaffolds, the dossier stubs `bootstrap` writes — is held to that
same rule and then one more, since those files exist to tell a reader what
to run. See "What an instance's own docs name" below.

**The binary knows which build it is.** See below.

### What an instance's own docs name

The template `init` scaffolds sits on the file side of that line and cannot
be settled by holding one form fixed: an instance's `README.md`,
`AGENTS.md` and `drivers/README.md` exist to tell a reader what to run, and
half of those readers installed the other way. Substituting the invoking
form as `init` writes is the tempting fix and is wrong for the reason the
bullet above is right — the instance's committed content would then record
which install created it, and read wrong for the teammate with the other
one. `TestAScaffoldedInstanceIsTheSameHoweverItWasInvoked` holds that shut,
and `tests/gh_extension_packaging.sh` holds it shut against the real
release artifact.

So the template names no invocation at all. It names the subcommand alone —
`spawn`, `run-driver <name> <repo-path> <output-path>`, "the `drivers`
listing" — and says once, in `README.md` under "Running a command", what an
operator puts in front of it. `AGENTS.md` points at that section rather
than restating it, because its reader is a coding agent that will do as it
is told and otherwise reach for a binary that may not be on the `PATH`. The
only fenced invocation in the whole template is the one in that section,
which shows both forms.

The template is not the only thing written into an instance, and the rule
is about the instance rather than about any one of the code paths that fill
it. The dossier stub `bootstrap` scaffolds into `repos/<repo>.md` is the
same class of file with the same readers — an operator edits it, the
instance commits it, a teammate or agent with either install reads it — so
it follows the same convention, naming `sync-house-rules` and `spawn` alone
and leaving the form to the README section.

Rewording that stub costs more than rewording a template file, because
`internal/dossier` matches it byte-for-byte to tell an untouched
placeholder from a real house rule — the package's worst failure being
instructional boilerplate delivered into somebody's repository as a
mandated rule. So each wording it has ever written stays listed in
`retiredStubBodies`, where a dossier scaffolded under an older one still
reads as having no house rules recorded. Entries are added, never removed:
knowing one is gone would mean knowing no dossier anywhere still carries
it.

That is a prose convention, so it is guarded like one, and guarded over the
artifact rather than over a list of the writers of it:
`TestAScaffoldedInstanceNamesNoCommandHalfItsReadersHaventGot` scaffolds a
real instance — `init`, a `bootstrap` pass over a fake org, then a `spawn`
in it — and reads every file it holds against the real subcommand list,
flattening hard wraps first because `archimedes` and its subcommand can sit
on two lines. What a subcommand writes into an instance is covered by being
in the instance rather than by anything naming it; a subcommand added later
is covered by joining that scaffolding, which is also what holds it to
`TestAScaffoldedInstanceIsTheSameHoweverItWasInvoked`. Two companions hold
the other end: that the README section still exists and still shows both
forms, and that
`AGENTS.md` still names it, since a renamed heading would leave the one
cross-reference an agent follows pointing at nothing. A sentence added
later that spells an invocation out fails the suite rather than shipping.
Instances that already exist keep the docs they were scaffolded with:
nothing refreshes a template file into an instance, which is the same rule
that makes the seeded content theirs (see "Two embedded trees").

The earlier shape of that check was a list of the sites — one walk over the
embedded template, one over a freshly written dossier stub — and it failed
the way a list does. The stub was not a template file, nothing looked at
it, and it told its readers to run `archimedes sync-house-rules` for months
after the convention it broke was written down. Adding a second hand-named
walk fixed that file and left the same gap in front of the third, which
turned out to exist: the `work/<slug>/status.md` `spawn` writes was in no
list and is in the instance.

Where the read is rooted is the whole of the other exemption. `bootstrap`
clones the org's repos as *siblings* of the instance and `spawn` puts their
worktrees beside them again, so one directory higher would be reading
repositories this tool only writes into, whose content is deliberately
fixed under both installs. The test stands one of those files in beside the
instance and asserts it was never read, so moving the root fails saying so
rather than quietly starting to police somebody else's repo.

`scaffolding/` is the opposite case and stays in: it lives inside the
instance and is pushed into other repos, which is a stricter rule than this
one rather than a different one, so it has nothing here to fail.

### Version

`--version` has to answer "which build is this?", and a downloaded release
artifact is the case that makes it matter: there is no working tree beside
it to look at instead, so whatever the binary says is the only evidence
there is. `internal/version` assembles that answer from whichever of the
three build routes ran, most authoritative first:

1. **A release build links the tag in**, with a `-ldflags` `-X` against
   `internal/version.stamped`. `.github/release-build.sh` is the only thing
   that passes it. This is the route the criterion is about, and the only
   one available to a downloaded artifact.
2. **Otherwise the module system answers for itself**, and since Go 1.24 it
   answers for more than it used to: `go install <module>@v1.2.3` reports
   that version, and a plain `go build` from a checkout reports a
   pseudo-version synthesized from the commit —
   `v0.0.0-20260907224930-f96985b1261c+dirty`, carrying the sha and a
   `+dirty` marker for a modified tree. It is passed through exactly as
   given: it is built from the same VCS stamps anything here would use, and
   is already the better answer than one reassembled by hand.
3. **Failing both, `dev`.** `(devel)` is the module system saying it has
   nothing to give, and passing *that* through would be reporting a
   placeholder as a version, which is the thing this exists to stop.

(3) is narrower than it looks, and worth knowing exactly because this
project is worked on in worktrees: it means a build whose toolchain
recorded nothing at all — `-buildvcs=false`, or a build made inside a git
worktree, which Go does not recognise as a checkout because it looks for a
`.git` *directory* and a worktree's is a file. In an ordinary checkout you
get (2). Nothing works around the worktree case; neither route that
installs the tool comes through there.

The version is not only for `--version`. `serve-mcp` reports it to the
agent tool on the other end of the protocol, which has even less ability to
go and look.

### Cutting a release

Tag and push; `.github/workflows/release.yml` does the rest.

```
git tag v0.1.0 && git push origin v0.1.0
```

The workflow runs the test suites first (`needs: test`, calling the same
job a push runs) and publishes only if they pass, so a tag on a red tree
produces no release, no assets, and no half-uploaded matrix.

That gate is the free suite, deliberately: it needs no credential and
reaches no billed API, so a release never waits on somebody else's service.
The billed half — the two live driver tests — is a `workflow_dispatch` away
and worth running by hand first; see [The live driver tests](#the-live-driver-tests).

`.github/release-build.sh` builds the platform matrix; the workflow hands it
to the action as `build_script_override`. `cli/gh-extension-precompile`
creates the release as a draft and attaches the binaries it is handed; the
workflow's own last step verifies them and promotes the draft. A tag
containing a `-` (`v0.2.0-rc.1`) publishes as a prerelease, which `gh
extension install` will not hand to anyone — the safe way to exercise the
workflow end to end.

With one exception, and it is the same property from the other side: a
prerelease cannot be installed as an extension *at all*, so the rehearsal
exercises everything except the install. `gh extension install` decides
whether a repository is a binary extension by asking `releases/latest`,
which does not return prereleases; it concludes there is no release, looks
for a script at the repository root instead, and reports `extension is not
installable`. `--pin` does not reach past that — the pinned tag is read
further in, inside the branch that first decision never takes. To rehearse
the install itself, clear the prerelease flag for as long as it takes and
set it back:

```
gh release edit <tag> --prerelease=false
rm -rf "$(gh config get cache_dir 2>/dev/null || echo ~/.cache/gh)"
gh extension install blockadence/gh-archimedes
gh release edit <tag> --prerelease
gh extension remove archimedes
```

The cache line is not superstition, and leaving it out is how this looks
broken. A `gh extension install` attempted while the release was still a
prerelease caches the `releases/latest` 404, and gh serves that cached 404
back for minutes afterwards — so the install keeps reporting `not
installable` with the flag already cleared and the API already returning
the release. Diagnosing that from the error message alone is not possible;
it is the same sentence as the real refusal.

The release is installable by anyone for the length of that window, which
is the cost of finding out. This is written down because it was learned the
expensive way, in issue 43: the criterion "install what the run published"
and the property "nobody can install it by accident" cannot both hold at
once, and nothing said so until a real tag was cut.

The build itself is ours (`build_script_override`) rather than the action's,
for two reasons the action cannot accommodate: the main package is
`./cmd/archimedes` and not the repository root (the root is the library
package carrying the embedded trees, so the action's default build has
nothing to compile), and the version has to be linked in — the action's
`go_build_options` reaches `go build` as a single word, which cannot carry
both a `-ldflags` value and a package path. Everything else in
`.github/release-build.sh` mirrors the action's own build deliberately:
same platform list, same `go tool dist list` guard, same `-trimpath` and
`-s -w`. Divergence there would be an accident rather than a decision.

Asset names end with `<os>-<arch>`, because matching the tail of an asset
name against the platform it is installing onto is how gh picks the file to
download. A rename that appends anything after that leaves a release that
looks fine on GitHub and installs on nothing.

The run also sets the action's `generate_attestations`, which puts
`actions/attest-build-provenance` over `dist/` before the assets are
uploaded. Each asset comes out bound to the workflow, repository and commit
that built it, and anyone holding the download can check that binding:

```
gh attestation verify <the-binary> --repo blockadence/gh-archimedes
```

That command belongs in `README.md`'s install section, next to `gh extension
install`, and is there — an attestation nobody is told how to check is
ceremony rather than evidence, and the install is where the person who would
check it is standing. This section is the design note, not the instruction.

What it says to check is the downloaded *asset*, and that detail is not
cosmetic: on `darwin-arm64` gh ad-hoc codesigns an extension binary in place
after downloading it (`codesignBinary` in cli/cli's extension manager), which
rewrites the file. The installed copy therefore hashes to something the
attestation does not cover, and pointing an operator at it would produce a
verification failure on a genuine build — the most expensive kind of wrong
answer this could give.

#### The run verifies its own attestations

Asking for attestations is not the same as getting them. Everything above
is an input in a file and a test that reads the file, and both are
satisfied by a repository that has never produced a single attestation: the
action gates its attest step on a string comparison against a
composite-action input, so anything that stops producing that exact string
skips the step rather than failing it. The run stays green, and the first
person to find out is an operator whose `gh attestation verify` reports no
attestation — which is exactly what they cannot tell apart from the
tampering that command exists to catch.

The workflow's last step runs `.github/release-verify.sh`, which is that
same command over the assets in `dist/`. Running the operator's command
rather than inspecting our own side of it is the point: it fails for the
reasons theirs would.

**A failed check publishes nothing.** `release.yml` passes the action's
`draft_release: true`, so the release exists as a draft while it is
checked, and `gh extension install` will not install from a draft — it
reads `releases/latest`, which does not return drafts. The script promotes
the draft on its last line and only there. Why that rather than publishing
outright and going red on failure is argued on the input itself in
`release.yml`; the short version is that a red run beside a downloadable
asset is better than silence and still leaves the operator holding the one
thing they cannot distinguish from tampering.

To recover from a failed run: fix the cause and re-run. The action's
`build_and_release.sh` calls `gh release view` before it creates anything,
and gh's release lookup falls back to finding a *draft* by tag name, so the
re-run finds the existing draft and re-uploads into it with `--clobber`.
Nothing needs deleting first, and no second draft appears. Promoting the
draft by hand stays available and stays a deliberate act.

`dist/` is the whole of what a release publishes, which is what makes the
check complete rather than merely broad — but only while `gpg_fingerprint`
stays unset. Passing it makes the action additionally write `checksums.txt`
and `checksums.txt.sig` *outside* `dist/` and attach those, and those two
would be published assets nothing attests and nothing here verifies.
That is not an argument about GPG (see below, and issue 33); it is a
precondition of this check, and `tests/release_provenance.sh` pins it as
one.

What the check leans on outside this repository, because a red run nobody
can act on is worse than no check at all: `gh`, which GitHub-hosted runners
preinstall; **GitHub's attestations API**, which `gh attestation verify`
asks for the attestation by artifact digest; and **Sigstore's trust root**,
which it fetches to check the signing certificate.

The second of those is the one with a real hazard in it. That read happens
seconds after the same run wrote it, and if it is not immediately
consistent, an unguarded check would fail a few percent of good releases —
for which the fix people learn ("re-run it") is also the fix for a real
failure. So the script carries a bounded retry budget shared across the
assets, and instruments it: a run that needed any retries prints a line
beginning `ATTESTATION-LOOKUP-RETRIES=`. That line is the measurement.

**Three releases have now been measured, and none needed a retry.**
`v0.1.0-rc.1`, `-rc.2` and `-rc.3` each verified twelve assets and printed
no marker line. What that is worth, stated precisely rather than
generously:

- Each run's verify loop *started* 0.36–0.57s after the attest step logged
  `Attestation created for 12 subjects`, so each run's **first** lookup is
  the tightest timing a release produces — and it succeeded first try, four
  times out of four.
- The loops then ran ~40s each, so the twelfth lookup is ~40s after the
  write. Only the first read of each run really tests immediate
  consistency; the rest are progressively weaker tests of it.
- For the first three runs "thirty-six lookups, no retries" was *inferred*
  from the per-run count check rather than read off thirty-six timestamps,
  because `gh` prints nothing on success. `v0.1.0-rc.4` is the first run
  whose twelve lookups are individually timestamped, by the per-asset line
  below: the first completed 4.7s after the attestation was uploaded and
  they ran 3.1–4.3s apart, none retried.

So `--bundle` is not needed now, and the budget stays rather than being
declared unnecessary: four runs on two commits inside two hours on one
runner pool is a small sample against a failure mode whose danger is that
it is intermittent, and the cost of keeping the budget is nothing on a
healthy run. `--bundle` remains the answer if the marker line starts
showing up. Either way a wait cannot turn a real failure green: an
attestation that does not exist never appears.

Two limits it does not close. It verifies the bytes in `dist/`, which are
the bytes uploaded in the same step, not a re-download from the release — a
transfer that corrupted an asset would be caught by the operator and not by
us. And it is proven against a stub `gh`
(`tests/release_verifies_attestations.sh`), which drives it through every
failure it is supposed to have — a missing attestation, a lookup not
readable yet, a `dist/` a glob expanded to nothing, a draft flag that
quietly stopped applying, a `gh` that eats the loop's stdin — but a stub is
not a release.

The real tags have since been cut, and one thing the stub had been hiding
came out with them (the fix is itself proven by `v0.1.0-rc.4`, whose log
carries twelve `<asset>: verified` lines rather than the stub's word for
it): the stub `gh` prints on a successful verify and the
real one does not. `gh attestation verify` gates its report on an
interactive terminal, so on a runner twelve successful verifies wrote
nothing at all to the log, and the whole of the evidence was the two count
lines the script printed around them. The script now prints `verified
<asset>` itself, once per asset. The count check was always what caught a
loop that ended early; this is what lets a reader see it having worked,
rather than having to take the exit status for it.

#### Attestations rather than GPG

Attestations rather than GPG, deliberately, and `release.yml` says so on the
`gpg_fingerprint` input it does not pass. The action supports both. The
difference is what each costs to hold: an attestation is signed with an OIDC
token minted for the one run and never stored, so adopting it changes
nothing about what a leak of this repository's secrets would be worth, while
a GPG signature needs a long-lived private key sitting in a repository
secret — the one credential whose theft would let someone sign a malicious
build. For a tool this size that liability outweighs what it buys, which is
verification by tools that predate all of this and evidence that survives
the repository moving off GitHub. Both of those are real, and both are the
reason the input is commented rather than deleted.

Signing needs two grants publishing does not: `id-token: write` to mint the
token, and `attestations: write` to record the result. They live on the
`release` job, along with the `contents: write` that was already there, and
the file's own `permissions:` is `contents: read`. That split is the point —
at the top of the file those grants would also reach the test gate, which
runs the suite and installs an npm package, and the blast radius of a tag is
supposed to be one job. No secret is involved anywhere in it; the run's own
`GITHUB_TOKEN` is the whole of what either half uses.

### Why the repository is named `gh-archimedes`

gh will only install an extension from a repository whose name starts with
`gh-`, and it refuses before it goes anywhere near the network. That is a
namespace rule about the repository, not a statement about the tool: the
binary is `archimedes`, standalone is the primary install, and the
extension is the additive one.

The module path was realigned with it, which is the one thing the rename
breaks: `go install github.com/blockadence/archimedes/cmd/archimedes@latest`
stops resolving. GitHub's rename redirect gets Go to the right repository
but not past the check that follows — the `go.mod` it finds there declares
`gh-archimedes`, and Go refuses a module whose declared path is not the one
requested. Leaving the module path alone would have dodged that at the cost
of a repository whose name and import path disagree forever, and of an
install line that depends on a redirect. Nothing had been tagged or
published under the old path, so the cost was one line in the README.

The alternative was a second, release-only repository, which was weighed
and rejected. It needed a standing cross-repository token (a workflow's
`GITHUB_TOKEN` cannot create a release elsewhere) or a second tag lineage
that could drift from this one — and a version that can drift is the exact
failure the section above exists to prevent. It also meant publishing, to
people gh explicitly tells to review an extension's source before trusting
it, a repository containing no source.

## Two embedded trees

The module root is the repository root, and `template/` and `drivers/` sit
beside it at the top level. That is deliberate: `go:embed` cannot reach
outside the package directory it appears in, so carrying either in the
binary meant either burying hand-maintained prose and bash
(`template/AGENTS.md`, `template/drivers/README.md`, the convention-pack
examples, three drivers' worth of shell) inside the Go package tree, or
moving the module up to meet them. The module moved.

`template.go` at the root is the whole of the mechanism: two `//go:embed
all:` directives, exposed as `archimedes.Template()` and
`archimedes.Drivers()`. Both trees stay ordinary files, edited by editing
them — nothing generates them, and no Go source holds a second copy. The
`all:` prefix is load-bearing; without it the template's dotfiles
(`.gitignore`, and the `.gitkeep` markers that give an instance its
`repos/` and `work/` directories) are silently dropped.

The two are carried for opposite reasons, and the difference is the whole of
issue 29's answer:

- **`template/` is seed data.** It is written into an instance once, by
  `init`, and is that instance's from then on. Nothing refreshes it.
- **`drivers/` is never written into an instance at all.** A driver is read
  out of the binary at the moment it runs. That is what makes a fix to one
  reach an instance that *already exists*: upgrading the tool is the whole
  of the delivery, and there is no step that copies tooling into an
  instance — the thing 15 retired and that this must not reintroduce under
  another name.

So `template/drivers/` holds a README and no drivers. A driver seeded into
an instance would be a driver beyond the reach of any fix, which is exactly
the state that had to be resolved.

The rest of the template — `scaffolding/`'s PR and issue templates, the
convention-pack examples, `AGENTS.md` — stays seed data, deliberately, and
the docs say so where an operator will read it (`template/README.md`).
Those carry an org's own wording and an instance's own conventions, so
re-supplying them would overwrite the work rather than deliver a fix. The
line is not "shipped versus not" but *inert content an operator tailors*
versus *programs that run inside their repositories*, and only the second
kind is worth a delivery route.

The layering is `internal/driver`'s `Set`: the instance's own `drivers/`
over the built-ins, most specific first. An operator's driver — written
from scratch, or taken over with `drivers adopt` — always wins, so owning a
driver means owning it, and the `drivers` listing marks such a name
`shadows built-in` because fixes to the shipped one stop arriving there.
`Set` answers with a *directory on disk* rather than with which layer won,
unpacking a built-in to a temp dir for the duration of the run; past that
point a built-in is an ordinary driver directory and there is one code path,
not two. Unpacking per run rather than caching is deliberate: a cache would
need invalidating on upgrade, and delivering upgrades is the point.

One thing an embedded filesystem cannot carry is file modes, and a driver
depends on exactly one: its command has to be runnable. `internal/driver`
restores it from what each `driver.yaml` declares its `command` to be,
rather than from what a filename looks like — a *sourced* helper
(`lib/repo-snapshot.sh`) is not a program and must stay inert. It is
the only mode anything restores; `internal/instance` needs none, because
nothing in the template is a program.

`drivers/lib/` is the one thing under `drivers/` that is not a driver: it
holds the bash helpers more than one of them sources, reached at `../lib/`
relative to a driver's own directory. Resolving a driver brings it along —
unpacked beside a built-in, copied into the instance by `drivers adopt` —
so that relative path means the same thing from either layer. It declares
no manifest, which is what keeps it out of the listing and out of `Run`:
`Set.List` passes over a built-in directory with no `driver.yaml` exactly
as it already passed over an instance one. It exists because both
fixed-location drivers have to leave someone else's repository as they
found it, and a second copy of the code that does that would be the one
that drifts — on the failure path, where nobody is watching.

## What an instance records as a path

Every path an instance writes down is relative to the instance root, and
that is a decision about readership rather than a formatting preference.
An instance is a git repository: its manifest, its dossiers, its map and
its `work/` are committed to it and read by everyone who has it, on
machines whose directory layout is their own. So `bootstrap` records a
checkout as `../<name>`, `WORKSPACE-MAP.md` links relatively, and a dossier
stub names `../<repo>`.

`spawn`'s worktree column in `work/<slug>/status.md` was the exception and
is not any more (issue 46). It recorded
`/Users/someone/Code/service-a-worktrees/widget-fix` — a directory that
exists on exactly one machine, in a file shared with everyone. That was not
only untidy: `prune` takes the column at its word and hands it to `git
worktree remove`, so a teammate who cloned the instance was naming a path
their box has never had.

The alternative considered first was the opposite one — that a spawned
worktree is per-machine state like `.archimedes-notify.json`, and the row
was never meant to travel, so `work/` should not be the instance's
committed content at all. It was rejected because `work/<slug>/` is also
where a unit of work's *reference material* lives, the ticket and the
mockup and the notes that `spawn` materializes into every worktree, and
sharing those is the whole reason the directory exists. Splitting the
directory to un-share one column of one file buys less than making the
column mean the same thing everywhere.

`internal/workdir` owns that argument now — see "Where a unit of work's
directory is" below.

And it does mean the same thing everywhere.
`../service-a-worktrees/widget-fix` is not a claim that the directory is
there; it is where this unit of work's worktree belongs, which is as true
on a colleague's clone as `repos.yaml`'s `../service-a` is true before
they have cloned anything.

`internal/worktree` owns the whole of that — `Path` (where a worktree
lives, beside its checkout), `Record` (how it is written down), `Resolve`
(how a reader turns the row back into a usable path) — so a writer and a
reader cannot come to different conclusions about the shape. `spawn`
records through `Record`; `prune.Scan` resolves through `Resolve`, and
takes the instance root rather than its `work/` directory for that reason.
The parse layer underneath (`internal/statusfile`) reports the column
exactly as the file states it: it is given a file, not an instance, and
inventing a root to resolve against is the mistake this is fixing.

`status` does not resolve it at all. It used to, and nothing read the
answer: a report prints a slug, a repo, a PR and a note, and never a path.
Resolving is done by the layer that hands the column to `git worktree
remove`, which is `prune` and only `prune` (issue 58).

`Resolve` answers with a path usable from any working directory, even when
the root it is given is not — `--root .` is the ordinary way to name an
instance, and the answer is consumed by git running inside the target
repo, which would read a shell-relative path against that repo instead.
An empty column stays empty rather than resolving to the instance root,
which is what `prune` would otherwise hand to `git worktree remove`.

Rows written under the old shape still read. `Resolve` returns an absolute
value untouched, so an instance that already carries them keeps working on
the machine that wrote them — the only machine they were ever usable from.
Nothing rewrites them: a row is replaced by the spawn that supersedes it or
removed by the prune that retires it, and a migration pass would be
rewriting the one machine's truth into another's guess.

`spawn`'s `Result` and its printed lines keep the absolute path. Those
answer for this machine — a `cd` line the operator pastes, a path an MCP
client hands to a tool — and are not written into the instance.

What holds the rule is
`TestAScaffoldedInstanceIsTheSameHoweverItWasInvoked` — the same test that
"What an instance's own docs name" leans on above — which compares two
scaffolded instances byte for byte with nothing normalized away. Two runs
land in two different temp directories, so a path that is true in one of
them fails the comparison and names the file it came from.

## Where a unit of work's directory is

`internal/workdir` owns `work/<slug>`, and `Path(root, slug)` is the whole
of it. `spawn` makes the directory through it, `spawn`'s materialize reads
the unit of work's reference material out of it, and `internal/statusfile`
joins `status.md` onto it — the three sites that each used to write
`filepath.Join(root, "work", slug)` out by hand (issue 66).

One function is not much to move, and moving it is not the point. The
directory is the one part of an instance that is *both* a unit of work's
reference material and, in the one file `internal/statusfile` owns,
Archimedes' bookkeeping — and each half is the premise of a decision made
somewhere else: the relative worktree column above, the single parser
below. Each of those packages was restating the premise to justify its own
decision. The package comment on `internal/workdir` states it once, in
full, and they cite it.

`internal/instance` would have been the obvious owner, since it scaffolds
what a new instance starts with. It is not: `Create` walks whatever
template tree it is handed and never names `work/`, so what knows the
layout at creation time is `template/`, not the package that copies it.

`work/<slug>/` itself is unchanged, and is not what this was about:
`template/` scaffolds it and every instance in existence carries it.

The fixtures that spell the layout out still spell it out — `work/<slug>`
written literally, never built by calling `workdir.Path` — because a
fixture that agrees with whatever produces it cannot catch that producer
changing. That is the same rule the `prune` and `statusfile` fixtures
follow for the worktree column and the table header.

## Where an instance's dossiers are

`internal/dossier` owns `repos/`, and `Dir(root)` is the whole of the
location. `bootstrap` scaffolds a stub through it, `sync-house-rules` reads
the `## House rules` section it pushes into a repo through it, and
`spawn`'s materialize reads that same section through it — the three sites
that each wrote `filepath.Join(root, "repos")` out by hand (issue 72).

What did *not* change is the difference from `work/<slug>` above. Every
entry point here still takes the directory as a parameter —
`WriteStub(dossierDir, s)`, `HouseRules(dossierDir, repo)`,
`Path(dossierDir, repo)` — rather than taking a root and joining inside.
That parameter is not a spelled-out path with a shorter spelling available:
it is what lets a dossier be written and parsed against a bare
`t.TempDir()` with no instance around it, and those tests are worth more
than the three lines it costs. So the joins moved and the signatures did
not. `internal/workdir` is a package whose whole content is a location;
`internal/dossier` is a package that had everything *except* one.

The other half of owning the location is saying which directory it is,
because two different things can live under this one name: `repos/<name>.md`
is the prose Archimedes parses, and `repos/<name>/` may be a checkout of the
repository that prose is about, since `repos.yaml` permits a path below the
root. `Dir`'s comment holds that argument in full, including why nothing
resolves a checkout through it. It is stated there rather than here because
the place a fourth caller reads is the package, not this file.

The directory's name and layout are unchanged, and were not what this was
about. `template/` ships an empty `repos/`, `bootstrap` writes
`repos/<name>.md` into it, and every instance in existence carries both — so
a name that could not be confused with a checkout would be a migration, not
a rename.

The fixtures that spell the layout out still spell it out — `repos/<name>.md`
written literally in `bootstrap`, `reposync`, `spawn` and `cmd`, never built
by calling `dossier.Dir` — for the same reason the `work/<slug>` fixtures
do. Mutating the join here fails tests in all four, which is the check that
they still hold it.

## Where an instance's manifest is

`internal/manifest` owns `repos.yaml` — it always did, apart from where the
file is — and `Path(root)` is that last piece. Eight production sites built
`filepath.Join(root, "repos.yaml")` by hand, and the eighth was inside
`LoadInstance`: the package that reads and writes the file knew where it
was, used the answer, and handed back `(root, *Manifest)` — everything
except the path it had just built (issue 75).

Three joins was a small cost, and the argument for leaving them was real
both times above. Eight is not that argument any more.

The alternative was to widen `LoadInstance` to return the path it already
has. It was rejected on the shape of the callers. `contextmap` and
`reposync`'s template sync do load an instance and then need the file's name
anyway — they are the two the wider return would have served. The other five
never call `LoadInstance` at all: `bootstrap` names the file to seed an empty
one before there is anything to load, and `status`, `dashboard`, `mcpserver`
and `applyconventionpack` need the name in order to `Load` it. They would
have gone on joining. `Path(root)` serves all eight, and `LoadInstance`
becomes its first caller rather than a ninth way to ask.

The signatures did not change, for `internal/dossier`'s reason: `Load`,
`AppendRepo` and `SetRepoField` all go on taking a file path rather than a
root, because that parameter is what lets a manifest be read and rewritten
against a bare `t.TempDir()` with no instance around it — which is exactly
what `setfield_test.go` and `append_test.go` do.

The two packages with the most uses had each already extracted something of
this privately, which is the tell that it wanted extracting.
`mcpserver.manifestPath()` was exactly this answer, scoped to one server
struct; it stays, now as a caller, because `s.root` is what a tool has in
hand — the same reason `s.repo` exists beside it. `cmd.loadManifest`
extracted the *other* half, the load prologue, with the path deliberately
dropped (issue 59) — which is why `applyconventionpack`, the one `cmd` site
that has to name the file, bypasses it and asks `Path` instead. That is also
why the rule about a relative `--root` is not restated on `Path`: `Path`
answers with the root as the operator typed it and points at `loadManifest`,
where the decision about what a caller may resolve against a relative root is
written down in full.

The file's name, its format, and the paths recorded *inside* it are
untouched, and were not what this was about — `Path` answers for the
manifest file, and where a repo's checkout is still comes from the entry
that records it (`manifest.CheckoutOf`).

The fixtures that spell the layout out still spell it out — `repos.yaml`
written literally in every test that writes one, never built by calling
`manifest.Path` — for the same reason as above. Mutating the join here fails
tests in `manifest`, `bootstrap`, `cmd`, `contextmap`, `dashboard`,
`mcpserver`, `notify`, `reposync` and `spawn`, which is the check that they
still hold it.

## What reads `work/<slug>/status.md`

`internal/statusfile` owns the file: its name, the header a slug's first
spawn writes, how a row is rendered, how a row is read back, and the walk
over an instance's units of work. Where an instance keeps it is
`internal/workdir`'s, above. `spawn` writes through it, `status` reports
what it says, `prune` acts on it, and none of the three decides for itself
what a row is.

They used to, and they disagreed. `status` skipped four header lines, split
on `|`, required five fields and put every cell through
`strings.Fields`-joined-by-a-space; `prune` skipped a literal `4`, split on
`|`, required six fields and trimmed every cell. One row, two readings.
Given a note an operator (or their editor's table formatter) had aligned by
hand, `status` read `based on main` where `prune` read `based   on    main`.

That is not cosmetic, because of what each does next. `status` hands the
note to `stackref.ParseNote`, which reads the collapsed form and finds the
base. `prune` decided whether a merged branch was still somebody's stacked
base by looking for `stacked on <repo>:<slug>` in the *raw file text* — so a
re-spaced table still showed the stack in the report and no longer blocked
the removal. The branch came out from under the unit of work stacked on it,
which is the exact removal `Item.Blockers` exists to refuse, and it was
silent on the side that destroys work. The same raw-text scan matched on a
prefix, so `service-a:widget-fix` was also "blocked" by anything stacked on
`service-a:widget-fix-2`.

So a cell is trimmed *and* whitespace-collapsed, once, for both readers: a
hand-aligned table means exactly what the terse one `spawn` wrote means.
The cost is a recorded path that itself contains a run of spaces, which
comes back with the run collapsed — a worktree lives beside its checkout
and is named after the slug, so that is a path nothing here produces. And
`prune`'s blocker check now asks each row's parsed note, through the
`stackref.Ref` the note names, rather than asking the file as a string.

The alternative worth taking seriously was that the two want different
things and one parse would serve neither: `status` needs the note
interpreted and `prune` did not, `prune` needs the worktree column resolved
against the instance root and `status` does not. It loses because that is a
difference about what to *do* with a row, not about what a row *says*.
`statusfile.Row` reports every cell and interprets none of them — whether a
note names a stacked base stays `internal/stackref`'s, whether a worktree
column resolves stays `internal/worktree`'s, whether a row is prunable stays
`prune`'s — so each reader still takes what it needs and they cannot
disagree about the taking.

Two smaller things fall out of one owner. The "skip four header lines" rule
now sits beside the header it skips, held by a test rather than by two
packages counting the same four lines; and `prune`'s row removal goes
through the same rule, so a repo that happened to be called `repo` can no
longer have the table's own header deleted out from under it. The walk over
`work/*/status.md` is likewise one glob, and it takes no slug filter,
because `prune` has to read every file whatever it was asked about:
whether a branch is somebody's base is a question about the *other* files.
`status` has no such tie, so narrowed to one slug it reads that slug's file
and no other — one unit of work's unreadable file must not cost an operator
the report on the unit of work they asked about.

### Why a row carries no pull request

A row is `repo | branch | worktree | note`, and every one of those is
something `spawn` knows when it writes the row and that stays true for as
long as the row exists. There was a fifth, `pr`. `spawn` wrote `-` into it
on every row it appended, nothing ever wrote anything else, and nothing read
it: `status` asks `gh pr list` for a row's live state on every run, `prune`
asks the same lookup before it acts, and `notify` goes through
`prune.Scan`. The column was state-shaped and was not state (issue 65).

That is not free, because the table is read by people. A `pr` header over a
dash reads as a record — *there is no pull request* — when what the dash
meant was that nothing had ever been recorded there, including for a unit of
work whose pull request merged last month. The one reader who trusted it was
the one it cost.

The alternative was to fill it in rather than drop it. `spawn` cannot — there
is no pull request when a worktree is created — but `status` holds the number
every time it runs and could write it back, which would make the table
readable by a teammate who has the instance and no `gh` session, and readable
at all offline. It loses because it turns bookkeeping into a cache: a number
written on Tuesday is wrong the moment anyone opens, closes or merges a pull
request, and then every reader that has one has to decide whether to believe
it. Nobody has to now. What a row carries is what a lookup is keyed by, and
the answer comes from `gh`.

Files written before the column went away are in operators' own git
histories, and they go on working, in both directions. Their rows have a
fifth cell; `parseRow` reads the four columns the header names and no more,
so an old row says exactly what it always said. And a row written now has
four cells where the reading before this one wanted five, which that reading
already tolerated — its last cell comes back empty, the same as for a row
whose last cell a hand had removed. Both directions are held by a test, the
older reading spelled out rather than imported, since it is gone from the
code and a fixture that agrees with what produces it cannot catch anything.

Any write through this package — `spawn` appending, `prune` removing — also
brings the file's two column lines up to the current header on the way past
(`upgradeColumns`), because a header naming a column is a promise about the
cells under it and this package is the one place that promise is made.
Dropping the column from new files alone would have left every instance in
existence still making it.

That rewrite fires only where the two lines it would replace name *exactly*
the columns this package has stopped writing. Anything else is somebody
else's — a paragraph an operator put under the title, a second table they
keep below — and the cost of guessing is their words gone, on a write they
asked for something else entirely. A header they have aligned by hand is
still recognized, since the column names are read the way a row's cells
are. And the rows are left byte for byte either way: a cell past the last
column renders as nothing, so an old row under the new header already reads
as what it is, and re-rendering the rows to be rid of it would take an
operator's alignment with them.

One thing moved that is not the column. A row was read from a line with at
least `cells+1` `|`-separated fields, which is one short of a full row, so
the last cell could go missing and still leave a row standing. That cost
nothing while the last cell was `pr`, because nobody read it. Over four
columns the cell that goes missing is the *note*, and the note is what says
a branch is somebody's stacked base — a row that quietly lost its note reads
as a row with nothing stacked on it, which is the removal `Item.Blockers`
exists to refuse, arriving silently and on the destroying side. So a row now
has to be a full row: short of a cell it is not a data row at all, and it is
invisible to every reader alike, which is loud. The operator sees their unit
of work gone from `status` rather than reported with a note it does not
have.

Nothing outside this repository reads the file. The drivers, the bash suite
and `template/` never name it; the MCP server serves `status`'s report
rather than the row. What is left is the reader the column was costing:
a person, sometimes, reading markdown in their own git repository.

## Adding a subcommand

Each subcommand lives in its own `internal/cmd/<name>.go`, exposing a
`new<Name>Cmd() *cobra.Command` constructor registered in
`internal/cmd/root.go`'s `newRootCmd`. Business logic belongs in its own
`internal/<package>`, kept independent of cobra/CLI concerns, so it can be
unit-tested directly (see `internal/workspacemap` for the pattern the
`render-map` subcommand follows).

A subcommand that is about to *work inside* one named repo — spawn a
worktree in it, edit its build file, push a commit — asks
`internal/manifest` for it rather than repeating the lookup:
`LoadInstance` reads the instance's `repos.yaml`, and `Manifest.Checkout`
turns a repo name into that repo's entry, its checkout path resolved
against the instance root, and whether anything is cloned there yet
(`CheckoutOf` answers the same for an entry already in hand, for a caller
walking every repo). The two shortfalls stay apart — `Listed` for a name
`repos.yaml` doesn't carry, `Cloned` for one it carries but nobody has
cloned — because commands react differently on purpose: a mapping pass
skips an uncloned repo and carries on where `spawn` refuses, and each
command that refuses words its own message. `Ready()` is for the ones that
treat both the same.

`Manifest.Resolve` is the same lookup without the disk: it answers where a
repo *would* be and nothing about whether it is there. That is what a
reader wants — `status` resolving the repo named on a `status.md` row, the
PR-state lookup behind `prune` and `notify` — since none of them are about
to work in the checkout, and a repo that isn't cloned is a row reporting
"no PR" rather than a command that has to stop.

Anything that shells out to `git` goes through `internal/gitutil` rather
than calling `exec.Command("git", ...)` directly, so "run git and interpret
the result" lives in one place. Helpers that more than one subcommand needs
— deriving a repo's `owner/name` slug from its origin remote, removing a
worktree or branch — belong there too. Tests are exempt: a test that builds
a git fixture drives git directly, so a bug in `gitutil` can't hide itself
by also breaking the fixture.

## Tests

Two suites, two commands, from a checkout:

```
go test ./...            # the Go suite
./tests/run-all.sh       # the bash suite (drivers, packaging, scaffolding)
```

Neither needs the network or a credential: the Go tests build their git
fixtures on disk, and the bash tests build the CLI once and drive it against
fixtures that are their own origins.

`.github/workflows/test.yml` runs exactly these two commands on every push,
and `release.yml` calls that same job as a gate — a tag whose tests fail
publishes nothing. The workflow is deliberately not a third recipe: if the
commands above change, that file changes with them.

A test file that cannot run says so and exits 77, and `run-all.sh` counts it
as skipped and names it in the summary rather than folding it into "0
failed" — the distinction between a suite that passed and a suite that
mostly didn't run. Two files are opt-in that way, because they make a real,
billed `claude -p` call: `tests/pocock-driver-e2e.sh` and
`tests/spec-kit-driver-e2e.sh`, both behind `ARCHIMEDES_TEST_LIVE_DRIVERS=1`.

```
ARCHIMEDES_TEST_LIVE_DRIVERS=1 ./tests/run-all.sh   # includes the live e2e files
```

The third file that guards itself, `tests/openspec-driver-e2e.sh`, needs
only the `openspec` CLI (`npm install -g @fission-ai/openspec`), which the
workflow installs so that it runs there too — pinned to a version there,
since that install is the one part of a release gate that reaches the
network, and an upstream reword should not be able to hold up a tag.

### The Node the actions run on

Every `uses:` across the three workflows is on a release that does not
target Node 20, and `tests/ci_action_runtimes.sh` is what keeps it that way.

This is not housekeeping. GitHub's runners were forcing the node20 actions
onto Node 24 and annotating every run to say so, and when that override goes
it goes on `test.yml` first — which is `release.yml`'s gate, so the first
thing to break would be the ability to cut a release, for a reason with
nothing to do with the tag being pushed. `live-drivers.yml` is the worse
case rather than the milder one: it is `workflow_dispatch` and a weekly
cron, so it is the file that gets discovered broken by a report nobody is
reading.

What the three of them run, and what for. `test.yml` is the push check and
`release.yml`'s gate: `actions/setup-go` off `go.mod`, then the two suites.
`release.yml` calls that same job and, once it passes, hands publishing to
`cli/gh-extension-precompile`, which creates the draft release and attaches
the binaries `.github/release-build.sh` built for it. `live-drivers.yml` is
the billed suite, on a weekly cron and a `workflow_dispatch`, so it installs
the most: `actions/setup-go` for the driver tests, `actions/setup-node` for
the `claude` CLI they drive headlessly, and `astral-sh/setup-uv` for the
`specify` CLI the spec-kit driver unpacks. All three start with
`actions/checkout`.

Which release each of those is on is in the workflow file that runs it, and
is deliberately not repeated here: Dependabot bumps those lines on a
cadence (below), and a list on this page would be the copy nothing checks.
What is written down instead is the floors, in `tests/ci_action_runtimes.sh`
— that table is the record of someone having read an upstream `action.yml`,
and it is the one to read when deciding whether a version is safe.

The test records a floor per action — the lowest major whose `action.yml`
says `runs: using: node24` — rather than the exact version in the tree, so a
routine bump is not also a test edit, and an action nobody has recorded a
floor for fails rather than passing quietly. Its header has the `gh api`
one-liner for working a new floor out. What it cannot do is check that table
against upstream, because a test in a release gate must not need the
network; that half was checked by reading each upstream `action.yml`, and
then by a real run of each of the three files reporting no annotation. Read
the run rather than trusting the bump: a green square is not the evidence,
the absence of the warning on the job is.

`cli/gh-extension-precompile` is the one action here we do not control, and
the answer for it is that it was never affected: it is a composite action, so
there is no Node runtime under it to deprecate — which is why the annotation
on `release.yml` named only `actions/checkout` — and its own nested actions
are SHA-pinned upstream and already on node24. It is deliberately not
bumped. A bump would mean re-reading its changelog for what it does with
`generate_attestations` and `draft_release`, which is the one failure mode
in this repository that publishes the wrong thing rather than nothing, and
the deprecation gives no reason to take that on.

`astral-sh/setup-uv` is the one step named by a full version rather than by
a floating major, and that is upstream's doing rather than a pinning policy
of ours: that action stopped publishing major tags with its v8 release, so
`@v7` is the newest floating major that exists and its line has had no
release since March 2026 — staying on it would mean sitting on a branch that
will not get the next deprecation's fix. Deliberately not done anywhere
here: pinning actions to commit SHAs. That is a supply-chain decision with
its own argument and its own maintenance cost, and it is not what the
deprecation was asking for.

#### What watches upstream, and which half is load-bearing

`.github/dependabot.yml` covers the `github-actions` ecosystem and nothing
else, monthly, with the bumps grouped into one pull request rather than one
per action. It is there because the notice that became this section sat on
every run for an unknown number of runs before anyone read one: "read the
annotations when cutting a release" was available the whole time and did not
happen, and the fix was half an hour of reading upstream `action.yml` files
by hand. The scoping is what makes the standing review cost bearable on a
repository with one maintainer — roughly twelve pull requests a year against
a handful of `uses:` lines, each arriving with `test.yml` already run
against it.

It and the floors table answer different questions, and **the table is the
load-bearing one**. Dependabot says a newer release exists. The table says
which releases someone has read the upstream `action.yml` of and found not
to be on a dead runtime. Only the second is a claim about what this section
is about, and only the second is checked on every push.

That the bot's pull request goes green is worth having and is not that
reading. Green means the versions in it clear floors that were already in
the table — which is the useful direction, since it makes a bump past a
floor fail before review rather than after merge. It says nothing about
whether the floors themselves are still current. So when a bump lands, do
the same thing 52 did by hand, only prompted: read each bumped action's
`action.yml` for its `runs: using:`, and if the deprecation has moved on —
node24 to whatever succeeds it — the floors table changes in that same pull
request, with the date in its header. The failure mode to design against is
merging the green square and letting the table rot behind it, which is the
old silence in a new place.

The mechanism that puts the guard in front of the bot: Dependabot pushes a
branch to this repository (`dependabot/github_actions/…`), `test.yml` runs
on a push to every branch, and the floors guard is in the suite it runs.
`tests/ci_watches_action_versions.sh` pins that whole shape — the config
exists, it covers `github-actions` and nothing else, monthly and grouped,
and `test.yml`'s `push` filter is still `"**"` rather than a list of named
branches. Narrowing that filter would take the guard off the bot's pull
requests without touching a line of the guard, and nothing else here would
notice.

## The live driver tests

Those two files are the only place the drivers meet the real tools they
wrap, so they cannot simply stay skipped — but they also cannot run on a
push, since a gate that spends money and needs a credential is a gate that
fails when somebody else's API is down. They run instead in
`.github/workflows/live-drivers.yml`: weekly on a Monday-morning cron, and
on demand via `workflow_dispatch`, which is the pre-tag ritual — dispatch
it, watch it go green, then push the tag. A red run files an issue labelled
`live-drivers` (and comments on that same issue while it stays red) rather
than relying on anyone noticing a square.

What that costs, so the schedule isn't a surprise on a bill: two headless
sessions per run against a throwaway repo holding one small source file, on
the order of $0.10–$0.50 a session — so $0.20–$1.00 a run, and $10–$52 a
year across the 52 weekly runs. Treat those as estimates until the first
month's usage lands, then correct the numbers here and in the workflow's
header comment. Changing the cadence is one line.

The credential is an `ANTHROPIC_API_KEY` secret on a `live-drivers`
[deployment environment][envs], not a repository secret, so only a job that
names that environment can read it. One-time setup: create the environment
under Settings → Environments and add the secret there. Resist adding a
required reviewer to that environment, tempting as it is on a workflow that
spends money: the protection rule gates *every* job naming the environment,
so the weekly run would sit waiting for an approval nobody knows to give,
and the schedule this issue exists to create would quietly stop. Add the
secret *only* to the environment: `secrets.ANTHROPIC_API_KEY`
resolves a repository-level secret of the same name just as happily, so a
repo-wide one would quietly undo the scoping without changing a line of
YAML. Until the environment exists the workflow fails on its first step
with a message saying so, rather than deep in a test log. Nothing triggers this workflow from a pull
request, which is deliberate and pinned by `tests/ci_runs_live_drivers.sh`:
a fork's PR runs the base repo's workflow files, so a `pull_request`
trigger on a job holding that key would hand it to anyone.

[envs]: https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment

What the live files add over the free suite is the upstream half only —
that the real `claude` and `specify` CLIs still behave the way the drivers
assume. Each driver's own orchestration is covered on every push against
stub CLIs: `tests/pocock_driver_run.sh` and `tests/spec_kit_driver_run.sh`.
That split is why a weekly cadence is enough. A change of ours that breaks
a driver fails on the push that made it; only a change of theirs waits for
Monday.

Underneath both sits `tests/fixed_location_conformance.sh`, which holds
every driver declaring `output_mode: fixed-location` to the half of that
contract Archimedes cannot enforce: the target repo is left exactly as it
was found apart from the harvested `fixed_path`, and whatever of the
operator's the run could not put back is named rather than tidied away in
silence. It discovers the drivers by reading the manifests rather than from a
list, so a third one is covered the day it declares the mode and without a
test of its own.

It asks that of both ways a run can end, because the promise is made about
both. A run allowed to finish is the easy half. A run *stopped* — a Ctrl-C,
a `kill`, a supervisor, a cancelled CI job — is the other, and it is the one
where a driver has to reach its rollback from a signal rather than from the
end of its own script. The check stops a run at the moment its stub session
is writing inside the target repo, which is a moment a driver that armed its
traps before anything wrote can act on and one that armed them afterwards
cannot — so the ordering `template/drivers/README.md` asks for is checked
rather than trusted. `tests/pocock_driver_run.sh` and
`tests/spec_kit_driver_run.sh` keep their own interrupted cases, in both
shapes an interrupt arrives in; this is the floor under them, not a
replacement for them.

Then it asks the same question of the repo an operator actually has — a
dirty one, with the stub session writing over the part that made it dirty.
That is the one shape of "as it was found" no driver can deliver, because
nothing keeps a copy of what an uncommitted file said, so what is required
there is the nearest thing that can be had: the repo comes back dirty in
exactly the way it started dirty, and the run *names* the file it wrote over.
A driver that tidied up silently around it fails, the same as one that left
files behind.

Twice, because the dirty path that matters most is the driver's own
`fixed_path`. Work in flight there is replaced by the run and then carried
out of the repo by the harvest, and every step of that is the run succeeding,
so the repo comes back pristine with nothing in its state to record that the
operator ever had a version of their own — all that is left to ask is whether
the run said so. Then the same question backwards, over a repo with nothing
of theirs at that path to lose: one that never held a file there, and one
they had deleted a committed file from without committing the deletion. Those
runs have to reach a session, succeed, be harvested, and say nothing about
the path. "The run named its `fixed_path`" is a sentence a banner satisfies
without ever having looked at what the repo held, which is why the note's
*when* is asked for as squarely as the note — the driver written to fail
those two comes through every check above them green. The third state the
library stays silent in, a file the run rewrote byte for byte, is not
reachable through a stub session; it is checked against the library itself in
`tests/repo_snapshot.sh`, the conformance file says why it cannot be asked
out there, and `template/drivers/README.md` says it is the driver's own to
keep.

It asks one thing of a driver, which the three shipped ones already do:
every CLI it runs is named by a `command -v <name>` guard before it touches
the repo. That is where the check learns what to stand a stub session in
for, and it is all-or-nothing — a driver whose guards it cannot read whole
is failed rather than run, because the alternative is reaching whatever the
driver really wraps, which for a driver in this mode is a billed call. An
instance's own drivers are outside its reach, which
`template/drivers/README.md` says out loud where a driver author will read
it.

## Test fixtures

A test that needs a real repository to work against builds one with
`internal/testrepo`: a bare "origin" plus a clone of it carrying one commit,
already pushed to the base branch, which is what makes the fetch, `rev-parse
origin/<base>`, worktree, and push paths exercisable against real git with
no network.

```go
repo := testrepo.New(t, testrepo.Spec{Dir: tmp, Name: "app"})
// repo.Clone, repo.Origin, repo.Branch
```

`Spec` defaults to `<Dir>/<Name>` for the clone, `<Dir>/<Name>.git` for the
origin, `main` for the branch, and a single seeded `README.md`; override any
of them for the cases that need it (a different base branch, a seed clone
that must not sit where the code under test is about to clone, a repo whose
tracked `.gitignore` is the point of the test). It is test-only scaffolding —
a test in the package fails if the shipped binary ever ends up depending on
it, and it drives git directly rather than through `internal/gitutil` under
the same exemption every git fixture has: a bug in `gitutil` must not be
able to hide itself by also breaking the fixture.

A test that drives git a step further than `New` does — committing on top,
pushing a second branch, reading back a ref — uses the same package's runner
rather than wrapping `exec.Command("git", ...)` itself:

```go
testrepo.Git(t, repo.Clone, "checkout", "-q", "-b", "auth-api")   // for effect
testrepo.GitOut(t, repo.Clone, "rev-parse", "origin/main")        // for output
```

Both fail the test with git's own output if the command doesn't succeed.
`GitOut` returns stdout with surrounding whitespace trimmed, since git
terminates nearly everything it prints with a newline no caller wants.

Every fixture the package builds carries a fixed commit identity, so no test
has to spell one out to commit — written into the checkout's config and
cleared out of the test's environment in the same breath, since git reads
`GIT_AUTHOR_NAME` and friends ahead of every config file and a fixture that
only wrote the config would commit as whatever the suite was launched
carrying. Clearing it is `t.Setenv`'s, so a test that builds a fixture is a
test that may not call `t.Parallel`. A test whose subject *builds the
repository itself* has no fixture checkout to carry it, and calls
`testrepo.IsolateGit(t)` instead: git gets a global config of that test's
own holding an identity and nothing else, so the test doesn't pass or fail
on whether the machine running the suite happens to have a global
`user.name` — and, on one that does, doesn't silently record it. Prefer the
fixtures wherever the test owns the repository; reach for this only when it
doesn't.

The bash suite under `tests/` exercises the shipped drivers end to end
against this binary, and builds the same repo shapes from
`tests/gitfixture.sh`; keep the two in step. `make_origin_and_clone_at` is
`testrepo.New`'s twin and `make_repo_at` is `Init`'s — a checkout with no
origin, on `main`, carrying one commit. Where `Init` seeds a `README.md` and
`Spec.Files` is how a Go test asks for different ones, `make_repo_at` commits
whatever the caller has already written into the directory and falls back to
that same `README.md` only when there is nothing there; the fixtures are the
same shape, and what varies is how each language's call sites were already
spelling the seed. Both carry the same fixed identity, and clear it out of the
environment while they set it: git reads `GIT_AUTHOR_NAME` and friends ahead
of every config file, so a fixture that only wrote `git config user.email`
would commit as whatever the shell was carrying, and a `-c user.email=` at
the call site could not reach the driver subprocesses a test spawns at all.
`tests/gitfixture.sh` also holds the three ways a test file says what
identity it runs under, the bash twins of `testrepo`'s: `isolate_git`, for
the files that scaffold an instance and so need a commit to succeed
(`driver_ownership.sh`, `gh_extension_packaging.sh`,
`init_scaffolds_data_only.sh`); `strip_git_identity`, for the machine where
git itself will not commit; and `unconfigure_git_identity`, for the machine
with nothing configured that git will guess an identity for anyway. The last
two are the pair `tests/init_without_a_git_identity.sh` walks in turn, since
one operator's box is one and another's is the other and `init` owes them
both the same answer. `tests/init_when_git_refuses_the_commit.sh` is the
third machine: `isolate_git` for the identity that makes it that machine
rather than one of the two above, and two `git config --global` lines of its
own pointing commit signing at a `gpg` that is not there. Its Go twin is
`testrepo.RefuseCommits`, which reaches the same machine through a
`pre-commit` hook, since a test cannot break a gpg it cannot assume. An identity belongs in the test file that needs one
and never in `.github/workflows/test.yml`: a runner without one is the
machine that caught `init` assuming one, and configuring the workflow around
that would blind the only runner that reliably reproduces it.
`tests/driver_ownership.sh` is where the instance/tool split is proved the
only way that means anything: a copy of the binary somewhere else on disk,
with no checkout of this repo in reach.
`tests/gh_extension_packaging.sh` does the same for the release artifact:
it runs `.github/release-build.sh` for the one platform it can execute,
then drives the result both as `archimedes` and as `gh-archimedes` under
`GH_EXTENSION=1` and compares what each scaffolds. Running the real build
script is the point — a test that restated the ldflags recipe would keep
passing after the recipe it copied had changed.

## Subcommands

- `init` — scaffold a new instance from the embedded template
- `bootstrap` — discover an org's repos, clone and scaffold them
- `render-map` — regenerate `WORKSPACE-MAP.md`'s repo list
- `context-map` — sequence a context-mapping pass across every repo
- `run-driver` — invoke one context-mapping driver directly
- `drivers` — list the drivers an instance can run, and where each is from
- `spawn` — create the branch and worktree for one unit of work
- `status` — live PR/branch state across every spawned worktree
- `prune` — remove worktrees whose PR has merged or closed
- `sync-templates` — push the canonical PR/issue templates out
- `sync-house-rules` — push one repo's house rules out
- `apply-convention-pack` — scaffold a repo onto its declared convention
- `notify` — the staleness and prune-eligibility checks above, run on a
  schedule instead of by hand
- `dashboard` — a live view of the above
- `serve-mcp` — the same instance served over the Model Context Protocol

`init` is the one subcommand that runs before an instance exists, so it is
also the only one with no `--root`: it takes the name to create and the
parent directory to create it in. It writes the embedded template there and
commits the result as the instance's first commit — a fresh history, so instance-specific (possibly
sensitive) content never shares one with this repo. A destination that
already exists is refused rather than merged into, and a run that fails while
writing the instance removes what it wrote, so the retry fails for the real
reason instead of "already exists". A first commit that does not happen is
not one of those failures — see below.

That first commit is the one part of `init` that depends on the machine
rather than on the binary, since a commit has to be authored by somebody —
and a fresh laptop, a container and every CI runner have nobody configured,
as has any operator who never got round to setting one. There, `init` writes
the instance, initializes its repository, and stops: it reports the instance
ready but uncommitted and prints the two `git config` settings plus the `git
add -A && git commit` that finishes it, under the same subject it would have
used.

What it never does is commit under an identity nobody chose. An instance is
the operator's own repository and its first commit stays in that history
forever, so an author they never picked is worse there than an instance that
is merely uncommitted — and that includes the one git guesses. Given no
configuration git derives an identity from the OS account and commits under
it wherever the derivation comes back usable, which on a developer's macOS
box it does: their full name and `login@their-hostname.local`, in the
instance's first commit for good. So the bar is an identity somebody set on
purpose — in config, or in the `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment
where CI systems put it — decided by `gitutil.HasConfiguredIdentity`, which
is `git var` again under `user.useConfigOnly`. Narrowing the question that
way keeps the answer git's own rather than making it a rule of ours, which
would have to re-derive where git looks and would sooner or later forget the
environment and refuse on the systems that set an identity there
deliberately.

That leaves `init` deliberately stricter than `git commit` on every machine
whose account git can guess from, and the uncommitted notice says so in as
many words: an operator who has just watched git commit in every other
repository they own would otherwise read a skipped commit as a bug rather
than as a decision.

The commit can also fail with an identity configured and perfectly correct:
signing configured with no key that works here — a dotfile copied to a new
laptop, a container with no keyring, a `gpg.program` that is not installed —
a `pre-commit` hook that says no, a disk with nothing left on it. `init` ends
there the same way, with the instance written and kept and a notice that the
commit did not happen, and with two differences the cause forces. It cannot
name the remedy the way the identity notice does, because the causes are a
list nobody can finish: it frames the failure in its own words and quotes
git's underneath, which is the only part that names the particular thing to
fix. And it says that no second attempt was made with the configuration
turned off, because `--no-gpg-sign` past a broken key is the fix that
suggests itself and would put a commit in the operator's permanent history
contradicting what they set on purpose — the same objection as an author
nobody chose. Neither case exits non-zero: `init`'s status is about the
instance, and in both of them the instance is there.

That is what splits `instance.Create`'s cleanup rule in two, and the rule is
now the question behind it rather than the mechanism — is there an instance
here? Writing the instance, the files and the repository they sit in, is
Create's own work, and a failure part-way through leaves something that is
not an instance, so the directory goes back and the error is returned. The
first commit is the operator's, made on their behalf, and a refusal leaves an
instance that is whole and usable, so it is reported in the `Result` rather
than returned as a failure. Taking the directory back there would cost them
the valuable half to punish them for the half that needs them, and the retry
after they had fixed their machine would rebuild the identical directory.
`tests/init_when_git_refuses_the_commit.sh` drives that through the installed
binary on a machine configured to reproduce it, down to running the retry
`init` printed.

`bootstrap` discovers a GitHub org's repos, clones the ones not already
checked out beside the instance, and scaffolds each one's `repos.yaml` entry
and dossier stub before regenerating `WORKSPACE-MAP.md`. Every step is
idempotent, since re-running as the org grows is the normal case: an entry
already listed, a checkout already present, and a dossier already written are
each left exactly as they are, so a run that discovers nothing new leaves the
instance byte-for-byte unchanged.

Scaffolded entries spell out every per-repo field, including the ones nothing
sets yet (`convention_pack`, `driver`, `depends_on`, `context_modeled_sha`) —
declaring a convention pack is filling in a key that's already there rather
than remembering its name. `repos.yaml` is edited as a YAML node tree rather
than re-marshalled, so its comments and any fields the CLI doesn't model
survive the rewrite.

`spawn` creates the branch and worktree for one unit of work in one target
repo. It always fetches first, so a branch starts from current remote state
rather than a stale local checkout, and resolves its start point by
precedence (`--stack-on` over `--base` over the repo's own base branch). It
then materializes the unit of work's reference material plus the target
repo's house rules into the worktree's `.archimedes/`, under the no-commit
guarantee (see `internal/spawn/materialize.go`).

`status` reads every `work/<slug>/status.md`, looks up each row's live PR
state via `gh pr list`, and prints a fixed-width table (or `--json` for a
machine-readable report). A row's PR lookup degrading to "no PR" — a missing
`gh` auth, no network, an unset repo — never fails the rest of the report:
one unanswerable row shouldn't cost you the other nine.

It also flags stacked branches left behind by a squash- or rebase-merged
base — the case where a dependent branch would open a pull request
re-proposing work that has already landed. A row whose note reads `stacked
on <repo>:<slug>` is flagged when three things hold: the base's commits are
still in the branch's history, those commits are *not* on the branch's
`origin/<base branch>`, and the base's pull request has actually merged
(`gh pr list --state merged`, since a rewriting merge leaves nothing git can
recognize).

Each condition earns its place. Testing against the base's own tip rather
than against upstream is what makes the flag stable: it clears when the
branch is rebased and stays clear as `origin/<base branch>` moves on, where
an "is the branch behind upstream?" test would re-fire on every unrelated
merge. The second condition is why a merge-commit or fast-forward base isn't
flagged — its commits are on upstream as themselves, so the dependent's pull
request already shows only the dependent's own work and no rebase is owed.
And without the third, every healthy stack would match.

Both git questions are asked of the *dependent's* checkout, since that's
where `spawn` resolved the start point (`--stack-on` names the base's repo
for bookkeeping, but branches from the base's slug in the repo being spawned
into); only the merged lookup goes to the base's own repo, where its pull
request lives. Anything unanswerable — no `gh`, no network, an upstream ref
nobody has fetched — reports no flag rather than guessing.

`prune` removes worktrees, branches, and status rows for units of work whose
PR has merged or closed. It's a dry run unless `--force` is passed, and it
refuses to remove a branch still acting as another unit of work's stacked
base — decided from every `status.md`'s parsed notes, not from their text
(see "What reads `work/<slug>/status.md`").

A `--force` run goes through every candidate it listed rather than stopping
at the first one git will not let go of. Each is its own worktree, branch
and row, and none of them is any less prunable for a locked worktree three
entries back; a run that stopped there left `removed.` behind it, silence
ahead of it, and a second run to find out which was which. Each candidate is
retired in one order — worktree, branch, row — and a step that fails leaves
the ones after it undone, so a worktree git kept keeps the branch and the
row that name it rather than being written out of the instance while it is
still on disk. The failures are named again at the end, since a caller
reading nothing but the error still has to learn what to come back for, and
the run exits non-zero.

Git's reason for each one stands under the entry it belongs to, in git's own
words, with none of this tool's framing around it — the opposite of what
`init` does one command over, and for a reason that is about who is reading
rather than about the errors. `gitutil`'s errors all name the command they
ran, including the ones `init` decided were not enough (issue 39). What
differs here is that the operator typed a git-shaped command with `--force`
in it, against their own checkout, and what comes back is git's objection to
exactly that: a locked worktree, a dirty one, a path already gone. What they
typed is the context that makes git's sentence readable (issue 47), which is
precisely what `init` has to supply for somebody who never asked for a
commit at all. It is printed against the candidate rather than carried up as
the command's error for the same reason: several failures arriving together
as one error reach an operator as a single reflowed paragraph with git's
sentences run into each other. The trade is that git's reason is in the
report and not in the command's error, so a caller reading stderr alone gets
the entries and not the reasons; the report is where this run's account of
itself is, and the entries are what a caller has to act on.
`contextmap.LocalSHA`'s `rev-parse` is the
same captured shape and reaches an operator less directly; the same
conclusion covers it. `tests/prune_when_a_worktree_will_not_go.sh` drives a
half-failing run through the installed binary, where that last hop is.

`context-map` sequences a mapping pass across every repo, dependency/base
repos first, skipping any repo already current for its base branch's latest
commit (`--dry-run` reports that plan without acting on it). It splits two
ways: `internal/contextmap` decides *which* repos need mapping and in what
order, `internal/driver` knows *how* to invoke one driver — so swapping the
configured driver never touches orchestration, and neither half hardcodes
any particular driver. Which driver runs is resolved
most-specific-first: a repo's own `driver` field, then `repos.yaml`'s
top-level one, then `ARCHIMEDES_DRIVER`; with none set, each repo becomes an
interactive session the operator confirms. Recording a repo as mapped goes
through `manifest.SetRepoField`, sharing the node-tree editing described
above so a hand-maintained `repos.yaml` survives the rewrite.

`run-driver` is that second half on its own: one driver, one repo, one
output path, with no pass around it and nothing read from or recorded in
`repos.yaml`. It exists because a driver is the part of an instance most
likely to be written or debugged locally, and stepping through a whole
mapping pass to exercise one is a poor way to do that. It keeps the driver's
own output on stderr so stdout carries only where the map landed.

Whichever of the two starts it, a driver runs in a process group of its own
and is handed every `SIGINT` or `SIGTERM` that reaches `archimedes`. Go
forwards nothing to a child process, so before this a `kill` on the
`archimedes` pid stopped `archimedes` and left the driver running
unsupervised — the operator's prompt back, a third-party toolchain still
unpacked in their repository, and nothing watching the process that was
going to take it out again. Ctrl-C at a terminal appeared to work, but only
because a terminal signals its whole foreground group; nothing arranged
that, and it stopped being true the moment a signal was aimed at the process
instead — a supervisor, a `timeout(1)`, a parent harness shutting its
children down.

Forwarding is half of it. The drivers' rollback runs in an exit trap, after
their session returns, so `archimedes` passes the signal on and then goes
back to waiting: exiting as soon as it had forwarded would be the old
behaviour with extra steps. Waiting is also what lets it relay what the
driver said about the repo, and exit with the status the driver chose — 130
for a `SIGINT`, 143 for a `SIGTERM`, the convention
`drivers/lib/repo-snapshot.sh` follows — rather than a status of its own. A
caller asking whether the target repo was left clean has nothing else to
read. Only the first signal is forwarded: a second would land in a rollback
already running, which is the one state that file cannot get a repo back out
of, so the operator is told what is being waited for — and what forcing it
would cost them — instead. The trade is deliberate and worth stating: while
a driver is running, `archimedes` can no longer be stopped by an interrupt
at all, only by a `SIGKILL` that strands whatever the run left in the target
repo, which is the outcome the waiting exists to avoid.

What this does not do is close the windows `repo-snapshot.sh` names. A
driver that was `SIGKILL`'d, or that died with the machine, never runs its
trap at all, and nothing outside it holds the snapshot; that is the other,
more expensive half of what that file asks for.
`internal/driver/interrupt.go` is the whole of the forwarding, and
`tests/interrupted_run.sh` drives it through the installed binary with the
signal aimed at the `archimedes` pid alone rather than at a process group.

`run-driver`, a mapping pass, and `drivers` all build their `driver.Set`
through the one `driver.SetFor` — `--root` or `ARCHIMEDES_DRIVERS_DIR` for
the instance layer, `archimedes.Drivers()` underneath — so none of them can
disagree about what a name means. Anything that resolves a driver goes
through there; a second answer to that question would mean a driver that
works in a pass and is missing outside it, or a listing that promises what
a run won't deliver. `ARCHIMEDES_DRIVERS_DIR` moves the *instance* layer,
not the whole lookup: the built-ins stay underneath whatever it names, so
pointing it at a scratch directory to test one driver does not make the
other three vanish.

One manifest reader (`driver.readManifest`) serves both layers, over an
`fs.FS` so the embedded copy and a real directory go through the same
parse. A manifest that loaded in a listing and failed in a run, or the
reverse, would be a disagreement about what a driver is. Listing keeps a
per-driver failure on that driver's entry rather than returning it, because
`drivers` is the command an operator reaches for when something is already
wrong, and one broken manifest must not cost them the report on the rest.

`drivers` is that resolution reported rather than acted on: every name the
three routes above could resolve, and which layer answers it. `drivers
adopt <name>` copies a shipped driver into the instance's own `drivers/`,
which is how a shipped driver gets edited. It is one-way and one-time —
nothing re-syncs an adopted driver, and adopting over one already there is
refused rather than resolved, since that copy may be the edit that was the
reason for adopting.

`sync-templates` and `sync-house-rules` (both in `internal/reposync`) push
canonical control-repo content into the target repos as pull requests. The
templates are identical everywhere, so that sync stays a thin wrapper around
`multi-gitter`'s fan-out — the repo list comes straight from `repos.yaml`,
and the per-repo change is a generated mod script `multi-gitter` runs inside
each clone. House rules are specific to one repo, so that sync works
directly on that repo's existing local clone with plain git plus `gh`,
reading the content from the same dossier section `spawn` delivers into a
worktree (`internal/dossier`), so a house rule is still only ever edited in
one place. Both take `--dry-run`.

Neither shells out to anything but git through `internal/gitutil`; every
other external command (`multi-gitter`, `gh`) goes through
`reposync.ExecFunc`, the seam tests replace.

`apply-convention-pack` wires one repo up to the shared build/lint
convention it declares, by adding whatever reference that repo's build tool
needs to start pulling in the pack's published config artifact. Both halves
are instance data — the pack name from the repo's `repos.yaml` entry, the
definition from the instance's `convention-packs/<name>.yaml` — so there is
no config of its own to keep in step with either.

It is one-time scaffolding rather than sync: afterwards the repo owns that
reference like any other dependency, and nothing pushes updates back into
it later. Re-running is a no-op, and the edit is left uncommitted for a
human to review.

`internal/conventionpack` dispatches on the pack's `build_tool`, so adding
a second language/build tool is one entry in its `scaffolders` map plus the
function it names — `gradle.go` is the worked example. Nothing above that
dispatch knows Java or Gradle, down to the pack's build-tool-named block,
which stays undecoded until a scaffolder asks for it in its own shape; so
a new build tool costs a file, not a field on the shared `Pack` type. A build file that already carries a
`buildscript {}` block of its own is refused: the two lines it needs are
printed for a human to place by hand, since where they belong inside an
existing block is a judgment call, not a rewrite worth guessing at.

`notify` asks the same two questions on a schedule instead of by hand: has
a repo's context map gone stale, and has a worktree become prune-eligible.
Each condition is reported once, when it becomes true, and again only if it
clears and comes back — a map that goes staler while still unaddressed is
not news twice.

Nothing stays resident to make that work. A pass compares what holds now
against a small state file beside `repos.yaml` and exits, so the thing that
keeps running is an ordinary scheduler:

```
*/15 * * * * cd /path/to/instance && archimedes notify
```

That file is the memory a daemon would otherwise hold in RAM, and it's what
lets a machine that was asleep for a week report each condition once rather
than not at all. A pass with no news prints nothing, so a scheduler that
mails a job's output mails only what's worth reading; `--seed` records
what's true now without reporting any of it, for adopting the notifier on
an instance whose backlog you already know about.

Reasoning from absence is what makes that work, and also what it has to be
careful about: a condition that stops being reported has either cleared or
gone unasked-about, and only the first should let it notify again. So a
pass names the repos whose remote wouldn't answer and the units of work
`gh` wouldn't report on, and carries their recorded conditions forward
untouched. Without that, one expired `gh` session or one flaky network
would erase the record and re-announce the whole backlog on the next pass
that worked — which is how a notifier gets muted. It is also why
`prune.LookupPRState` reports *why* it came back with no pull request:
prune only needs the safe answer ("no PR, don't touch it"), but a watch
needs to know whether anyone actually asked.

Both conditions are read through the packages that own them —
`contextmap.Survey` and `prune.Scan`, the same reads the dashboard and the
MCP server make — so a notification can't reach a different conclusion than
the `context-map` or `prune` run made in response to it. It surveys with
`FetchedSHA` rather than the dashboard's `LocalSHA`: a watch is the one
reader with no human waiting on it, and reading whatever the checkout last
fetched would leave a repo nobody has fetched in weeks looking current —
exactly the silence this exists to break. A merged unit of work something
else is still stacked on isn't reported, because `prune` would refuse to
remove it; it becomes news once the dependent is rebased, which is when
there is something to do about it.

Where a notification goes is the operator's business. With
`ARCHIMEDES_NOTIFY_CMD` (or `--command`) set, each one is handed to
whatever they already run — `terminal-notifier`, `notify-send`, `ntfy`, a
webhook — invoked via `sh` with the event in its environment
(`ARCHIMEDES_EVENT_TITLE`, `_MESSAGE`, `_KIND`, `_SUBJECT`, `_DETAIL`,
`_REMEDY`) and its text on stdin; with none set it is printed. Event data
never reaches the hook as part of the command string, so a repo or branch
name can't become shell on the machine watching it. A hook that fails
leaves its condition out of the state file and fails the pass: the
scheduler learns the notifier is broken, and the condition is still owed
rather than filed away as news broken to someone who never heard it.

### Dashboard (optional)

`archimedes dashboard` opens a live view of the whole instance: the worktree
table `status` prints — PR state, stack notes, the rebase-needed list, the
concurrent-stream guardrail — next to the per-repo context-map staleness
`context-map --dry-run` reports. It retakes the reading every 30 seconds
(`--refresh`, or `0` for on-demand only), on `r`, and quits on `q`.

It is a presentation layer and nothing else. `internal/dashboard` collects a
`Snapshot` by calling the same `status.BuildReport` and `contextmap.Assess`
the two subcommands call, renders it, and loops; nothing about what a row
*means* is decided there. So the dashboard can't drift from the CLI, and
every command works exactly as it did before — the dashboard is additive and
nothing depends on it.

That parity is what the shared seams are for. `status.ManifestRepos` is the
one place a *status row's* repo name becomes a checkout path plus a base
branch (over `manifest.Resolve`, the disk-free lookup above), and
`contextmap.Survey` is the one place "assess every repo, dependency order
first" lives — `context-map` walks its pass through the same
`contextmap.State` the dashboard reads through.

The one deliberate difference is the network. A mapping pass fetches before
assessing, because it's about to spend a driver run on the answer; a
dashboard refresh reads `origin/<base branch>` as the checkout last saw it,
because a screen that repaints every 30 seconds must not drag the network in
with it. That's the `contextmap.SHALookup` seam — `FetchedSHA` for a pass,
`LocalSHA` for a reading — and it means a repo nobody has fetched lately can
under-report, which is the safe direction: the dashboard stays quiet about a
pass that's due rather than inventing one.

Everything narrower than an unreadable `repos.yaml` is carried in the
snapshot rather than raised: a row whose `gh` lookup failed reads "no PR", a
repo whose base branch couldn't be resolved says so in its own row, and a
refresh that fails outright leaves the last good reading on screen under a
visible error. A dashboard that blanks itself over one unreachable repo
would be worse than one showing that repo as unknown.

`Collect` and `Render` are ordinary functions over data — no terminal, no
clock — and `Model` takes its clock by injection, so the whole thing is
tested by driving messages through `Update` and asserting on frames. Only
`internal/cmd/dashboard.go` touches a terminal; without one (a pipe, a CI
log) it refuses and points at `archimedes status`, which answers the same
question in a form a pipe can hold.
### Terminal workspace integration (opt-in)

`spawn` can also hand the finished worktree to a terminal workspace
manager, so a new unit of work arrives in a pane already rooted at its own
checkout instead of needing a manual `cd`. It is off unless you turn it on:

```
export ARCHIMEDES_WORKSPACE=herdr   # instance-wide, in your shell profile
archimedes spawn widget-fix target --workspace herdr   # or just this once
archimedes spawn widget-fix target --workspace off     # ...or not this once
archimedes spawn widget-fix target --focus             # and switch to it
```

[herdr](https://herdr.dev) is the one integration implemented today
(`internal/workspace`). It's invoked as `herdr worktree open`, adopting the
checkout git already made rather than creating a second one, and labelled
`<repo>:<slug>` — the same shape `--stack-on` parses — because one slug can
be spawned into several repos. herdr also opens a workspace for the parent
repo if it doesn't already have one; that's its own worktree model, not
something spawn asks for.

Without `--focus` the new workspace opens in the background, so a spawn
never yanks you out of what you were doing — including a sweep that spawns
one slug across several repos in a row.

The integration is best-effort by construction. By the time it runs, the
branch, the worktree, its materialized context, and its status row all
exist, so nothing that happens here can fail a spawn — the operator would
only be left cleaning up state that was already complete. A tool that isn't
installed is reported as a `note:` on stderr, since that's the expected
state on most machines and says nothing is wrong; a tool that *is*
installed and still refused the call (its server isn't running, say) gets a
`warning:` carrying whatever it said for itself. The one thing that is a
hard error is naming an integration that doesn't exist — a typo fails
loudly, before any git work, rather than silently withholding the pane you
asked for.

Adding another workspace manager means adding a case to
`workspace.Select` and an `Opener` beside `openHerdr`. Everything above
`internal/workspace` — `spawn`, the flags, the warning path — is written
against the `Integration` type, not against herdr.

### MCP server

`serve-mcp` serves one instance over the Model Context Protocol, so an
MCP-capable agent tool can query and act on repo/worktree state as
structured tool calls instead of shelling out to this CLI and parsing its
tables:

```
archimedes serve-mcp --root /path/to/instance
```

It speaks over stdin/stdout and runs until the client disconnects, so it is
started by the agent tool rather than by hand. Everything else — git's own
output, any warning — goes to stderr, because stdout carries the protocol
itself.

Four tools, matching the subcommands an agent would otherwise have had to
run:

| Tool | Reports | Equivalent |
| --- | --- | --- |
| `list_repos` | every tracked repo, its checkout, base branch, dependencies and context-map bookkeeping | `repos.yaml` itself |
| `repo_status` | every spawned worktree, its live PR state, the rebase flag and the guardrail verdict | `status --json` |
| `context_map_status` | which repos' maps are stale, and the dependency order a pass would rebuild them in | `context-map --dry-run` |
| `spawn_worktree` | the branch and worktree it created for one unit of work | `spawn` |

The first three are annotated read-only; `spawn_worktree` is the one that
writes, and both its description and the server's instructions say so.

It is a second way in, not a second implementation. Each tool is a thin
mapping from a tool call onto the same `internal/` package the subcommand
calls — `status.Collect`, `contextmap.Survey`, `spawn.Run` — so the two
paths can't drift on what the instance currently looks like. That's what
`internal/cmd/servemcp_test.go` pins: it asks the same instance the same
question both ways and compares the answers, so a change that only moves
one of them fails there.

The staleness tool shares `contextmap.Survey` with the dashboard, and the
`SHALookup` seam is what lets one primitive serve both: it passes
`FetchedSHA`, because it answers the question `context-map --dry-run`
answers and that one measures staleness against the remote, where the
dashboard passes `LocalSHA` rather than drag the network into a screen
refresh. `mcpserver.Plan` is the wire projection of the `[]RepoState` that
comes back — JSON tags and schema descriptions belong to the protocol
boundary, not to `contextmap`.

Four things the CLI does that a tool call deliberately doesn't. No
interactive mapping session is offered, which is why the context-map tool
surveys staleness rather than running a pass. No terminal workspace is
opened: a pane appearing on the operator's machine is something they ask
for at their own prompt, not a side effect of an agent's tool call. A
spawn's `cd <worktree> && <agent>` next-step hint is dropped, since its
whole content is already in the result and it is addressed to a person who
isn't there; git's own output still reaches the log.

And a repo whose state can't be read — an unreachable remote, a base branch
that isn't there — is reported as an `error` on that repo rather than
failing the call, where a pass stops at the first one. That is the one
place a tool answers differently from its command, and deliberately: a pass
is about to spend a driver run and can't proceed on an unknown, while a
reader asking "what needs mapping?" is still better off with the answer for
every other repo than with nothing. It is `RepoState.Err`'s documented
contract, and the dashboard reads it the same way.

The server is bound to one instance by `--root` for its lifetime, resolved to
an absolute path when the server is built — a client won't share the working
directory the server was started from, so every path a tool reports is one it
can open. No tool takes a path to another instance.

It reads the same environment as the subcommands (`ARCHIMEDES_MAX_STREAMS`,
`ARCHIMEDES_DRIVER`, `ARCHIMEDES_DRIVERS_DIR`, `ARCHIMEDES_CONTEXT_FILE`), and
carries each setting in the form the environment holds it so the *same*
parser decides what it means — `ARCHIMEDES_MAX_STREAMS=0` is a guardrail of
zero to a tool call exactly as it is to `archimedes status`, not an unset
field falling back to the default. It requires `git` but not `gh`: a PR
lookup degrades to "no PR" rather than failing, so demanding `gh` would
refuse to start a server on a machine where `archimedes status` itself works.

It is built on the official
[Go MCP SDK](https://github.com/modelcontextprotocol/go-sdk); tool schemas
are inferred from the Go argument and result types in
`internal/mcpserver/tools.go`, so a field gains a schema entry by being
declared, not by being described twice.
