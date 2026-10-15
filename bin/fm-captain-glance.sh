#!/usr/bin/env bash
# Publish a compact captain glance from the existing Bearings projection.
# Usage: fm-captain-glance.sh [--snapshot <bearings-json-file>]
# The optional snapshot is a test and operator seam; normal use collects Bearings.
# state/captain-glance.json is replaced atomically. Only newly present stable
# captain-action keys notify, after the new set is durably published.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
SNAPSHOT=
case ${1:-} in
  '') ;;
  --snapshot) [ "$#" -eq 2 ] || exit 2; SNAPSHOT=$2 ;;
  *) echo 'usage: fm-captain-glance.sh [--snapshot <bearings-json-file>]' >&2; exit 2 ;;
esac

mkdir -p "$STATE"
LOCK=$STATE/.captain-glance.lock
mkdir "$LOCK" 2>/dev/null || exit 0
TMP=
cleanup() { [ -z "$TMP" ] || rm -f "$TMP"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
TMP=$(mktemp "$STATE/.captain-glance.XXXXXX")
if [ -n "$SNAPSHOT" ]; then
  cp "$SNAPSHOT" "$TMP"
else
  "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-in-flight --all-decisions > "$TMP"
fi
jq -e '.schema == "fm-bearings.v1"' "$TMP" >/dev/null
NOW=$(date +%s)
PREVIOUS=$STATE/captain-glance.json
OLD_KEYS='[]'
if [ -f "$PREVIOUS" ]; then
  OLD_KEYS=$(jq -c '[.needs[]?.key | strings]' "$PREVIOUS" 2>/dev/null) || OLD_KEYS='[]'
fi
MODEL=$(jq -c --argjson now "$NOW" --argjson old "$OLD_KEYS" '
  def short: tostring | gsub("[\\r\\n\\t]+"; " ") | .[:72];
  ([.decisions_open[]? | {key:("decision:" + (.owner // "main") + ":" + (.key // .id)),
      item:((.summary // .id // "decision") | short)}]
   + [.contributions.captain[]? | {key:("contribution:" + (.owner // "main") + ":" + .task + ":" + .url),
      item:((.reason // .url) | short)}]) as $needs
  | ($needs | unique_by(.key)) as $unique
  | ($unique | map(select(.key as $key | $old | index($key) | not))) as $added
  | (.in_flight | length) as $running
  | {schema:"fm-captain-glance.v1",updated:$now,needs:$unique,added:$added,running:$running,
     line:("⚑ \($unique | length) need you · ▶ \($running) running"
       + (if ($unique | length) > 0 then " · " + ($unique[0].item | short) else "" end))}
' "$TMP")
printf '%s\n' "$MODEL" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PREVIOUS"
TMP=

ADDED=$(printf '%s' "$MODEL" | jq -r '.added | length')
[ "$ADDED" -gt 0 ] || exit 0
SUMMARY=$(printf '%s' "$MODEL" | jq -r '"\(.added | length) new item(s) need you: \(.added[0].item)"')
if [ -n "${FM_GLANCE_NOTIFY_EXEC:-}" ]; then
  "$FM_GLANCE_NOTIFY_EXEC" "$SUMMARY" || true
elif [ "${FM_SUPERVISOR_BACKEND:-}" = herdr ] || { [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && [ -z "${TMUX_PANE:-}" ]; }; then
  if command -v herdr >/dev/null 2>&1; then herdr notification show "$SUMMARY" >/dev/null 2>&1 || true; fi
elif [ "$(uname)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Firstmate"' -e 'end run' "$SUMMARY" >/dev/null 2>&1 || true
fi
