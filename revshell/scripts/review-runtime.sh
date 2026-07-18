#!/usr/bin/env bash
# Shared runtime for revshell reviewer drivers. Source this file; do not execute it.

# Keep progress on stderr so each driver's stdout remains the reviewer response plus
# its parseable terminal VERDICT line.
REVSHELL_HEARTBEAT_SECONDS_DEFAULT=30
REVSHELL_TERM_GRACE_SECONDS_DEFAULT=2
REVSHELL_INVOCATION_COUNTER=0
REVSHELL_CURRENT_INVOCATION_ID=""

revshell_log() {
  printf '[revshell:%s] %s\n' "$1" "$2" >&2
}

revshell_is_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Set REVSHELL_CURRENT_INVOCATION_ID instead of printing it so repeated calls in one
# shell can increment the counter without losing state through command substitution.
revshell_make_invocation_id() {
  local backend="$1"
  local phase="$2"
  local label="${REVSHELL_INVOCATION_LABEL:-${backend}-${phase}}"
  local timestamp

  REVSHELL_INVOCATION_COUNTER=$((REVSHELL_INVOCATION_COUNTER + 1))
  label="$(LC_ALL=C printf '%s' "$label" | tr -c '[:alnum:]_.-' '-')"
  [ -n "$label" ] || label="review"
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  REVSHELL_CURRENT_INVOCATION_ID="${label}-${timestamp}-$$-${REVSHELL_INVOCATION_COUNTER}"
}

revshell_process_group_alive() {
  local pid="$1"
  [ "$pid" -gt 1 ] 2>/dev/null || return 1
  kill -0 -- "-$pid" 2>/dev/null
}

revshell_kill_process_group() {
  local pid="$1"
  local signal_name="$2"
  [ "$pid" -gt 1 ] 2>/dev/null || return 0
  kill "-$signal_name" -- "-$pid" 2>/dev/null || true
}

revshell_restore_trap() {
  local saved_trap="$1"
  local signal_name="$2"
  if [ -n "$saved_trap" ]; then
    eval "$saved_trap"
  else
    trap - "$signal_name"
  fi
}

