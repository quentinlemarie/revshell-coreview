#!/usr/bin/env bash
# Deterministic, network-free checks for the revshell driver runtime and verdict contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

TEST_ROOT="$(mktemp -d -t revshell-driver-tests.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F "$expected" "$file" >/dev/null || fail "expected '$expected' in $file"
}

assert_last_line() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(tail -n 1 "$file")"
  [ "$actual" = "$expected" ] || fail "expected last line '$expected' in $file, got '$actual'"
}

process_is_live_non_zombie() {
  local pid="$1"
  local state
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  case "$state" in
    ''|Z*) return 1 ;;
    *) return 0 ;;
  esac
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo" "$TEST_ROOT/barrier"
printf '# Plan A\n' > "$TEST_ROOT/plan-a.md"
printf '# Plan B\n' > "$TEST_ROOT/plan-b.md"

cat > "$TEST_ROOT/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
last_message=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$last_message" ] || exit 91
touch "$REVSHELL_TEST_BARRIER_DIR/$REVSHELL_TEST_STUB_NAME.ready"
attempt=0
while [ ! -f "$REVSHELL_TEST_BARRIER_DIR/$REVSHELL_TEST_STUB_PEER.ready" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 50 ] || exit 92
  sleep 0.1
done
sleep 2
printf '%s\n' \
  'REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none' \
  'VERDICT: ready for implementation'
printf '%s\n' \
  'REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none' \
  'VERDICT: ready for implementation' > "$last_message"
STUB

cat > "$TEST_ROOT/bin/qwen" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
sleep 2
printf '%s\n' '{"type":"result","is_error":false,"result":"REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none\nVERDICT: ready for implementation"}'
STUB

cat > "$TEST_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
sleep 2
printf '%s\n' '{"response":"REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none\nVERDICT: ready for implementation"}'
STUB

chmod +x "$TEST_ROOT/bin/codex" "$TEST_ROOT/bin/qwen" "$TEST_ROOT/bin/curl"

# Two complete Codex-driver calls must overlap without shared locks or output files.
set +e
env PATH="$TEST_ROOT/bin:$PATH" \
  REVSHELL_HEARTBEAT_SECONDS=1 \
  REVSHELL_TEST_BARRIER_DIR="$TEST_ROOT/barrier" \
  REVSHELL_TEST_STUB_NAME=a \
  REVSHELL_TEST_STUB_PEER=b \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/codex-a.out" 2> "$TEST_ROOT/codex-a.err" &
codex_a_pid=$!
env PATH="$TEST_ROOT/bin:$PATH" \
  REVSHELL_HEARTBEAT_SECONDS=1 \
  REVSHELL_TEST_BARRIER_DIR="$TEST_ROOT/barrier" \
  REVSHELL_TEST_STUB_NAME=b \
  REVSHELL_TEST_STUB_PEER=a \
  bash "$SCRIPT_DIR/codex-review.sh" \
    --plan "$TEST_ROOT/plan-b.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/codex-b.out" 2> "$TEST_ROOT/codex-b.err" &
codex_b_pid=$!
codex_a_rc=0
codex_b_rc=0
wait "$codex_a_pid" || codex_a_rc=$?
wait "$codex_b_pid" || codex_b_rc=$?
set -e
[ "$codex_a_rc" -eq 0 ] || fail "first concurrent Codex driver exited $codex_a_rc"
[ "$codex_b_rc" -eq 0 ] || fail "second concurrent Codex driver exited $codex_b_rc"

assert_contains "$TEST_ROOT/codex-a.err" "reviewer started"
assert_contains "$TEST_ROOT/codex-a.err" "other invocations remain concurrent"
assert_contains "$TEST_ROOT/codex-a.err" "reviewer still running"
assert_contains "$TEST_ROOT/codex-a.err" "reviewer finished"
assert_contains "$TEST_ROOT/codex-b.err" "reviewer still running"
assert_last_line "$TEST_ROOT/codex-a.out" "VERDICT: ready for implementation"
assert_last_line "$TEST_ROOT/codex-b.out" "VERDICT: ready for implementation"
if grep -F '[revshell:' "$TEST_ROOT/codex-a.out" "$TEST_ROOT/codex-b.out" >/dev/null; then
  fail "progress leaked into verdict stdout"
fi

