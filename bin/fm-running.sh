#!/usr/bin/env bash
# fm-running.sh - grouped, bounded survey of what is running on this Mac.
#
# Read-only: never kills, signals, or restarts anything. When a process is
# flagged as stale, the script prints the exact `kill <pid>` command and does
# not run it. There is no --kill flag.
#
# System-noise rule: drop a process when its executable path (argv0) starts
# with /System/, /usr/libexec/, /usr/sbin/, /sbin/, /Library/Apple/, or
# /Library/SystemExtensions/.
#
# Orphan heuristic: parent is init (ppid 1) AND cwd is missing/unreadable or
# sits under a temp path AND elapsed seconds exceed FM_RUNNING_STALE_SECS
# (default 86400). Age alone never flags. The reason is always printed next
# to a flagged process. Temp roots: /tmp, /private/tmp, /var/tmp,
# /private/var/tmp, /var/folders, /private/var/folders. A process with no
# cwd row from lsof is unknown, not unreadable, and is not flagged.
#
# macOS only. Uses BSD ps and lsof; there is no Linux layer. Elapsed time
# comes from BSD ps `etime` ([[dd-]hh:]mm:ss); macOS has no `etimes` keyword.
#
# Usage:
#   fm-running.sh           grouped AI/tool survey
#   fm-running.sh --all     every non-system process
#   fm-running.sh --help
#
# Default mode keeps AI/tool servers (node, bun, deno, python, uv, npx, tsx,
# known agent CLIs, and commands whose path looks like an MCP server).
# Firstmate's own long-running services are always listed, unfiltered.
# --all drops that AI/tooling filter and still excludes system daemons.
#
# The orphan classifier is fm_running_orphan_reason. Tests source this file
# and call it with synthetic ppid/cwd/elapsed rows; the live process table
# is not a test fixture.
set -u

FM_RUNNING_STALE_SECS=${FM_RUNNING_STALE_SECS:-86400}
FM_RUNNING_CMD_WIDTH=96
FM_RUNNING_GROUP_CAP=12
FM_RUNNING_PORT_CAP=40

fm_running_usage() {
  cat <<'EOF'
usage: fm-running.sh [--all]

Print a grouped survey of AI and tooling processes on this Mac.
Read-only: never kills, signals, or restarts anything.

--all   drop the AI/tooling filter and show every non-system process
--help  print this usage
EOF
}

fm_running_error() {
  printf 'fm-running: %s\n' "$*" >&2
}

# Strip leading zeros so bash arithmetic never treats 08 as octal.
fm_running_int() {  # <digits>
  local v=$1
  v=$(printf '%s' "$v" | sed 's/^0*//')
  [ -n "$v" ] || v=0
  case "$v" in
    *[!0-9]*) v=0 ;;
  esac
  printf '%s' "$v"
}

fm_running_fmt_age() {  # <seconds>
  local s
  s=$(fm_running_int "$1")
  if [ "$s" -ge 86400 ]; then
    printf '%dd' $((s / 86400))
  elif [ "$s" -ge 3600 ]; then
    printf '%dh' $((s / 3600))
  elif [ "$s" -ge 60 ]; then
    printf '%dm' $((s / 60))
  else
    printf '%ds' "$s"
  fi
}

# Print the temp root when cwd sits under one; otherwise print nothing.
fm_running_temp_root() {  # <cwd>
  case "$1" in
    /tmp|/tmp/*) printf '/tmp\n' ;;
    /private/tmp|/private/tmp/*) printf '/private/tmp\n' ;;
    /var/tmp|/var/tmp/*) printf '/var/tmp\n' ;;
    /private/var/tmp|/private/var/tmp/*) printf '/var/tmp\n' ;;
    /var/folders|/var/folders/*) printf '/var/folders\n' ;;
    /private/var/folders|/private/var/folders/*) printf '/var/folders\n' ;;
    *) return 1 ;;
  esac
}

# Print a reason and return 0 when the row is an orphan; print nothing and
# return 1 otherwise. Never flags on age alone.
fm_running_orphan_reason() {  # <ppid> <cwd> <elapsed_seconds>
  local ppid=$1 cwd=$2 elapsed=$3 threshold=$FM_RUNNING_STALE_SECS
  local temp_root reason_cwd
  case "$ppid" in
    1) ;;
    *) return 1 ;;
  esac
  elapsed=$(fm_running_int "$elapsed")
  threshold=$(fm_running_int "$threshold")
  [ "$elapsed" -gt "$threshold" ] || return 1
  if [ -z "$cwd" ]; then
    reason_cwd='cwd unreadable'
  elif temp_root=$(fm_running_temp_root "$cwd"); then
    reason_cwd="cwd in $temp_root"
  else
    return 1
  fi
  printf 'parent gone; %s; up %s\n' "$reason_cwd" "$(fm_running_fmt_age "$elapsed")"
}

fm_running_argv0() {  # <command>
  local cmd=$1
  cmd=${cmd#"${cmd%%[![:space:]]*}"}
  case "$cmd" in
    '' ) printf '\n' ;;
    *) printf '%s\n' "${cmd%%[[:space:]]*}" ;;
  esac
}

fm_running_basename() {  # <path>
  local p=$1
  p=${p##*/}
  printf '%s' "$p"
}

