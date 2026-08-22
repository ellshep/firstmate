#!/usr/bin/env bash
# Claude Code Calm narration presentation regression.
#
# Drives the REAL installed Claude Code binary against a deterministic local
# Anthropic Messages stand-in, so every screen assertion comes from Claude's own
# rendering rather than from a re-implementation of the hook contract. No
# credentials are used and no live fleet home, project, or session is touched.
#
# Covered: marked narration hidden, unmarked text byte-identical to a no-hook
# run, mixed flushes keeping exactly the unmarked lines, per-flush hiding in the
# real interactive TUI, the preference gate, the transcript/persistence boundary,
# an absent MessageDisplay seam, malformed hook input, and the fail-open paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-claude-calm-display.sh"
# U+2062 INVISIBLE TIMES, the narration marker owned by that script.
MARK=$(printf '\342\201\242')

SERVER_PID=

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  fm_test_cleanup
}
trap cleanup EXIT

# --- hook-level contract (no harness required) ------------------------------

test_hook_fail_open_matrix() {
  local tmp config out status
  tmp=$(fm_test_tmproot fm-calm-claude-hook) || fail "could not create temp root"
  config="$tmp/config"
  mkdir -p "$config"
  printf 'on\n' > "$config/calm"

  hook() {  # <stdin-payload> -> stdout, with Calm on unless FM_CONFIG_OVERRIDE is repointed
    printf '%s' "$1" | FM_CONFIG_OVERRIDE="${2:-$config}" "$OWNER"
  }

  # A marked-only flush hides the row.
  out=$(hook "{\"delta\":\"${MARK}narration\\n\"}")
  assert_contains "$out" '"displayContent":""' \
    "a fully marked flush did not resolve to an empty display row"

  # Anything unmarked prints nothing at all, so Claude renders its own bytes.
  for payload in \
    '{"delta":"a genuine answer"}' \
    '{"delta":""}' \
    '{"delta":"line one\nline two\n"}'; do
    out=$(hook "$payload")
    [ -z "$out" ] || fail "unmarked flush was rewritten instead of passed through: $payload -> $out"
  done

  # Every malformed, absent, or wrongly typed input shows the original text.
  for payload in \
    'not json at all' \
    '' \
    '{' \
    '{"delta":null}' \
    '{"delta":123}' \
    '{"delta":["array"]}' \
    '{"hook_event_name":"MessageDisplay"}' \
    "[{\"delta\":\"${MARK}x\"}]"; do
    out=$(hook "$payload")
    status=$?
    expect_code 0 "$status" "malformed hook input did not exit 0: $payload"
    [ -z "$out" ] || fail "malformed hook input produced display output: $payload -> $out"
  done

  # The preference gate: only on/max hide, and an absent or unreadable
  # preference leaves the text alone.
  local value
  for value in off '' garbage; do
    printf '%s\n' "$value" > "$config/calm"
    out=$(hook "{\"delta\":\"${MARK}narration\\n\"}")
    [ -z "$out" ] || fail "Calm preference '$value' hid text: $out"
  done
  rm -f "$config/calm"
  out=$(hook "{\"delta\":\"${MARK}narration\\n\"}")
  [ -z "$out" ] || fail "an absent Calm preference hid text: $out"
  out=$(hook "{\"delta\":\"${MARK}narration\\n\"}" "$tmp/no-such-config-dir")
  [ -z "$out" ] || fail "an unreadable Calm config dir hid text: $out"
  printf 'max\n' > "$config/calm"
  out=$(hook "{\"delta\":\"${MARK}narration\\n\"}")
  assert_contains "$out" '"displayContent":""' \
    "the legacy 'max' preference did not resolve to ordinary Calm on"

  # A missing jq is a fail-open path, not a hidden row.
  printf 'on\n' > "$config/calm"
  local fakebin
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
echo "jq exploded" >&2
exit 127
SH
  chmod +x "$fakebin/jq"
  out=$(printf '%s' "{\"delta\":\"${MARK}narration\\n\"}" \
    | PATH="$fakebin:$PATH" FM_CONFIG_OVERRIDE="$config" "$OWNER" 2>/dev/null)
  status=$?
  expect_code 0 "$status" "a broken jq did not exit 0"
  [ -z "$out" ] || fail "a broken jq still hid text: $out"

  pass "Calm's Claude display hook hides only marked lines and shows the original text on every malformed, ungated, and degraded path"
}

