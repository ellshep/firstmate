#!/usr/bin/env bash
# Regression tests for fm-spawn's local environment propagation.
#
# A project's working credentials live in gitignored `.env*` files at its
# checkout root, so a fresh task worktree never receives them and every worker
# starts credential-blind. These tests drive the real spawn path with a fake
# terminal and prove the worktree inherits those files with the excluded keys
# filtered out, that a tracked `.env.schema` is never copied, that a recycled
# pool destination is refreshed, stale unmatched files are cleared, that a
# dangling symlink is safe, and that a project with nothing to copy still
# spawns.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-env-local)

# The keys this suite expects to survive and to be dropped, spelled out here
# rather than read from the script, so widening bin/fm-spawn.sh's exclusion
# constant fails a test instead of passing silently.
KEPT_KEYS='APP_NAME SUPABASE_URL SUPABASE_SERVICE_KEY MY_PRODUCT USER PORT user port PUBLIC_URL'
DROPPED_KEYS='DATABASE_URL DATABASE_URL_POOLED DATABASE_URL_DIRECT DATABASE_URL_PROD POSTGRES_URL INTERNAL_DB DB_HOST DB_USER DB_PASSWORD MYSQL_HOST PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE APP_DB_HOST SUPABASE_DB_CONNECTION MSSQL_URL SQLSERVER_URL COCKROACH_URL SERVICE_CONNECTION SERVICE_ENDPOINT SUPABASE_SERVICE_KEY_PROD'

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
POSTGRES_URL=opaque-connection
INTERNAL_DB="postgres://hosted/app"
PGHOST=prod-db.internal
PGHOSTADDR=10.0.0.4
PGPORT=5432
PGDATABASE=production
PGUSER=production-user
PGPASSWORD=production-password
PGPASSFILE=/private/production/.pgpass
PGSERVICE=production-service
PGSERVICEFILE=/private/production/pg_service.conf
DB_HOST=prod-db.internal
DB_USER=production-user
DB_PASSWORD=production-password
MYSQL_HOST=prod-mysql.internal
APP_DB_HOST=prod-app-db.internal
SUPABASE_DB_CONNECTION=prod-supabase-connection
MSSQL_URL=server=prod-db;database=app
SQLSERVER_URL=sqlserver://host/db
COCKROACH_URL=cockroachdb://host/db
SERVICE_ENDPOINT=POSTGRES://HOST/DB
SUPABASE_URL=https://example.supabase.co
SUPABASE_SERVICE_KEY=service-key
SUPABASE_SERVICE_KEY_PROD=prod-service-key
MY_PRODUCT=keep-me-too
USER=public-user
PORT=443
user=lowercase-user
port=8443
PUBLIC_URL=https://example.com
SERVICE_CONNECTION=ambiguous-connection
ENV
}

run_spawn() { # <id> [args...]
  local id=$1
  shift
  if [ "${1:-}" = --relaunch ]; then
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$@"
  else
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
  fi
}

test_gitignored_env_reaches_the_worktree_without_excluded_keys() {
  local rec id out status key lock
  id='env-local-copy'
  rec=$(make_case copy "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  printf 'SECOND_FILE_KEY=second\nDATABASE_URL=postgres://hosted/second\n' > "$PROJECT_DIR/.env.local"
  export FM_FAKE_KILL_LOG="$CASE_DIR/kill.log"
  export FM_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

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

  assert_contains "$out" "DATABASE_URL" \
    "the spawn should report excluded key names"
  assert_contains "$out" "DB_HOST" \
    "the spawn should report host-style excluded key names"
  assert_contains "$out" "APP_DB_HOST" \
    "the spawn should report multi-segment excluded key names"
  assert_contains "$out" "MSSQL_URL" \
    "the spawn should report excluded database URI key names"
  assert_contains "$out" "SERVICE_ENDPOINT" \
    "the spawn should report case-insensitive URI matches"
  case "$out" in
  *postgres://*|*POSTGRES://*|*prod-db*|*prod-db.internal*|*service-key*)
    fail "the spawn logged an excluded value: $out"
    ;;
  esac
  [ ! -s "$CASE_DIR/kill.log" ] || fail "a successful spawn closed its endpoint"
  [ ! -s "$CASE_DIR/treehouse.log" ] || fail "a successful spawn returned its worktree"
  [ -e "$POOL_DIR/.git" ] || fail "a successful spawn did not retain its worktree"
  lock="$HOME_DIR/state/.spawn-$id.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    fm_lock_release "$lock"
  ) || fail "the next operation on a successfully spawned task hit a leaked lock"
  pass "a gitignored .env reaches the task worktree at mode 600 with excluded keys filtered out"
}

