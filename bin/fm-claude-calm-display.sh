#!/usr/bin/env bash
# fm-claude-calm-display.sh - Claude Code Calm narration presentation hook.
#
# Registered in tracked .claude/settings.json as a MessageDisplay command hook.
# Claude Code fires it for every flush of displayed assistant text and, when the
# hook prints a MessageDisplay result, renders that result instead of the flush.
#
# Calm on Claude is INVERTED relative to Pi: nothing is hidden unless Firstmate
# explicitly marks it. AGENTS.md section 9 owns when Firstmate marks a line;
# docs/calm.md owns the captain-facing contract. This script owns the marker
# bytes and the filter.
#
#   Marker: U+2062 INVISIBLE TIMES at the START of a narration line.
#           Distinct from the U+2063 operational-input mark owned by
#           bin/fm-operational-input.sh, invisible on screen and in a commit,
#           and absent from ordinary prose, code, and command output.
#
# Contract:
#   - A flush whose lines are ALL marked renders as displayContent "" and the
#     row disappears.
#   - A flush with a mix keeps the unmarked lines exactly, in order, with the
#     trailing-newline shape of the original flush.
#   - A flush with NO marked line prints nothing and exits 0, so Claude renders
#     its own original bytes rather than a re-encoded copy.
#   - Claude Code flushes displayed text on line boundaries, so a marked line
#     arrives whole. That is an observed, undocumented property, so the filter
#     never depends on it: an unmarked fragment is always SHOWN. A missed marker
#     therefore degrades to a stray narration line, never to a swallowed
#     captain-facing answer.
#
# Every failure path - Calm off, absent or unreadable preference, missing jq,
# absent or altered MessageDisplay seam, malformed hook input, absent delta -
# prints nothing and exits 0, which shows the original text. The hook never
# reads or writes session data, so the stored transcript, the model's context,
# /export, and message ordering are unchanged.
#
# The MessageDisplay displayContent capability is undocumented (the published
# hook reference states the opposite), so treat it as an unstable seam: this
# hook probes nothing and asserts nothing about the harness, it simply prints a
# result Claude Code is free to ignore.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# U+2062 INVISIBLE TIMES.
FM_CALM_NARRATION_MARK=$'\xE2\x81\xA2'

case "$(head -n 1 "$CONFIG/calm" 2>/dev/null | tr -d '[:space:]')" in
  on|max) ;;
  *) exit 0 ;;
esac

# One jq program owns the split, filter, and re-encode so the kept text keeps
# its exact bytes and no shell word splitting or trailing-newline stripping can
# touch it. `empty` means "no marked line", which is the byte-identical path.
result=$(jq -c --arg mark "$FM_CALM_NARRATION_MARK" '
  if (.delta | type) != "string" then empty
  else
    (.delta | split("\n")) as $lines
    | [$lines[] | select(startswith($mark) | not)] as $kept
    | if ($kept | length) == ($lines | length) then empty
      else {
        hookSpecificOutput: {
          hookEventName: "MessageDisplay",
          displayContent: ($kept | join("\n"))
        }
      }
      end
  end
' 2>/dev/null) || exit 0

[ -n "$result" ] && printf '%s\n' "$result"
exit 0