# Run one reviewer command with an isolated output file and process group.
#
# The call blocks only its own caller. It creates no shared lock or shared filename,
# so other shells and agents can run review rounds concurrently. Start/heartbeat/end
# status goes to stderr; captured reviewer output is emitted unchanged on stdout after
# the command exits. Return 124 on timeout, or the reviewer's own status otherwise.
revshell_run_with_timeout() {
  local invocation_id="$1"
  local secs="$2"
  shift 2

  local heartbeat_seconds="${REVSHELL_HEARTBEAT_SECONDS:-$REVSHELL_HEARTBEAT_SECONDS_DEFAULT}"
  local term_grace_seconds="${REVSHELL_TERM_GRACE_SECONDS:-$REVSHELL_TERM_GRACE_SECONDS_DEFAULT}"
  local out_capture timeout_marker
  local restore_monitor=0
  local cmd_pid=0 watchdog_pid=0 heartbeat_pid=0
  local rc=0 signal_rc=0
  local started_at finished_at elapsed
  local previous_int previous_term previous_hup

  if ! revshell_is_nonnegative_integer "$secs" || [ "$secs" -eq 0 ]; then
    revshell_log "$invocation_id" "invalid timeout '${secs}'; expected a positive integer"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$heartbeat_seconds"; then
    revshell_log "$invocation_id" "invalid REVSHELL_HEARTBEAT_SECONDS '${heartbeat_seconds}'; expected 0 or a positive integer"
    return 125
  fi
  if ! revshell_is_nonnegative_integer "$term_grace_seconds"; then
    revshell_log "$invocation_id" "invalid REVSHELL_TERM_GRACE_SECONDS '${term_grace_seconds}'; expected 0 or a positive integer"
    return 125
  fi

  out_capture="$(mktemp -t revshell-review-out.XXXXXX)"
  timeout_marker="${out_capture}.timeout"
  started_at="$(date '+%s')"

  revshell_log "$invocation_id" "reviewer started (timeout=${secs}s, heartbeat=${heartbeat_seconds}s); this caller waits while other invocations remain concurrent; output buffered safely"

  case "$-" in
    *m*) : ;;
    *) restore_monitor=1; set -m ;;
  esac

  # A private regular file prevents an escaped descendant from holding the caller's
  # stdout pipe open. Job control gives this command its own process group.
  "$@" <&0 >"$out_capture" 2>&1 &
  cmd_pid=$!

  # The watchdog owns no caller output descriptors. TERM allows graceful cleanup;
  # KILL bounds the timeout even when a reviewer or tool child ignores TERM.
  (
    sleep "$secs"
    printf 'timeout\n' > "$timeout_marker"
    revshell_kill_process_group "$cmd_pid" TERM
    if [ "$term_grace_seconds" -gt 0 ]; then sleep "$term_grace_seconds"; fi
    revshell_kill_process_group "$cmd_pid" KILL
  ) </dev/null >/dev/null 2>&1 &
  watchdog_pid=$!

  if [ "$heartbeat_seconds" -gt 0 ]; then
    (
      while :; do
        sleep "$heartbeat_seconds" || exit 0
        revshell_process_group_alive "$cmd_pid" || exit 0
        finished_at="$(date '+%s')"
        elapsed=$((finished_at - started_at))
        revshell_log "$invocation_id" "reviewer still running (elapsed=${elapsed}s; output buffered safely)"
      done
    ) </dev/null >/dev/null &
    heartbeat_pid=$!
  fi

  # Preserve any caller traps. On interruption, signal only this invocation's groups;
  # concurrent revshell processes have distinct IDs, temp files, and process groups.
  previous_int="$(trap -p INT || true)"
  previous_term="$(trap -p TERM || true)"
  previous_hup="$(trap -p HUP || true)"
  trap 'signal_rc=130; revshell_kill_process_group "$cmd_pid" TERM; revshell_kill_process_group "$watchdog_pid" TERM; revshell_kill_process_group "$heartbeat_pid" TERM' INT
  trap 'signal_rc=143; revshell_kill_process_group "$cmd_pid" TERM; revshell_kill_process_group "$watchdog_pid" TERM; revshell_kill_process_group "$heartbeat_pid" TERM' TERM
  trap 'signal_rc=129; revshell_kill_process_group "$cmd_pid" TERM; revshell_kill_process_group "$watchdog_pid" TERM; revshell_kill_process_group "$heartbeat_pid" TERM' HUP

  wait "$cmd_pid" 2>/dev/null || rc=$?
  [ "$signal_rc" -ne 0 ] && rc="$signal_rc"

  revshell_kill_process_group "$watchdog_pid" TERM
  revshell_kill_process_group "$heartbeat_pid" TERM
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$heartbeat_pid" -gt 1 ]; then wait "$heartbeat_pid" 2>/dev/null || true; fi

  # Sweep descendants the reviewer failed to reap. Escalate only if its process group
  # remains alive, so cleanup stays scoped to this invocation.
  if revshell_process_group_alive "$cmd_pid"; then
    revshell_kill_process_group "$cmd_pid" TERM
    if [ "$term_grace_seconds" -gt 0 ]; then sleep "$term_grace_seconds"; fi
    revshell_kill_process_group "$cmd_pid" KILL
  fi

  revshell_restore_trap "$previous_int" INT
  revshell_restore_trap "$previous_term" TERM
  revshell_restore_trap "$previous_hup" HUP
  [ "$restore_monitor" -eq 1 ] && set +m

  [ -f "$timeout_marker" ] && rc=124
  finished_at="$(date '+%s')"
  elapsed=$((finished_at - started_at))
  case "$rc" in
    0)   revshell_log "$invocation_id" "reviewer finished (elapsed=${elapsed}s, exit=0); emitting captured output" ;;
    124) revshell_log "$invocation_id" "reviewer timed out (elapsed=${elapsed}s); emitting captured output" ;;
    *)   revshell_log "$invocation_id" "reviewer failed (elapsed=${elapsed}s, exit=${rc}); emitting captured output" ;;
  esac

  command cat "$out_capture" 2>/dev/null || true
  rm -f "$out_capture" "$timeout_marker"
  return "$rc"
}
