#!/usr/bin/env bash
# append-marker.sh — write a coreview marker the RIGHT way, every time, for EITHER role.
#
# Generalised from the original append-claude-marker.sh so the host can write its own
# marker whether it is the IMPLEMENTER or the REVIEWER. Fixes two real stall modes
# (2026-06-06), both runtime-agnostic:
#   1. PLACEHOLDER TIMESTAMP — some orchestration runtimes disable Date.now()/new Date(),
#      tempting a hand-typed ISO time that lands EARLIER than the counterpart's last
#      verdict. The counterpart's symmetric watcher compares timestamps to decide whose
#      turn it is and reads the marker as stale → silent stall. This script always stamps
#      a REAL `date -u`.
#   2. MULTIPLE LIVE TRIGGERS — every round appended a fresh marker that ALSO carried the
#      live trigger phrase. With several live copies, the counterpart's watcher latched
#      onto an older one (head-vs-tail scoping) and never saw the newest. This script
#      NEUTRALIZES the trigger phrase in all prior lines OF THIS ACTOR so exactly ONE live
#      trigger remains — the new one, at the footer.
#
# Usage:
#   append-marker.sh <plan-path> <actor> <block-tag> <status-or-verdict> <trigger-phrase> <verdict-note> <detail-note>
#
#   <actor>           impl | review          (role lexeme written into the marker)
#   <block-tag>       coreview-plan-status | coreview-impl-status | coreview-review-status
#                     | coreviewlight-impl-status | coreviewlight-fix-status | coreviewlight-review-status
#   <status-or-verdict>
#                     impl: complete | partial (use partial for any intermediate/incomplete handoff)
#                     review: actual watcher verdict, e.g. "ready for implementation",
#                             "changes requested", or "ready to ship". Do NOT write
#                             review: complete ... - ready for implementation; some
#                             watchers require the verdict immediately after review:.
#   <trigger-phrase>  the canonical phrase the counterpart's watcher greps for, e.g.
#                     "ready for review" (impl→reviewer) or "ready for fixes" (reviewer→impl, light).
#                     Phase 1 plan rounds have no special trigger — pass "" to skip neutralization + append.
#   <verdict-note>    short human note for the verdict line (round number + one-liner)
#   <detail-note>     verbose narrative for the <actor>-detail line
#
# Example (regular-mode Phase 2 round N, host is the implementer):
#   append-marker.sh "$PLAN" impl coreview-impl-status partial "ready for review" \
#     "round 3: both P1s closed at a48f15bd (508 tests pass)" \
#     "Re-review 3cecd1c0..a48f15bd. P1#1 ... P1#2 ..."

set -euo pipefail

PLAN="${1:?plan path required}"
ACTOR="${2:?actor (impl|review) required}"
BLOCK="${3:?block tag required}"
STATUS="${4:?status (complete|partial) required}"
TRIGGER="${5-}"
VERDICT="${6:?verdict note required}"
DETAIL="${7-}"

case "$ACTOR" in
  impl)   COUNTER='(review|codex)';   COUNTER_DETAIL='(review|codex)-detail' ;;
  review) COUNTER='(impl|claude)';    COUNTER_DETAIL='(impl|claude)-detail' ;;
  *) echo "append-marker: actor must be 'impl' or 'review', got '$ACTOR'" >&2; exit 1 ;;
esac

[ -f "$PLAN" ] || { echo "append-marker: plan not found: $PLAN" >&2; exit 1; }

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Guard: ensure the real clock is AFTER the counterpart's last verdict timestamp.
# If not (clock skew / wrong machine), warn loudly — a marker older than the counterpart's
# last verdict will be ignored by the symmetric watcher.
LAST_COUNTER_TS="$(grep -oiE "<!-- ${COUNTER}(-detail)?:[^@]*@ [0-9T:Z+-]+" "$PLAN" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z?' | sort | tail -1 || true)"
if [ -n "$LAST_COUNTER_TS" ] && [ "$TS" \< "$LAST_COUNTER_TS" ]; then
  echo "append-marker: WARNING — new marker $TS is NOT after counterpart's last verdict $LAST_COUNTER_TS; it may be treated as stale." >&2
fi

# (2) Neutralize prior live triggers from THIS actor so exactly ONE live trigger remains.
if [ -n "$TRIGGER" ]; then
  perl -i -pe "s/\Q$TRIGGER\E/(superseded - see latest marker)/g if /^<!-- ${ACTOR}:/" "$PLAN"
fi

# (1)+(3) Append the new block at the FOOTER with a REAL timestamp.
{
  printf '\n<!-- %s -->\n' "$BLOCK"
  if [ -n "$TRIGGER" ]; then
    printf '<!-- %s: %s @ %s - %s - %s -->\n' "$ACTOR" "$STATUS" "$TS" "$VERDICT" "$TRIGGER"
  else
    printf '<!-- %s: %s @ %s - %s -->\n' "$ACTOR" "$STATUS" "$TS" "$VERDICT"
  fi
  [ -n "$DETAIL" ] && printf '<!-- %s-detail: %s -->\n' "$ACTOR" "$DETAIL"
} >> "$PLAN"

echo "append-marker: appended <$BLOCK> $ACTOR marker @ $TS (status=$STATUS, trigger='${TRIGGER:-none}'); prior live triggers from this actor neutralized."
