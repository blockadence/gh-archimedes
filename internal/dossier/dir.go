package dossier

import "path/filepath"

// Dir is where the instance at root keeps its dossiers.
//
// Two different things can live under this name, and this is only one of
// them. `repos/<name>.md` is the prose Archimedes parses — the dossiers,
// which is what Dir answers for. `repos/<name>/` may be somebody's
// checkout of the repository that prose is about: `repos.yaml` records a
// checkout as `../<name>` and bootstrap clones beside the instance, but the
// manifest permits a path below the root too, and `repos/<name>` is exactly
// the layout internal/worktree's own test exercises for that case. So one
// instance can hold `repos/service-a.md` and `repos/service-a/` at once —
// two entries that share a name and never a path. Nothing resolves a
// checkout through Dir, and nothing should: where a checkout is comes from
// the manifest entry that records it (manifest.CheckoutOf), wherever that
// entry says.
//
// That arrangement stays, decided rather than inherited (issue 76). The
// ambiguity costs the paragraph above; removing it would cost a migration
// of every instance in existence, since `repos/<name>.md` is what each of
// them carries and an instance is a git repository whose dossiers are
// committed, whose history refers to them by that path, and whose generated
// WORKSPACE-MAP.md links them there (workspacemap.RepoLine). That is a
// move, a compatibility read of the old location, and some way to tell an
// operator any of it happened — bought for a collision that has never
// occurred and that only a manifest pointing a checkout below the root can
// arrange. What keeps it from being one is that every reader here looks a
// dossier up by name (Path) rather than walking the directory: dir_test.go
// holds that with a checkout sitting under the same name, and spawn's suite
// holds it through a real subcommand.
//
// The answer changes the day something does resolve a checkout through Dir
// — a subcommand that opens a repo from a dossier name, say. That is the
// day to run the argument again, with a real collision to weigh the
// migration against, rather than a reason to let the join below mean two
// things in the meantime.
//
// Dir rather than the DirName the packages owning an instance's other
// directories export (conventionpack.DirName, reposync.ScaffoldingDirName,
// driver.dirName): those hand out a name their callers join, and a name is
// what would put the join back at the three call sites this removes. Dir
// answers with the joined directory, the way workdir.Path does — Path being
// the name it cannot have here, since a dossier's own file already has it.
//
// root is answered as it was given, as in workdir.Path: `--root .` is the
// ordinary way to name an instance, and every caller reads this answer from
// the directory the operator typed it in.
//
// The directory stays a parameter to the rest of this package — WriteStub,
// HouseRules, Path — rather than each of them taking root and joining. That
// parameter is what lets a dossier be read and written against a bare
// t.TempDir() with no instance around it, which is worth more than the join
// it would save; this is the difference from internal/workdir, where the
// location was the whole of the new package. Callers ask Dir, so the three
// that used to write `filepath.Join(root, "repos")` out by hand — bootstrap,
// reposync's house-rules sync, and spawn's materialize — still agree, and
// nobody spells the layout out for a fourth time (issue 72).
//
// A fourth caller wants the layout without wanting a file: workspacemap's
// generated map links a dossier rather than opening one, and asks RelPath
// below, which is built from this join so that it cannot drift from it
// (issue 90).
func Dir(root string) string {
	return filepath.Join(root, "repos")
}

// RelPath is a repo's dossier as an instance-relative path —
// `repos/<repo>.md`, the shape a document committed inside the instance has
// to link to.
//
// It exists because one caller does not want a filesystem path.
// workspacemap.RepoLine writes a markdown link into WORKSPACE-MAP.md, which
// is committed in the instance and resolved relative to it by whatever
// renders the file, so the joined directory Dir answers with is the wrong
// shape and `Path(Dir(""), repo)` at the call site would be a worse
// spelling than the literal it replaced. Rather than leave the one caller
// that could disagree with Dir the one nothing would tell, the question it
// actually asks is answered here, by the package that owns both halves
// (issue 90).
//
// The answer is built from Dir and Path rather than written out again — the
// empty root is what leaves Dir's join relative — so a change to that join
// changes every rendered link with it.
//
// The separator is forced to a slash because this answer is read by a
// renderer and not by a filesystem: a map rendered on Windows must not
// commit `repos\service-a.md` into a file a teammate on another platform
// opens, and no markdown renderer resolves a backslash. Dir and Path answer
// for a filesystem and stay native.
//
// It takes no root, and Dir's answer goes on meaning one thing: a caller
// wanting the file on disk asks Path(Dir(root), repo), as the three
// filesystem callers do.
func RelPath(repo string) string {
	return filepath.ToSlash(Path(Dir(""), repo))
}
