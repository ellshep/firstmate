#!/usr/bin/env bash
# Regression tests for fm-spawn's local environment propagation.
#
# A project's working credentials live in gitignored `.env*` files at its
# checkout root, so a fresh task worktree never receives them and every worker
# starts credential-blind. These tests drive the real spawn path with a fake
# terminal and prove the worktree inherits those files with the excluded keys
# filtered out, that a tracked `.env.schema` is never copied, that an existing
# destination is left alone, and that a project with nothing to copy still
# spawns.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-env-local)

# The keys this suite expects to survive and to be dropped, spelled out here
# rather than read from the script, so widening bin/fm-spawn.sh's exclusion
# constant fails a test instead of passing silently.
KEPT_KEYS='APP_NAME SUPABASE_URL SUPABASE_SERVICE_KEY NOT_DATABASE_URL MY_PRODUCT'
DROPPED_KEYS='DATABASE_URL DATABASE_URL_POOLED DATABASE_URL_DIRECT DATABASE_URL_PROD SUPABASE_SERVICE_KEY_PROD'

file_mode() { # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

has_key() { # <file> <key>
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1"
}

make_case() { # <name> <id> [tracked-schema|uncommitted-ignore]
  local name=$1 id=$2 mode=${3:-} case_dir home project origin pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  if [ "$mode" != uncommitted-ignore ]; then
    printf '.env*\n' > "$project/.gitignore"
    git -C "$project" add .gitignore
  fi
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$project" worktree add --quiet --detach "$pool" HEAD

  # The two special modes leave the project without an origin, so the pooled base
  # is never refreshed and the worktree stays exactly on the commit below.
  case $mode in
  tracked-schema)
    # The pool is detached on the commit before .env.schema was tracked, so the
    # destination path genuinely does not exist. Only the SOURCE repository's
    # ignore check can keep the tracked file out of the copy.
    printf 'DATABASE_URL=\nTRACKED_SENTINEL=from-project\n' > "$project/.env.schema"
    git -C "$project" add -f .env.schema
    git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm track-schema
    ;;
  uncommitted-ignore)
    # The ignore rule exists only in the project's own uncommitted .gitignore, so
    # the project ignores .env while the worktree on the committed base does not.
    printf '.env*\n' > "$project/.gitignore"
    ;;
  *)
    git clone --quiet --bare "$project" "$origin"
    git -C "$project" remote add origin "file://$origin"
    ;;
  esac

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_env_local() { # <project>
  cat > "$1/.env" <<'ENV'
# local credentials
APP_NAME=firstmate
DATABASE_URL=postgres://hosted/app
DATABASE_URL_POOLED=postgres://hosted/pool
export DATABASE_URL_DIRECT=postgres://hosted/direct
DATABASE_URL_PROD=postgres://prod/app
SUPABASE_URL=https://example.supabase.co
SUPABASE_SERVICE_KEY=service-key
SUPABASE_SERVICE_KEY_PROD=prod-service-key
NOT_DATABASE_URL=keep-me
MY_PRODUCT=keep-me-too
ENV
}

run_spawn() { # <id> [args...]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

test_gitignored_env_reaches_the_worktree_without_excluded_keys() {
  local rec id out status key
  id='env-local-copy'
  rec=$(make_case copy "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  printf 'SECOND_FILE_KEY=second\nDATABASE_URL=postgres://hosted/second\n' > "$PROJECT_DIR/.env.local"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch with local credentials to propagate"$'\n'"$out"

  [ -f "$POOL_DIR/.env" ] || fail "the task worktree did not receive the project's .env"
  for key in $KEPT_KEYS; do
    has_key "$POOL_DIR/.env" "$key" \
      || fail "the copied .env dropped ordinary key $key"
  done
  for key in $DROPPED_KEYS; do
    ! has_key "$POOL_DIR/.env" "$key" \
      || fail "the copied .env carried excluded key $key into a disposable worktree"
  done
  grep -q '^# local credentials$' "$POOL_DIR/.env" \
    || fail "the copy did not pass a non-KEY= line through untouched"
  [ "$(file_mode "$POOL_DIR/.env")" = 600 ] \
    || fail "the copied credentials are mode $(file_mode "$POOL_DIR/.env"), not 600"

  [ -f "$POOL_DIR/.env.local" ] || fail "the task worktree did not receive .env.local"
  has_key "$POOL_DIR/.env.local" SECOND_FILE_KEY \
    || fail "the second copied file lost its ordinary key"
  ! has_key "$POOL_DIR/.env.local" DATABASE_URL \
    || fail "the second copied file carried an excluded key"

  case "$out" in
  *DATABASE_URL*|*SUPABASE*|*service-key*)
    fail "the spawn logged a credential key or value: $out"
    ;;
  esac
  pass "a gitignored .env reaches the task worktree at mode 600 with excluded keys filtered out"
}

test_tracked_env_schema_is_not_copied() {
  local rec id out status
  id='env-local-tracked'
  rec=$(make_case tracked "$id" tracked-schema)
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch beside a tracked .env.schema"$'\n'"$out"
  [ -f "$POOL_DIR/.env" ] || fail "the task worktree did not receive the project's .env"
  [ ! -e "$POOL_DIR/.env.schema" ] \
    || fail "the tracked .env.schema was copied into the task worktree"
  pass "a tracked .env.schema is excluded by the ignore check"
}

test_file_the_worktree_would_not_ignore_is_not_copied() {
  local rec id out status
  id='env-local-committable'
  rec=$(make_case committable "$id" uncommitted-ignore)
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch when the destination would be committable"$'\n'"$out"
  [ ! -e "$POOL_DIR/.env" ] \
    || fail "credentials were copied to a path the task worktree does not ignore"
  pass "a destination the worktree would let a worker commit is not written"
}

test_existing_destination_is_not_overwritten() {
  local rec id out status
  id='env-local-existing'
  rec=$(make_case existing "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  printf 'WORKER_EDITED=yes\n' > "$POOL_DIR/.env"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch over an existing worktree .env"$'\n'"$out"
  [ "$(cat "$POOL_DIR/.env")" = 'WORKER_EDITED=yes' ] \
    || fail "an existing worktree .env was overwritten: $(cat "$POOL_DIR/.env")"
  pass "an existing destination file is left completely alone"
}

test_dangling_symlink_destination_is_not_written_through() {
  local rec id out status outside
  id='env-local-symlink'
  rec=$(make_case symlink "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  outside="$CASE_DIR/outside-the-worktree.env"
  ln -s "$outside" "$POOL_DIR/.env"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn should launch over a dangling worktree .env symlink"$'\n'"$out"
  [ ! -e "$outside" ] \
    || fail "credentials were written through a dangling symlink to $outside"
  pass "a dangling symlink destination is treated as present, not absent"
}

test_project_without_env_files_spawns_normally() {
  local rec id out status
  id='env-local-none'
  rec=$(make_case none "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a project with no local credentials should spawn normally"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn with nothing to copy did not report success"
  [ ! -e "$POOL_DIR/.env" ] || fail "a project with no .env produced one in the task worktree"
  pass "a project with nothing to copy spawns normally"
}

test_gitignored_env_reaches_the_worktree_without_excluded_keys
test_tracked_env_schema_is_not_copied
test_file_the_worktree_would_not_ignore_is_not_copied
test_existing_destination_is_not_overwritten
test_dangling_symlink_destination_is_not_written_through
test_project_without_env_files_spawns_normally

echo "# all fm-spawn-env-local tests passed"
