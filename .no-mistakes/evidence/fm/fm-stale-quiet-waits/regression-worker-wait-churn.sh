#!/usr/bin/env bash
# Regression: base fm-watch re-queues stale on pane hash churn; fixed watch absorbs.
set -eu
ROOT="/Users/ellingtonshephard/.no-mistakes/worktrees/9fde14bc0ad4/01M65KSG3V3KBQM3PARE4TN1TZ"
cd "$ROOT"
# shellcheck source=tests/watch-triage-helpers.sh
. "$ROOT/tests/watch-triage-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-regression-worker-wait)
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN
OLD_WATCH="$ROOT/bin/fm-watch-regression-old.sh"
[ -x "$OLD_WATCH" ] || { echo "missing $OLD_WATCH"; exit 1; }

run_churn_round() { # <watch-bin> <label>
  local watch_bin=$1 label=$2
  local dir state fakebin out capture statusf window key sig wakes
  dir=$(make_case "reg-$label"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"; statusf="$state/parked.status"
  window="test:fm-worker-wait"; key=$(printf '%s' "$window" | tr ':/.' '___')
  mkdir -p "$dir/config"
  : > "$dir/config/wedge-defer-worker-wait"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
  printf 'needs-decision [key=review]: awaiting firstmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-parked_status"
  printf 'idle prompt, quota footer 1' > "$capture"
  printf '%s' "$(hash_text "$(cat "$capture")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$watch_bin" >> "$out" &
  local pid=$!; wait_for_exit "$pid" 100 || { reap "$pid"; echo "$label: first sight failed"; return 1; }
  ack_stopped_cycle "$state" || { echo "$label: ack failed"; return 1; }
  printf 'idle prompt, quota footer 2' > "$capture"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_CONFIG_OVERRIDE="$dir/config" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$watch_bin" >> "$out" &
  pid=$!
  if [ "$label" = fixed ]; then
    local cycles=0
    while [ "$cycles" -lt 4 ]; do
      wait_poll_cycle "$state" "$pid" 300 || { reap "$pid"; echo "$label: second round died (absorb)" >&2; return 1; }
      cycles=$((cycles + 1))
    done
    reap "$pid"
  else
    wait_for_exit "$pid" 100 || { reap "$pid"; echo "$label: second round did not exit (re-alarm path)" >&2; return 1; }
  fi
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || echo 0)
  echo "$label second-round stale wakes=$wakes triage=$(grep -E 'absorbed stale|stale:' "$out" | tail -1 || true)" >&2
  printf '%s' "$wakes"
}

echo "=== regression worker-wait pane churn ==="
old_wakes=$(run_churn_round "$OLD_WATCH" "base")
new_wakes=$(run_churn_round "$WATCH" "fixed")
echo "base second-round wakes=$old_wakes fixed second-round wakes=$new_wakes"
if [ "${old_wakes:-0}" -gt 0 ] && [ "${new_wakes:-0}" -eq 0 ]; then
  echo "REGRESSION_OK: base re-alarmed ($old_wakes), fixed quiet ($new_wakes)"
  exit 0
fi
echo "REGRESSION_UNEXPECTED: base=$old_wakes fixed=$new_wakes"
exit 1
