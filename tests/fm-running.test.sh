#!/usr/bin/env bash
# Orphan classifier for bin/fm-running.sh: synthetic ppid/cwd/elapsed rows,
# including the age-alone case that must not flag. Does not read the live
# process table.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-running.sh"

DAY=86400

reason_of() {  # <ppid> <cwd> <elapsed>
  fm_running_orphan_reason "$1" "$2" "$3"
}

test_tmp_orphan_is_flagged() {
  local got
  got=$(reason_of 1 /private/tmp/claude-501/scratchpad/lab $((20 * DAY)))
  assert_equals "parent gone; cwd in /private/tmp; up 20d" "$got" \
    "a 20-day init child in /private/tmp must flag with an explained reason"
  pass "orphan classifier flags a long-lived init child whose cwd is under /private/tmp"
}

test_var_folders_orphan_is_flagged() {
  local got
  got=$(reason_of 1 /var/folders/yl/r0vn90j910bdmdqt36txn9sh0000gn/T/leftover $((2 * DAY)))
  assert_equals "parent gone; cwd in /var/folders; up 2d" "$got" \
    "a stale init child under /var/folders must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is under /var/folders"
}

test_slash_tmp_orphan_is_flagged() {
  local got
  got=$(reason_of 1 /tmp/fake-server $((3 * DAY)))
  assert_equals "parent gone; cwd in /tmp; up 3d" "$got" \
    "a stale init child under /tmp must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is under /tmp"
}

test_unreadable_cwd_orphan_is_flagged() {
  local got
  got=$(reason_of 1 '' $((2 * DAY)))
  assert_equals "parent gone; cwd unreadable; up 2d" "$got" \
    "a stale init child with a missing cwd must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is unreadable"
}

test_age_alone_does_not_flag() {
  local got rc
  got=$(reason_of 1 /Users/someone/code_projects/server $((32 * DAY)))
  rc=$?
  assert_equals '' "$got" "age alone must print no reason"
  [ "$rc" -ne 0 ] || fail "age alone must not flag a legitimate long-lived server"
  pass "orphan classifier does not flag on age alone when cwd is a real project path"
}

test_young_tmp_process_does_not_flag() {
  local got rc
  got=$(reason_of 1 /private/tmp/just-started $((DAY - 1)))
  rc=$?
  assert_equals '' "$got" "a young temp-cwd process must print no reason"
  [ "$rc" -ne 0 ] || fail "elapsed at the stale threshold must not flag"
  pass "orphan classifier does not flag a temp-cwd init child younger than the stale threshold"
}

test_live_parent_does_not_flag() {
  local got rc
  got=$(reason_of 42 /private/tmp/claude-501/scratchpad/lab $((20 * DAY)))
  rc=$?
  assert_equals '' "$got" "a process whose parent is still alive must print no reason"
  [ "$rc" -ne 0 ] || fail "ppid other than init must not flag even in a temp cwd"
  pass "orphan classifier does not flag a temp-cwd process whose parent is not init"
}

test_tmp_prefix_is_not_a_substring_match() {
  local got rc
  got=$(reason_of 1 /private/tmpdir/server $((20 * DAY)))
  rc=$?
  assert_equals '' "$got" "/private/tmpdir is not a temp root"
  [ "$rc" -ne 0 ] || fail "a /private/tmpdir path must not inherit the /private/tmp rule"
  pass "orphan classifier does not treat /private/tmpdir as a temp cwd"
}

test_tmp_orphan_is_flagged
test_var_folders_orphan_is_flagged
test_slash_tmp_orphan_is_flagged
test_unreadable_cwd_orphan_is_flagged
test_age_alone_does_not_flag
test_young_tmp_process_does_not_flag
test_live_parent_does_not_flag
test_tmp_prefix_is_not_a_substring_match
