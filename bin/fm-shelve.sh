#!/usr/bin/env bash
# Shelve a deferred ship task without discarding its draft or closing its backlog item.
# Usage: fm-shelve.sh <task-id> --until YYYY-MM-DD [--reason <text>]
# data/<id>/shelved.meta is the durable snapshot; teardown removes task meta but
# keeps data/<id>. A retry after a partial failure repeats only safe operations.
# The worker writes resume.md and commits drafts; this script never commits for it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

fail() { printf 'fm-shelve: REFUSED: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: fm-shelve.sh <task-id> --until YYYY-MM-DD [--reason <text>]\n'; }

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
case "$1" in --help|-h) usage; exit 0 ;; esac
ID=$1
shift
fm_task_id_creation_valid "$ID" || fail "invalid task id"
UNTIL=
REASON="Deferred task snapshot"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --until|--reason)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in --until) UNTIL=$2 ;; --reason) REASON=$2 ;; esac
      shift 2
      ;;
    *) fail "unknown argument $1" ;;
  esac
done
[ -n "$UNTIL" ] || fail "--until is required"
[[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "--until must be YYYY-MM-DD"
[ -n "$REASON" ] || fail "--reason must be nonempty"

TASK_DIR="$DATA/$ID"
SNAPSHOT="$TASK_DIR/shelved.meta"
NOTE="$TASK_DIR/resume.md"
META="$STATE/$ID.meta"
[ -d "$TASK_DIR" ] && [ ! -L "$TASK_DIR" ] || fail "task data directory is missing or unsafe: $TASK_DIR"
[ ! -L "$SNAPSHOT" ] && [ ! -L "$NOTE" ] || fail "snapshot or resume note is a symlink"
if [ ! -f "$META" ]; then
  [ -f "$SNAPSHOT" ] && [ -s "$NOTE" ] || fail "task has no live record and no completed snapshot"
  printf 'fm-shelve: task %s is already shelved at %s\n' "$ID" "$SNAPSHOT"
  exit 0
fi
[ ! -L "$META" ] || fail "task record is a symlink"
[ "$(fm_meta_get "$META" kind)" = ship ] || fail "only ship tasks can be shelved"
MODE=$(fm_meta_get "$META" mode)
[ "$MODE" != local-only ] || fail "local-only tasks cannot publish a snapshot branch"
case "$MODE" in no-mistakes|direct-PR) ;; *) fail "unknown delivery mode $MODE" ;; esac
[ -z "$(fm_meta_get "$META" pr)" ] || fail "a task with an open PR is outside the shelve path"
WT=$(fm_meta_get "$META" worktree)
PROJECT=$(fm_meta_get "$META" project)
BRANCH=$(fm_meta_get "$META" branch)
[ -n "$WT" ] && [ -d "$WT" ] || fail "task worktree is missing"
[ -n "$PROJECT" ] && [ -d "$PROJECT" ] || fail "task project is missing"
[ "$(cd "$WT" && pwd -P)" != "$(cd "$PROJECT" && pwd -P)" ] || fail "task has no isolated copy to release"
if [ -z "$BRANCH" ] || ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  fail "task branch is missing or invalid"
fi
[ "$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" = "$WT" ] || fail "recorded worktree is not its git root"
[ "$(git -C "$WT" branch --show-current 2>/dev/null)" = "$BRANCH" ] || fail "worktree is not on recorded task branch $BRANCH"
git -C "$WT" remote get-url origin >/dev/null 2>&1 || fail "project has no origin to hold the snapshot"

DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all) || fail "could not inspect worktree status"
if [ ! -s "$NOTE" ] || [ -n "$DIRTY" ]; then
  # A missing worker cannot be asked to preserve context. The command refuses
  # instead of guessing the work that remains.
  "$SCRIPT_DIR/fm-send.sh" "$ID" "Write $NOTE with what is done, what remains, open questions, and branch $BRANCH. Commit every draft in your task worktree. Do not push or open a PR; the shelve command handles the snapshot." \
    || fail "could not ask the worker for a resume note"
  WAIT_SECS=${FM_SHELVE_NOTE_WAIT_SECS:-120}
  [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || fail "FM_SHELVE_NOTE_WAIT_SECS must be seconds"
  elapsed=0
  while [ "$elapsed" -lt "$WAIT_SECS" ]; do
    [ ! -s "$NOTE" ] || [ -n "$DIRTY" ] || break
    sleep 1
    elapsed=$((elapsed + 1))
    DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all) || fail "could not inspect worktree status"
  done
fi
[ -f "$NOTE" ] && [ -s "$NOTE" ] || fail "resume note is missing at $NOTE; copy remains leased"
DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all) || fail "could not inspect worktree status"
[ -z "$DIRTY" ] || fail "worktree has uncommitted or untracked work; copy remains leased"
HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}') || fail "task HEAD is not a commit"

# A non-force push refuses a conflicting remote history. Read the remote head
# back so teardown's existing remote-reachability check sees the same commit.
# This publishes a draft branch only; the resumed task's validation runs the project's gates.
git -C "$WT" push --no-verify origin "refs/heads/$BRANCH:refs/heads/$BRANCH" || fail "plain branch push failed; copy remains leased"
git -C "$WT" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || fail "could not verify pushed branch; copy remains leased"
[ "$(git -C "$WT" rev-parse --verify "refs/remotes/origin/$BRANCH^{commit}")" = "$HEAD" ] || fail "remote branch does not match task HEAD; copy remains leased"

TMP="$TASK_DIR/.shelved.meta.$$"
umask 077
{
  printf 'branch=%s\n' "$BRANCH"
  printf 'head=%s\n' "$HEAD"
  printf 'resume=%s\n' "$NOTE"
  printf 'shelved_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP" || fail "could not write snapshot record"
mv "$TMP" "$SNAPSHOT" || fail "could not publish snapshot record"

FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$ID" --reason "$REASON" --until "$UNTIL" \
  || fail "captain hold failed; snapshot is saved and copy remains leased"
release_attempt=0
while :; do
  if release_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-teardown.sh" "$ID" 2>&1); then
    [ -z "$release_out" ] || printf '%s\n' "$release_out"
    break
  fi
  printf '%s\n' "$release_out" >&2
  case "$release_out" in
    *'REFUSED: another Treehouse slot allocation or return is in progress for '*'nothing was changed'*)
      [ "$release_attempt" -lt 3 ] || fail "guarded teardown failed; snapshot and hold are saved, and the copy remains leased"
      release_attempt=$((release_attempt + 1))
      sleep 1
      ;;
    *) fail "guarded teardown failed; snapshot and hold are saved, and the copy remains leased" ;;
  esac
done
printf 'fm-shelve: shelved %s at %s; copy released\n' "$ID" "$BRANCH"
