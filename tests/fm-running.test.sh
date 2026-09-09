#!/usr/bin/env bash
# Orphan classifier and layout helpers for bin/fm-running.sh: synthetic
# ppid/cwd/elapsed rows, including the age-alone case that must not flag,
# and synthetic process rows for the column layout. Does not read the live
# process table.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-running.sh"

if locale -a 2>/dev/null | grep -qiE 'en_US\.utf-?8'; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
elif locale -a 2>/dev/null | grep -qiE 'C\.utf-?8'; then
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
fi

DAY=86400

reason_of() {  # <ppid> <cwd> <elapsed>
  fm_running_orphan_reason "$1" "$2" "$3"
}

# Exact string match. tests/lib.sh has contains/exit-code helpers, not equals.
assert_eq() {  # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3"$'\n'"expected: '$1'"$'\n'"actual: '$2'"
}

test_tmp_orphan_is_flagged() {
  local got rc
  got=$(reason_of 1 /private/tmp/claude-501/scratchpad/lab $((20 * DAY)))
  rc=$?
  expect_code 0 "$rc" "a 20-day init child in /private/tmp must flag"
  assert_eq "parent gone; cwd in /private/tmp; up 20d" "$got" \
    "a 20-day init child in /private/tmp must flag with an explained reason"
  pass "orphan classifier flags a long-lived init child whose cwd is under /private/tmp"
}

test_var_folders_orphan_is_flagged() {
  local got rc
  got=$(reason_of 1 /var/folders/yl/r0vn90j910bdmdqt36txn9sh0000gn/T/leftover $((2 * DAY)))
  rc=$?
  expect_code 0 "$rc" "a stale init child under /var/folders must flag"
  assert_eq "parent gone; cwd in /var/folders; up 2d" "$got" \
    "a stale init child under /var/folders must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is under /var/folders"
}

test_slash_tmp_orphan_is_flagged() {
  local got rc
  got=$(reason_of 1 /tmp/fake-server $((3 * DAY)))
  rc=$?
  expect_code 0 "$rc" "a stale init child under /tmp must flag"
  assert_eq "parent gone; cwd in /tmp; up 3d" "$got" \
    "a stale init child under /tmp must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is under /tmp"
}

test_unreadable_cwd_orphan_is_flagged() {
  local got rc
  got=$(reason_of 1 '' $((2 * DAY)))
  rc=$?
  expect_code 0 "$rc" "a stale init child with an unreadable cwd must flag"
  assert_eq "parent gone; cwd unreadable; up 2d" "$got" \
    "a stale init child with a missing cwd must flag"
  pass "orphan classifier flags a long-lived init child whose cwd is unreadable"
}

test_age_alone_does_not_flag() {
  local got rc
  got=$(reason_of 1 /Users/someone/code_projects/server $((32 * DAY)))
  rc=$?
  expect_code 1 "$rc" "age alone must not flag a legitimate long-lived server"
  assert_eq '' "$got" "age alone must print no reason"
  pass "orphan classifier does not flag on age alone when cwd is a real project path"
}

test_young_tmp_process_does_not_flag() {
  local got rc
  got=$(reason_of 1 /private/tmp/just-started $((DAY - 1)))
  rc=$?
  expect_code 1 "$rc" "elapsed at the stale threshold must not flag"
  assert_eq '' "$got" "a young temp-cwd process must print no reason"
  pass "orphan classifier does not flag a temp-cwd init child younger than the stale threshold"
}

test_live_parent_does_not_flag() {
  local got rc
  got=$(reason_of 42 /private/tmp/claude-501/scratchpad/lab $((20 * DAY)))
  rc=$?
  expect_code 1 "$rc" "ppid other than init must not flag even in a temp cwd"
  assert_eq '' "$got" "a process whose parent is still alive must print no reason"
  pass "orphan classifier does not flag a temp-cwd process whose parent is not init"
}

test_tmp_prefix_is_not_a_substring_match() {
  local got rc
  got=$(reason_of 1 /private/tmpdir/server $((20 * DAY)))
  rc=$?
  expect_code 1 "$rc" "a /private/tmpdir path must not inherit the /private/tmp rule"
  assert_eq '' "$got" "/private/tmpdir is not a temp root"
  pass "orphan classifier does not treat /private/tmpdir as a temp cwd"
}

