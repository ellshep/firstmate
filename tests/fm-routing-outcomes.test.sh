#!/usr/bin/env bash
# Private routing ledger: safe concurrent launch appends and a deduplicated outcome.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-routing-outcomes)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/task-a" "$HOME_DIR/state"
TOOL="$ROOT/bin/fm-routing-outcomes.sh"
cat > "$HOME_DIR/data/task-a/dispatch-resolution.json" <<'JSON'
{"task":"task-a","status":"clear","profile":{"harness":"claude","model":"sonnet","effort":"medium"},"jev_pick":"rule_3","selected_rule":"rule_3","confidence":0.9,"suggested_effort":"high","qualification_floor":0.75,"qualification_score":0.8}
JSON
cat > "$HOME_DIR/state/task-a.meta" <<'META'
harness=claude
model=opus
effort=high
dispatch_override=important work needs a stronger model
spawn_gen=gen-a
META
FM_HOME="$HOME_DIR" "$TOOL" launch task-a
FM_HOME="$HOME_DIR" "$TOOL" launch task-a
LEDGER="$HOME_DIR/data/routing-outcomes.jsonl"
[ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ] || fail "launch replay appended twice"
[ "$(jq -r 'select(.event=="launch") | .would_have_qualified' "$LEDGER")" = true ] || fail "qualification evidence was lost"
[ "$(jq -r 'select(.event=="launch") | .override_reason' "$LEDGER")" = 'important work needs a stronger model' ] || fail "override reason was lost"
! grep -q 'brief\|raw_reply' "$LEDGER" || fail "task text reached the ledger"

# Concurrent tasks share one file, but each JSON line must remain complete.
for n in 1 2 3 4 5 6; do
  id="concurrent-$n"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'harness=codex\nmodel=gpt-6-sol\neffort=medium\nspawn_gen=gen-%s\n' "$n" > "$HOME_DIR/state/$id.meta"
  FM_HOME="$HOME_DIR" "$TOOL" launch "$id" &
done
wait
[ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 7 ] || fail "concurrent appends were lost"
jq -e . "$LEDGER" >/dev/null || fail "concurrent appends corrupted JSON"

FM_HOME="$HOME_DIR" "$TOOL" finalize task-a gen-a true false false true
FM_HOME="$HOME_DIR" "$TOOL" finalize task-a gen-a true false false true
FM_HOME="$HOME_DIR" "$TOOL" finalize task-a gen-after-relaunch true false false true
[ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 8 ] || fail "outcome replay appended twice"
[ "$(jq -r 'select(.event=="outcome") | [.stalled,.escalated,.failed,.success,.review_rounds,.review_cost] | @json' "$LEDGER")" = '[true,false,false,true,null,null]' ] || fail "outcome evidence was changed or invented"
mkdir -p "$HOME_DIR/data/task-b"
cat > "$HOME_DIR/data/task-b/dispatch-resolution.json" <<'JSON'
{"status":"clear","profile":{"harness":"claude","model":"sonnet","effort":"medium"},"jev_pick":"rule_2","confidence":0.9,"suggested_effort":"high","selected_effort_ceiling":"medium","qualification_floor":0.75,"qualification_score":0.9}
JSON
printf 'harness=claude\nmodel=sonnet\neffort=medium\nspawn_gen=gen-b\n' > "$HOME_DIR/state/task-b.meta"
FM_HOME="$HOME_DIR" "$TOOL" launch task-b
[ "$(jq -r 'select(.task=="task-b") | .effort_difference_reason' "$LEDGER")" = 'rule effort ceiling' ] || fail "effort clipping lost its reason"
pass "routing ledger serializes concurrent appends and deduplicates launch and outcome events"
