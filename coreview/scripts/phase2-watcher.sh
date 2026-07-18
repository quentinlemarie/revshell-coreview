#!/usr/bin/env bash
# coreview Phase 2 watcher — tracks the latest reviewer sentinel INSIDE the most
# recent <!-- coreview-impl-status --> block, across ONE OR MORE plan files.
# Usage: phase2-watcher.sh <plan-path> [<plan-path> ...]
#
# Emits one stdout line per signature change. Exits when the reviewer verdict line
# contains any Phase 2 terminator phrase (ready to ship / ship it / ready for
# implementation in a Phase 2 block / implementation reviewed / accepted).
#
# 2026-06-19 — MULTI-FILE: pass every file that can carry a sentinel; the watcher
# covers all of them with per-file signature tracking (indexed arrays, bash-3.2 safe),
# so a handoff that lands in a sibling artifact is never missed. Prefer ONE canonical
# marker file (SKILL.md); multi-file is the safety net.
#
# ROLE-NEUTRAL: implementer handoff block boundary is `<!-- coreview-impl-status -->`;
# the reviewer verdict line is matched as `<!-- review: ... -->` (canonical) OR the
# legacy `<!-- codex: ... -->`. Whoever the user assigned as reviewer writes these.
#
# Awk uses `v=$0` / `d=$0` — see phase1-watcher.sh notes. Shipping as a script
# prevents the v6.7.x family of transcription bugs.

set -u
[ "$#" -ge 1 ] || { echo "phase2 watcher: at least one plan path required" >&2; exit 2; }
PLANS=("$@")
N=${#PLANS[@]}
for ((i=0;i<N;i++)); do
  [ -f "${PLANS[$i]}" ] || { echo "phase2 watcher: plan not found: ${PLANS[$i]}" >&2; exit 2; }
done

extract_latest_block() {  # $1 = file
  awk '
    BEGIN{in_block=0; v=""; d=""}
    /<!-- coreview-impl-status -->/{in_block=1; v=""; d=""; next}
    # NB: do NOT reset in_block on <!-- coreview-plan-status --> / <!-- codexreview-status -->.
    # Symmetric counterparts write Phase 2 reviews under EITHER <!-- coreview-review-status -->
    # OR the Phase-1 marker name. Resetting on the latter blinded the watcher to
    # `<!-- review: implementation changes requested -->` (missed round, 2026-06-18).
    in_block && /^<!-- (review|codex): /{v=$0}
    in_block && /^<!-- (review|codex)-detail: /{d=$0}
    END{printf "%s|%s", v, d}
  ' "$1" 2>/dev/null
}
extract_latest_verdict() {  # $1 = file
  awk '
    BEGIN{in_block=0; v=""}
    /<!-- coreview-impl-status -->/{in_block=1; v=""; next}
    in_block && /^<!-- (review|codex): /{v=$0}
    END{print v}
  ' "$1" 2>/dev/null
}

TERMINATORS='ready[ _-]?to[ _-]?ship|ship[ _-]?it|ready[ _-]?for[ _-]?implementation|implementation[ _-]?reviewed|^<!-- (review|codex): accepted'

# Baseline per-file signatures; surface any already-present terminator.
LAST_SIG=()
shown_verdict=""
for ((i=0;i<N;i++)); do
  p="${PLANS[$i]}"
  LAST_SIG[$i]=$(extract_latest_block "$p")
  v=$(extract_latest_verdict "$p")
  [ -n "$v" ] && shown_verdict="$v"
  if printf '%s' "$v" | grep -qiE 'ready[ _-]?to[ _-]?ship|ship[ _-]?it'; then
    printf 'READY-TO-SHIP already present (%s): %s\n' "$p" "$v"
    exit 0
  fi
done

printf 'phase2 watcher armed on %d file(s); latest reviewer verdict below coreview-impl-status: %s\n' "$N" "$shown_verdict"

while :; do
  for ((i=0;i<N;i++)); do
    p="${PLANS[$i]}"
    cur_signature=$(extract_latest_block "$p")
    if [ "$cur_signature" != "${LAST_SIG[$i]}" ]; then
      LAST_SIG[$i]="$cur_signature"
      verdict=$(extract_latest_verdict "$p")
      if printf '%s' "$verdict" | grep -qiE "$TERMINATORS"; then
        printf 'READY-TO-SHIP sentinel (%s): %s\n' "$p" "$verdict"
        exit 0
      fi
      printf 'reviewer review-status updated (%s): %s\n' "$p" "$verdict"
    fi
  done
  sleep 2
done
