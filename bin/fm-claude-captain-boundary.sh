#!/usr/bin/env bash
# Record the two most recent real captain prompt times for /ahoy after compaction.
# Claude UserPromptSubmit JSON arrives on stdin. Every path is best effort and
# exits zero without output, so a failed state write never blocks the prompt.
# The newest timestamp is this prompt; the second is /ahoy's prior boundary.
# Usage: fm-claude-captain-boundary.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_captain_boundary_record() {
  local payload prompt classified previous now tmp record="$STATE/.last-captain-message"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  payload=$(cat 2>/dev/null) || return 0
  fm_hook_payload_is_foreign_host "$payload" && return 0
  prompt=$(printf '%s' "$payload" | jq -erj '.prompt | strings' 2>/dev/null; printf x)
  prompt=${prompt%x}
  [ -n "$prompt" ] || return 0

  # Only the /ahoy exclusions are applied. The general legacy classifier also
  # recognizes old watcher prose, which this boundary must not suppress.
  case "$prompt" in
    "$FM_OPERATIONAL_PREFIX"*|"$FM_LEGACY_AWAY_PREFIX"*) return 0 ;;
  esac
  [ "$prompt" = "$FM_LEGACY_SESSIONSTART" ] && return 0
  case "$prompt" in
    ': Firstmate instruction waiting: '*)
      fm_operational_doorbell_kind "$prompt" "$STATE" classified && return 0
      ;;
  esac

  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 0
  previous=
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS= read -r previous < "$record" || true
  fi
  umask 077
  tmp=$(mktemp "$STATE/.last-captain-message.XXXXXX" 2>/dev/null) || return 0
  if { printf '%s\n' "$now"; [ -z "$previous" ] || printf '%s\n' "$previous"; } > "$tmp" &&
     mv -f -- "$tmp" "$record"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 0
}

fm_captain_boundary_record >/dev/null 2>&1 || true
exit 0
