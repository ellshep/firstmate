#!/usr/bin/env bash
# Nudge eligibility, reply scope, and one-send-per-set behavior through the CLI.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE="$ROOT/bin/fm-afk-nudge.mjs"
HOME_DIR=$(fm_test_tmproot fm-afk-nudge-tests)
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'entered_epoch: 1000\n' > "$HOME_DIR/state/.afk-contract"

CLAUDE_HOME="$HOME_DIR/claude"
mkdir -p "$CLAUDE_HOME/state"
out=$(FM_HOME="$CLAUDE_HOME" CLAUDECODE=1 bash "$ROOT/bin/fm-afk-contract.sh" enter 2>&1)
assert_contains "$out" 'A phone nudge can ask you' 'Claude entry announces phone reach'
case "$out" in *'No phone channel is configured'*) fail 'Claude entry falsely says no phone channel' ;; esac

CLAUDE_HOME_DANGLING_OFF="$HOME_DIR/claude-dangling-off"
mkdir -p "$CLAUDE_HOME_DANGLING_OFF/state" "$CLAUDE_HOME_DANGLING_OFF/config"
ln -s "$CLAUDE_HOME_DANGLING_OFF/config/missing-target" "$CLAUDE_HOME_DANGLING_OFF/config/supervision-host-off"
out=$(FM_HOME="$CLAUDE_HOME_DANGLING_OFF" CLAUDECODE=1 bash "$ROOT/bin/fm-afk-contract.sh" enter 2>&1)
assert_contains "$out" 'No phone channel is configured' 'a dangling supervision-host-off symlink is treated as the host disabled'
case "$out" in *'A phone nudge can ask you'*) fail 'a dangling supervision-host-off symlink falsely announced phone reach' ;; esac

add() {
  tasks-axi add "$1" "$2" --kind "$3" --repo "$4" --body "$5" --file "$HOME_DIR/data/backlog.md" >/dev/null
}
check() {
  FM_HOME="$HOME_DIR" FM_AWAY_NUDGE_NOW_EPOCH="$1" "$NUDGE" check
}
reply() {
  FM_HOME="$HOME_DIR" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" reply "$1"
}

add s1 'Inspect the form' scout app $'Ready gate: passed\nAway start: scout'
add f1 'Fix Firstmate tool' ship firstmate $'Ready gate: passed\nAway start: firstmate-fork-pr'
add a1 'Fix the form' ship app $'Ready gate: passed\nAway start: app-pr'
add x1 'Change billing' ship app $'Ready gate: passed\nAway start: app-pr'
add x2 'Unreviewed issue' scout app 'Away start: scout'
add x3 'Migrate records' ship app $'Ready gate: passed\nAway start: app-pr'
add x4 'Fix app' ship app $'Ready gate: passed\nAway start: app-pr'
add x5 'Fix deployment script typo' ship app $'Ready gate: passed\nAway start: app-pr'
tasks-axi block x4 --by x2 --file "$HOME_DIR/data/backlog.md" >/dev/null

out=$(check 87000)
[ -z "$out" ] || fail 'nudge fired before 24 hours'
out=$(check 90000)
assert_contains "$out" 's1: Inspect the form' 'scout listed'
if FM_HOME="$HOME_DIR" "$NUDGE" guard-start s1 >/dev/null 2>&1; then
  fail 'pending suggestion allowed a start before reply'
fi
assert_contains "$out" 'f1: Fix Firstmate tool' 'fork fix listed'
assert_contains "$out" 'a1: Fix the form' 'app fix listed'
for id in x1 x2 x3 x4 x5; do
  case "$out" in *"$id:"*) fail "unsafe item $id listed" ;; esac
done

FM_HOME="$HOME_DIR" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" mark-sent
[ -z "$(check 90000)" ] || fail 'same set nudged twice'
if FM_HOME="$HOME_DIR" "$NUDGE" guard-start s1 >/dev/null 2>&1; then
  fail 'sent suggestion allowed a start before reply'
fi
[ "$(reply yes)" = $'s1\nf1\na1' ] || fail 'yes did not authorize the listed set'
[ "$(reply '2, 3')" = $'f1\na1' ] || fail 'numbers did not select exact items'
[ -z "$(reply 'yes, and merge them')" ] || fail 'ordinary chat parsed as go'
[ -z "$(reply 9)" ] || fail 'out of range number parsed as go'

