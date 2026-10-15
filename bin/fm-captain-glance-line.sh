#!/usr/bin/env bash
# Claude Code statusLine command: print the last published captain glance.
# Usage: fm-captain-glance-line.sh (ignores statusLine stdin JSON).
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
FILE=$STATE/captain-glance.json
if [ ! -f "$FILE" ]; then printf '◌ fleet glance unavailable\n'; exit 0; fi
NOW=$(date +%s)
jq -r --argjson now "$NOW" '
  if .schema != "fm-captain-glance.v1" or (.updated | type) != "number" or (.line | type) != "string" then
    "◌ fleet glance unavailable"
  elif ($now - .updated > 600) or ($now < .updated) then
    "◌ stale · " + .line
  else .line end
' "$FILE" 2>/dev/null || printf '◌ fleet glance unavailable\n'
