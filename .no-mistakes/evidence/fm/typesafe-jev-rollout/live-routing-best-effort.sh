#!/usr/bin/env bash
set -u
ROOT={run-worktree}
EVIDENCE=~/.no-mistakes/evidence/01M6ZA648NZKMD2P0YHERRC75S
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-routing.XXXXXX")
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

spawn_best_effort() {
  local home="$TMP_ROOT/spawn-home" wt="$TMP_ROOT/spawn-wt" proj="$TMP_ROOT/spawn-proj"
  local fakebin id=ledger-fail-spawn out sp_code=0
  fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/spawn-fakes")
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo 'fm-routing-outcomes: simulated ledger failure' >&2
exit 1
SH
  chmod +x "$fakebin/python3"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" wt-ledger
  mkdir -p "$home/data/$id"
  printf '%s\n' '{"task":"ledger-fail-spawn","status":"clear","profile":{"harness":"codex","model":"gpt-6-sol","effort":"high"}}' \
    > "$home/data/$id/dispatch-resolution.json"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode local-only --mode-reason 'live validation fixture' --yolo off \
    --harness codex --model gpt-6-sol --effort high 2>&1) || sp_code=$?
  printf '%s\n' "$out" > "$EVIDENCE/spawn-routing-ledger-best-effort.log"
  grep -q 'routing evidence could not be appended' "$EVIDENCE/spawn-routing-ledger-best-effort.log" \
    && grep -q "spawned $id harness=codex" "$EVIDENCE/spawn-routing-ledger-best-effort.log" \
    && [ "$sp_code" -eq 0 ]
}

teardown_best_effort() {
  local case_dir="$TMP_ROOT/teardown-case" fakebin out td_code=0
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  for stub in treehouse tmux podman docker supabase; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$stub"
    chmod +x "$fakebin/$stub"
  done
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) shift; case "${1:-}" in status) printf '%s\n' "" ;; abort) exit 0 ;; esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
echo 'fm-routing-outcomes: simulated ledger failure' >&2
exit 1
SH
  chmod +x "$fakebin/python3"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id jq ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs tasks-axi; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$resolved" "$fakebin/$cmd"
  done
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed"
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=no-mistakes" \
    "spawn_gen=teardown-routing-gen"
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "routing teardown fixture" --kind scout --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$fakebin:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
    "$ROOT/bin/fm-teardown.sh" task-x1 --force > "$EVIDENCE/teardown-routing-ledger-best-effort.log" 2>&1 || td_code=$?
  grep -q "routing outcome could not be appended" "$EVIDENCE/teardown-routing-ledger-best-effort.log" \
    && [ "$td_code" -eq 0 ]
}

compact_absent() {
  ! grep -rq 'COMPACT_ADVISER\|compact.adviser\|compact-adviser' "$ROOT/bin" "$ROOT/tests" 2>/dev/null
}

main() {
  local ok=0 fail=0
  if spawn_best_effort; then echo spawn_best_effort=pass; ok=$((ok+1)); else echo spawn_best_effort=fail; fail=$((fail+1)); fi
  if teardown_best_effort; then echo teardown_best_effort=pass; ok=$((ok+1)); else echo teardown_best_effort=fail; fail=$((fail+1)); fi
  if compact_absent; then echo compact_adviser_removed=pass; ok=$((ok+1)); else echo compact_adviser_removed=fail; fail=$((fail+1)); fi
  echo "summary ok=$ok fail=$fail" | tee "$EVIDENCE/live-routing-best-effort-summary.txt"
  [ "$fail" -eq 0 ]
}
main
