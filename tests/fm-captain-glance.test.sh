#!/usr/bin/env bash
# The public writer and status-line reader preserve action-key notification edges.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-glance)
export FM_HOME=$TMP_ROOT/home FM_GLANCE_NOTIFY_EXEC=$TMP_ROOT/notify
mkdir -p "$FM_HOME/state"
export FM_GLANCE_LOG=$TMP_ROOT/notifications
cat > "$FM_GLANCE_NOTIFY_EXEC" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_GLANCE_LOG"
SH
chmod +x "$FM_GLANCE_NOTIFY_EXEC"
WRITER=$ROOT/bin/fm-captain-glance.sh
READER=$ROOT/bin/fm-captain-glance-line.sh
SNAP=$TMP_ROOT/snapshot.json

cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[{"id":"one","key":"one","owner":"main","summary":"Approve launch"}],"contributions":{"captain":[]},"in_flight":[{"id":"ship"}]}
JSON
bash "$WRITER" --snapshot "$SNAP"
[[ $(bash "$READER") == *'1 need you · ▶ 1 running'* ]]
[[ $(wc -l < "$FM_GLANCE_LOG") -eq 1 ]]
bash "$WRITER" --snapshot "$SNAP"
[[ $(wc -l < "$FM_GLANCE_LOG") -eq 1 ]]

cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[],"contributions":{"captain":[]},"in_flight":[]}
JSON
bash "$WRITER" --snapshot "$SNAP"
[[ $(wc -l < "$FM_GLANCE_LOG") -eq 1 ]]
cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[{"id":"one","key":"one","owner":"main","summary":"Approve launch"}],"contributions":{"captain":[{"owner":"main","task":"ship","url":"https://example.com/pull/1","reason":"Review PR"}]},"in_flight":[]}
JSON
bash "$WRITER" --snapshot "$SNAP"
[[ $(wc -l < "$FM_GLANCE_LOG") -eq 2 ]]
[[ $(tail -1 "$FM_GLANCE_LOG") == *'2 new item(s)'* ]]

jq '.updated = 1' "$FM_HOME/state/captain-glance.json" > "$TMP_ROOT/stale.json"
mv "$TMP_ROOT/stale.json" "$FM_HOME/state/captain-glance.json"
[[ $(bash "$READER") == '◌ stale · '* ]]
printf 'ok: captain glance diff, dedupe, and stale reader\n'
