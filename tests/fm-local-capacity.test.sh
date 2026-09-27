#!/usr/bin/env bash
# Behavior tests for bin/fm-local-capacity.sh and the spawn ceiling that calls it.
#
# Capacity 0, 2, and 3 are claims held by live processes, so the cases do not
# need a harness. Endpoint cases use tmux when it is installed and, otherwise,
# assert that a recorded window which cannot be proved idle still occupies a
# slot. Spawn cases use the shared fake tmux.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TOOL="$ROOT/bin/fm-local-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-capacity)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
MODEL='local-inference-lab/Qwen3.8-Flash-Next-NVFP4'
mkdir -p "$HOME_DIR/config" "$STATE_DIR"
SLOTS=""
TMUX_SESSION=""

cleanup_slots() {
  local pid
  for pid in $SLOTS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  SLOTS=""
  if [ -n "$TMUX_SESSION" ]; then
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    TMUX_SESSION=""
  fi
}
trap 'cleanup_slots; fm_test_cleanup' EXIT

cap() {
  FM_HOME="$HOME_DIR" "$TOOL" "$@"
}

reset_state() {
  cleanup_slots
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
}

field() { # <text> <key>
  printf '%s\n' "$1" | awk -v key="$2" '$1 == key { sub(/^[^ ]+ /, ""); print; exit }'
}

hold() { # <n> <max>
  local i pid out
  for i in $(seq 1 "$1"); do
    sleep 300 &
    pid=$!
    SLOTS="$SLOTS $pid"
    out=$(cap admit --model "$MODEL" --max "$2" --task "slot$i" --pid "$pid")
    assert_contains "$out" '  status: admitted' "slot $i should be admitted under max $2"
  done
}

reset_state
out=$(cap count --model "$MODEL")
assert_contains "$out" '  status: known' "empty home is a known count"
assert_contains "$out" '  active: 0' "empty home has no occupants"
assert_contains "$out" 'non-Firstmate sessions on the local server are not counted' "the count discloses sessions it cannot see"
pass "capacity 0: an empty home has no local occupants"

hold 2 3
out=$(cap count --model "$MODEL")
assert_contains "$out" '  active: 2' "two claims occupy two slots"
out=$(cap admit --model "$MODEL" --max 3 --task slot3 --pid "$$")
assert_contains "$out" '  status: admitted' "the third slot is still open at two occupants"
assert_contains "$out" '  active: 3' "admitting the third reaches the ceiling"
out=$(cap admit --model "$MODEL" --max 3 --task slot4 --pid "$$")
assert_contains "$out" '  status: full' "a fourth admit at the ceiling is refused"
assert_contains "$out" '  active: 3' "a refusal reports the occupants already held"
[ ! -e "$STATE_DIR/local-capacity.d/slot4" ] || fail "a full admit wrote a claim"
pass "capacity 2 admits the next and capacity 3 refuses it"

reset_state
printf 'model=%s\n' "$MODEL" > "$STATE_DIR/mystery.meta"
chmod 000 "$STATE_DIR/mystery.meta"
out=$(cap count --model "$MODEL")
assert_contains "$out" '  status: unknown' "an unreadable task record makes the count unknown"
assert_contains "$out" '  active: -' "unknown does not publish a number"
out=$(cap admit --model "$MODEL" --max 3 --task slot1 --pid "$$")
assert_contains "$out" '  status: unknown' "unknown inventory refuses the admit"
[ ! -e "$STATE_DIR/local-capacity.d/slot1" ] || fail "an unknown admit wrote a claim"
chmod 644 "$STATE_DIR/mystery.meta" || fail "could not restore the unreadable record"
rm -f "$STATE_DIR/mystery.meta"
ln -s "$STATE_DIR/nowhere.meta" "$STATE_DIR/linked.meta"
out=$(cap count --model "$MODEL")
assert_contains "$out" '  status: unknown' "a symlinked task record is not a free slot"
rm -f "$STATE_DIR/linked.meta"
pass "unreadable and symlinked records do not count as a free slot"

