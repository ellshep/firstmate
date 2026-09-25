#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It fails naming the harness and version rather than degrading
# quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
# It also guards the daemon's Claude detailed-transcript recovery against the
# real harness: a hidden composer reads unknown, and revealing a draft stays
# pending rather than licensing an injection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

# The away daemon shares this adapter. A Claude prompt suggestion under
# NO_COLOR has no ghost styling in Herdr's ANSI read, so it cannot be
# distinguished from a draft containing the same words. Keep that verdict
# unsafe; color or disabling suggestions must restore a proven empty read.
probe_suggestion() {  # <no-color|color> <wanted-verdict>
  local mode=$1 want=$2 ws pane target command status capture verdict i esc
  ws=$(lab workspace create --cwd "$ROOT" --label "fm-suggestion-$mode" --no-focus) \
    || fail "could not create the $mode suggestion probe workspace"
  pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') \
    || fail "$mode suggestion probe did not return a pane id"
  target="$SESSION:$pane"
  case "$mode" in
    no-color) command='env -u CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION NO_COLOR=1 claude --dangerously-skip-permissions' ;;
    color) command='env -u CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION -u NO_COLOR claude --dangerously-skip-permissions' ;;
  esac
  lab pane run "$pane" "$command" >/dev/null \
    || fail "could not launch Claude Code ($VERSION) $mode suggestion probe"
  i=0
  while [ "$i" -lt 45 ]; do
    status=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    capture=$(fm_backend_herdr_capture_ansi "$target" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null || true)
    if [ "$status" = idle ] && printf '%s' "$capture" | grep -F 'Try "' >/dev/null; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt 45 ] || fail "Claude Code ($VERSION) on $HERDR_VER did not render an idle $mode suggestion"
  esc=$(printf '\033')
  case "$mode" in
    no-color)
      case "$capture" in *"$esc"*) fail "$mode suggestion unexpectedly carried ANSI styling" ;; esac
      ;;
    color)
      case "$capture" in *"$esc"*) : ;; *) fail "$mode suggestion had no ANSI styling" ;; esac
      ;;
  esac
  verdict=$(fm_backend_herdr_composer_state "$target")
  [ "$verdict" = "$want" ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: idle $mode suggestion read '$verdict', expected '$want'"
  if [ "$mode" = color ]; then
    lab pane send-text "$pane" 'unsubmitted draft stays pending' >/dev/null \
      || fail "could not type the $mode safety draft"
    i=0
    while [ "$i" -lt 20 ]; do
      verdict=$(fm_backend_herdr_composer_state "$target")
      [ "$verdict" = pending ] && break
      i=$((i + 1))
      sleep 0.25
    done
    [ "$verdict" = pending ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: typed draft read '$verdict', expected pending"
  fi
}

probe_suggestion no-color pending
probe_suggestion color empty
pass "live Herdr Claude suggestion: no-color stays unsafe, styled idle is empty, typed draft is pending"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
FM_DAEMON_PRIMARY_HARNESS=claude
i=0
while [ "$i" -lt 45 ]; do
  identity=$(fm_backend_herdr_composer_identity "$TARGET" || true)
  [ "$identity" = $'claude\tidle' ] && break
  i=$((i + 1))
  sleep 1
done
[ "$identity" = $'claude\tidle' ] || fail "Claude Code ($VERSION) on $HERDR_VER did not become idle after replying"
lab pane send-keys "$PANE" ctrl+o >/dev/null || fail "could not open Claude's detailed transcript"
i=0
while [ "$i" -lt 20 ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$verdict" = unknown ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$verdict" = unknown ] || fail "Claude Code ($VERSION) on $HERDR_VER: detailed transcript read '$verdict', expected unknown"
if ! reveal_herdr_claude_composer "$TARGET"; then
  agent_state=$(fm_backend_agent_state herdr "$TARGET")
  identity=$(fm_backend_herdr_composer_identity "$TARGET" || true)
  footer=$(fm_backend_visible_capture herdr "$TARGET" | tail -n 1)
  fail "daemon could not reveal Claude Code ($VERSION) on $HERDR_VER: agent=$agent_state identity=$identity footer=$footer"
fi
i=0
while [ "$i" -lt 20 ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$verdict" = empty ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$verdict" = empty ] || fail "Claude Code ($VERSION) on $HERDR_VER: revealed composer read '$verdict', expected empty"

lab pane send-text "$PANE" 'unsubmitted draft must survive transcript toggle' >/dev/null || fail "could not type a safety draft"
i=0
while [ "$i" -lt 20 ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$verdict" = pending ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$verdict" = pending ] || fail "Claude Code ($VERSION) on $HERDR_VER: draft read '$verdict', expected pending"
lab pane send-keys "$PANE" ctrl+o >/dev/null || fail "could not reopen Claude's detailed transcript"
i=0
while [ "$i" -lt 20 ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$verdict" = unknown ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$verdict" = unknown ] || fail "Claude Code ($VERSION) on $HERDR_VER: draft-hidden transcript read '$verdict', expected unknown"
reveal_herdr_claude_composer "$TARGET" || fail "daemon could not reveal the Claude draft"
i=0
while [ "$i" -lt 20 ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$verdict" = pending ] && break
  i=$((i + 1))
  sleep 0.25
done
[ "$verdict" = pending ] || fail "Claude Code ($VERSION) on $HERDR_VER: restored draft read '$verdict', expected pending"
pass "live Herdr Claude transcript: unknown toggles to empty; a hidden draft toggles back to pending"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