fm_running_is_system_argv0() {  # <argv0>
  case "$1" in
    /System/*|/usr/libexec/*|/usr/sbin/*|/sbin/*|/Library/Apple/*|/Library/SystemExtensions/*)
      return 0
      ;;
  esac
  return 1
}

# First eight argv words only. Crewmate commands embed whole briefs, and those
# briefs mention firstmate services by name.
fm_running_cmd_head() {  # <command>
  printf '%s' "$1" | awk '{
    n = (NF < 8) ? NF : 8
    for (i = 1; i <= n; i++) {
      if (i > 1) printf " "
      printf "%s", $i
    }
  }'
}

fm_running_firstmate_label() {  # <command>
  local cmd
  cmd=$(fm_running_cmd_head "$1")
  case "$cmd" in
    *fm-watch-arm.sh*) return 1 ;;
  esac
  case "$cmd" in
    *'no-mistakes daemon log-sink'*) printf 'no-mistakes log sink\n' ;;
    *'no-mistakes daemon run'*|*'no-mistakes daemon'*) printf 'no-mistakes daemon\n' ;;
    *'herdr server'*) printf 'herdr server\n' ;;
    *'lavish-axi poll '*) printf 'lavish poll\n' ;;
    *'lavish-axi'*' server'*|*'/cli.mjs server'*) printf 'lavish server\n' ;;
    *'fm-watch.sh'*) printf 'fleet watcher\n' ;;
    *) return 1 ;;
  esac
}

# pid<TAB>owner for every process in <procs-file>, walking each parent chain
# and naming the owner from the ancestor's own command, never the child's.
fm_running_write_owners() {  # <procs-file> <out-file>
  awk -F'\t' '
    function argv0(cmd,   a) {
      sub(/^ +/, "", cmd)
      split(cmd, a, /[[:space:]]+/)
      return a[1]
    }
    function basename(p,   n, a) {
      n = split(p, a, "/")
      return a[n]
    }
    function app(cmd,   i, j, s, b, n, a, prefix) {
      prefix = "/Applications/"
      i = index(cmd, prefix)
      if (i > 0) {
        s = substr(cmd, i + length(prefix))
        j = index(s, ".app/")
        if (j > 1) {
          s = substr(s, 1, j - 1)
          n = split(s, a, "/")
          return a[n]
        }
      }
      b = basename(argv0(cmd))
      if (b == "Cursor" || b == "cursor-agent") return "Cursor"
      if (b == "Claude" || b == "claude") return "Claude"
      if (b == "Codex" || b == "codex") return "Codex"
      if (b == "Grok" || b == "grok") return "Grok Bot"
      return ""
    }
    BEGIN { n = 0 }
    {
      ppid[$1] = $2
      cmd[$1] = $5
      pids[++n] = $1
    }
    END {
      for (i = 1; i <= n; i++) {
        pid = pids[i]
        current = pid
        last = ""
        for (h = 0; h < 24; h++) {
          if (current == "" || current == "0" || current == "1") break
          a = app(cmd[current])
          if (a != "") last = a
          p = ppid[current]
          if (p == "" || p == "0" || p == "1" || p == current) break
          current = p
        }
        if (last == "") last = "no owning app"
        print pid "\t" last
      }
    }
  ' "$1" > "$2"
}

fm_running_is_tooling_command() {  # <command>
  local cmd=$1 argv0 base
  fm_running_firstmate_label "$cmd" >/dev/null && return 0
  argv0=$(fm_running_argv0 "$cmd")
  base=$(fm_running_basename "$argv0")
  case "$base" in
    node|bun|deno|python|python3|Python|uv|npx|tsx|cursor-agent|claude|codex|grok|opencode|kimi|gemini|ollama|lavish-axi)
      return 0
      ;;
  esac
  case "$base" in
    python3.*) return 0 ;;
  esac
  case "$cmd" in
    */mcp/*|*'/mcp '*|*mcp-server*|*/mcp.js*|*/mcp.mjs*) return 0 ;;
  esac
  return 1
}

