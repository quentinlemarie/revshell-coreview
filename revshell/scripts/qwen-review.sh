#!/usr/bin/env bash
# qwen-review.sh — drive Qwen Code as the in-shell REVIEWER for `revshell` mode.
#
# Parallel to codex-review.sh but uses the `qwen` CLI (local MLX model or API).
# Inherits the SAME review contract as Backend A (Codex): same prompt structure,
# same verdict sentinels, same reviewer-edit tagging protocol.
#
# Usage:
#   qwen-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                  [--base <ref>] [--model <m>] [--context <file>] [--timeout <secs>]
#
#   --plan      the ONE canonical plan file
#   --phase     plan → review the PLAN only; code → review the implemented DIFF
#   --repo      working root (qwen runs from this directory)
#   --base      git ref the diff is measured from (code phase only; default: HEAD~1)
#   --model     model override; for local MLX pass the mlx model name (e.g. qwen3-30b-a3b-mlx)
#               defaults to QWEN_REVIEW_MODEL env var or qwen's own configured default
#   --context   optional file appended as extra steering for this round
#   --timeout   seconds before giving up (default: 1800)
#
# Prints Qwen's full response to stdout, then a final line:  VERDICT: <verdict>
# Exit status: 0 on clean run; non-zero only on qwen invocation failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

# ---- constants ---------------------------------------------------------------
QWEN_MODEL_DEFAULT="${QWEN_REVIEW_MODEL:-}"
QWEN_TIMEOUT_DEFAULT="${QWEN_REVIEW_TIMEOUT:-1800}"
QWEN_BASE_DEFAULT="HEAD~1"

VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

# ---- arg parse ---------------------------------------------------------------
PLAN="" ; PHASE="" ; REPO="" ; BASE="$QWEN_BASE_DEFAULT"
MODEL="$QWEN_MODEL_DEFAULT" ; CONTEXT_FILE="" ; TIMEOUT="$QWEN_TIMEOUT_DEFAULT"

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2";    shift 2 ;;
    --phase)   PHASE="$2";   shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    --base)    BASE="$2";    shift 2 ;;
    --model)   MODEL="$2";   shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "qwen-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "qwen-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "qwen-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "qwen-review.sh: plan file not found: $PLAN" >&2; exit 2; }
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "qwen-review.sh: repo dir not found: $REPO" >&2; exit 2; }
command -v qwen >/dev/null 2>&1 || { echo "qwen-review.sh: qwen CLI not on PATH" >&2; exit 3; }

# ---- coding conventions (shared with codex-review.sh) -----------------------
write_conventions() {
  cat >> "$PROMPT_FILE" <<'EOF'

Project coding conventions to enforce while reviewing:
1. i18n every USER-FACING string (route through the project's t()/translation helper).
   Internal-only strings (console.log, thrown invariant messages, debug labels) are exempt.
2. Tunable values (magic numbers, model names, URLs, retry counts, timeouts, flags) live in
   centralized, scoped constants modules — never inline at call sites. Test assertions exempt.
3. No duplicate logic: reuse/export an existing helper rather than copy-pasting an equivalent.
   But do NOT abstract prematurely — duplication is cheaper than the wrong abstraction.
4. Exported helpers used by >=2 modules get their own single-responsibility file + a unit test;
   no utils.ts/helpers.ts dumping grounds. Private one-module helpers may co-locate.
Also: prefer pure functions, validate types at boundaries, never write client names into code.
EOF
}

# ---- build prompt ------------------------------------------------------------
PROMPT_FILE="$(mktemp -t qwen-review-prompt.XXXXXX)"
RESULT_FILE="$(mktemp -t qwen-review-result.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$RESULT_FILE"' EXIT

if [ "$PHASE" = "plan" ]; then
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop. The IMPLEMENTER wrote the plan at: $PLAN
Read that plan IN FULL. This is PHASE 1 (plan convergence) — review the PLAN ONLY.

Your job, as a tough but fair peer:
- Verify load-bearing claims in the plan (file:line references, named symbols) with read-only
  checks against the repo at $REPO. Flag anything unverifiable or wrong.
- Pressure-test the approach: missing edge cases, wrong abstraction, risky steps, scope gaps.
- MANDATE: directly implement EVERY plan issue you can fix yourself by editing the plan file —
  structural gaps included, not just wording. Never hand back a fixable issue for the implementer
  to apply. Reserve a description-without-a-fix ONLY for genuine judgement calls / design decisions
  the author must make, or user arbitration. A "changes requested" verdict MUST still carry your
  own plan edits for everything that was fixable.
- TAG every edit you make: (1) inline in the plan, append " [reviewer: <reason>]" on or beside
  each changed line; (2) in your reply, list every edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).