test_hook_keeps_unmarked_lines_exactly() {
  local tmp config out kept
  tmp=$(fm_test_tmproot fm-calm-claude-mixed) || fail "could not create temp root"
  config="$tmp/config"
  mkdir -p "$config"
  printf 'on\n' > "$config/calm"

  # A mixed flush keeps the unmarked lines in order, with the original
  # trailing-newline shape.
  out=$(printf '%s' "{\"delta\":\"${MARK}note one\\nANSWER A\\n${MARK}note two\\nANSWER B\\n\"}" \
    | FM_CONFIG_OVERRIDE="$config" "$OWNER")
  kept=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent')
  [ "$kept" = "$(printf 'ANSWER A\nANSWER B\n')" ] \
    || fail "a mixed flush did not keep exactly the unmarked lines: $(printf '%s' "$kept" | od -c | head -4)"

  # A marker anywhere but the start of a line is ordinary text and prints.
  out=$(printf '%s' "{\"delta\":\"answer with ${MARK} inside\\n\"}" \
    | FM_CONFIG_OVERRIDE="$config" "$OWNER")
  [ -z "$out" ] || fail "a mid-line marker hid a captain-facing line: $out"

  # A fragment of a marked line - the shape a mid-line flush split would
  # produce - is unmarked, so it is SHOWN rather than swallowed.
  out=$(printf '%s' '{"delta":"rration continues\n"}' \
    | FM_CONFIG_OVERRIDE="$config" "$OWNER")
  [ -z "$out" ] || fail "an unmarked continuation fragment was hidden: $out"

  pass "Calm's Claude display hook keeps every unmarked line, marker position and flush split included"
}

# --- real Claude Code process against a deterministic provider ---------------

LAB=
PORT=

lab_require() {
  local tool
  for tool in claude node jq python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "skip: $tool not found for the real Claude Code Calm presentation regression"
      return 1
    fi
  done
  return 0
}

lab_start() {
  LAB=$(fm_test_tmproot fm-calm-claude-lab) || fail "could not create lab root"
  mkdir -p "$LAB/home" "$LAB/fmhome/config" "$LAB/proj/bin" "$LAB/proj/.claude"
  cp "$OWNER" "$LAB/proj/bin/"

  cat > "$LAB/server.js" <<'JS'
// Deterministic Anthropic Messages stand-in: streams the text chunks named by
// CHUNKS_FILE as one assistant message, so Claude Code's own renderer and hook
// dispatch run unchanged with no credentials and no network.
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', async () => {
    if (!req.url.startsWith('/v1/messages')) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end('{}');
      return;
    }
    const chunks = JSON.parse(fs.readFileSync(process.env.CHUNKS_FILE, 'utf8'));
    const send = (ev, d) => res.write(`event: ${ev}\ndata: ${JSON.stringify(d)}\n\n`);
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
    send('message_start', { type: 'message_start', message: { id: 'msg_fm_calm', type: 'message', role: 'assistant', model: 'deterministic', content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } });
    send('content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
    for (const c of chunks) {
      send('content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: c } });
      await new Promise((r) => setTimeout(r, 350));
    }
    send('content_block_stop', { type: 'content_block_stop', index: 0 });
    send('message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 5 } });
    send('message_stop', { type: 'message_stop' });
    res.end();
  });
});
server.listen(0, '127.0.0.1', () => console.log(`PORT ${server.address().port}`));
JS

  CHUNKS_FILE="$LAB/chunks.json" node "$LAB/server.js" > "$LAB/server.out" 2>&1 &
  SERVER_PID=$!
  local waited=0
  while [ "$waited" -lt 100 ]; do
    PORT=$(sed -n 's/^PORT //p' "$LAB/server.out" 2>/dev/null | head -n 1)
    [ -n "$PORT" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -n "$PORT" ] || fail "deterministic provider never reported a port: $(cat "$LAB/server.out" 2>/dev/null)"
}

lab_set_chunks() {
  jq -n --args '$ARGS.positional' "$@" > "$LAB/chunks.json"
}

