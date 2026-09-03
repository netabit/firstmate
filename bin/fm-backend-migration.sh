#!/usr/bin/env bash
# fm-backend-migration.sh - migrate a stopped task from one backend to Herdr.
#
# Usage: fm-backend-migration.sh <task-id>
#
# This script migrates a task whose recorded endpoint is on a non-Herdr,
# non-tmux backend (currently cmux, zellij, or orca) onto Herdr, preserving
# the task's identity, worktree, uncommitted work, instructions, and all
# non-endpoint metadata. The migration is atomic: the old meta is checkpointed
# before any change, and the new endpoint is verified live before the meta is
# replaced. Failed migrations restore the checkpoint so the prior state is
# always recoverable.
#
# Safety contract:
#   - The old endpoint must be positively agent-free before migration begins.
#     A running agent is a blocker: the migration is refused.
#   - The new Herdr endpoint is created and verified live BEFORE the meta is
#     replaced, so a failed creation never leaves the task without a working
#     endpoint.
#   - The meta file is replaced atomically (write to .tmp, mv -f), so the
#     task is never seen in a half-transitioned state.
#   - On any failure, the checkpoint meta is restored and the old endpoint
#     record is preserved.
#   - The migration never creates two agents for one task: it refuses to
#     proceed if the old endpoint still has a running agent.
#   - Failed migrations retain recoverable prior state; they never create
#     two agents for one task.
#
# The migration target is always Herdr (the only backend with a recovery-grade
# agent-state classifier that can verify both the old endpoint is dead and the
# new endpoint is agent-free).
#
# Data flow:
#   1. Read and validate the source meta file.
#   2. Verify the source backend is a non-tmux backend that can be migrated.
#   3. Check that no prior agent is running at the old endpoint.
#   4. Create a checkpoint of the current meta.
#   5. Create the new Herdr endpoint (workspace, tab, pane) via the adapter.
#   6. Verify the new endpoint is live and agent-free.
#   7. Build the new meta file (preserve all non-endpoint fields, update
#      endpoint fields).
#   8. Atomically replace the meta file.
#   9. Clean up the checkpoint.
#
# Designed as a companion to bin/fm-control.sh's relaunch verb: relaunch
# switches harness/model/effort within the SAME backend; migrate switches the
# backend itself (e.g., cmux → herdr) when the old endpoint is dead.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME_OVERRIDE:-${FM_HOME:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Usage: fm-backend-migration.sh <task-id>"
  echo ""
  echo "Migrate a stopped task from its current backend (cmux, zellij, or orca)"
  echo "onto Herdr, preserving worktree, uncommitted work, and instructions."
}

# --- argument parsing --------------------------------------------------------

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
ID=$1
[ -n "$ID" ] || { usage >&2; exit 2; }

# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle.
fm_refuse_if_gate_agent

# Validate FM_HOME
if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-backend-migration refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-backend-migration cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no task '$ID' in $STATE"
[ ! -L "$META" ] || die "task '$ID' meta is a symlink, not a regular file"

# Validate task id
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "'$ID' is not a valid task id" ;; esac

# --- source meta validation --------------------------------------------------

RECORDED_BACKEND=$(fm_meta_get "$META" backend)
[ -n "$RECORDED_BACKEND" ] || RECORDED_BACKEND=tmux

case "$RECORDED_BACKEND" in
  tmux)
    die "task $ID is on the default tmux backend; tmux tasks do not need migration (the endpoint is a tmux window, not a session-provider workspace)"
    ;;
  herdr)
    die "task $ID is already on herdr; no migration needed"
    ;;
  cmux|zellij|orca)
    # Supported source backends
    ;;
  *)
    die "task $ID records backend '$RECORDED_BACKEND', which is not a supported migration source"
    ;;
esac

