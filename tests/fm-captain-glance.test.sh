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
{"schema":"fm-bearings.v1","decisions_open":[{"id":"one","key":"one","owner":"main","title":"Approve launch","hold_bucket":"live","summary":"Approve launch: choose timing"}],"contributions":{"captain":[]},"in_flight":[{"id":"ship"}]}
JSON
bash "$WRITER" --snapshot "$SNAP"
assert_contains "$(bash "$READER")" '1 need you · ▶ 1 running · Approve launch' "reader shows first decision"
[ "$(wc -l < "$FM_GLANCE_LOG")" -eq 1 ] || fail "expected one notification after first write"
bash "$WRITER" --snapshot "$SNAP"
[ "$(wc -l < "$FM_GLANCE_LOG")" -eq 1 ] || fail "unchanged snapshot must not re-notify"

cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[],"contributions":{"captain":[]},"in_flight":[]}
JSON
bash "$WRITER" --snapshot "$SNAP"
[ "$(wc -l < "$FM_GLANCE_LOG")" -eq 1 ] || fail "clearing all items must not notify"
cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[{"id":"one","key":"one","owner":"main","title":"Approve launch","hold_bucket":"live","summary":"Approve launch: choose timing"}],"contributions":{"captain":[{"owner":"main","task":"ship","url":"https://example.com/pull/1","kind":"pr","reason":"checks green; merge approval needed"}]},"in_flight":[]}
JSON
bash "$WRITER" --snapshot "$SNAP"
[ "$(wc -l < "$FM_GLANCE_LOG")" -eq 2 ] || fail "expected a second notification"
assert_contains "$(tail -1 "$FM_GLANCE_LOG")" '2 new item(s)' "second notification summary"

cat > "$SNAP" <<'JSON'
{"schema":"fm-bearings.v1","decisions_open":[{"id":"parked","key":"parked","owner":"main","title":"Adversarial audit","hold_bucket":"blocked","summary":"Adversarial audit: blocked-by internal-id: DEFERRED BY"},{"id":"future","key":"future","owner":"main","title":"Future decision","hold_bucket":"dated","summary":"Future decision: until 2027-01-01"},{"id":"old","key":"old","owner":"main","title":"Old decision","hold_bucket":"aged","summary":"Old decision: held 40d"},{"id":"due","key":"due","owner":"main","title":"Check AgeVerif client ID before enabling the production verification flow and shipping the release","hold_bucket":"live","summary":"Check AgeVerif client ID: choose the next step"}],"contributions":{"captain":[]},"in_flight":[]}
JSON
bash "$WRITER" --snapshot "$SNAP"
jq -e '.needs | length == 4' "$FM_HOME/state/captain-glance.json" >/dev/null
assert_equals '⚑ 4 need you · ▶ 0 running · Check AgeVerif client ID before enabling the production verification…' \
  "$(bash "$READER")" "reader surfaces only the due action, word-truncated"

jq '.decisions_open |= map(select(.hold_bucket != "live"))' "$SNAP" > "$TMP_ROOT/parked.json"
bash "$WRITER" --snapshot "$TMP_ROOT/parked.json"
assert_equals '⚑ 3 need you · ▶ 0 running' "$(bash "$READER")" "reader omits next-action when nothing is due"

jq '.contributions.captain = [{"owner":"main","task":"ship","url":"https://example.com/pull/2","kind":"pr","reason":"checks green; merge approval needed"}]' "$TMP_ROOT/parked.json" > "$TMP_ROOT/contribution.json"
bash "$WRITER" --snapshot "$TMP_ROOT/contribution.json"
assert_equals '⚑ 4 need you · ▶ 0 running · Approve pull request' "$(bash "$READER")" "reader falls back to a captain contribution"

jq '.updated = 1' "$FM_HOME/state/captain-glance.json" > "$TMP_ROOT/stale.json"
mv "$TMP_ROOT/stale.json" "$FM_HOME/state/captain-glance.json"
case "$(bash "$READER")" in
  '◌ stale · '*) : ;;
  *) fail "reader must flag a stale snapshot" ;;
esac
printf 'ok: captain glance diff, dedupe, and stale reader\n'
