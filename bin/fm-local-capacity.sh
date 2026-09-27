#!/usr/bin/env bash
# fm-local-capacity.sh - count and admit local session capacity for one model.
#
# Usage:
#   fm-local-capacity.sh count --model <model>
#   fm-local-capacity.sh admit --model <model> --task <id> --pid <pid> [--max <n>]
#   fm-local-capacity.sh anchor --task <id>
#   fm-local-capacity.sh release --task <id>
#
# This is the session ceiling for an explicit Luna local-capacity profile.
# docs/configuration.md "Crew dispatch profiles" owns the rule fields.
# The count is not a quota reading and never treats unknown quota as healthy.
#
# count prints the number of slots occupied by this model in this local home group.
# A slot is occupied by a provably local Firstmate-owned worker whose recorded
# model matches and whose endpoint is alive, or whose endpoint is ambiguous,
# unreadable, or unverified (those are not free slots). A worker whose
# endpoint is dead or missing does not occupy a slot. A remote_host worker
# is not local and does not occupy a slot.
# An unreadable, symlinked, or otherwise unclassifiable task record or claim
# makes the whole count unknown. Unknown never counts as a free slot.
# Workers outside registered local secondmate homes, and sessions that are not
# Firstmate task records, are not counted. Every result says so.
#
# admit writes a claim under the home's capacity lock so two spawns cannot
# both observe the same free slot. The claim occupies a slot while its pid
# is alive, for 30 seconds after the claim file's mtime (the launch window),
# and after that for as long as the task's own endpoint is not provably dead
# or missing. admit excludes its own task id, so a relaunch of that task
# replaces the claim instead of counting the task twice.
# --max is required only when this home has no crew-dispatch.json profile
# declaring localCapacity for the model. When that profile exists, its
# maxActive is the ceiling and a different --max is refused.
# Zero, one, or two occupants with maxActive 3 admit the next task.
# Three occupants do not.
# unknown and full write no claim.
#
# anchor refreshes the claim mtime after a spawn has launched, so the 30
# second window starts at launch rather than at the earlier admit.
# release removes the claim. A missing claim is still released.
#
# Claims live in $STATE/local-capacity.d/<task-id> and the lock is
# $STATE/.local-capacity.lock. A claim for a provably dead or missing
# endpoint older than the launch window does not occupy a slot, so removing
# the file is not required for the ceiling to open.
#
# Output (stdout):
#   local-capacity:
#     status: known | unknown | admitted | full | anchored | released
#     active: <n> | -
#     model: <model> | -
#     task: <id> | -
#     reason: <text> | -
#     disclosure: non-Firstmate sessions on the local server are not counted, and workers outside this home are not counted
#     occupant: <id> via=<endpoint|claim> state=<alive|uncertain|grace|pid>
#   Exit 0 for every capacity result, including unknown and full.
#   Exit 2 for usage, a bad task id, a bad pid, or a rules-file error.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE select the home,
#   state directory, and rules file the same way as the other fleet scripts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLAIM_DIR="$STATE/local-capacity.d"
LOCK="$STATE/.local-capacity.lock"
GRACE=30
DISCLOSURE='non-Firstmate sessions on the local server are not counted; registered local homes only'
LOCK_HELD=0

if [ -f "$FM_HOME/.fm-secondmate-parent" ] && [ ! -L "$FM_HOME/.fm-secondmate-parent" ]; then
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    LOCK="$FM_SECONDMATE_PARENT_HOME/state/.local-capacity.lock"
  fi
fi

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK" || true
    LOCK_HELD=0
  fi
}
trap cleanup EXIT

lock_on() {
  fm_lock_acquire_wait "$LOCK"
  LOCK_HELD=1
}
lock_off() {
  [ "$LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$LOCK" || true
  LOCK_HELD=0
}

model_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._/+-]*) return 1 ;;
  esac
}

pid_ok() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
}

endpoint_class() { # <meta>
  local window backend state
  window=$(fm_meta_get "$1" window)
  if [ -z "$window" ]; then
    printf 'uncertain'
    return 0
  fi
  backend=$(fm_backend_of_meta "$1")
  state=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null) || state=unreadable
  case "$state" in
    alive|dead|missing) printf '%s' "$state" ;;
    *) printf 'uncertain' ;;
  esac
}

