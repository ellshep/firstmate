#!/usr/bin/env bash
# Claude prompt boundary hook: narrow captain classification and atomic storage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap fm_test_cleanup EXIT
TMP_ROOT=$(fm_test_tmproot captain-boundary)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state"
git init -q "$HOME_DIR"
printf '# Firstmate fixture\n' > "$HOME_DIR/AGENTS.md"
HOOK="$ROOT/bin/fm-claude-captain-boundary.sh"
RECORD="$HOME_DIR/state/.last-captain-message"
MARK=$(printf '\342\201\243')

submit() {
  local message=$1
  jq -n --arg prompt "$message" '{prompt:$prompt}' |
    FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" "$HOOK"
}

test_captain_includes_and_excludes() {
  local first second doorbell record="$HOME_DIR/state/sample.inbox/001.msg"
  submit 'First real message'
  first=$(sed -n '1p' "$RECORD")
  [ -n "$first" ] || fail "real captain prompt did not record a UTC time"
  [ "$(wc -l < "$RECORD" | tr -d ' ')" = 1 ] || fail "first prompt wrote extra lines"

  submit "${MARK}FIRSTMATE_OP: v1 watcher: wake"
  submit "${MARK}Supervisor escalate (1 event(s)): wake"
  submit 'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
  [ "$(cat "$RECORD")" = "$first" ] || fail "operational prompt moved the boundary"

  mkdir -p "${record%/*}"
  printf 'schema=fm-task-inbox.v1\n--\nsteer\n' > "$record"
  doorbell=$(bash -c '. "$1"; fm_task_inbox_doorbell_line "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$record") || fail "could not build doorbell fixture"
  submit "$doorbell"
  [ "$(cat "$RECORD")" = "$first" ] || fail "record-backed doorbell moved the boundary"
  mkdir -p "${record%/*}/handled"
  mv "$record" "${record%/*}/handled/001.msg"
  submit "$doorbell"
  [ "$(wc -l < "$RECORD" | tr -d ' ')" = 2 ] || fail "unbacked doorbell was not treated as captain text"
  [ "$(sed -n '2p' "$RECORD")" = "$first" ] || fail "previous timestamp was not retained"

  submit "Captain quote: ${MARK}FIRSTMATE_OP: v1 watcher: wake"
  second=$(sed -n '1p' "$RECORD")
  [ "$(sed -n '2p' "$RECORD")" = "$second" ] || fail "ordinary captain text did not shift the prior timestamp"
  submit 'FIRSTMATE_OP: v1 watcher: ordinary ASCII text'
  submit "${MARK}arbitrary captain text"
  submit 'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions. Please explain.'
  [ "$(wc -l < "$RECORD" | tr -d ' ')" = 2 ] || fail "captain prompts changed record shape"
  pass "captain boundary: operational messages are excluded and ordinary near misses are included"
}

test_atomic_failure_and_scope() {
  local before fake="$TMP_ROOT/fakebin"
  before=$(cat "$RECORD")
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake/mv"
  chmod +x "$fake/mv"
  jq -n --arg prompt 'Failed publish' '{prompt:$prompt}' |
    PATH="$fake:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" "$HOOK" \
    || fail "failed state write blocked the prompt"
  [ "$(cat "$RECORD")" = "$before" ] || fail "failed rename damaged the published boundary"
  [ -z "$(find "$HOME_DIR/state" -name '.last-captain-message.*' -print)" ] \
    || fail "failed rename left a staging file"

  local other="$TMP_ROOT/not-home"
  mkdir -p "$other/state" "$other/bin"
  jq -n '{prompt:"No home"}' |
    FM_ROOT_OVERRIDE="$other" FM_HOME="$other" "$HOOK" || fail "outside-home hook failed"
  [ ! -e "$other/state/.last-captain-message" ] || fail "hook wrote outside a firstmate home"
  pass "captain boundary: publication is atomic and non-home prompts are inert"
}

test_registered_hook() {
  local command
  command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command // empty' "$ROOT/.claude/settings.json")
  [ -n "$command" ] || fail "Claude UserPromptSubmit hook is not registered"
  printf '2020-01-01T00:00:00Z\n2019-01-01T00:00:00Z\n' > "$RECORD"
  jq -n '{prompt:"Via registered hook"}' |
    CLAUDE_PROJECT_DIR="$ROOT" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    bash -c "$command" || fail "registered Claude hook command failed"
  [ "$(wc -l < "$RECORD" | tr -d ' ')" = 2 ] \
    || fail "registered Claude hook did not publish a two-time boundary"
  [ "$(sed -n '2p' "$RECORD")" = '2020-01-01T00:00:00Z' ] \
    || fail "registered Claude hook did not shift the prior boundary"
  pass "captain boundary: Claude UserPromptSubmit is wired"
}

test_captain_includes_and_excludes
test_atomic_failure_and_scope
test_registered_hook
