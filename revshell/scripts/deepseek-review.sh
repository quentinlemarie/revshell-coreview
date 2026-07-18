#!/usr/bin/env bash
# deepseek-review.sh — drive DeepSeek Coder (via local Ollama) as the in-shell
# REVIEWER for `revshell` mode.
#
# Same contract as codex-review.sh and qwen-review.sh: same prompt structure,
# same verdict sentinels, same reviewer-edit tagging protocol.
# DeepSeek does NOT get write access to the repo — it returns findings as text only.
# (Unlike Codex/Qwen which can edit files directly, DeepSeek via Ollama is text-in/text-out.)
#
# Usage:
#   deepseek-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                      [--base <ref>] [--model <ollama-tag>] [--host <url>] \
#                      [--context <file>] [--timeout <secs>]
#
#   --model  Ollama model tag (default: DEEPSEEK_MODEL env or deepseek-coder:33b)
#   --host   Ollama base URL (default: OLLAMA_HOST env or http://localhost:11434)
#
# Prints DeepSeek's findings + VERDICT to stdout.
# Exit status: 0 on clean run; non-zero only on API/network failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

MODEL="${DEEPSEEK_MODEL:-deepseek-coder:33b}"
HOST="${OLLAMA_HOST:-http://localhost:11434}"
TIMEOUT="${DEEPSEEK_REVIEW_TIMEOUT:-1800}"
BASE_DEFAULT="HEAD~1"

VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

PLAN="" ; PHASE="" ; REPO="" ; BASE="$BASE_DEFAULT"
CONTEXT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2";    shift 2 ;;
    --phase)   PHASE="$2";   shift 2 ;;
    --repo)    REPO="$2";    shift 2 ;;
    --base)    BASE="$2";    shift 2 ;;
    --model)   MODEL="$2";   shift 2 ;;
    --host)    HOST="$2";    shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "deepseek-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "deepseek-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "deepseek-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "deepseek-review.sh: plan file not found: $PLAN" >&2; exit 2; }
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "deepseek-review.sh: repo dir not found: $REPO" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "deepseek-review.sh: curl not on PATH" >&2; exit 3; }

# ---- coding conventions (shared contract) ------------------------------------
CONVENTIONS="
Project coding conventions to enforce while reviewing:
1. i18n every USER-FACING string. Internal-only strings (console.log, debug labels) are exempt.
2. Tunable values (magic numbers, model names, URLs, retry counts, timeouts, flags) live in
   centralized constants modules — never inline at call sites. Test assertions exempt.
3. No duplicate logic: reuse/export an existing helper rather than copy-pasting.
   But do NOT abstract prematurely — duplication is cheaper than the wrong abstraction.
4. Exported helpers used by >=2 modules get their own file + a unit test; no utils.ts dumping grounds.
Also: prefer pure functions, validate types at boundaries, never write client names into code."

# ---- build prompt ------------------------------------------------------------
PROMPT_FILE="$(mktemp -t deepseek-review-prompt.XXXXXX)"
trap 'rm -f "$PROMPT_FILE"' EXIT

if [ "$PHASE" = "plan" ]; then
  PLAN_CONTENT="$(cat "$PLAN")"
  cat > "$PROMPT_FILE" <<EOF
You are a senior code reviewer. The implementer wrote the following implementation plan.
Review it as a tough but fair peer. This is PHASE 1 (plan review only) — do NOT suggest
source code edits, only review the plan.

PLAN (at $PLAN):
$PLAN_CONTENT

Your job:
- Flag any load-bearing claims that are wrong or unverifiable.
- Identify missing edge cases, wrong abstractions, risky steps, scope gaps.
- Note any convention violations (see below).
- Be concise. List each issue as: file:line - issue description (CRITICAL/HIGH/MEDIUM/LOW)
  If no file/line applicable, use: general - issue (SEVERITY)

Note: you do NOT have file system access. Review based on the plan text only.
In your reply, include this block:
    REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none
(You cannot edit files directly, so this is always "none" for this backend.)
$CONVENTIONS

End your reply with EXACTLY ONE of these two lines, nothing after it:
VERDICT: $VERDICT_PLAN_GO
VERDICT: $VERDICT_CHANGES
EOF

elif [ "$PHASE" = "code" ]; then
  CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  DIFF_BYTES=${#CODE_DIFF}
  if [ "$DIFF_BYTES" -gt 400000 ]; then
    echo "deepseek-review.sh: diff is large (${DIFF_BYTES} bytes); truncating to 400KB." >&2
    CODE_DIFF="${CODE_DIFF:0:400000}"
  fi
  PLAN_CONTENT="$(cat "$PLAN")"
  cat > "$PROMPT_FILE" <<EOF
You are a senior code reviewer. Review ONLY the unified diff below. Do not explore the
repository or reference past sessions — judge this diff on its own.

Plan context:
$PLAN_CONTENT

Review constraints:
- List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW)
- Focus on real correctness bugs, regressions, convention violations, missing tests.
- Be concise and direct. Skip nitpicks.
- You do NOT have file system access. Findings-only (no direct edits).
- In your reply, include this block exactly:
    REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none
$CONVENTIONS

End your reply with EXACTLY ONE of these two lines, nothing after it:
VERDICT: $VERDICT_SHIP
VERDICT: $VERDICT_CHANGES

=== UNIFIED DIFF (base $BASE) ===
$CODE_DIFF
EOF

else
  echo "deepseek-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
  cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
fi

PROMPT_TEXT="$(cat "$PROMPT_FILE")"

# ---- call Ollama REST API (blocking) -----------------------------------------
PAYLOAD="$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'prompt': sys.argv[2],
    'stream': False,
    'options': {'temperature': 0.1, 'num_predict': 4096},
}))
" "$MODEL" "$PROMPT_TEXT")"

set +e
revshell_make_invocation_id "deepseek" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"
RAW="$(revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" curl -sf "${HOST}/api/generate" -d "$PAYLOAD")"
RC=$?
set -e

if [ "$RC" -eq 124 ]; then
  echo "deepseek-review.sh[$REVIEW_INVOCATION_ID]: request timed out after ${TIMEOUT}s" >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "deepseek-review.sh[$REVIEW_INVOCATION_ID]: curl failed (exit=$RC) — is Ollama running at $HOST?" >&2
  exit 5
fi

# ---- extract response text ---------------------------------------------------
RESULT_TEXT="$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
except json.JSONDecodeError as e:
    print(f'JSON parse error: {e}', file=sys.stderr)
    sys.exit(1)
if d.get('error'):
    print(f'Ollama error: {d[\"error\"]}', file=sys.stderr)
    sys.exit(1)
print(d.get('response', ''), end='')
" "$RAW")"

printf '%s\n' "$RESULT_TEXT"

# ---- parse + emit verdict ----------------------------------------------------
VERDICT_LINE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  BARE="$(printf '%s\n' "$RESULT_TEXT" | grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

echo
echo "==== deepseek-review verdict (phase=$PHASE, model=$MODEL) ===="
echo "$VERDICT_LINE"
