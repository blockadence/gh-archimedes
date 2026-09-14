#!/usr/bin/env bash
# Switching an instance to the spec-kit driver has to be a configuration
# change and nothing else -- no orchestration edits, no per-driver special
# cases anywhere. These tests prove that without running spec-kit: they set
# up a PATH the `specify` CLI isn't on, so a run gets as far as the driver's
# own dependency check and stops there. Reaching that error at all means
# repos.yaml named the driver, the CLI resolved its manifest, and the
# driver's command ran -- the whole chain minus the billed part.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_DIR="$ROOT/drivers/spec-kit"
build_archimedes || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A PATH with git on it but neither `specify` nor `claude`, wherever this
# machine happens to keep them.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
# bash included deliberately: the driver's `#!/usr/bin/env bash` would
# otherwise resolve to whatever /usr/bin holds, which on macOS is bash 3.2,
# and spec-kit's needs bash 4+.
for tool in bash git; do
  resolved="$(command -v "$tool" 2>/dev/null)" && ln -sf "$resolved" "$STUB_BIN/$tool"
done
SPECLESS_PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

echo "spec-kit driver manifest:"

MANIFEST="$DRIVER_DIR/driver.yaml"
assert_file_exists "$MANIFEST" "the driver ships a manifest under drivers/spec-kit/"
assert_eq "$(manifest_field "$MANIFEST" name)" "spec-kit" "manifest name matches its directory name"
assert_eq "$(manifest_field "$MANIFEST" output_mode)" "fixed-location" \
  "spec-kit is a fixed-location driver -- Spec Kit can't be told where to write"
DECLARED_FIXED_PATH="$(manifest_field "$MANIFEST" fixed_path)"
assert_eq "$DECLARED_FIXED_PATH" ".specify/memory/constitution.md" \
  "manifest declares the constitution path Spec Kit always writes to"
COMMAND="$(manifest_field "$MANIFEST" command)"
[ -x "$DRIVER_DIR/$COMMAND" ] \
  && pass "the command the manifest names is executable" \
  || fail "the command the manifest names is executable"

# A fixed_path that drifts from the path run.sh actually keeps would fail
# silently at harvest time, so the two are pinned to each other here.
assert_contains "$(cat "$DRIVER_DIR/$COMMAND")" "CONSTITUTION=\"$DECLARED_FIXED_PATH\"" \
  "the path run.sh keeps is the same one the manifest declares as fixed_path"

echo ""
echo "spec-kit driver is reachable through archimedes run-driver:"

REPO="$WORK/repo"
mkdir -p "$REPO"
echo "hi" > "$REPO/README.md"
make_repo_at "$REPO"

out_path="$WORK/out.md"
# No ARCHIMEDES_DRIVERS_DIR and no instance: spec-kit comes out of the
# binary, which is the only reason a run from an empty directory can find it
# at all.
if err="$(cd "$WORK" && PATH="$SPECLESS_PATH" \
    "$ARCHIMEDES_BIN" run-driver --root "$WORK" spec-kit "$REPO" "$out_path" 2>&1 >/dev/null)"; then
  fail "a run without the specify CLI installed exits non-zero"
else
  pass "a run without the specify CLI installed exits non-zero"
fi
assert_contains "$err" "specify CLI not found on PATH" \
  "the failure is the driver's own dependency check, so the manifest resolved and the driver ran"
assert_contains "$err" "spec-kit" \
  "the failure names an install hint for Spec Kit rather than leaving the operator guessing"
assert_file_missing "$out_path" "a failed run leaves no output file"
assert_eq "$(git -C "$REPO" status --porcelain)" "" "a failed run leaves the target repo clean"

echo ""
echo "switching an instance to spec-kit is a configuration change only:"

make_origin_and_clone "$WORK" spec-kit-repo
# An instance is data: an empty directory plus the repos.yaml below is all
# this pass needs to find.
INSTANCE="$WORK/instance"
mkdir -p "$INSTANCE"

cat > "$INSTANCE/repos.yaml" <<EOF
driver: spec-kit
repos:
  - name: spec-kit-repo
    path: ../spec-kit-repo
    base_branch: main
    depends_on: []
    context_modeled_sha: null
EOF

(
  cd "$INSTANCE"
  PATH="$SPECLESS_PATH" "$ARCHIMEDES_BIN" context-map
) </dev/null >"$WORK/run.log" 2>&1
run_status=$?

if [ "$run_status" -ne 0 ]; then
  pass "a pass with driver: spec-kit fails on the missing CLI rather than succeeding by accident"
else
  fail "a pass with driver: spec-kit fails on the missing CLI rather than succeeding by accident"
fi
log="$(cat "$WORK/run.log")"
assert_contains "$log" "specify CLI not found on PATH" \
  "naming spec-kit in repos.yaml reaches the real driver -- no orchestration change needed to switch"
case "$log" in
  *"unknown driver"*) fail "spec-kit is a driver a mapping pass can actually find" ;;
  *) pass "spec-kit is a driver a mapping pass can actually find" ;;
esac

echo ""
echo "one repo can be switched to spec-kit on its own:"

# drivers/README.md's spec-kit entry argues the map it produces is a
# different shape from the other two drivers', so which one suits a repo is
# a per-repo judgement. That's only true if the per-repo override actually
# reaches this driver.
# The two layers in one pass: the instance owns stub-ok, spec-kit comes out
# of the binary, and a repos.yaml naming either resolves without the
# operator arranging for both to sit in one directory.
make_origin_and_clone "$WORK" stays-on-default
make_origin_and_clone "$WORK" switched-to-spec-kit
INSTANCE2="$WORK/instance2"
mkdir -p "$INSTANCE2/drivers"
cp -R "$HERE/fixtures/drivers/stub-ok" "$INSTANCE2/drivers/"

cat > "$INSTANCE2/repos.yaml" <<EOF
driver: stub-ok
repos:
  - name: stays-on-default
    path: ../stays-on-default
    base_branch: main
    depends_on: []
    context_modeled_sha: null
  - name: switched-to-spec-kit
    path: ../switched-to-spec-kit
    base_branch: main
    depends_on: []
    context_modeled_sha: null
    driver: spec-kit
EOF

(
  cd "$INSTANCE2"
  PATH="$SPECLESS_PATH" "$ARCHIMEDES_BIN" context-map
) </dev/null >"$WORK/override.log" 2>&1

override_log="$(cat "$WORK/override.log")"
assert_contains "$override_log" "specify CLI not found on PATH" \
  "a single repo's own driver field reaches spec-kit, so one repo can use it without the rest of the instance doing so"
assert_contains "$(cat "$WORK/stays-on-default/CONTEXT.md" 2>/dev/null)" "stub-ok saw repo" \
  "the repo that didn't override stays on the instance-wide default"

report
