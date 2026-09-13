package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The command tree is what these tests drive, rather than the RunE bodies
// underneath it: flags, argument validation and the environment reads all
// belong to the subcommand, and a test that called the internal package
// directly would exercise none of them.

// executeStreams runs the whole command tree with args, returning stdout,
// stderr and whatever the command returned. Nothing is read from stdin.
func executeStreams(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	root := newRootCmd()
	var out, errOut bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&errOut)
	root.SetIn(strings.NewReader(""))
	root.SetArgs(args)
	err = root.Execute()
	return out.String(), errOut.String(), err
}

// execute runs the command tree expecting it to succeed, returning stdout.
func execute(t *testing.T, args ...string) string {
	t.Helper()
	out, _, err := executeStreams(t, args...)
	if err != nil {
		t.Fatalf("archimedes %v: %v\n%s", args, err, out)
	}
	return out
}

// executeErr runs the command tree expecting it to fail, returning the
// error. A subcommand that refuses a misconfiguration is as much of a
// contract as one that works.
func executeErr(t *testing.T, args ...string) error {
	t.Helper()
	out, _, err := executeStreams(t, args...)
	if err == nil {
		t.Fatalf("archimedes %v: expected an error, got none\n%s", args, out)
	}
	return err
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeExecutable writes a script and makes it runnable, for the stub
// drivers and fake external commands the tests hand the CLI.
func writeExecutable(t *testing.T, path, content string) {
	t.Helper()
	writeFile(t, path, content)
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

// instanceBesideCwd makes an empty instance directory and leaves the test
// standing in the directory that holds it, so a subcommand can be given
// `--root instance` -- the ordinary way to name an instance, and the shape
// no test used while 46's bug was live, since an absolute t.TempDir hides
// every question about which working directory a path is true in.
//
// Both names come back because the test needs both: the typed one to hand
// the subcommand, and the absolute one to write assertions against, since
// what a subcommand does with the typed root is the thing under test.
func instanceBesideCwd(t *testing.T) (root, typed string) {
	t.Helper()
	parent := t.TempDir()
	typed = "instance"
	root = filepath.Join(parent, typed)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(parent)
	return root, typed
}