test_fit_leaves_a_row_that_fits() {
  local got
  got=$(fm_running_fit 12 "node app.js")
  assert_eq "node app.js" "$got" "a command shorter than the column must print in full"
  case "$got" in
    *…*) fail "a fitting command must not grow an ellipsis" ;;
  esac
  pass "fm_running_fit keeps a value that already fits the column"
}

test_fit_truncates_to_column_width() {
  local got
  got=$(fm_running_fit 4 "hello")
  assert_eq 4 "${#got}" "truncated text must occupy exactly the requested column width"
  assert_eq "hel…" "$got" "a too-long value must end in a one-column ellipsis"
  pass "fm_running_fit truncates a too-long value to the column width"
}

test_process_row_that_fits_keeps_the_command() {
  local row
  row=$(FM_RUNNING_RICH=0 fm_running_process_row 80 42 3d "app.js" "node app.js")
  assert_contains "$row" "node app.js" "a fitting command must appear in full"
  assert_contains "$row" "app.js" "the tool name must appear"
  assert_contains "$row" "42" "the pid must appear"
  assert_contains "$row" "3d" "the uptime must appear"
  case "$row" in
    *…*) fail "a fitting process row must not truncate" ;;
    *$'\n'*) fail "a process row must never wrap" ;;
  esac
  pass "process row keeps a command that fits the column"
}

test_process_row_truncates_command_to_width() {
  local row cmd
  cmd='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  row=$(FM_RUNNING_RICH=0 fm_running_process_row 48 1 1s "tool" "$cmd")
  assert_eq 48 "${#row}" "a truncated process row must be exactly the requested width"
  case "$row" in
    *…*) ;;
    *) fail "a too-long command must be truncated with an ellipsis"$'\n'"row: '$row'" ;;
  esac
  case "$row" in
    *$'\n'*) fail "a truncated process row must never wrap" ;;
  esac
  assert_not_contains "$row" "0123456789" "the truncated tail must not appear in the row"
  pass "process row truncates a too-long command to the column width"
}

test_process_rows_align_across_pid_widths() {
  local r1 r2 p1 p2
  r1=$(FM_RUNNING_RICH=0 fm_running_process_row 64 9 2m mytool shortcmd)
  r2=$(FM_RUNNING_RICH=0 fm_running_process_row 64 8888 2m mytool shortcmd)
  p1=${r1%shortcmd}
  p2=${r2%shortcmd}
  assert_eq "${#p1}" "${#p2}" \
    "pid, uptime, and tool columns must occupy the same width so commands line up"$'\n'"row1: '$r1'"$'\n'"row2: '$r2'"
  r1=$(FM_RUNNING_RICH=0 fm_running_process_row 64 12 5s mytool shortcmd)
  r2=$(FM_RUNNING_RICH=0 fm_running_process_row 64 12 12h mytool shortcmd)
  p1=${r1%shortcmd}
  p2=${r2%shortcmd}
  assert_eq "${#p1}" "${#p2}" \
    "differing uptime widths must still leave the command column aligned"$'\n'"row1: '$r1'"$'\n'"row2: '$r2'"
  pass "process rows keep pid and uptime columns aligned across differing field lengths"
}

