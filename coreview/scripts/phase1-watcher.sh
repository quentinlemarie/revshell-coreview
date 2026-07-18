#!/usr/bin/env bash
# coreview Phase 1 watcher — tracks the LATEST reviewer sentinel across ONE OR MORE plan files.
# Usage: phase1-watcher.sh <plan-path> [<plan-path> ...]
# Emits one stdout line per reviewer-sentinel change. Exits when a verdict contains
# the canonical Phase 1 terminator ("ready for implementation").
# Designed to be invoked from a background-monitor mechanism (Claude: Monitor tool;
# Gemini: background exec) so each stdout line becomes a chat notification.
#
# 2026-06-19 — MULTI-FILE: a coreview round can split its handoff across artifacts
# (design/spec in one file, sentinel markers in another). A single-file watcher then
# watches the wrong file and silently misses the counterpart's turn (this exact miss
# happened). FIX: pass EVERY file that can carry a sentinel and the watcher covers all
# of them. Per-file signature tracking (indexed arrays, bash-3.2 safe) — no cross-file
# flap. Still: prefer keeping ALL markers in ONE canonical plan file (see SKILL.md);
# multi-file is the safety net, not a license to scatter markers.
#
# ROLE-NEUTRAL: the reviewer's verdict line is matched as `<!-- review: ... -->`
# (canonical role lexeme) OR the legacy `<!-- codex: ... -->`. Whoever the user
# assigned as reviewer (Claude / Codex / Gemini) writes these lines.
#
# The awk uses `v=$0` / `d=$0` to capture matched line text (NOT `v=` which would
# assign the empty string and silently break the watcher — that exact mis-transcription
# burnt the v6.7.13 plan-mode round on 2026-05-28). Shipping the watcher as a script
# instead of inline-in-skill prevents the typo from re-occurring.

set -u
[ "$#" -ge 1 ] || { echo "phase1 watcher: at least one plan path required" >&2; exit 2; }
PLANS=("$@")
N=${#PLANS[@]}
for ((i=0;i<N;i++)); do
  [ -f "${PLANS[$i]}" ] || { echo "phase1 watcher: plan not found: ${PLANS[$i]}" >&2; exit 2; }
done

extract_latest_review() {  # $1 = file
  awk '
    /^<!-- (review|codex): /{v=$0}
    /^<!-- (review|codex)-detail: /{d=$0}
    END{printf "%s|%s", v, d}
  ' "$1" 2>/dev/null
}
extract_latest_verdict() {  # $1 = file
  awk '/^<!-- (review|codex): /{v=$0} END{print v}' "$1" 2>/dev/null
}

# Preflight sanity per file: if an implementer line exists but the reviewer extractor
# returns a purely empty signature WHILE reviewer lines exist, the awk is broken.
for ((i=0;i<N;i++)); do
  p="${PLANS[$i]}"
  impl_present=$(awk '/^<!-- (impl|claude): /{c=1} END{print c+0}' "$p" 2>/dev/null)
  sig=$(extract_latest_review "$p")
  if [ "$impl_present" = "1" ] && [ "$sig" = "|" ]; then
    review_present=$(awk '/^<!-- (review|codex): /{c=1} END{print c+0}' "$p" 2>/dev/null)
    if [ "$review_present" = "1" ]; then
      echo "phase1 watcher: BROKEN — reviewer lines exist in $p but extractor returned empty. Awk likely missing \$0." >&2
      exit 3
    fi
  fi
done

# Baseline per-file signatures; surface any already-present terminator.
LAST_SIG=()
shown_verdict=""
for ((i=0;i<N;i++)); do
  p="${PLANS[$i]}"
  LAST_SIG[$i]=$(extract_latest_review "$p")
  v=$(extract_latest_verdict "$p")
  [ -n "$v" ] && shown_verdict="$v"
  if printf '%s' "$v" | grep -qiE 'ready[ _-]?for[ _-]?implementation'; then
    printf 'READY-FOR-IMPLEMENTATION already in reviewer sentinel (%s): %s\n' "$p" "$v"
    exit 0
  fi
done

printf 'phase1 watcher armed on %d file(s); latest reviewer verdict: %s\n' "$N" "$shown_verdict"

while :; do
  for ((i=0;i<N;i++)); do
    p="${PLANS[$i]}"
    cur_signature=$(extract_latest_review "$p")
    if [ "$cur_signature" != "${LAST_SIG[$i]}" ]; then
      LAST_SIG[$i]="$cur_signature"
      verdict=$(extract_latest_verdict "$p")
      if printf '%s' "$verdict" | grep -qiE 'ready[ _-]?for[ _-]?implementation'; then
        printf 'READY-FOR-IMPLEMENTATION sentinel (%s): %s\n' "$p" "$verdict"
        exit 0
      fi
      printf 'reviewer sentinel updated (%s): %s\n' "$p" "$verdict"
    fi
  done
  sleep 2
done
