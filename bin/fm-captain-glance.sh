#!/usr/bin/env bash
# Publish a compact captain glance from the existing Bearings projection.
# Usage: fm-captain-glance.sh [--snapshot <bearings-json-file>]
# The optional snapshot is a test and operator seam; normal use collects Bearings.
# state/captain-glance.json is replaced atomically. Only newly present stable
# captain-action keys notify, after the new set is durably published.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
SNAPSHOT=
case ${1:-} in
  '') ;;
  --snapshot) [ "$#" -eq 2 ] || exit 2; SNAPSHOT=$2 ;;
  *) echo 'usage: fm-captain-glance.sh [--snapshot <bearings-json-file>]' >&2; exit 2 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK=$STATE/.captain-glance.lock
fm_lock_try_acquire "$LOCK" || exit 0
TMP=
cleanup() { [ -z "$TMP" ] || rm -f "$TMP"; fm_lock_release "$LOCK"; }
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
OLD_NOTIFIED='[]'
if [ -f "$PREVIOUS" ]; then
  OLD_NOTIFIED=$(jq -c '[.notified[]? | strings]' "$PREVIOUS" 2>/dev/null) || OLD_NOTIFIED='[]'
fi
MODEL=$(jq -c --argjson now "$NOW" --argjson notified "$OLD_NOTIFIED" '
  def short: tostring | gsub("[\\r\\n\\t]+"; " ") | .[:72];
  def action_title:
    tostring | gsub("\\s+"; " ") | gsub("^ +| +$"; "")
    | if length <= 72 then .
      else . as $title
        | ($title[:71] | sub(" +[^ ]*$"; "")) as $whole_words
        | (if $whole_words == "" then $title[:71] else $whole_words end) + "…"
      end;
  ([.decisions_open[]? | select(.hold_bucket == "live") | (.title // "Captain decision")]
   + [.contributions.captain[]? | if .kind == "pr" then "Approve pull request" else "Review contribution" end]
   | first // null) as $next_action
  |
  ([.decisions_open[]? | {key:("decision:" + (.owner // "main") + ":" + (.key // .id)),
      item:((.summary // .id // "decision") | short)}]
   + [.contributions.captain[]? | {key:("contribution:" + (.owner // "main") + ":" + .task + ":" + .url),
      item:((.reason // .url) | short)}]) as $needs
  # unique_by sorts groups by key, which would silently swap which item leads
  # the line/summary; restore append order (decisions before contributions)
  # after dedup via the original index.
  | ($needs | to_entries | unique_by(.value.key) | sort_by(.key) | map(.value)) as $unique
  | ($unique | map(.key)) as $unique_keys
  | ($notified | map(select(. as $k | $unique_keys | index($k)))) as $kept_notified
  | ($unique | map(select(.key as $k | $kept_notified | index($k) | not))) as $added
  | (.in_flight | length) as $running
  | {schema:"fm-captain-glance.v1",updated:$now,needs:$unique,added:$added,notified:$kept_notified,running:$running,
     line:("⚑ \($unique | length) need you · ▶ \($running) running"
       + (if $next_action != null then " · " + ($next_action | action_title) else "" end))}
' "$TMP")
printf '%s\n' "$MODEL" > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PREVIOUS"
TMP=

ADDED=$(printf '%s' "$MODEL" | jq -r '.added | length')
[ "$ADDED" -gt 0 ] || exit 0
SUMMARY=$(printf '%s' "$MODEL" | jq -r '"\(.added | length) new item(s) need you: \(.added[0].item)"')
NOTIFY_OK=1
if [ -n "${FM_GLANCE_NOTIFY_EXEC:-}" ]; then
  "$FM_GLANCE_NOTIFY_EXEC" "$SUMMARY" || NOTIFY_OK=0
elif [ "$(discover_supervisor_backend || true)" = herdr ]; then
  if command -v herdr >/dev/null 2>&1; then herdr notification show "$SUMMARY" >/dev/null 2>&1 || NOTIFY_OK=0; fi
elif [ "$(uname)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Firstmate"' -e 'end run' "$SUMMARY" >/dev/null 2>&1 || NOTIFY_OK=0
fi
# A failed delivery must not be recorded as notified, so the next run retries
# the same keys instead of silently dropping them.
[ "$NOTIFY_OK" -eq 1 ] || exit 0
TMP=$(mktemp "$STATE/.captain-glance.XXXXXX")
printf '%s' "$MODEL" | jq -c '.notified += (.added | map(.key))' > "$TMP"
chmod 0600 "$TMP"
mv -f "$TMP" "$PREVIOUS"
TMP=
