#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-lavish.sh's cmd_read result-shape
# validation.
#
# publish_result (bin/fm-procevent.sh) tells the agent to read a terminal or
# non-terminal result with `fm-procevent-lavish.sh read`, for every classify()
# lifecycle, not only the newer `prompts[N]:`/`feedback[N]:` content shape.
# cmd_read's fail-closed validation must keep recognizing the pre-existing
# "missing" (no active session) and "unknown" (unrecognized session status)
# lifecycles it already had to handle, while still refusing to present a
# genuinely unrecognized content shape as an empty board.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-lavish-read.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# A classify()=missing result: the documented "no active Lavish Editor
# session" error response. This must present as an empty, zero-item board
# rather than crash, or a captain's queued feedback that only hours later
# turns out to have arrived through this shape gets silently dropped.
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' \
  > "$LAB/missing.txt"
out=$("$BIN/fm-procevent-lavish.sh" read "$LAB/missing.txt" 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || fail "missing-session result was refused instead of presented: $out"
printf '%s\n' "$out" | grep -qx 'declared_items: 0' \
  || fail "missing-session result did not present as zero declared items: $out"
printf '%s\n' "$out" | grep -qx 'lifecycle: missing' \
  || fail "missing-session result did not carry the missing lifecycle: $out"
ok "missing-session error shape presents as an empty board"

# A classify()=unknown result: a session block whose status cmd_classify does
# not recognize. This is not one of the lifecycles cmd_read already had to
# support, and must stay refused so unrecognized captain feedback can never be
# silently certified as zero items.
printf 'session:\n  file: /a.html\n  status: closed\n' > "$LAB/unknown.txt"
out=$("$BIN/fm-procevent-lavish.sh" read "$LAB/unknown.txt" 2>&1)
rc=$?
[ "$rc" -ne 0 ] \
  || fail "unknown-lifecycle result was presented instead of refused: $out"
printf '%s\n' "$out" | grep -Fq 'unrecognized Lavish result lifecycle' \
  || fail "unknown-lifecycle result failed for the wrong reason: $out"
ok "unknown-lifecycle result stays refused"

# A genuinely unrecognized top-level content line must also stay refused, even
# for an otherwise-recognized lifecycle, so a future unknown Lavish shape can
# never be presented as an empty board either.
printf 'session:\n  file: /a.html\n  status: feedback\ngarbage top level line\n' \
  > "$LAB/garbage.txt"
out=$("$BIN/fm-procevent-lavish.sh" read "$LAB/garbage.txt" 2>&1)
rc=$?
[ "$rc" -ne 0 ] \
  || fail "unrecognized content shape was presented instead of refused: $out"
printf '%s\n' "$out" | grep -Fq 'unrecognized Lavish result shape' \
  || fail "unrecognized content shape failed for the wrong reason: $out"
ok "genuinely unrecognized content shape stays refused"

# The newer prompts[N]{...} shape with a full house of annotations and a
# freeform message must still report every queued item, not zero - this is
# the original defect: a 5-item board reporting declared_items 0.
cp "$FM_ROOT/tests/captures/lavish-prompts-five.txt" "$LAB/five.txt"
out=$("$BIN/fm-procevent-lavish.sh" read "$LAB/five.txt" 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || fail "five-item prompts board was refused: $out"
printf '%s\n' "$out" | grep -qx 'declared_items: 5' \
  || fail "five-item prompts board did not report its declared items: $out"
printf '%s\n' "$out" | grep -qx 'annotation_count: 4' \
  || fail "five-item prompts board dropped its annotations: $out"
ok "a full prompts board reports all queued items, not zero"

printf '# all fm-procevent-lavish read tests passed\n'