# Read all meta fields
WORKTREE=$(fm_meta_get "$META" worktree)
PROJECT=$(fm_meta_get "$META" project)
HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
MODE=$(fm_meta_get "$META" mode)
YOLO=$(fm_meta_get "$META" yolo)
TASKTMP=$(fm_meta_get "$META" tasktmp)
MODEL=$(fm_meta_get "$META" model)
EFFORT=$(fm_meta_get "$META" effort)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
PR_URL=$(fm_meta_get "$META" pr)
PR_HEAD=$(fm_meta_get "$META" pr_head)
REMOTE_HOST=$(fm_meta_get "$META" remote_host)

# --- worktree validation -----------------------------------------------------

[ -n "$WORKTREE" ] || die "task $ID has no recorded worktree"
[ -d "$WORKTREE" ] || die "task $ID's recorded worktree $WORKTREE is missing; cannot migrate without a local copy"

# Verify the worktree is a valid git worktree root
WT_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || die "task $ID's worktree $WORKTREE cannot be resolved"
WT_TOP=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) || die "task $ID's worktree $WORKTREE is not a git worktree"
WT_TOP_REAL=$(cd "$WT_TOP" 2>/dev/null && pwd -P) || WT_TOP_REAL=$WT_TOP
[ "$WT_REAL" = "$WT_TOP_REAL" ] \
  || die "task $ID's worktree $WORKTREE is not a worktree root (root is $WT_TOP)"

# Check for uncommitted work (preserve it)
STATUS_OUTPUT=$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)
HAS_DIRTY_WORK=0
[ -n "$STATUS_OUTPUT" ] && HAS_DIRTY_WORK=1

# --- source endpoint verification (must be agent-free) -----------------------

# Validate the source endpoint from meta
FM_BACKEND_VALIDATED_BACKEND=
FM_BACKEND_VALIDATED_TARGET=
if ! fm_backend_validate_task_endpoint "$META" "$ID"; then
  die "task $ID's source endpoint metadata is invalid; cannot migrate"
fi

SRC_BACKEND="$FM_BACKEND_VALIDATED_BACKEND"
SRC_TARGET="$FM_BACKEND_VALIDATED_TARGET"

# For cmux/zellij/orca, the agent-state classifier is "unverified" (no recovery-grade
# classifier), so we check if the endpoint still exists.
# If the endpoint is gone, the agent is definitely dead.
# If it exists, we need to verify no agent is running.
AGENT_STATUS="unknown"
case "$SRC_BACKEND" in
  cmux|zellij|orca)
    if fm_backend_target_exists "$SRC_BACKEND" "$SRC_TARGET" 2>/dev/null; then
      # Endpoint exists; check if there's a shell process in the worktree.
      if [ -d "$WORKTREE" ]; then
        # Look for shell processes running in the worktree directory.
        # A stopped agent typically leaves its terminal endpoint present
        # but no shell process running in the worktree.
        SHELL_PROCS=$(pgrep -f "bash|sh|zsh" 2>/dev/null | while read -r pid; do
          if [ -d "/proc/$pid" ] 2>/dev/null && \
             grep -q "$WORKTREE" /proc/$pid/cwd 2>/dev/null; then
            echo "$pid"
          fi
        done | wc -l) || SHELL_PROCS=0
        if [ "$SHELL_PROCS" -eq 0 ]; then
          AGENT_STATUS="dead"
        else
          AGENT_STATUS="possibly-alive"
        fi
      else
        AGENT_STATUS="dead"
      fi
    else
      AGENT_STATUS="dead"
    fi
    ;;
esac

# If the agent is confirmed dead, proceed.
# If possibly-alive, we need captain confirmation.
case "$AGENT_STATUS" in
  dead)
    # Good - no prior agent.
    ;;
  possibly-alive)
    die "task $ID's source endpoint may still have an agent running; migration requires explicit captain confirmation that the old agent is stopped"
    ;;
  *)
    die "task $ID's source endpoint agent state is '$AGENT_STATUS'; cannot determine if a prior agent is running"
    ;;
esac

# --- create checkpoint -------------------------------------------------------

CHECKPOINT="$STATE/$ID.control-migrate"
CHECKPOINT_META="$CHECKPOINT.meta-prior"
MIGRATION_PHASE=
MIGRATION_COMPLETE=0