- Do NOT edit any source code in this phase.
EOF
  write_conventions
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE of these two lines, on its own line, nothing after it:
VERDICT: $VERDICT_PLAN_GO
VERDICT: $VERDICT_CHANGES
EOF

elif [ "$PHASE" = "code" ]; then
  CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  DIFF_BYTES=${#CODE_DIFF}
  if [ "$DIFF_BYTES" -gt 600000 ]; then
    echo "qwen-review.sh: diff is large (${DIFF_BYTES} bytes); consider a tighter --base." >&2
  fi
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a revshell loop (PHASE 2: implementation review).
Review ONLY the unified diff at the END of this message. It is the COMPLETE change set
(base $BASE -> working tree of $REPO). Plan context: $PLAN

HARD CONSTRAINTS:
- Do NOT broadly explore or grep the repository.
- Do NOT recall or reference past sessions or other repositories.
- You MAY open at most a couple of specific changed files for surrounding context — default to the diff.
- List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW).
- MANDATE: directly implement EVERY finding you can fix mechanically yourself by editing source
  in $REPO — structural fixes included, not just one-liners. Never hand back a fixable finding for
  the implementer to apply. Reserve a description-without-a-fix ONLY for items that genuinely need
  architectural judgement the author must make, or user arbitration. A "changes requested" verdict
  MUST still carry your own self-fixes for everything that was mechanically fixable.
- TAG every source edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).

Find real correctness bugs, regressions, convention violations, or missing tests IN THIS DIFF.
EOF
  write_conventions
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE line, on its own line, nothing after it:
VERDICT: $VERDICT_SHIP
VERDICT: $VERDICT_CHANGES

=== UNIFIED DIFF (base $BASE) ===
EOF
  printf '%s\n' "$CODE_DIFF" >> "$PROMPT_FILE"

else
  echo "qwen-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
  cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# ---- run qwen (blocking, non-interactive, streaming JSON) --------------------
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")
revshell_make_invocation_id "qwen" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"

set +e
revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" \
  bash -c 'cd "$1" && qwen --output-format json ${2:+--model "$2"} < "$3"' \
  _ "$REPO" "$MODEL" "$PROMPT_FILE" \
  > "$RESULT_FILE"
RC=$?
set -e

if [ "$RC" -eq 124 ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: qwen timed out after ${TIMEOUT}s" >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "qwen-review.sh[$REVIEW_INVOCATION_ID]: qwen failed (exit=$RC)" >&2
  cat "$RESULT_FILE" >&2
  exit 5
fi

# ---- extract and print the result text from JSON stream ----------------------
RESULT_TEXT="$(python3 - "$RESULT_FILE" <<'PYEOF'
import sys, json
result_events = []
with open(sys.argv[1], encoding='utf-8') as result_stream:
    for line in result_stream:
        line = line.strip()
        if not line:
            continue
        try:
            chunk = json.loads(line)
            items = chunk if isinstance(chunk, list) else [chunk]
            for item in items:
                if isinstance(item, dict) and item.get('type') == 'result':
                    result_events.append(item)
        except json.JSONDecodeError:
            pass

if not result_events:
    print('[qwen-review: no result event parsed]', file=sys.stderr)
    sys.exit(1)

r = result_events[-1]
if r.get('is_error'):
    print('[qwen-review: result is_error=true]', file=sys.stderr)
    sys.exit(1)
print(r.get('result', ''), end='')
PYEOF
)"

printf '%s\n' "$RESULT_TEXT"

# ---- parse + emit the verdict ------------------------------------------------
VERDICT_LINE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  BARE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

echo
echo "==== qwen-review verdict (phase=$PHASE, model=${MODEL:-qwen-default}) ===="
echo "$VERDICT_LINE"