COMMAND_HOME="$HOME_DIR/command"
mkdir -p "$COMMAND_HOME/data" "$COMMAND_HOME/state" "$COMMAND_HOME/config"
cp "$HOME_DIR/data/backlog.md" "$COMMAND_HOME/data/backlog.md"
printf 'entered_epoch: 1000\n' > "$COMMAND_HOME/state/.afk-contract"
# shellcheck disable=SC2016 # $1 expands in the command channel's child shell, not here
printf 'command: printf "%%s" "$1" > "%s"\n' "$COMMAND_HOME/delivered" > "$COMMAND_HOME/config/wedge-alarm"
FM_HOME="$COMMAND_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" check --command >/dev/null
[ -s "$COMMAND_HOME/delivered" ] || fail 'command channel did not receive nudge'
[ -z "$(FM_HOME="$COMMAND_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" check)" ] || fail 'command channel nudge repeated'

MISMATCH_HOME="$HOME_DIR/mismatch"
mkdir -p "$MISMATCH_HOME/data" "$MISMATCH_HOME/state" "$MISMATCH_HOME/config"
cp "$HOME_DIR/data/backlog.md" "$MISMATCH_HOME/data/backlog.md"
# shellcheck disable=SC2016 # $1 expands in the command channel's child shell, not here
printf 'command:\ncommand: printf "%%s" "$1" > "%s"\n' "$MISMATCH_HOME/delivered" > "$MISMATCH_HOME/config/wedge-alarm"
out=$(FM_HOME="$MISMATCH_HOME" FM_TEST_HARNESS=codex bash "$ROOT/bin/fm-afk-contract.sh" enter 2>&1)
assert_contains "$out" 'No phone channel is configured' 'an empty command: line before a real one is not announced as reachable'
entered=$(FM_HOME="$MISMATCH_HOME" bash "$ROOT/bin/fm-afk-contract.sh" field entered_epoch)
FM_HOME="$MISMATCH_HOME" FM_AWAY_NUDGE_NOW_EPOCH=$((entered + 90000)) "$NUDGE" check --command >/dev/null 2>&1 || true
[ ! -s "$MISMATCH_HOME/delivered" ] || fail 'an empty command: line before a real one must not deliver, matching the announcement'

QUOTE_HOME="$HOME_DIR/quote"
mkdir -p "$QUOTE_HOME/data" "$QUOTE_HOME/state"
printf 'entered_epoch: 1000\n' > "$QUOTE_HOME/state/.afk-contract"
tasks-axi add q1 'Fix: colon title bug' --kind ship --repo app --body $'Ready gate: passed\nAway start: app-pr' --file "$QUOTE_HOME/data/backlog.md" >/dev/null
out=$(FM_HOME="$QUOTE_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" check)
assert_contains "$out" 'q1: Fix: colon title bug' 'a title tasks-axi JSON-quotes renders plain, not escaped'
case "$out" in *'"Fix: colon title bug"'*) fail 'a quoted title leaked its JSON escaping into the nudge message' ;; esac

PENDING_HOME="$HOME_DIR/pending"
mkdir -p "$PENDING_HOME/data" "$PENDING_HOME/state"
printf 'entered_epoch: 1000\n' > "$PENDING_HOME/state/.afk-contract"
tasks-axi add p1 'Fix the widget' --kind ship --repo app --body $'Ready gate: passed\nAway start: app-pr' --file "$PENDING_HOME/data/backlog.md" >/dev/null
tasks-axi add p2 'Fix the gadget' --kind ship --repo app --body $'Ready gate: passed\nAway start: app-pr' --file "$PENDING_HOME/data/backlog.md" >/dev/null
FM_HOME="$PENDING_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" check >/dev/null
[ "$(FM_HOME="$PENDING_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" reply yes)" = $'p1\np2' ] \
  || fail 'a reply arriving before mark-sent did not resolve against the still-pending, unacked nudge'
[ "$(FM_HOME="$PENDING_HOME" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" reply '2')" = p2 ] \
  || fail 'a numbered reply arriving before mark-sent did not resolve against the still-pending, unacked nudge'

add s2 'Inspect the list' scout app $'Ready gate: passed\nAway start: scout'
out=$(check 90000)
assert_contains "$out" 's2: Inspect the list' 'changed set can be nudged'
FM_HOME="$HOME_DIR" FM_AWAY_NUDGE_NOW_EPOCH=90000 "$NUDGE" mark-sent
tasks-axi 'done' s2 --file "$HOME_DIR/data/backlog.md" >/dev/null
[ -z "$(check 90000)" ] || fail 'returning to an already nudged set fired again'

pass 'away nudge filters ready tickets, parses explicit replies, and deduplicates item sets'