# Sets CAP_STATUS, CAP_ACTIVE, CAP_REASON, and CAP_OCCUPANTS (newline records
# "id via state"). $1 is the model. $2, when non-empty, is a task id excluded
# so admit can replace that task's own claim.
cap_collect() {
  local model=$1 except=${2:-} meta base id remote recorded class claim rest
  local claim_model claim_pid mtime now age via state
  local home parent_home parent_path registry_line
  local home_list="$FM_HOME" original_state=$STATE original_claim_dir=$CLAIM_DIR
  CAP_STATUS=known
  CAP_ACTIVE=0
  CAP_REASON='-'
  CAP_OCCUPANTS=''
  now=$(date +%s) || { CAP_STATUS=unknown; CAP_REASON='clock unreadable'; return 0; }

  add_occupant() { # id via state
    local id=$1 via=$2 state=$3 row identity
    identity="$STATE/$id"
    row="$id|$via|$state|$identity"
    case "
$CAP_OCCUPANTS
" in
      *"|$identity
"*) return 0 ;;
    esac
    CAP_OCCUPANTS="${CAP_OCCUPANTS:+$CAP_OCCUPANTS
}$row"
  }

  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    # shellcheck source=bin/fm-secondmate-parent-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
    if [ -f "$FM_HOME/.fm-secondmate-parent" ] && [ ! -L "$FM_HOME/.fm-secondmate-parent" ] &&
      fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
      parent_path=$(cd "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || parent_path=''
      [ -n "$parent_path" ] || { CAP_STATUS=unknown; CAP_REASON='local parent home is unavailable'; return 0; }
      home_list=$parent_path
    else
      CAP_STATUS=unknown; CAP_REASON='local parent binding is unreadable'; return 0
    fi
  fi
  if [ -e "$home_list/data/secondmates.md" ] || [ -L "$home_list/data/secondmates.md" ]; then
    if [ ! -f "$home_list/data/secondmates.md" ] || [ -L "$home_list/data/secondmates.md" ] || [ ! -r "$home_list/data/secondmates.md" ]; then
      CAP_STATUS=unknown; CAP_REASON='secondmate registry is unreadable'; return 0
    fi
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    while IFS= read -r registry_line || [ -n "$registry_line" ]; do
      case "$registry_line" in '- '*)
        if ! secondmate_registry_parse_line "$registry_line"; then
          CAP_STATUS=unknown; CAP_REASON='secondmate registry has a malformed entry'; return 0
        fi
        [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
        home=$SECONDMATE_REGISTRY_HOME
        [ -d "$home" ] && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || {
          CAP_STATUS=unknown; CAP_REASON='registered local home is unavailable'; return 0;
        }
        [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$SECONDMATE_REGISTRY_ID" ] || {
          CAP_STATUS=unknown; CAP_REASON='registered local home identity is ambiguous'; return 0;
        }
        parent_path=$(cd "$home_list" 2>/dev/null && pwd -P) || parent_path=''
        home=$(cd "$home" 2>/dev/null && pwd -P) || home=''
        [ -n "$home" ] && [ "$home" != "$parent_path" ] || {
          CAP_STATUS=unknown; CAP_REASON='registered local home path is ambiguous'; return 0;
        }
        case "\n$home_list\n" in *"\n$home\n"*) ;; *) home_list="$home_list