fm_running_short_cmd() {  # <command>
  local cmd=$1
  cmd=$(printf '%s' "$cmd" | tr '\t\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')
  if [ "${#cmd}" -gt "$FM_RUNNING_CMD_WIDTH" ]; then
    printf '%s…' "${cmd:0:$((FM_RUNNING_CMD_WIDTH - 1))}"
  else
    printf '%s' "$cmd"
  fi
}

fm_running_lsof_bin() {
  if [ -x /usr/sbin/lsof ]; then
    printf '%s\n' /usr/sbin/lsof
    return 0
  fi
  command -v lsof
}

# Parse lsof -Fpn cwd records into pid<TAB>cwd lines on stdout.
fm_running_parse_cwd_f() {
  awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ {
      if (pid != "") print pid "\t" substr($0, 2)
      next
    }
  '
}

# Parse lsof -Fpn listen records into pid<TAB>port lines, deduped.
fm_running_parse_listen_f() {
  awk '
    /^p/ { pid = substr($0, 2); next }
    /^n/ {
      name = substr($0, 2)
      port = name
      sub(/.*:/, "", port)
      if (pid != "" && port != "" && port != name) {
        key = pid SUBSEP port
        if (!seen[key]++) print pid "\t" port
      }
      next
    }
  '
}

fm_running_print_section() {  # <title>
  printf '\n## %s\n' "$1"
}

fm_running_cleanup() {
  [ -n "${FM_RUNNING_WORK:-}" ] || return 0
  rm -rf -- "$FM_RUNNING_WORK"
  FM_RUNNING_WORK=
}