test_gitignored_source_symlink_is_skipped_without_blocking_regular_copy() {
  local rec id out status outside
  id='env-local-source-symlink'
  rec=$(make_case source-symlink "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  outside="$CASE_DIR/outside-project.env"
  printf 'LEAKED_SECRET=outside-project\nDATABASE_URL=postgres://outside\n' > "$outside"
  ln -s "$outside" "$PROJECT_DIR/.env.outside"
  printf 'SIDE_FILE_KEY=present\n' > "$PROJECT_DIR/.env.local"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a source symlink should be skipped without blocking the spawn"$'\n'"$out"
  [ ! -e "$POOL_DIR/.env.outside" ] \
    || fail "an outside-project source symlink was copied into the task worktree"
  [ -f "$POOL_DIR/.env.local" ] \
    || fail "a regular gitignored env file beside the symlink was not copied"
  has_key "$POOL_DIR/.env.local" SIDE_FILE_KEY \
    || fail "the regular env file beside the symlink lost its ordinary key"
  assert_contains "$out" "$PROJECT_DIR/.env.outside" \
    "the skipped source symlink path was not reported"
  assert_contains "$out" "because it is a symlink" \
    "the source symlink skip did not explain the reason"
  pass "a gitignored source symlink is skipped while a regular env file still propagates"
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

test_fresh_spawn_replaces_pooled_destination_with_filtered_current_source() {
  local rec id out status
  id='env-local-pooled'
  rec=$(make_case pooled "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  printf 'STALE_WORKER_KEY=stale\nDATABASE_URL=postgres://stale/app\n' > "$POOL_DIR/.env"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a fresh spawn should launch over a recycled pool .env"$'\n'"$out"
  ! has_key "$POOL_DIR/.env" DATABASE_URL \
    || fail "a recycled pool .env carried the excluded database key"
  has_key "$POOL_DIR/.env" APP_NAME \
    || fail "a fresh spawn did not copy an ordinary key from the current source"
  ! has_key "$POOL_DIR/.env" STALE_WORKER_KEY \
    || fail "a fresh spawn inherited stale worker state from the pool slot"
  pass "a fresh spawn refreshes a recycled pool destination through the env filter"
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
  [ -f "$POOL_DIR/.env" ] && [ ! -L "$POOL_DIR/.env" ] \
    || fail "a fresh spawn did not replace the dangling symlink with a local copy"
  pass "a fresh spawn removes a dangling symlink before writing the local copy"
}

test_fresh_spawn_clears_stale_unmatched_env_file() {
  local rec id out status
  id='env-local-stale-unmatched'
  rec=$(make_case stale-unmatched "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  printf 'STALE_ONLY=yes\n' > "$POOL_DIR/.env.local"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a fresh spawn should clear an ignored env file absent from the source"$'\n'"$out"
  [ ! -e "$POOL_DIR/.env.local" ] \
    || fail "a stale source-absent .env.local survived fresh pool cleanup"
  [ -f "$POOL_DIR/.env" ] || fail "fresh cleanup removed the current source env file"
  has_key "$POOL_DIR/.env" APP_NAME \
    || fail "fresh cleanup left no ordinary key from the current source"
  pass "a fresh spawn clears a stale source-absent env file and copies current credentials"
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

test_fresh_spawn_refuses_unremovable_destination_env() {
  local rec id out status
  id='env-local-dir'
  rec=$(make_case unremovable "$id")
  read_case_record "$rec"
  write_env_local "$PROJECT_DIR"
  mkdir "$POOL_DIR/.env"
  printf 'DATABASE_URL=postgres://stale/app\n' > "$POOL_DIR/.env/stale"
  export FM_FAKE_KILL_LOG="$CASE_DIR/kill.log"
  export FM_TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a fresh spawn must refuse an unremovable destination env"$'\n'"$out"
  [ -d "$POOL_DIR/.env" ] || fail "a failed fresh cleanup removed or replaced the unremovable destination"
  grep -Fq "kill-window" "$CASE_DIR/kill.log" \
    || fail "an environment refusal left the spawned endpoint alive"
  grep -Fq "return --force $POOL_DIR" "$CASE_DIR/treehouse.log" \
    || fail "an environment refusal left the Treehouse worktree leased"
  pass "a fresh spawn refuses an unremovable destination env"
}

test_gitignored_env_reaches_the_worktree_without_excluded_keys
test_gitignored_source_symlink_is_skipped_without_blocking_regular_copy
test_tracked_env_schema_is_not_copied
test_file_the_worktree_would_not_ignore_is_not_copied
test_fresh_spawn_replaces_pooled_destination_with_filtered_current_source
test_dangling_symlink_destination_is_not_written_through
test_fresh_spawn_clears_stale_unmatched_env_file
test_project_without_env_files_spawns_normally
test_fresh_spawn_refuses_unremovable_destination_env

echo "# all fm-spawn-env-local tests passed"