$home" ;; esac
        ;;
      esac
    done < "$home_list/data/secondmates.md"
  fi

  while IFS= read -r home; do
  STATE="$home/state"
  CLAIM_DIR="$STATE/local-capacity.d"
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    base=$(basename "$meta")
    id=${base%.meta}
    if [ -L "$meta" ] || [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
      CAP_STATUS=unknown
      CAP_OCCUPANTS=''
      CAP_REASON="task record $base is not a readable regular file"
      return 0
    fi
    fm_task_id_creation_valid "$id" || {
      CAP_STATUS=unknown
      CAP_OCCUPANTS=''
      CAP_REASON="task record $base is not a task id"
      return 0
    }
    [ "$home" = "$FM_HOME" ] && [ "$id" = "$except" ] && continue
    recorded=$(fm_meta_get "$meta" model)
    [ "$recorded" = "$model" ] || continue
    remote=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote" ] || continue
    class=$(endpoint_class "$meta")
    case "$class" in
      alive) add_occupant "$id" endpoint alive ;;
      dead|missing) ;;
      *) add_occupant "$id" endpoint uncertain ;;
    esac
  done

  if [ -d "$CLAIM_DIR" ]; then
    for claim in "$CLAIM_DIR"/*; do
      [ -e "$claim" ] || [ -L "$claim" ] || continue
      id=$(basename "$claim")
      if [ -L "$claim" ] || [ ! -f "$claim" ] || [ ! -r "$claim" ]; then
        CAP_STATUS=unknown
        CAP_OCCUPANTS=''
        CAP_REASON="capacity claim $id is not a readable regular file"
        return 0
      fi
      fm_task_id_creation_valid "$id" || {
        CAP_STATUS=unknown
        CAP_OCCUPANTS=''
        CAP_REASON="capacity claim $id is not a task id"
        return 0
      }
      [ "$home" = "$FM_HOME" ] && [ "$id" = "$except" ] && continue
      claim_model=''
      claim_pid=''
      while IFS= read -r rest || [ -n "$rest" ]; do
        case "$rest" in
          model=*) claim_model=${rest#model=} ;;
          pid=*) claim_pid=${rest#pid=} ;;
        esac
      done <"$claim" || {
        CAP_STATUS=unknown
        CAP_OCCUPANTS=''
        CAP_REASON="capacity claim $id could not be read"
        return 0
      }
      [ "$claim_model" = "$model" ] || {
        [ -n "$claim_model" ] || {
          CAP_STATUS=unknown
          CAP_OCCUPANTS=''
          CAP_REASON="capacity claim $id has no model"
          return 0
        }
        continue
      }
      mtime=$(fm_path_mtime "$claim") || {
        CAP_STATUS=unknown
        CAP_OCCUPANTS=''
        CAP_REASON="capacity claim $id has no mtime"
        return 0
      }
      age=$((now - mtime))
      if pid_ok "$claim_pid" && fm_pid_alive "$claim_pid"; then
        add_occupant "$id" claim pid
        continue
      fi
      if [ "$age" -le "$GRACE" ]; then
        add_occupant "$id" claim grace
        continue
      fi
      meta="$STATE/$id.meta"
      if [ -L "$meta" ]; then
        CAP_STATUS=unknown
        CAP_OCCUPANTS=''
        CAP_REASON="task record $id.meta is not a readable regular file"
        return 0
      fi
      if [ -f "$meta" ] && [ -r "$meta" ]; then
        recorded=$(fm_meta_get "$meta" model)
        remote=$(fm_meta_get "$meta" remote_host)
        if [ "$recorded" = "$model" ] && [ -z "$remote" ]; then
          class=$(endpoint_class "$meta")
          case "$class" in
            alive) add_occupant "$id" endpoint alive ;;
            dead|missing) ;;
            *) add_occupant "$id" endpoint uncertain ;;
          esac
        fi
      fi
    done
  fi
  done <<EOF_CAPACITY_HOMES
$home_list
EOF_CAPACITY_HOMES

  if [ -n "$CAP_OCCUPANTS" ]; then
    CAP_ACTIVE=$(printf '%s\n' "$CAP_OCCUPANTS" | awk 'NF { n++ } END { print n+0 }')
  else
    CAP_ACTIVE=0
  fi
  STATE=$original_state
  CLAIM_DIR=$original_claim_dir
}

emit() { # status active model task reason
  printf 'local-capacity:\n'
  printf '  status: %s\n' "$1"
  printf '  active: %s\n' "$2"
  printf '  model: %s\n' "$3"
  printf '  task: %s\n' "$4"
  printf '  reason: %s\n' "$5"
  printf '  disclosure: %s\n' "$DISCLOSURE"
  if [ -n "$CAP_OCCUPANTS" ]; then
    printf '%s\n' "$CAP_OCCUPANTS" | while IFS='|' read -r id via state identity; do
      [ -n "$id" ] || continue
      printf '  occupant: %s via=%s state=%s\n' "$id" "$via" "$state"
    done
  fi
}

configured_max() { # model; prints maxActive, or returns 1 when this model has no profile
  local file max
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 1
  max=$(jq -r --arg model "$1" '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [ .rules[]? | select(.localPreference == "luna")
      | profiles(.use)[]
      | select(.model == $model and has("localCapacity"))
      | .localCapacity.maxActive ] | unique
    | if length == 1 then .[0] | tostring else "" end
  ' "$file") || return 2
  [ -n "$max" ] || return 1
  printf '%s\n' "$max"
}

write_claim() { # task model max pid
  local tmp
  mkdir -p "$CLAIM_DIR" || return 1
  tmp="$CLAIM_DIR/.$1.tmp.$$"
  printf 'model=%s\nmax=%s\npid=%s\n' "$2" "$3" "$4" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CLAIM_DIR/$1"
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || usage
shift || true
MODEL=''
TASK=''
PID=''
MAX=''
case "$COMMAND" in
  count|admit|anchor|release) ;;
  -h|--help|help) usage ;;
  *) die "unknown command $COMMAND" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --model) [ $# -ge 2 ] || die "--model needs a value"; MODEL=$2; shift 2 ;;
    --task) [ $# -ge 2 ] || die "--task needs a value"; TASK=$2; shift 2 ;;
    --pid) [ $# -ge 2 ] || die "--pid needs a value"; PID=$2; shift 2 ;;
    --max) [ $# -ge 2 ] || die "--max needs a value"; MAX=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown flag $1" ;;
  esac
done

case "$COMMAND" in
  count)
    model_ok "$MODEL" || die "--model must be a non-empty model id"
    lock_on
    cap_collect "$MODEL" ''
    lock_off
    if [ "$CAP_STATUS" = unknown ]; then
      emit unknown - "$MODEL" - "$CAP_REASON"
    else
      emit known "$CAP_ACTIVE" "$MODEL" - "$CAP_REASON"
    fi
    ;;
  admit)
    model_ok "$MODEL" || die "--model must be a non-empty model id"
    fm_task_id_creation_valid "$TASK" || die "--task must be a task id"
    pid_ok "$PID" || die "--pid must be a positive integer"
    fm_pid_alive "$PID" || die "--pid $PID is not running"
    ceiling=''
    if ceiling=$(configured_max "$MODEL"); then
      case "$MAX" in
        '') MAX=$ceiling ;;
        "$ceiling") ;;
        *) die "--max $MAX does not match configured maxActive $ceiling for $MODEL" ;;
      esac
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        die "could not read localCapacity for $MODEL from $CONFIG/crew-dispatch.json"
      fi
      [ -n "$MAX" ] || die "--max is required when no crew-dispatch.json declares localCapacity for $MODEL"
    fi
    case "$MAX" in
      ''|*[!0-9]*|0) die "--max must be an integer from 1 through 99" ;;
    esac
    [ "$MAX" -ge 1 ] && [ "$MAX" -le 99 ] || die "--max must be an integer from 1 through 99"
    lock_on
    cap_collect "$MODEL" "$TASK"
    if [ "$CAP_STATUS" = unknown ]; then
      lock_off
      emit unknown - "$MODEL" "$TASK" "$CAP_REASON"
      exit 0
    fi
    if [ "$CAP_ACTIVE" -ge "$MAX" ]; then
      lock_off
      emit full "$CAP_ACTIVE" "$MODEL" "$TASK" "local capacity full"
      exit 0
    fi
    if ! write_claim "$TASK" "$MODEL" "$MAX" "$PID"; then
      lock_off
      die "could not write the capacity claim for $TASK"
    fi
    cap_collect "$MODEL" ''
    lock_off
    emit admitted "$CAP_ACTIVE" "$MODEL" "$TASK" "local capacity open"
    ;;
  anchor)
    fm_task_id_creation_valid "$TASK" || die "--task must be a task id"
    lock_on
    if [ ! -f "$CLAIM_DIR/$TASK" ] || [ -L "$CLAIM_DIR/$TASK" ]; then
      lock_off
      die "no capacity claim for $TASK"
    fi
    touch "$CLAIM_DIR/$TASK" || { lock_off; die "could not anchor the capacity claim for $TASK"; }
    claim_model=$(awk -F= '$1=="model" { print substr($0, 7); exit }' "$CLAIM_DIR/$TASK") || claim_model=''
    cap_collect "$claim_model" ''
    lock_off
    if [ "$CAP_STATUS" = unknown ]; then
      emit anchored - "$claim_model" "$TASK" "$CAP_REASON"
    else
      emit anchored "$CAP_ACTIVE" "$claim_model" "$TASK" "claim mtime refreshed"
    fi
    ;;
  release)
    fm_task_id_creation_valid "$TASK" || die "--task must be a task id"
    lock_on
    rm -f -- "$CLAIM_DIR/$TASK" || { lock_off; die "could not release the capacity claim for $TASK"; }
    CAP_OCCUPANTS=''
    lock_off
    emit released - - "$TASK" "claim removed"
    ;;
esac
exit 0
