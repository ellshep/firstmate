#!/usr/bin/env bash
# Read a real Codex worker's visible pane without changing its lifecycle.
# Set FM_BUSY_CODEX_LIVE_TARGET=<backend target> and
# FM_BUSY_CODEX_LIVE_EXPECT=busy|idle for the state observed during this read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_BUSY_CODEX_LIVE codex

target=${FM_BUSY_CODEX_LIVE_TARGET:-}
backend=${FM_BUSY_CODEX_LIVE_BACKEND:-herdr}
expected=${FM_BUSY_CODEX_LIVE_EXPECT:-}
version=$(codex --version | head -1)
[ -n "$target" ] || fail "codex ($version): FM_BUSY_CODEX_LIVE_TARGET is required"
case "$expected" in busy|idle) : ;; *) fail "codex ($version): FM_BUSY_CODEX_LIVE_EXPECT must be busy or idle" ;; esac

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
viewport=$(fm_backend_visible_capture "$backend" "$target") \
  || fail "codex ($version): visible viewport unavailable on $backend"
verdict=$(printf '%s\n' "$viewport" | fm_busy_codex_viewport_state)
[ "$verdict" = "$expected" ] \
  || fail "codex ($version): expected $expected on $backend, got $verdict"
pass "codex ($version): live $backend viewport classified $verdict"
