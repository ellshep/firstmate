#!/usr/bin/env bash
# Validate a resolved worker model and effort against config/worker-effort-ceiling.
# An absent file leaves launch behavior unchanged. A present file requires both
# axes to be explicit so a harness default cannot bypass the ceiling.

fm_worker_effort_check() {  # <config-dir> <model> <effort>
  local file=$1 model=$2 effort=$3 ceiling requested_rank ceiling_rank
  file=$file/worker-effort-ceiling
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/worker-effort-ceiling is not a readable regular file" >&2
    return 1
  fi
  ceiling=$(cat "$file") || return 1
  case "$ceiling" in
    low) ceiling_rank=1 ;;
    medium) ceiling_rank=2 ;;
    high) ceiling_rank=3 ;;
    xhigh) ceiling_rank=4 ;;
    max) ceiling_rank=5 ;;
    *) echo "error: config/worker-effort-ceiling must contain one of low, medium, high, xhigh, max" >&2; return 1 ;;
  esac
  case "$model" in
    ''|default) echo "error: config/worker-effort-ceiling=$ceiling requires an explicit worker model" >&2; return 1 ;;
  esac
  case "$effort" in
    low) requested_rank=1 ;;
    medium) requested_rank=2 ;;
    high) requested_rank=3 ;;
    xhigh) requested_rank=4 ;;
    max) requested_rank=5 ;;
    ultra) requested_rank=6 ;;
    *) echo "error: config/worker-effort-ceiling=$ceiling requires an explicit worker effort" >&2; return 1 ;;
  esac
  if [ "$requested_rank" -gt "$ceiling_rank" ]; then
    echo "error: worker effort '$effort' exceeds config/worker-effort-ceiling '$ceiling'" >&2
    return 1
  fi
}
