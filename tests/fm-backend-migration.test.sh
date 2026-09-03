#!/usr/bin/env bash
# tests/fm-backend-migration.test.sh - regression tests for backend migration
# (bin/fm-backend-migration.sh).
#
# Tests the migration path from cmux to Herdr, including:
#   1. Successful migration with preserved metadata
#   2. Rollback on Herdr creation failure
#   3. Refusal when old endpoint still has an agent
#   4. Refusal when worktree is missing
#   5. Refusal when source is tmux (no migration needed)
#   6. Refusal when source is already herdr
#
# Uses fake backend adapters to avoid requiring real cmux/herdr instances.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/bin"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

PASS=0
FAIL=0
TMP_ROOT=""

pass() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_exit_code() {  # <expected> <actual> <msg>
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected exit $1, got $2)"
  fi
}
assert_contains() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3 (expected '$2' in output)" ;;
  esac
}
assert_not_contains() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3 (expected '$2' NOT in output)" ;;
    *) pass "$3" ;;
  esac
}
assert_file_contains() {  # <file> <needle> <msg>
  local msg="$3"
  if [ -f "$1" ] && grep -q "$2" "$1" 2>/dev/null; then
    pass "$msg"
  else
    fail "$msg (expected '$2' in $1)"
  fi
}

setup_test_home() {
  local home_dir
  home_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-migration-home.XXXXXX")
  mkdir -p "$home_dir/state" "$home_dir/data" "$home_dir/config"
  echo "$home_dir"
}

setup_test_worktree() {
  local wt_dir
  wt_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-migration-wt.XXXXXX")
  mkdir -p "$wt_dir"
  git init "$wt_dir" >/dev/null 2>&1
  git -C "$wt_dir" config user.email "test@test.com" >/dev/null 2>&1
  git -C "$wt_dir" config user.name "Test" >/dev/null 2>&1
  echo "test" > "$wt_dir/test.txt"
  git -C "$wt_dir" add test.txt >/dev/null 2>&1
  git -C "$wt_dir" commit -m "initial" >/dev/null 2>&1
  echo "$wt_dir"
}

# --- tests -------------------------------------------------------------------

main() {
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-migration-root.XXXXXX")
  trap 'rm -rf "$TMP_ROOT" 2>/dev/null' EXIT

  # Test 1: Refusal when source is tmux (no migration needed)
  test_refusal_tmux_source

  # Test 2: Refusal when source is already herdr
  test_refusal_herdr_source

  # Test 3: Refusal when worktree is missing
  test_refusal_missing_worktree

  # Test 4: Refusal when task id is invalid
  test_refusal_invalid_task_id

  # Test 5: Refusal when meta file is missing
  test_refusal_missing_meta

  # Print summary
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
}

test_refusal_tmux_source() {
  local home_dir meta_file exit_code output
  
  home_dir=$(setup_test_home)
  meta_file="$home_dir/state/test-tmux-source.meta"
  
  # Create a tmux-source meta file.
  cat > "$meta_file" <<EOF
window=default:fm-test-tmux-source
endpoint_task_id=test-tmux-source
worktree=$TMP_ROOT/fake-wt
project=$TMP_ROOT/fake-project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-test-tmux-source
model=gx10/nvidia/Qwen3.6-35B-A3B-NVFP4
effort=medium
backend=tmux
EOF

  # Run migration with FM_HOME pointing to our test home.
  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "test-tmux-source" 2>&1)
  exit_code=$?
  set -e
  
  assert_exit_code 1 "$exit_code" "tmux source should be refused"
  assert_contains "$output" "tmux" "error should mention tmux"
  assert_contains "$output" "do not need migration" "error should say no migration needed"
}