test_plain_layout_has_no_colour_or_box_drawing() {
  local heading row block
  heading=$(FM_RUNNING_RICH=0 fm_running_section_heading 40 "Ports")
  assert_eq 40 "${#heading}" "a plain section heading must fill the requested width"
  assert_contains "$heading" "Ports" "the section title must remain visible"
  assert_not_contains "$heading" $'\033' "plain section headings must not emit ANSI"
  assert_not_contains "$heading" "─" "plain section headings must not emit box-drawing"
  row=$(FM_RUNNING_RICH=0 fm_running_process_row 64 7 1s "app.js" "node app.js")
  assert_not_contains "$row" $'\033' "plain process rows must not emit ANSI"
  block=$(FM_RUNNING_RICH=0 fm_running_orphan_block 80 99 3d "leftover.js" "node leftover.js" "parent gone; cwd in /tmp; up 3d")
  assert_contains "$block" "!!" "a flagged leftover must be marked in the plain form"
  assert_contains "$block" "leftover.js" "a flagged leftover must be named"
  assert_contains "$block" "stop: kill 99" "the plain leftover block must keep the stop command"
  assert_contains "$block" "parent gone" "the plain leftover block must keep the reason"
  assert_not_contains "$block" $'\033' "plain leftover blocks must not emit ANSI"
  pass "plain (not-a-TTY / no-colour) layout keeps the same rows without ANSI or box-drawing"
}

test_tool_name_from_npx_bin_path() {
  local got
  got=$(fm_running_tool_name 'node /Users/me/.npm/_npx/9833c18b2d85bc59/node_modules/.bin/playwright-mcp --stdio')
  assert_eq "playwright-mcp" "$got" "an npx .bin path must name the binary, not node"
  pass "tool name from an npx .bin path is the binary basename"
}

test_tool_name_from_uvx_invocation() {
  local got
  got=$(fm_running_tool_name '/opt/homebrew/bin/uv tool uvx --python 3.12 browser-use@latest --mcp')
  assert_eq "browser-use" "$got" "a uv/uvx invocation must name the package, not uv"
  got=$(fm_running_tool_name '/Users/me/.local/bin/uv tool uvx --from git+https://github.com/snyk/cli snyk mcp')
  assert_eq "snyk" "$got" "a uvx --from git invocation must name the package after the URL"
  pass "tool name from a uv/uvx invocation is the package, not the launcher"
}

test_tool_name_from_bare_node_script() {
  local got
  got=$(fm_running_tool_name 'node server.js')
  assert_eq "server.js" "$got" "node server.js must name the script"
  pass "tool name from a bare node script is the script basename"
}

test_tool_name_falls_back_to_argv0_basename() {
  local got
  got=$(fm_running_tool_name 'claude')
  assert_eq "claude" "$got" "a bare agent CLI must keep its own name"
  got=$(fm_running_tool_name '/usr/bin/node')
  assert_eq "node" "$got" "a launcher with no script argument must fall back to argv0 basename"
  got=$(fm_running_tool_name 'node -e console.log(1)')
  assert_eq "node" "$got" "node -e with no script path must fall back to node"
  pass "tool name falls back to argv0 basename when nothing useful can be derived"
}

test_init_style_respects_no_color() {
  local saved_no_color saved_rich
  saved_no_color=${NO_COLOR-}
  saved_rich=${FM_RUNNING_RICH-}
  NO_COLOR=1
  FM_RUNNING_RICH=1
  fm_running_init_style
  assert_eq 0 "$FM_RUNNING_RICH" "NO_COLOR must disable colour and box-drawing"
  if [ -n "$saved_no_color" ]; then
    NO_COLOR=$saved_no_color
  else
    unset NO_COLOR
  fi
  if [ -n "$saved_rich" ]; then
    FM_RUNNING_RICH=$saved_rich
  else
    unset FM_RUNNING_RICH
  fi
  pass "init_style honours NO_COLOR even when rich output was previously enabled"
}

test_tmp_orphan_is_flagged
test_var_folders_orphan_is_flagged
test_slash_tmp_orphan_is_flagged
test_unreadable_cwd_orphan_is_flagged
test_age_alone_does_not_flag
test_young_tmp_process_does_not_flag
test_live_parent_does_not_flag
test_tmp_prefix_is_not_a_substring_match
test_fit_leaves_a_row_that_fits
test_fit_truncates_to_column_width
test_process_row_that_fits_keeps_the_command
test_process_row_truncates_command_to_width
test_process_rows_align_across_pid_widths
test_plain_layout_has_no_colour_or_box_drawing
test_init_style_respects_no_color
test_tool_name_from_npx_bin_path
test_tool_name_from_uvx_invocation
test_tool_name_from_bare_node_script
test_tool_name_falls_back_to_argv0_basename