lab_register_hook() {  # on|off
  if [ "$1" = on ]; then
    cat > "$LAB/proj/.claude/settings.json" <<'JSON'
{"hooks":{"MessageDisplay":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/bin/fm-claude-calm-display.sh"}]}]}}
JSON
  else
    printf '%s\n' '{"hooks":{}}' > "$LAB/proj/.claude/settings.json"
  fi
}

lab_print() {  # -> Claude's own rendered stdout for one print-mode turn
  (
    cd "$LAB/proj" || exit 1
    env -i \
      PATH="$PATH" \
      HOME="$LAB/home" \
      TMPDIR="${TMPDIR:-/tmp}" \
      FM_HOME="$LAB/fmhome" \
      ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
      ANTHROPIC_API_KEY=fm-calm-deterministic \
      ANTHROPIC_MODEL=claude-haiku-4-5-20251001 \
      claude -p 'render the fixture' < /dev/null 2>/dev/null
  )
}

test_real_claude_presentation() {
  lab_require || return 0
  lab_start

  local calm_on calm_off no_hook marked_line answer_line
  marked_line="${MARK}scanning the local copy"
  answer_line='CAPTAIN FACING ANSWER'

  lab_register_hook on
  lab_set_chunks "$marked_line"$'\n' "${MARK}still working"$'\n' "$answer_line"$'\n' 'SECOND ANSWER LINE'

  printf 'on\n' > "$LAB/fmhome/config/calm"
  calm_on=$(lab_print)
  [ -n "$calm_on" ] || fail "the deterministic provider produced no rendered turn at all"
  assert_contains "$calm_on" "$answer_line" \
    "Calm hid a captain-facing answer line"
  assert_contains "$calm_on" 'SECOND ANSWER LINE' \
    "Calm hid the final unterminated answer line"
  assert_not_contains "$calm_on" 'scanning the local copy' \
    "Calm left marked narration on screen"
  assert_not_contains "$calm_on" 'still working' \
    "Calm left a second marked narration line on screen"

  printf 'off\n' > "$LAB/fmhome/config/calm"
  calm_off=$(lab_print)
  assert_contains "$calm_off" 'scanning the local copy' \
    "Calm off still hid marked narration"

  # An absent MessageDisplay seam must show the original text, never swallow it.
  lab_register_hook off
  no_hook=$(lab_print)
  assert_contains "$no_hook" 'scanning the local copy' \
    "an unregistered display hook lost the narration text"
  [ "$calm_off" = "$no_hook" ] \
    || fail "Calm off did not render byte-identically to an unregistered display hook"

  # Unmarked text is byte-identical whether or not the hook is armed.
  lab_set_chunks 'plain line one'$'\n' 'plain line two'
  lab_register_hook off
  no_hook=$(lab_print)
  lab_register_hook on
  printf 'on\n' > "$LAB/fmhome/config/calm"
  calm_on=$(lab_print)
  [ "$calm_on" = "$no_hook" ] \
    || fail "an unmarked turn was not byte-identical with Calm armed"$'\n'"--- armed ---"$'\n'"$calm_on"$'\n'"--- bare ---"$'\n'"$no_hook"

  # A wholly marked message leaves no row at all.
  lab_set_chunks "${MARK}narration only"$'\n' "${MARK}nothing else"
  calm_on=$(lab_print)
  [ -z "$(printf '%s' "$calm_on" | tr -d '[:space:]')" ] \
    || fail "a wholly marked message still rendered a row: $(printf '%s' "$calm_on" | od -c | head -4)"

  # Presentation only: the hidden text is still in the stored transcript.
  local transcripts
  transcripts=$(find "$LAB/home/.claude/projects" -name '*.jsonl' -type f 2>/dev/null)
  [ -n "$transcripts" ] || fail "the lab session wrote no transcript to inspect"
  printf '%s\n' "$transcripts" | tr '\n' '\0' | xargs -0 grep -F -l 'narration only' >/dev/null \
    || fail "hidden narration was missing from every stored transcript, so Calm changed persisted data"

  pass "the real Claude Code renderer hides only marked narration, stays byte-identical everywhere else, and leaves the stored transcript intact"
}

test_real_claude_interactive_flushes() {
  lab_require || return 0
  [ -n "$LAB" ] || lab_start

  # The interactive TUI flushes one message across several MessageDisplay
  # calls, so this proves the per-line filter on the surface the captain
  # actually watches rather than on print mode's single buffered flush.
  cat > "$LAB/tui.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct

env = dict(
    PATH=os.environ["PATH"], HOME=os.environ["LAB_HOME"], TMPDIR=os.environ.get("TMPDIR", "/tmp"),
    FM_HOME=os.environ["LAB_FM_HOME"], TERM="xterm-256color", COLUMNS="120", LINES="40",
    ANTHROPIC_BASE_URL=os.environ["LAB_BASE_URL"], ANTHROPIC_API_KEY="fm-calm-deterministic",
    ANTHROPIC_MODEL="claude-haiku-4-5-20251001",
)
pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.environ["LAB_PROJ"])
    os.execvpe("claude", ["claude"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
buf = b""

def pump(seconds):
    global buf
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk

pump(8)
os.write(fd, b"render the fixture\r")
pump(20)
os.write(fd, b"\x03\x03")
sys.stdout.buffer.write(buf)
PY

  cat > "$LAB/screen.py" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read().decode("utf8", "replace")
# Claude Code separates words with absolute column moves rather than literal
# spaces, so those become one space before the remaining escapes are dropped.
txt = re.sub(r"\x1b\[[0-9;]*G", " ", raw)
txt = re.sub(r"\x1b\][^\x07]*\x07", "", re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", txt))
sys.stdout.write(txt.replace("\r", "\n"))
PY

  # One warm print-mode turn creates the harness config this home needs, then
  # the interactive onboarding, trust, and API-key prompts are answered in it so
  # the TUI reaches a prompt instead of a dialog.
  lab_register_hook on
  printf 'on\n' > "$LAB/fmhome/config/calm"
  lab_set_chunks 'warmup'
  lab_print > /dev/null
  local proj_real
  proj_real=$(cd "$LAB/proj" && pwd -P)
  python3 - "$LAB/home/.claude.json" "$proj_real" <<'PY'
import json, sys
path, project = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    data = {}
data["hasCompletedOnboarding"] = True
data["theme"] = "dark"
# Claude Code identifies an approved key by its last 20 characters.
data["customApiKeyResponses"] = {"approved": ["fm-calm-deterministic"[-20:]], "rejected": []}
data.setdefault("projects", {})[project] = {
    "hasTrustDialogAccepted": True,
    "hasCompletedProjectOnboarding": True,
    "allowedTools": [],
    "history": [],
}
json.dump(data, open(path, "w"))
PY

  lab_set_chunks "${MARK}reading the local copy"$'\n' \
    "${MARK}checking the branch"$'\n' \
    'INTERACTIVE ANSWER LINE'$'\n' \
    "${MARK}tidying up"$'\n' \
    'INTERACTIVE FINAL LINE'

  LAB_HOME="$LAB/home" LAB_FM_HOME="$LAB/fmhome" LAB_PROJ="$proj_real" \
    LAB_BASE_URL="http://127.0.0.1:$PORT" \
    python3 "$LAB/tui.py" > "$LAB/tui.raw" 2>/dev/null
  local screen
  screen=$(python3 "$LAB/screen.py" "$LAB/tui.raw")

  assert_not_contains "$screen" 'Enter to confirm' \
    "the interactive TUI stalled on a harness dialog instead of rendering a turn"
  assert_contains "$screen" 'INTERACTIVE ANSWER LINE' \
    "the interactive TUI lost a captain-facing answer line"
  assert_contains "$screen" 'INTERACTIVE FINAL LINE' \
    "the interactive TUI lost the final answer line"
  assert_not_contains "$screen" 'reading the local copy' \
    "the interactive TUI showed marked narration from the first flush"
  assert_not_contains "$screen" 'checking the branch' \
    "the interactive TUI showed marked narration from a middle flush"
  assert_not_contains "$screen" 'tidying up' \
    "the interactive TUI showed marked narration from a late flush"

  pass "the real Claude Code TUI hides marked narration on every flush of one streamed message while keeping the answer lines"
}

test_hook_fail_open_matrix
test_hook_keeps_unmarked_lines_exactly
test_real_claude_presentation
test_real_claude_interactive_flushes
