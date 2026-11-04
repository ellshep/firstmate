#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
# `update <id> --append-body <file>` appends to the current body. A replacement
# `--body-file` must be nonempty and retain at least half the current body unless
# `--force-body` is explicit. These wrapper-only flags never reach tasks-axi.
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
BODY_FILE=
APPEND_BODY=
FORCE_BODY=0
for arg in "$@"; do
  if [ "$path_value_next" = append ]; then
    APPEND_BODY=$(absolute_from_caller "$arg")
    path_value_next=0
    continue
  fi
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    [ "${ARGS[${#ARGS[@]}-2]}" != --body-file ] || BODY_FILE=${ARGS[${#ARGS[@]}-1]}
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --append-body)
      [ "${1:-}" = update ] || fail "--append-body applies only to update"
      path_value_next=append
      ;;
    --force-body)
      [ "${1:-}" = update ] || fail "--force-body applies only to update"
      FORCE_BODY=1
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --append-body=*)
      [ "${1:-}" = update ] || fail "--append-body applies only to update"
      APPEND_BODY=$(absolute_from_caller "${arg#*=}")
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      [ "${arg%%=*}" != --body-file ] || BODY_FILE=$(absolute_from_caller "${arg#*=}")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done
[ "$path_value_next" = 0 ] || fail "a file flag requires a path"
[ -z "$APPEND_BODY" ] || [ -z "$BODY_FILE" ] || fail "use either --append-body or --body-file"
[ "$FORCE_BODY" -eq 0 ] || [ -n "$BODY_FILE" ] || fail "--force-body requires --body-file"

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
if [ "${1:-}" = update ] && { [ -n "$BODY_FILE" ] || [ -n "$APPEND_BODY" ]; }; then
  source_file=${APPEND_BODY:-$BODY_FILE}
  [ -f "$source_file" ] && [ -r "$source_file" ] && [ -s "$source_file" ] || fail "body file must be a readable nonempty regular file: $source_file"
  # `show --full` exposes the complete body as one scalar: plain for simple
  # one-line notes and JSON-quoted when escaping is needed. It has no --json.
  current=$(tasks-axi show "${2:-}" --full) || fail "could not read current body for ${2:-}"
  old_file=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-old-body.XXXXXX") || fail "could not stage current body"
  trap 'rm -f "$old_file" "${merged:-}"' EXIT
  printf '%s\n' "$current" | perl -MJSON::PP -ne 'if (/^  body: (.*)$/) { $body=$1; print $body =~ /^"/ ? JSON::PP::decode_json($body) : $body; $found=1 } END { exit !$found }' > "$old_file" || fail "could not decode current body for ${2:-}"
  old_bytes=$(wc -c < "$old_file" | tr -d ' ')
  if [ -n "$APPEND_BODY" ]; then
    merged=$(mktemp "${TMPDIR:-/tmp}/fm-tasks-body.XXXXXX") || fail "could not stage appended body"
    cat "$old_file" > "$merged"
    if [ "$old_bytes" -gt 0 ] && [ "$(tail -c 1 "$old_file" | od -An -tu1 | tr -d '[:space:]')" != 10 ]; then
      printf '\n' >> "$merged"
    fi
    cat "$APPEND_BODY" >> "$merged" || fail "could not append body file"
    ARGS+=(--body-file "$merged")
  elif [ "$FORCE_BODY" -eq 0 ] && [ "$old_bytes" -gt 0 ]; then
    new_bytes=$(wc -c < "$BODY_FILE" | tr -d ' ')
    [ "$((new_bytes * 2))" -ge "$old_bytes" ] || fail "replacement body drops more than half the current note; use --append-body or explicit --force-body"
  fi
fi
case "${1:-}" in
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
tasks-axi ${ARGS[@]+"${ARGS[@]}"}