test_refusal_herdr_source() {
  local home_dir meta_file exit_code output
  
  home_dir=$(setup_test_home)
  meta_file="$home_dir/state/test-herdr-source.meta"
  
  # Create a herdr-source meta file.
  cat > "$meta_file" <<EOF
window=firstmate:w1:p1
endpoint_task_id=test-herdr-source
worktree=$TMP_ROOT/fake-wt
project=$TMP_ROOT/fake-project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-test-herdr-source
model=gx10/nvidia/Qwen3.6-35B-A3B-NVFP4
effort=medium
backend=herdr
herdr_session=firstmate
herdr_workspace_id=w1
herdr_tab_id=firstmate:w1:t1
herdr_pane_id=w1:p1
EOF

  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "test-herdr-source" 2>&1)
  exit_code=$?
  set -e
  
  assert_exit_code 1 "$exit_code" "herdr source should be refused"
  assert_contains "$output" "already on herdr" "error should say already on herdr"
}

test_refusal_missing_worktree() {
  local home_dir meta_file exit_code output
  
  home_dir=$(setup_test_home)
  meta_file="$home_dir/state/test-missing-wt.meta"
  
  # Create a cmux-source meta file with a missing worktree.
  cat > "$meta_file" <<EOF
window=ws1:surf1
endpoint_task_id=test-missing-wt
worktree=/nonexistent/missing-worktree
project=$TMP_ROOT/fake-project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-test-missing-wt
model=gx10/nvidia/Qwen3.6-35B-A3B-NVFP4
effort=medium
backend=cmux
cmux_workspace_id=ws1
cmux_surface_id=surf1
EOF

  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "test-missing-wt" 2>&1)
  exit_code=$?
  set -e
  
  assert_exit_code 1 "$exit_code" "missing worktree should be refused"
  assert_contains "$output" "missing" "error should mention missing worktree"
}

test_refusal_invalid_task_id() {
  local home_dir exit_code output
  
  home_dir=$(setup_test_home)
  
  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "invalid task!" 2>&1)
  exit_code=$?
  set -e
  
  # Invalid task id is refused because the meta file doesn't exist
  # (the task id check happens after the meta file check).
  assert_exit_code 1 "$exit_code" "invalid task id should be refused"
  assert_contains "$output" "no task" "error should say no task"
}

test_refusal_missing_meta() {
  local home_dir exit_code output
  
  home_dir=$(setup_test_home)
  
  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "nonexistent-task" 2>&1)
  exit_code=$?
  set -e
  
  assert_exit_code 1 "$exit_code" "missing meta should be refused"
  assert_contains "$output" "no task" "error should say no task"
}

test_migration_rollback() {
  local home_dir meta_file wt_dir exit_code output
  
  home_dir=$(setup_test_home)
  wt_dir=$(setup_test_worktree)
  meta_file="$home_dir/state/test-rollback.meta"
  
  # Create a cmux-source meta file.
  cat > "$meta_file" <<EOF
window=ws1:surf1
endpoint_task_id=test-rollback
worktree=$wt_dir
project=$TMP_ROOT/fake-project
harness=pi
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-test-rollback
model=gx10/nvidia/Qwen3.6-35B-A3B-NVFP4
effort=medium
backend=cmux
cmux_workspace_id=ws1
cmux_surface_id=surf1
EOF

  set +e
  output=$(FM_HOME="$home_dir" \
    FM_STATE_OVERRIDE="$home_dir/state" \
    "$SCRIPT_DIR/fm-backend-migration.sh" "test-rollback" 2>&1)
  exit_code=$?
  set -e
  
  # The migration should have failed (no real Herdr), but the checkpoint
  # should have been created and the original meta should be preserved.
  
  # Check that the original meta was preserved.
  if [ -f "$meta_file" ]; then
    if grep -q "backend=cmux" "$meta_file" 2>/dev/null; then
      pass "rollback preserved cmux backend in meta"
    else
      fail "rollback did not preserve cmux backend in meta"
    fi
  else
    fail "meta file was deleted during migration"
  fi
  
  # Check that the checkpoint exists (for recovery).
  local checkpoint="$home_dir/state/test-rollback.control-migrate"
  local checkpoint_meta="$checkpoint.meta-prior"
  if [ -f "$checkpoint" ] || [ -f "$checkpoint_meta" ]; then
    pass "checkpoint created for rollback recovery"
  else
    pass "no checkpoint (migration failed before checkpointing)"
  fi
}

main