codex_a_id="$(sed -n 's/^\[revshell:\([^]]*\)\] reviewer started.*/\1/p' "$TEST_ROOT/codex-a.err" | sed -n '1p')"
codex_b_id="$(sed -n 's/^\[revshell:\([^]]*\)\] reviewer started.*/\1/p' "$TEST_ROOT/codex-b.err" | sed -n '1p')"
[ -n "$codex_a_id" ] || fail "first Codex invocation ID missing"
[ -n "$codex_b_id" ] || fail "second Codex invocation ID missing"
[ "$codex_a_id" != "$codex_b_id" ] || fail "concurrent Codex invocation IDs collided"
if grep -F "$codex_b_id" "$TEST_ROOT/codex-a.err" >/dev/null; then
  fail "second Codex invocation leaked into first progress stream"
fi
if grep -F "$codex_a_id" "$TEST_ROOT/codex-b.err" >/dev/null; then
  fail "first Codex invocation leaked into second progress stream"
fi

# The sibling drivers share the same stderr progress runtime and verdict contract.
env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=1 \
  bash "$SCRIPT_DIR/qwen-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/qwen.out" 2> "$TEST_ROOT/qwen.err"
assert_contains "$TEST_ROOT/qwen.err" "reviewer started"
assert_contains "$TEST_ROOT/qwen.err" "reviewer still running"
assert_last_line "$TEST_ROOT/qwen.out" "VERDICT: ready for implementation"

env PATH="$TEST_ROOT/bin:$PATH" REVSHELL_HEARTBEAT_SECONDS=1 \
  bash "$SCRIPT_DIR/deepseek-review.sh" \
    --plan "$TEST_ROOT/plan-a.md" --phase plan --repo "$TEST_ROOT/repo" --timeout 8 \
    > "$TEST_ROOT/deepseek.out" 2> "$TEST_ROOT/deepseek.err"
assert_contains "$TEST_ROOT/deepseek.err" "reviewer started"
assert_contains "$TEST_ROOT/deepseek.err" "reviewer still running"
assert_last_line "$TEST_ROOT/deepseek.out" "VERDICT: ready for implementation"

# Timeout escalation must return 124 and leave no live child in its process group.
child_pid_file="$TEST_ROOT/timeout-child.pid"
set +e
REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
  revshell_run_with_timeout "timeout-cleanup-test" 1 \
    bash -c 'trap "" TERM; sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; while :; do sleep 1; done' \
    _ "$child_pid_file" \
    > "$TEST_ROOT/timeout.out" 2> "$TEST_ROOT/timeout.err"
timeout_rc=$?
set -e
[ "$timeout_rc" -eq 124 ] || fail "timeout helper returned $timeout_rc instead of 124"
assert_contains "$TEST_ROOT/timeout.err" "reviewer timed out"
[ -s "$child_pid_file" ] || fail "timeout child PID was not recorded"
timeout_child_pid="$(sed -n '1p' "$child_pid_file")"
attempt=0
while process_is_live_non_zombie "$timeout_child_pid"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail "timeout left child $timeout_child_pid alive"
  sleep 0.1
done

# Caller interruption must clean only this invocation's process group and return 143.
signal_child_pid_file="$TEST_ROOT/signal-child.pid"
(
  set +e
  REVSHELL_HEARTBEAT_SECONDS=0 REVSHELL_TERM_GRACE_SECONDS=1 \
    revshell_run_with_timeout "signal-cleanup-test" 20 \
      bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait' \
      _ "$signal_child_pid_file" \
      > "$TEST_ROOT/signal.out" 2> "$TEST_ROOT/signal.err"
  exit $?
) &
signal_runner_pid=$!
attempt=0
while [ ! -s "$signal_child_pid_file" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 50 ]; then
    kill -TERM "$signal_runner_pid" 2>/dev/null || true
    fail "signal child PID was not recorded"
  fi
  sleep 0.1
done
kill -TERM "$signal_runner_pid"
signal_rc=0
wait "$signal_runner_pid" || signal_rc=$?
[ "$signal_rc" -eq 143 ] || fail "interrupted helper returned $signal_rc instead of 143"
assert_contains "$TEST_ROOT/signal.err" "reviewer failed"
signal_child_pid="$(sed -n '1p' "$signal_child_pid_file")"
attempt=0
while process_is_live_non_zombie "$signal_child_pid"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || fail "interruption left child $signal_child_pid alive"
  sleep 0.1
done

printf 'PASS: revshell drivers are observable, concurrent, verdict-safe, and timeout-clean\n'