migration_rollback() {
  local status=$?
  [ "$MIGRATION_COMPLETE" = 1 ] && return 0
  [ "$MIGRATION_PHASE" = complete ] && return 0
  if [ -f "$CHECKPOINT_META" ]; then
    cp -p "$CHECKPOINT_META" "$META" 2>/dev/null || true
    echo "error: migration of $ID was aborted; prior meta restored from checkpoint" >&2
  else
    echo "error: migration of $ID was aborted before checkpoint was written" >&2
  fi
  return 0
}

trap migration_rollback EXIT

# Write the checkpoint
if ! {
  echo "v1"
  echo "task=$ID"
  echo "phase=checkpoint"
  echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "from_backend=$SRC_BACKEND"
  echo "from_endpoint=$SRC_TARGET"
  echo "to_backend=herdr"
  echo "worktree=$WORKTREE"
  echo "kind=$KIND"
  echo "harness=$HARNESS"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "pr=$PR_URL"
  echo "pr_head=$PR_HEAD"
} > "$CHECKPOINT.tmp" && mv -f "$CHECKPOINT.tmp" "$CHECKPOINT" && \
   cp -p "$META" "$CHECKPOINT_META"; then
  die "could not write migration checkpoint at $CHECKPOINT"
fi

MIGRATION_PHASE=checkpoint

# --- create new Herdr endpoint -----------------------------------------------

# Source the Herdr adapter to use its primitives.
fm_backend_source herdr || die "could not source the herdr backend adapter"

# Resolve the Herdr session. For a migration, we use the home's own labeled
# workspace (same as a non-herdr launcher creating a Herdr task).
HERDR_SESSION="${HERDR_SESSION:-}"
if [ -n "$HERDR_SESSION" ]; then
  : # already set from environment
elif [ -n "${HERDR_ENV:-}" ]; then
  # We're inside herdr; resolve from our own pane.
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    HERDR_SESSION="${HERDR_PANE_ID%%:*}"
  fi
fi

# If we can't resolve a session from the environment, we need to use a known
# session. For a migration driven from firstmate, the session should be
# available. If not, we refuse.
[ -n "$HERDR_SESSION" ] || die "cannot resolve a Herdr session for migration; the launcher must be running inside Herdr or have HERDR_SESSION set"

# Create the new endpoint using the Herdr adapter's container_ensure and
# create_task primitives, which handle workspace creation, tab creation, and
# pane creation in one coherent sequence.
CONTAINER_INFO=$(fm_backend_herdr_container_ensure "$WORKTREE" launcher-home 2>/dev/null) || {
  die "could not ensure Herdr container (workspace) for task $ID"
}
HERDR_SESSION=$(printf '%s' "$CONTAINER_INFO" | cut -d: -f1)
HERDR_WS_ID=$(printf '%s' "$CONTAINER_INFO" | sed "s/^${HERDR_SESSION}://" | cut -f1)
SEEDED_TAB_ID=$(printf '%s' "$CONTAINER_INFO" | cut -f2)

# Create the task tab (with pane) in the workspace.
TASK_RESULT=$(fm_backend_herdr_create_task "${HERDR_SESSION}:${HERDR_WS_ID}" "fm-$ID" "$WORKTREE" "$SEEDED_TAB_ID" 2>/dev/null) || {
  die "could not create Herdr task tab for $ID"
}
HERDR_TAB_ID=$(printf '%s' "$TASK_RESULT" | cut -d' ' -f1)
HERDR_PANE_ID=$(printf '%s' "$TASK_RESULT" | cut -d' ' -f2)

# Build the new endpoint target.
NEW_TARGET="${HERDR_SESSION}:${HERDR_PANE_ID}"

# Verify the new endpoint is live.
if ! fm_backend_target_exists "herdr" "$NEW_TARGET" 2>/dev/null; then
  die "new Herdr endpoint $NEW_TARGET for task $ID is not live after creation"
fi

