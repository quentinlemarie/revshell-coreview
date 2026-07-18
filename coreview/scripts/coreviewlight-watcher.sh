#!/usr/bin/env bash
# DEPRECATED (2026-06-19) — prefer the canonical watchers:
#   * waiting for a REVIEWER verdict (you handed off a plan/design/impl):
#       phase1-watcher.sh <plan> [<plan> ...]   (Phase 1, terminator "ready for implementation")
#       phase2-watcher.sh <plan> [<plan> ...]   (Phase 2, terminator "ready to ship")
#       watch_reviewer.py <plan> [<plan> ...]   (cross-runtime; exits on next reviewer marker)
#   * waiting for an IMPLEMENTER completion marker:
#       watch_plan.py <plan> [<plan> ...] --phase <plan|implementation> --after-latest-review
#
# This script remains only so older invocations keep working. Two failure modes
# it used to have — and why you should use the canonical watchers — are now fixed
# here too:
#   1) It matched ONLY `impl:`/`claude:` lines, so it was BLIND to a counterpart
#      that writes `review:`/`codex:` markers (the exact miss on 2026-06-19). It
#      now tracks ANY counterparty marker (impl|claude|review|codex).
#   2) It watched a SINGLE file, so a handoff that landed in a sibling artifact was
#      missed. It now accepts MULTIPLE plan files.
#
# There is NO auto-terminator here (coreviewlight's host decides ship). Each
# counterparty-marker change is surfaced; the host reviews and decides.
#
# Usage: coreviewlight-watcher.sh <plan-path> [<plan-path> ...]

set -u
[ "$#" -ge 1 ] || { echo "coreviewlight-watcher: at least one plan path required" >&2; exit 2; }
PLANS=("$@")
N=${#PLANS[@]}
for ((i=0;i<N;i++)); do
  [ -f "${PLANS[$i]}" ] || { echo "coreviewlight-watcher: plan not found: ${PLANS[$i]}" >&2; exit 2; }
done

echo "coreviewlight-watcher: DEPRECATED — prefer phase1-watcher.sh / watch_plan.py / watch_reviewer.py (see header). Continuing in compatibility mode." >&2

# Tail-most counterparty marker line in a file. Counterparty roles cover both the
# legacy (impl:/claude:) and canonical (review:/codex:) lexemes so neither side is
# ever invisible. `v=$0` captures the matched LINE (never `v=` — empty-string bug).
extract_latest() {  # $1 = file
  awk '/^<!-- (impl|claude|review|codex): /{v=$0} END{print v}' "$1" 2>/dev/null
}

LAST=()
for ((i=0;i<N;i++)); do LAST[$i]=$(extract_latest "${PLANS[$i]}"); done

printf 'coreviewlight-watcher armed on %d file(s); latest counterparty marker: %s\n' \
  "$N" "$(for ((i=0;i<N;i++)); do extract_latest "${PLANS[$i]}"; done | tail -1)"

while :; do
  for ((i=0;i<N;i++)); do
    cur=$(extract_latest "${PLANS[$i]}")
    if [ "$cur" != "${LAST[$i]}" ]; then
      LAST[$i]="$cur"
      if printf '%s' "$cur" | grep -qiE 'ready[ _-]?for[ _-]?(implementation|review)|ready[ _-]?to[ _-]?ship|changes[ _-]?requested|implementation[ _-]?(staged[ _-]?accepted|reviewed)|fixes[ _-]?complete|accepted'; then
        printf 'COUNTERPARTY-ROUND-READY (%s): %s\n' "${PLANS[$i]}" "$cur"
      else
        printf 'counterparty marker updated (%s): %s\n' "${PLANS[$i]}" "$cur"
      fi
    fi
  done
  sleep 2
done