fm_running_main() {
  local show_all=0 uname_s ps_bin lsof_bin work procs cwds listens
  local listen_err listen_raw listen_rc cwd_raw pid_list
  local pid ppid cmd argv0 secs label owner cwd port reason short cwd_row
  local fm_count=0 group_owner='' group_shown=0 group_skipped=0
  local port_shown=0 port_skipped=0 orphan_count=0
  local listen_note=''

  case "${1:-}" in
    '') ;;
    --all)
      show_all=1
      [ "$#" -eq 1 ] || { fm_running_usage >&2; exit 2; }
      ;;
    -h|--help)
      fm_running_usage
      exit 0
      ;;
    *)
      fm_running_usage >&2
      exit 2
      ;;
  esac
  [ "$#" -le 1 ] || { fm_running_usage >&2; exit 2; }

  uname_s=$(uname -s 2>/dev/null || true)
  if [ "$uname_s" != Darwin ]; then
    fm_running_error "macOS only (this kernel reports ${uname_s:-unknown})"
    exit 2
  fi

  ps_bin=/bin/ps
  [ -x "$ps_bin" ] || ps_bin='ps'
  lsof_bin=$(fm_running_lsof_bin || true)

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-running.XXXXXX") || {
    fm_running_error 'could not create a temporary directory'
    exit 1
  }
  FM_RUNNING_WORK=$work
  trap fm_running_cleanup EXIT
  procs=$work/procs
  cwds=$work/cwds
  listens=$work/listens
  listen_raw=$work/listen.raw
  listen_err=$work/listen.err
  cwd_raw=$work/cwd.raw
  pid_list=$work/pids
  : > "$procs"
  : > "$cwds"
  : > "$listens"
  : > "$pid_list"

  if ! "$ps_bin" -axo pid=,ppid=,etime=,command= > "$work/ps.out"; then
    fm_running_error 'ps failed'
    exit 1
  fi

  awk '
    function etos(etime,   days, rest, n, a, h, m, s) {
      days = 0
      if (split(etime, a, "-") == 2) {
        days = a[1] + 0
        rest = a[2]
      } else {
        rest = etime
      }
      n = split(rest, a, ":")
      if (n == 3) {
        h = a[1] + 0
        m = a[2] + 0
        s = a[3] + 0
      } else if (n == 2) {
        h = 0
        m = a[1] + 0
        s = a[2] + 0
      } else {
        h = 0
        m = 0
        s = rest + 0
      }
      return days * 86400 + h * 3600 + m * 60 + s
    }
    {
      pid = $1
      ppid = $2
      etime = $3
      if (pid !~ /^[0-9]+$/) next
      if (ppid !~ /^[0-9]+$/) ppid = 0
      $1 = $2 = $3 = ""
      sub(/^ +/, "")
      gsub(/\t/, " ")
      cmd = $0
      argv0 = cmd
      sub(/[[:space:]].*/, "", argv0)
      print pid "\t" ppid "\t" etos(etime) "\t" argv0 "\t" cmd
    }
  ' "$work/ps.out" > "$procs"

  if [ -n "$lsof_bin" ]; then
    listen_rc=0
    "$lsof_bin" -nP -iTCP -sTCP:LISTEN -Fpn > "$listen_raw" 2>"$listen_err" || listen_rc=$?
    if [ -s "$listen_raw" ]; then
      fm_running_parse_listen_f < "$listen_raw" > "$listens"
    elif [ "$listen_rc" -ne 0 ]; then
      listen_note=$(head -1 "$listen_err" | tr '\t' ' ')
      [ -n "$listen_note" ] || listen_note="lsof exited $listen_rc with no listener records"
    fi
  else
    listen_note='lsof not found'
  fi

  : > "$work/all.pids"
  if [ -s "$listens" ]; then
    awk -F'\t' '{ print $1 }' "$listens" >> "$work/all.pids"
  fi
  awk -F'\t' -v stale="$FM_RUNNING_STALE_SECS" '
    $2 == 1 && $3 + 0 > stale {
      argv0 = $4
      if (argv0 ~ /^\/System\//) next
      if (argv0 ~ /^\/usr\/libexec\//) next
      if (argv0 ~ /^\/usr\/sbin\//) next
      if (argv0 ~ /^\/sbin\//) next
      if (argv0 ~ /^\/Library\/Apple\//) next
      if (argv0 ~ /^\/Library\/SystemExtensions\//) next
      print $1
    }
  ' "$procs" >> "$work/all.pids"
  sort -u "$work/all.pids" | awk '
    BEGIN { list = "" }
    /^[0-9]+$/ {
      if (list == "") list = $1
      else list = list "," $1
    }
    END { print list }
  ' > "$pid_list"

  if [ -n "$lsof_bin" ]; then
    pidcsv=$(tr -d '\n' < "$pid_list")
    if [ -n "$pidcsv" ]; then
      "$lsof_bin" -a -nP -d cwd -p "$pidcsv" -Fn > "$cwd_raw" 2>/dev/null || true
      if [ -s "$cwd_raw" ]; then
        fm_running_parse_cwd_f < "$cwd_raw" > "$cwds"
      fi
    fi
  fi

  fm_running_write_owners "$procs" "$work/owners"

  printf '# Running\n'

  fm_running_print_section 'Firstmate services'
  while IFS="$(printf '\t')" read -r pid ppid secs argv0 cmd || [ -n "$pid" ]; do
    [ -n "$pid" ] || continue
    label=$(fm_running_firstmate_label "$cmd") || continue
    printf '  %s  pid %s  up %s\n' "$label" "$pid" "$(fm_running_fmt_age "$secs")"
    fm_count=$((fm_count + 1))
  done < "$procs"
  if [ "$fm_count" -eq 0 ]; then
    printf '  none found\n'
  fi

  fm_running_print_section 'AI / tool servers'
  : > "$work/groups.unsorted"
  while IFS="$(printf '\t')" read -r pid ppid secs argv0 cmd || [ -n "$pid" ]; do
    [ -n "$pid" ] || continue
    fm_running_is_system_argv0 "$argv0" && continue
    fm_running_firstmate_label "$cmd" >/dev/null && continue
    if [ "$show_all" -eq 0 ] && ! fm_running_is_tooling_command "$cmd"; then
      continue
    fi
    owner=$(awk -F'\t' -v pid="$pid" '$1 == pid { print $2; exit }' "$work/owners")
    [ -n "$owner" ] || owner='no owning app'
    short=$(fm_running_short_cmd "$cmd")
    printf '%s\t%s\t%s\t%s\n' "$owner" "$pid" "$secs" "$short"
  done < "$procs" >> "$work/groups.unsorted"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n "$work/groups.unsorted" > "$work/groups"

  if [ ! -s "$work/groups" ]; then
    printf '  none found\n'
  else
    group_owner=''
    group_shown=0
    group_skipped=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      owner=$(printf '%s' "$line" | awk -F'\t' '{ print $1 }')
      pid=$(printf '%s' "$line" | awk -F'\t' '{ print $2 }')
      secs=$(printf '%s' "$line" | awk -F'\t' '{ print $3 }')
      short=$(printf '%s' "$line" | awk -F'\t' '{ print $4 }')
      if [ "$owner" != "$group_owner" ]; then
        if [ -n "$group_owner" ] && [ "$group_skipped" -gt 0 ]; then
          printf '    … %s more\n' "$group_skipped"
        fi
        printf '  %s\n' "$owner"
        group_owner=$owner
        group_shown=0
        group_skipped=0
      fi
      if [ "$group_shown" -ge "$FM_RUNNING_GROUP_CAP" ]; then
        group_skipped=$((group_skipped + 1))
        continue
      fi
      printf '    pid %s  up %s  %s\n' "$pid" "$(fm_running_fmt_age "$secs")" "$short"
      group_shown=$((group_shown + 1))
    done < "$work/groups"
    if [ -n "$group_owner" ] && [ "$group_skipped" -gt 0 ]; then
      printf '    … %s more\n' "$group_skipped"
    fi
  fi

  fm_running_print_section 'Listening TCP ports'
  if [ -n "$listen_note" ]; then
    printf '  unavailable: %s\n' "$listen_note"
  elif [ ! -s "$listens" ]; then
    printf '  no non-system TCP listeners\n'
  else
    : > "$work/ports.unsorted"
    while IFS="$(printf '\t')" read -r pid port || [ -n "$pid" ]; do
      [ -n "$pid" ] || continue
      argv0=$(awk -F'\t' -v pid="$pid" '$1 == pid { print $4; exit }' "$procs")
      if [ -n "$argv0" ] && fm_running_is_system_argv0 "$argv0"; then
        continue
      fi
      secs=$(awk -F'\t' -v pid="$pid" '$1 == pid { print $3; exit }' "$procs")
      cmd=$(awk -F'\t' -v pid="$pid" '$1 == pid { print $5; exit }' "$procs")
      [ -n "$cmd" ] || cmd="pid $pid"
      cwd=$(awk -F'\t' -v pid="$pid" '$1 == pid { print $2; exit }' "$cwds")
      short=$(fm_running_short_cmd "$cmd")
      [ -n "$secs" ] || secs=0
      printf '%s\t%s\t%s\t%s\t%s\n' "$port" "$pid" "$secs" "$short" "$cwd"
    done < "$listens" >> "$work/ports.unsorted"
    LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n "$work/ports.unsorted" > "$work/ports"
    if [ ! -s "$work/ports" ]; then
      printf '  no non-system TCP listeners\n'
    else
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$port_shown" -ge "$FM_RUNNING_PORT_CAP" ]; then
          port_skipped=$((port_skipped + 1))
          continue
        fi
        port=$(printf '%s' "$line" | awk -F'\t' '{ print $1 }')
        pid=$(printf '%s' "$line" | awk -F'\t' '{ print $2 }')
        secs=$(printf '%s' "$line" | awk -F'\t' '{ print $3 }')
        short=$(printf '%s' "$line" | awk -F'\t' '{ print $4 }')
        cwd=$(printf '%s' "$line" | awk -F'\t' '{ print $5 }')
        printf '  %s  pid %s  up %s  %s\n' "$port" "$pid" "$(fm_running_fmt_age "$secs")" "$short"
        if [ -n "$cwd" ]; then
          printf '      cwd %s\n' "$cwd"
        fi
        port_shown=$((port_shown + 1))
      done < "$work/ports"
      if [ "$port_skipped" -gt 0 ]; then
        printf '  … %s more\n' "$port_skipped"
      fi
    fi
  fi

  fm_running_print_section 'Stale or orphaned'
  while IFS="$(printf '\t')" read -r pid ppid secs argv0 cmd || [ -n "$pid" ]; do
    [ -n "$pid" ] || continue
    fm_running_is_system_argv0 "$argv0" && continue
    cwd_row=$(awk -F'\t' -v pid="$pid" '$1 == pid { print; exit }' "$cwds")
    [ -n "$cwd_row" ] || continue
    cwd=$(printf '%s' "$cwd_row" | awk -F'\t' '{ print $2 }')
    reason=$(fm_running_orphan_reason "$ppid" "$cwd" "$secs") || continue
    short=$(fm_running_short_cmd "$cmd")
    printf '  pid %s  %s\n' "$pid" "$short"
    printf '    %s\n' "$reason"
    printf '    stop: kill %s\n' "$pid"
    orphan_count=$((orphan_count + 1))
  done < "$procs"
  if [ "$orphan_count" -eq 0 ]; then
    printf '  none flagged\n'
  fi
}

# Sourced by tests loading the classifier; skip the live survey.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

fm_running_main "$@"