reset_state
printf 'model=%s\nremote_host=other.example\nwindow=missing:nope\n' "$MODEL" > "$STATE_DIR/remote1.meta"
printf 'model=some-other-model\nwindow=missing:nope\n' > "$STATE_DIR/other1.meta"
out=$(cap count --model "$MODEL")
assert_contains "$out" '  status: known' "remote and other-model records stay classifiable"
assert_contains "$out" '  active: 0' "a remote worker and a different model do not occupy the local model"
pass "only a matching local record can occupy a slot"

reset_state
sleep 300 &
pid=$!
SLOTS="$pid"
out=$(cap admit --model "$MODEL" --max 3 --task grace1 --pid "$pid")
assert_contains "$out" '  status: admitted' "grace fixture admitted"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
SLOTS=""
out=$(cap count --model "$MODEL")
assert_contains "$out" '  active: 1' "a just-ended claim still holds the launch window"
assert_contains "$out" 'occupant: grace1 via=claim state=grace' "the launch window is named"
touch -t 202001010000 "$STATE_DIR/local-capacity.d/grace1"
out=$(cap count --model "$MODEL")
assert_contains "$out" '  active: 0' "an old claim with a dead pid and no endpoint does not occupy"
pass "a dead claim occupies only during the launch window"

reset_state
mkdir -p "$TMP_ROOT/burst"
burst_pids=""
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  sleep 300 &
  pid=$!
  SLOTS="$SLOTS $pid"
  cap admit --model "$MODEL" --max 3 --task "burst$i" --pid "$pid" > "$TMP_ROOT/burst/$i" &
  burst_pids="$burst_pids $!"
done
for pid in $burst_pids; do
  wait "$pid" || fail "a concurrent admit exited nonzero"
