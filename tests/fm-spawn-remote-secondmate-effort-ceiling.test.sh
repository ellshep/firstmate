#!/usr/bin/env bash
# tests/fm-spawn-remote-secondmate-effort-ceiling.test.sh - the captain's
# config/worker-effort-ceiling must gate spawn_remote_secondmate() in
# bin/fm-spawn.sh, the route a registered remote secondmate (remote=1 in
# data/secondmates.md) always launches and relaunches through - including the
# liveness/recovery sweep's bare `fm-spawn.sh <id> --secondmate` call with no
# --model/--effort, which inherits config/secondmate-harness exactly like the
# local path the generic effort fallback can push above policy.
#
# This is the gap review round 1 named: fm_worker_effort_check is wired into
# spawn_remote_secondmate, but no suite drove a registered remote=1 secondmate
# through it. These assertions drive the real chain end to end - parent
# fm-spawn -> fm-on -> the real remote entrypoint -> fm-remote-secondmate
# control -> a fake Herdr CLI - so a refusal is proven to happen before the
# remote host is ever contacted, and an allowed launch is proven to actually
# reach it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-spawn-remote-ceiling)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '\xe2\x9d\xaf\n'; exit 0 ;;
  send-keys) exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# Register the remote route from the captain-facing primary. No launch yet:
# this only writes the data/secondmates.md remote=1 entry fm-spawn.sh's
# spawn_remote_secondmate() reads.
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the registered route"

# --- a bare secondmate launch above the captain's ceiling is refused, and the
#     remote host is never contacted -----------------------------------------
# config/secondmate-harness carries the model/effort a bare `--secondmate` call
# (no --model/--effort) inherits, exactly like the liveness/recovery sweep's
# `fm-spawn.sh <id> --secondmate` call (bin/fm-secondmate-liveness-lib.sh).
printf 'claude sonnet xhigh\n' > "$PARENT/config/secondmate-harness"
printf 'high\n' > "$PARENT/config/worker-effort-ceiling"
: > "$HERDR_LOG"
OUT=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "a bare remote secondmate launch above the ceiling must be refused"
assert_contains "$OUT" "exceeds config/worker-effort-ceiling 'high'" \
  "the refusal should name the ceiling"
[ ! -s "$HERDR_LOG" ] \
  || fail "a ceiling refusal must happen before the remote Herdr host is ever contacted"
assert_absent "$PARENT/state/ios.meta" \
  "a ceiling refusal on first launch must not publish task metadata"
pass "fm-spawn: a bare remote secondmate launch above the captain's ceiling is refused before the remote host is contacted"

# --- at the ceiling, the launch proceeds and actually reaches the remote host
printf 'claude sonnet high\n' > "$PARENT/config/secondmate-harness"
: > "$HERDR_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
  || fail "a bare remote secondmate launch at the ceiling should succeed"
assert_present "$PARENT/state/ios.meta" \
  "a launch at the ceiling did not publish parent task metadata"
[ "$(fm_meta_get "$PARENT/state/ios.meta" remote_host 2>/dev/null || sed -n 's/^remote_host=//p' "$PARENT/state/ios.meta")" = remote-mac ] \
  || fail "the launch at the ceiling did not record the remote route"
grep -q 'workspace create' "$HERDR_LOG" \
  || fail "a launch at the ceiling should actually reach the remote Herdr host (got: $(cat "$HERDR_LOG")) "
pass "fm-spawn: a bare remote secondmate launch at the captain's ceiling reaches the remote Herdr host"

# --- the recovery/relaunch route is gated the same way, after the task
#     metadata already exists (the liveness sweep's exact call shape) --------
printf 'claude sonnet xhigh\n' > "$PARENT/config/secondmate-harness"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/ios-before-ceiling.meta"
: > "$HERDR_LOG"
OUT=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "a recovery relaunch above the ceiling must be refused"
assert_contains "$OUT" "exceeds config/worker-effort-ceiling 'high'" \
  "the recovery refusal should name the ceiling"
[ ! -s "$HERDR_LOG" ] \
  || fail "a recovery-relaunch ceiling refusal must happen before the remote host is contacted"
cmp -s "$TMP_ROOT/ios-before-ceiling.meta" "$PARENT/state/ios.meta" \
  || fail "a recovery-relaunch ceiling refusal must not touch the existing task record"
pass "fm-spawn: the recovery/relaunch route for an already-registered remote secondmate is refused the same way, before touching existing metadata"

echo "ALL TESTS PASSED"