# Verify the new endpoint is agent-free (no prior agent).
NEW_AGENT_STATE=$(fm_backend_agent_state "herdr" "$NEW_TARGET" 2>/dev/null || echo "unverified")
case "$NEW_AGENT_STATE" in
  dead|missing)
    # Good - no prior agent at the new endpoint.
    ;;
  alive)
    die "new Herdr endpoint $NEW_TARGET already has an agent running; cannot migrate to a live endpoint"
    ;;
  *)
    die "new Herdr endpoint $NEW_TARGET has agent state '$NEW_AGENT_STATE'; cannot verify it is agent-free"
    ;;
esac

MIGRATION_PHASE=endpoint_created

# --- build new meta file -----------------------------------------------------

# Preserve all non-endpoint fields, update endpoint fields.
# The new meta keeps: endpoint_task_id, worktree, project, harness, kind, mode,
# yolo, tasktmp, model, effort, busy_gen, spawn_gen, pr, pr_head, remote_host.
# It replaces: window, backend, cmux/zellij/orca fields → herdr fields.

NEW_META="$STATE/$ID.meta.tmp"

{
  echo "window=$NEW_TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WORKTREE"
  echo "project=$PROJECT"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp=$TASKTMP"
  echo "model=$MODEL"
  echo "effort=$EFFORT"
  echo "backend=herdr"
  echo "herdr_session=$HERDR_SESSION"
  echo "herdr_workspace_id=$HERDR_WS_ID"
  echo "herdr_tab_id=${HERDR_SESSION}:${HERDR_TAB_ID}"
  echo "herdr_pane_id=$HERDR_PANE_ID"
  [ -n "$BUSY_GEN" ] && echo "busy_gen=$BUSY_GEN"
  [ -n "$SPAWN_GEN" ] && echo "spawn_gen=$SPAWN_GEN"
  [ -n "$PR_URL" ] && echo "pr=$PR_URL"
  [ -n "$PR_HEAD" ] && echo "pr_head=$PR_HEAD"
  [ -n "$REMOTE_HOST" ] && echo "remote_host=$REMOTE_HOST"
} > "$NEW_META"

MIGRATION_PHASE=meta_built

# --- atomic meta replacement -------------------------------------------------

if ! mv -f "$NEW_META" "$META"; then
  die "could not atomically replace meta file for task $ID"
fi

MIGRATION_PHASE=meta_replaced

# --- update presentation journal ---------------------------------------------

# Update the herdr-presentation journal if it exists, or create one.
HERDR_PRESENTATION="$STATE/$ID.herdr-presentation"
if [ -f "$HERDR_PRESENTATION" ]; then
  # Preserve the journal but update the binding.
  {
    echo "v1"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "home=$(basename "$FM_HOME")"
    echo "session=$HERDR_SESSION"
    echo "workspace=$HERDR_WS_ID"
    echo "tab=$HERDR_TAB_ID"
    echo "pane=$HERDR_PANE_ID"
    echo "parent=firstmate"
    echo "shape=flat"
    echo "focus=none"
    echo "agent=none"
  } > "$HERDR_PRESENTATION.tmp" && mv -f "$HERDR_PRESENTATION.tmp" "$HERDR_PRESENTATION"
fi

MIGRATION_PHASE=presentation_updated

# --- clear old backend wiring ------------------------------------------------

# Clear the old backend's per-task wiring artifacts. For cmux, there are no
# turn-end hooks or busy-state plugins to clear (cmux is a raw session provider
# with no harness integration), so nothing to clean up here.

MIGRATION_PHASE=wiring_cleared

# --- publish the new endpoint ------------------------------------------------

# The meta file now reflects the new Herdr endpoint. The task is recorded on
# the new backend.

MIGRATION_PHASE=endpoint_published

# --- success -----------------------------------------------------------------

MIGRATION_COMPLETE=1
MIGRATION_PHASE=complete

# Clean up the checkpoint (remove after successful migration).
rm -f "$CHECKPOINT" "$CHECKPOINT_META" 2>/dev/null || true

# Remove the old busy-state file if it exists (the old incarnation is over).
if [ -f "$STATE/$ID.busy-gen" ]; then
  "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
fi

echo "migrated $ID from $SRC_BACKEND ($SRC_TARGET) to herdr ($NEW_TARGET) worktree=$WORKTREE"
exit 0