done
admitted=$(grep -h '  status: admitted' "$TMP_ROOT/burst"/* | wc -l | tr -d ' ')
full=$(grep -h '  status: full' "$TMP_ROOT/burst"/* | wc -l | tr -d ' ')
claims=$(find "$STATE_DIR/local-capacity.d" -type f ! -name '.*' | wc -l | tr -d ' ')
[ "$admitted" = 3 ] || fail "concurrent admits accepted $admitted, want 3"
[ "$full" = 5 ] || fail "concurrent admits refused $full, want 5"
[ "$claims" = 3 ] || fail "concurrent admits left $claims claims, want 3"
out=$(cap count --model "$MODEL")
assert_contains "$out" '  active: 3' "the concurrent ceiling is visible to the next count"
pass "concurrent admits stop at the ceiling"

if command -v tmux >/dev/null 2>&1; then
  reset_state
  TMUX_SESSION="fmcap-$$"
  tmux new-session -d -s "$TMUX_SESSION" -n alive0 'exec -a grok-capacity-fixture sleep 300'
  tmux new-window -d -t "$TMUX_SESSION" -n alive1 'exec -a grok-capacity-fixture sleep 300'
  tmux new-window -d -t "$TMUX_SESSION" -n dead0
  tmux new-window -d -t "$TMUX_SESSION" -n amb0 'sleep 300'
  for name in alive0 alive1; do
    printf 'model=%s\nwindow=%s:%s\n' "$MODEL" "$TMUX_SESSION" "$name" > "$STATE_DIR/$name.meta"
  done
  printf 'model=%s\nwindow=%s:dead0\n' "$MODEL" "$TMUX_SESSION" > "$STATE_DIR/dead0.meta"
  printf 'model=%s\nwindow=%s:amb0\n' "$MODEL" "$TMUX_SESSION" > "$STATE_DIR/amb0.meta"
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(cap count --model "$MODEL")
    case "$out" in
      *'occupant: alive0 via=endpoint state=alive'*'occupant: alive1 via=endpoint state=alive'*) ready=1; break ;;
    esac
    sleep 0.2
  done
  [ "$ready" = 1 ] || fail "tmux agents were not proved alive: $out"
  assert_contains "$out" 'occupant: amb0 via=endpoint state=uncertain' "an unclassified pane is not a free slot"
  case "$out" in
    *'occupant: dead0 '*) fail "a shell pane occupied a slot: $out" ;;
  esac
  assert_contains "$out" '  active: 3' "two alive agents plus one uncertain pane fill three slots"
  out=$(cap admit --model "$MODEL" --max 3 --task slot4 --pid "$$")
  assert_contains "$out" '  status: full' "three proved occupants refuse another admit"
  tmux kill-session -t "$TMUX_SESSION"
  TMUX_SESSION=""
  pass "alive, idle, and uncertain endpoints occupy only the proved slots"
else
  reset_state
  printf 'model=%s\nwindow=missing:nope\n' "$MODEL" > "$STATE_DIR/unproved.meta"
  out=$(cap count --model "$MODEL")
  assert_contains "$out" '  status: known' "an unproved endpoint is still a known inventory"
  assert_contains "$out" '  active: 1' "an endpoint that cannot be proved idle occupies a slot"
  assert_contains "$out" 'occupant: unproved via=endpoint state=uncertain' "the unproved endpoint is uncertain"
  pass "without tmux, a recorded window is not treated as a free slot"
fi

# Spawn admits the configured model and releases the claim if launch fails.
reset_state
SPAWN_ROOT="$TMP_ROOT/spawn"
mkdir -p "$SPAWN_ROOT"
FAKEBIN=$(fm_test_make_spawn_fakebin "$SPAWN_ROOT/fake")
fm_test_spawn_home "$HOME_DIR" claude
fm_test_spawn_brief "$HOME_DIR" cap-ok
fm_test_spawn_brief "$HOME_DIR" cap-full
fm_test_spawn_brief "$HOME_DIR" cap-abort
cat > "$HOME_DIR/config/crew-dispatch.json" <<JSON
{
  "rules": [
    {
      "when": "Luna local work.",
      "localPreference": "luna",
      "use": [
        {"harness": "claude", "model": "$MODEL", "localCapacity": {"maxActive": 1}},
        {"harness": "claude", "model": "gpt-6-luna"}
      ]
    }
  ]
}
JSON
PROJ="$SPAWN_ROOT/project"
WT="$SPAWN_ROOT/wt"
fm_git_worktree "$PROJ" "$WT" wt-cap
run_spawn() {
  FM_TEST_CLAUDE_CONFIG_DIR='' \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$@" --mode no-mistakes --yolo off
}

out=$(run_spawn cap-ok "$PROJ" --harness claude --model "$MODEL")
status=$?
expect_code 0 "$status" "a spawn under the ceiling should launch"
[ -f "$STATE_DIR/local-capacity.d/cap-ok" ] || fail "a successful local spawn left no claim"
out=$(run_spawn cap-full "$PROJ" --harness claude --model "$MODEL")
status=$?
[ "$status" -ne 0 ] || fail "a second local spawn at maxActive 1 should be refused"
assert_contains "$out" 'local session capacity refused' "the refusal tells the supervisor to resolve again"
[ ! -e "$STATE_DIR/local-capacity.d/cap-full" ] || fail "a refused spawn left a claim"
cap release --task cap-ok >/dev/null
out=$(run_spawn cap-abort "$SPAWN_ROOT/missing-project" --harness claude --model "$MODEL")
status=$?
[ "$status" -ne 0 ] || fail "a spawn with no project should fail"
case "$out" in
  *'local session capacity refused'*) fail "the failed launch was refused by capacity instead of admitted and released: $out" ;;
esac
[ ! -e "$STATE_DIR/local-capacity.d/cap-abort" ] || fail "a failed spawn left its capacity claim: $out"
pass "spawn admits one local session, refuses the next, and releases a failed launch"

printf '# all fm-local-capacity tests passed\n'
