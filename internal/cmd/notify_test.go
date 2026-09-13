package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/blockadence/gh-archimedes/internal/notify"
	"github.com/blockadence/gh-archimedes/internal/testrepo"
)

func TestNotifyOptionsPrefersTheFlagOverTheEnvironment(t *testing.T) {
	env := map[string]string{
		notifyCmdEnvVar:   "from-env",
		contextFileEnvVar: "docs/DOMAIN.md",
	}
	get := func(k string) string { return env[k] }

	opts := notifyOptions("/instance", "/state.json", "from-flag", true, get)
	if opts.Root != "/instance" || opts.StatePath != "/state.json" || !opts.Seed {
		t.Errorf("flags not carried through: %+v", opts)
	}
	if opts.Command != "from-flag" {
		t.Errorf("Command = %q, want the flag to win over the environment", opts.Command)
	}
	if opts.ContextFile != "docs/DOMAIN.md" {
		t.Errorf("ContextFile = %q, want the shared context-file override", opts.ContextFile)
	}

	if got := notifyOptions(".", "", "", false, get).Command; got != "from-env" {
		t.Errorf("Command = %q, want the environment's hook when no flag is given", got)
	}
	if got := notifyOptions(".", "", "", false, func(string) string { return "" }); got.Command != "" || got.ContextFile != "" {
		t.Errorf("unset environment should leave the package's own defaults to apply: %+v", got)
	}
}

// End-to-end through the command tree: a real instance whose one repo has
// never been mapped, reported once and then not again.
func TestNotifyCommandReportsAStaleMapOnceThenStaysQuiet(t *testing.T) {
	tmp := t.TempDir()
	testrepo.New(t, testrepo.Spec{Dir: tmp, Name: "app"})

	root := filepath.Join(tmp, "instance")
	writeFile(t, filepath.Join(root, "repos.yaml"),
		"repos:\n  - name: app\n    path: ../app\n    base_branch: main\n")

	out := execute(t, "notify", "--root", root)
	if !strings.Contains(out, "Context map stale: app") {
		t.Errorf("first pass:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(root, notify.DefaultStateFile)); err != nil {
		t.Errorf("state file not written beside repos.yaml: %v", err)
	}

	if out := execute(t, "notify", "--root", root); out != "" {
		t.Errorf("second pass said %q, want silence", out)
	}
}

func TestRunNotifyResolvesPRStateThroughTheManifest(t *testing.T) {
	root := t.TempDir()
	_, wt := setupInstance(t, root, "service-a", "widget-fix", "based on main")

	var buf bytes.Buffer
	merged := func(_, _ string) (string, error) { return "MERGED", nil }
	opts := notifyOptions(root, "", "", false, func(string) string { return "" })
	if err := runNotify(&buf, &bytes.Buffer{}, opts, merged); err != nil {
		t.Fatalf("runNotify: %v\n%s", err, buf.String())
	}

	out := buf.String()
	if !strings.Contains(out, "Ready to prune: service-a:widget-fix") {
		t.Errorf("missing the merged unit of work, got:\n%s", out)
	}
	if !strings.Contains(out, "archimedes prune widget-fix") {
		t.Errorf("notification should name what to run about it, got:\n%s", out)
	}
	if _, err := os.Stat(wt); err != nil {
		t.Errorf("a watch must not remove anything, stat worktree = %v", err)
	}
}

// The other half of the rule prune's relative-root test pins above: a repo
// path resolved against the typed root goes to git as the working
// directory it runs *in* -- here, reading a checkout's origin remote to
// turn a status.md row's repo name into a pull request lookup -- so it is
// right for it to stay relative, and a watch named by a relative root has
// to report what the same instance reports under an absolute one.
func TestRunNotifyReadsAnInstanceNamedByARelativeRoot(t *testing.T) {
	root, typed := instanceBesideCwd(t)
	setupInstance(t, root, "service-a", "widget-fix", "based on main")

	var buf bytes.Buffer
	merged := func(_, _ string) (string, error) { return "MERGED", nil }
	opts := notifyOptions(typed, "", "", false, func(string) string { return "" })
	if err := runNotify(&buf, &bytes.Buffer{}, opts, merged); err != nil {
		t.Fatalf("runNotify: %v\n%s", err, buf.String())
	}

	out := buf.String()
	if !strings.Contains(out, "Ready to prune: service-a:widget-fix") {
		t.Errorf("missing the merged unit of work, got:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(root, notify.DefaultStateFile)); err != nil {
		t.Errorf("state file not written beside the instance's repos.yaml: %v", err)
	}
}
