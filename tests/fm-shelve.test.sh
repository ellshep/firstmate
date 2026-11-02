#!/usr/bin/env bash
# End-to-end snapshot and release checks through the public commands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-shelve)

make_case() {
  local name=$1 home="$TMP_ROOT/$1" id=task-x1
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/fakebin"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  tasks-axi add "$id" 'Shelve fixture task' --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  git init --quiet --bare "$home/origin.git"
  git -C "$home/origin.git" symbolic-ref HEAD refs/heads/main
  git clone --quiet "$home/origin.git" "$home/project" 2>/dev/null
  git -C "$home/project" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m baseline
  git -C "$home/project" push --quiet origin main
  git -C "$home/project" worktree add --quiet -b fm/task-x1 "$home/wt" main
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$home/wt" "project=$home/project" \
    'harness=codex' 'kind=ship' 'mode=direct-PR' \
    'branch=fm/task-x1' 'spawn_gen=shelve-fixture'
  touch "$home/state/.last-watcher-beat"
  fm_fake_exit0 "$home/fakebin" tmux treehouse podman docker supabase no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_shelve() {
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SHELVE_NOTE_WAIT_SECS=0 \
    PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-shelve.sh" task-x1 --until 2027-01-15 "$@" 2>&1
}

test_push_hold_release_and_retry() {
  local home out rc head
  home=$(make_case success)
  printf 'Draft\n' > "$home/wt/draft.txt"
  git -C "$home/wt" add draft.txt
  git -C "$home/wt" -c user.email=t@t -c user.name=t commit --quiet -m draft
  printf 'Done: draft.\nRemaining: finish.\nOpen questions: none.\nBranch: fm/task-x1.\n' > "$home/data/task-x1/resume.md"
  head=$(git -C "$home/wt" rev-parse HEAD)
  out=$(run_shelve "$home")
  rc=$?
  expect_code 0 "$rc" "shelve failed: $out"
  [ "$(git -C "$home/origin.git" rev-parse refs/heads/fm/task-x1)" = "$head" ] || fail 'snapshot branch was not pushed'
  assert_grep "head=$head" "$home/data/task-x1/shelved.meta" 'snapshot head was not recorded'
  [ ! -e "$home/state/task-x1.meta" ] || fail 'guarded teardown did not release the task record'
  tasks-axi show task-x1 --file "$home/data/backlog.md" | grep -q '2027-01-15' || fail 'captain hold did not retain the return date'
  out=$(run_shelve "$home")
  expect_code 0 "$?" "retry of completed shelve failed: $out"
  pass 'committed draft is pushed, held with a date, released, and retryable'
}

test_missing_note_and_dirty_copy_refuse() {
  local home out rc
  home=$(make_case refusals)
  out=$(run_shelve "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail 'missing note was accepted'
  [ -e "$home/state/task-x1.meta" ] || fail 'missing note released the copy'
  printf 'Remaining: finish.\nBranch: fm/task-x1.\n' > "$home/data/task-x1/resume.md"
  printf 'unsaved\n' > "$home/wt/unsaved.txt"
  out=$(run_shelve "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail 'dirty copy was accepted'
  [ -e "$home/state/task-x1.meta" ] || fail 'dirty copy released the copy'
  [ ! -e "$home/data/task-x1/shelved.meta" ] || fail 'dirty copy published a snapshot'
  pass 'missing resume note and unsaved work refuse without releasing the copy'
}

fm_test_run test_push_hold_release_and_retry test_missing_note_and_dirty_copy_refuse
