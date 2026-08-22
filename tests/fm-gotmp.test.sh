#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise fm-teardown directly as a subprocess against a fake FM_HOME/FM_ROOT
# built so the real script resolves into it, with stub helper scripts.
# The isolated fm-spawn subprocess in fm-kimi-harness.test.sh covers temp-root creation,
# metadata publication, and the pane environment export.
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. A nonexistent worktree path makes both
# `if [ -d "$WT" ]` guards skip, so teardown runs straight to the cleanup + state rm.
#
# Every sourced library is linked wholesale rather than hand-listed: bash aborts the
# whole script - reporting exit status 0 - the moment a `.` target is missing, so one
# unlisted transitive dependency silently skipped the cleanup this suite asserts.
# Executables teardown shells out to stay stubbed, so linking libraries wholesale
# never puts live fleet state in reach.
link_fake_bin() {
  local fake=$1 f
  mkdir -p "$fake/bin/backends" "$fake/state"
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  for f in "$ROOT"/bin/*-lib.sh "$ROOT"/bin/backends/*.sh; do
    ln -s "$f" "$fake/bin/${f#"$ROOT"/bin/}"
  done
  # Stubs for the scripts teardown shells out to (each best-effort at its call site).
  for f in fm-guard.sh fm-fleet-sync.sh fm-remote-job-reap-orphans.sh; do
    rm -f "$fake/bin/$f"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/bin/$f"
    chmod +x "$fake/bin/$f"
  done
  # Report no backend so backlog_refresh_reminder takes the plain-message path.
  rm -f "$fake/bin/fm-tasks-axi-lib.sh"
  printf 'fm_tasks_axi_backend_available() { return 1; }\n' > "$fake/bin/fm-tasks-axi-lib.sh"
}

make_fake_root() {
  local id=$1 tasktmp=$2
  local fake="$TMP_ROOT/$id"
  link_fake_bin "$fake"
  # Meta with a nonexistent worktree so the dirty/treehouse blocks skip.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-worktree-$id
project=$TMP_ROOT/nonexistent-project-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=$tasktmp
META
  printf '%s' "$fake"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero with a valid tasktmp"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake="$TMP_ROOT/$id-root"
  link_fake_bin "$fake"
  # No tasktmp= line at all.
  cat > "$fake/state/$id.meta" <<META
window=fakeses:fm-$id
worktree=$TMP_ROOT/nonexistent-wt-$id
project=$TMP_ROOT/nonexistent-proj-$id
harness=claude
kind=ship
mode=no-mistakes
yolo=off
META
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_teardown_skips_gracefully_when_dir_missing() {
  # tasktmp= points to a path that does not exist. Teardown must not error.
  local id=td-missing-z4
  local task_tmp="$TMP_ROOT/never-created-fm-$id"
  # Intentionally do NOT create $task_tmp.
  [ ! -e "$task_tmp" ] || fail "precondition: task_tmp should not exist yet"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp dir was missing"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "fm-teardown skips gracefully when tasktmp= points to a nonexistent dir"
}

test_teardown_refuses_to_report_success_when_it_aborts_midway() {
  # A code root missing a transitively sourced library makes bash abort the whole
  # script mid-sequence and report status 0. Teardown must not pass that off as a
  # finished cleanup: the temp root, the state files, and the endpoint are all
  # still there, and the caller has to rerun it.
  local id=td-abort-z5
  local task_tmp="$TMP_ROOT/fm-$id"
  mkdir -p "$task_tmp/gotmp"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sourced by the tmux adapter at the endpoint-close step, so it is reached long
  # after teardown installs its EXIT trap and clears every refusal.
  rm -f "$fake/bin/fm-cursor-lib.sh"
  if FM_HOME="$fake" bash "$fake/bin/fm-teardown.sh" "$id" >/dev/null 2>&1; then
    fail "teardown reported success after aborting before it finished"
  fi
  # Proves the abort really did skip the cleanup, so the case cannot go vacuous.
  [ -e "$task_tmp" ] || fail "expected the aborted teardown to leave the tasktmp dir behind"
  pass "fm-teardown refuses to report success when it aborts before finishing"
}

test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_teardown_skips_gracefully_when_dir_missing
test_teardown_refuses_to_report_success_when_it_aborts_midway
