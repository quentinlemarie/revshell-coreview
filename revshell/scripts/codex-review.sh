#!/usr/bin/env bash
# codex-review.sh — drive Codex as the in-shell REVIEWER for `shellrev` mode.
#
# In shellrev mode the host (Claude) is BOTH orchestrator and IMPLEMENTER and runs
# in a single session: there is no second human-driven Codex session, no plan-file
# marker dance, and no cross-session watcher. Each review round is just a BLOCKING
# `codex exec` subprocess — this script — whose stdout carries Codex's findings and
# whose last line carries a parseable verdict. Codex runs with `workspace-write`, and its
# MANDATE is to directly implement EVERY finding it can fix itself — it edits the plan in
# --phase plan and source in --phase code — and TAGS each edit (a `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block
# in its output, plus an inline `[reviewer: reason]` marker in edited prose/plan). The host
# (implementer) then reviews every tagged edit with `git diff` + focused tests before landing.
#
# Usage:
#   codex-review.sh --plan <plan-path> --phase <plan|code> --repo <worktree-dir> \
#                   [--base <ref>] [--model <m>] [--sandbox <mode>] [--context <file>] \
#                   [--timeout <seconds>]
#
#   --plan      the ONE canonical plan file (Codex reads it; in --phase plan it fixes every fixable issue in it directly, tagged)
#   --phase     plan  → review the PLAN; Codex fixes every fixable plan issue directly (tagged), no source edits
#               code  → review the implemented DIFF; Codex fixes every fixable finding in source directly (tagged)
#   --repo      working root passed to `codex -C` (the temp-branch worktree)
#   --base      git ref the diff is measured against (code phase only; default: HEAD~1)
#   --context   optional file whose contents are appended as extra steering for this round
#               (e.g. the host's "here is what I changed since your last verdict" note)
#
# Prints Codex's full message to stdout, then a final line:  VERDICT: <verdict>
# Exit status is 0 on a clean run regardless of verdict; non-zero only on a Codex
# invocation failure (so the host can distinguish "Codex spoke" from "Codex broke").

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=review-runtime.sh
. "$SCRIPT_DIR/review-runtime.sh"

# ---- centralized, tunable constants -----------------------------------------
# Empty => use Codex's own configured default model (config.toml). Set COREVIEW_CODEX_MODEL
# or --model only to override; hardcoding a model breaks if the user's account lacks it
# (e.g. ChatGPT-account Codex rejects gpt-5-codex).
CODEX_MODEL_DEFAULT="${COREVIEW_CODEX_MODEL:-}"
CODEX_SANDBOX_DEFAULT="${COREVIEW_CODEX_SANDBOX:-workspace-write}"
CODEX_TIMEOUT_DEFAULT="${COREVIEW_CODEX_TIMEOUT:-1800}"   # seconds; a review round can be long
CODEX_BASE_DEFAULT="HEAD~1"
APPROVAL_POLICY="never"                                   # non-interactive: never prompt

# Verdict sentinels Codex is instructed to emit (the host parses these).
VERDICT_PLAN_GO="ready for implementation"
VERDICT_SHIP="ready to ship"
VERDICT_CHANGES="changes requested"

# ---- arg parse ---------------------------------------------------------------
PLAN="" ; PHASE="" ; REPO="" ; BASE="$CODEX_BASE_DEFAULT"
MODEL="$CODEX_MODEL_DEFAULT" ; SANDBOX="$CODEX_SANDBOX_DEFAULT"
CONTEXT_FILE="" ; TIMEOUT="$CODEX_TIMEOUT_DEFAULT"

while [ $# -gt 0 ]; do
  case "$1" in
    --plan)    PLAN="$2"; shift 2 ;;
    --phase)   PHASE="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --base)    BASE="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --sandbox) SANDBOX="$2"; shift 2 ;;
    --context) CONTEXT_FILE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "codex-review.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$PLAN" ]  || { echo "codex-review.sh: --plan is required" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "codex-review.sh: --phase is required (plan|code)" >&2; exit 2; }
[ -f "$PLAN" ]  || { echo "codex-review.sh: plan file not found: $PLAN" >&2; exit 2; }
if [ -z "$REPO" ]; then REPO="$(cd "$(dirname "$PLAN")" && pwd)"; fi
[ -d "$REPO" ]  || { echo "codex-review.sh: repo dir not found: $REPO" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { echo "codex-review.sh: codex CLI not on PATH" >&2; exit 3; }

# ---- build the per-phase prompt into a temp file (avoids bash-3.2 nested-heredoc bugs) ----
PROMPT_FILE="$(mktemp -t coreview-codex-prompt.XXXXXX)"
LAST_MSG="$(mktemp -t coreview-codex-last.XXXXXX)"
trap 'rm -f "$PROMPT_FILE" "$LAST_MSG"' EXIT

# Coding conventions restated for the reviewer (keep in sync with your global agent instructions).
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

if [ "$PHASE" = "plan" ]; then
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a coreview "shellrev" loop. The IMPLEMENTER (another agent) wrote
the plan at: $PLAN
Read that plan IN FULL. This is PHASE 1 (plan convergence) — review the PLAN ONLY.

Your job, as a tough but fair peer:
- Verify load-bearing claims in the plan (file:line references, named symbols) with read-only
  checks against the repo at $REPO. Flag anything unverifiable or wrong.
- Pressure-test the approach: missing edge cases, wrong abstraction, risky steps, scope gaps.
- MANDATE: directly implement EVERY plan issue you can fix yourself by editing the plan file
  (you run with $SANDBOX) — structural gaps included, not just wording. Never hand back a
  fixable issue for the implementer to apply. Reserve a description-without-a-fix ONLY for
  genuine judgement calls / design decisions the author must make, or user arbitration. A
  "$VERDICT_CHANGES" verdict MUST still carry your own plan edits for everything that was fixable.
- TAG every edit you make so the implementer reviews it: (1) inline in the plan, append
  " [reviewer: <reason>]" on or beside each changed line; (2) in your reply, list every
  edit under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits).
  Never silently revert or rewrite the author's intent.
- Do NOT edit any source code in this phase. The plan file is the only artifact you may touch.
EOF
  write_conventions
  cat >> "$PROMPT_FILE" <<EOF

End your reply with EXACTLY ONE of these two lines, on its own line, nothing after it:
VERDICT: $VERDICT_PLAN_GO        (only when the plan is sound enough to implement)
VERDICT: $VERDICT_CHANGES        (when anything still needs to change — list the specifics above)
EOF

elif [ "$PHASE" = "code" ]; then
  # Compute the diff and INLINE it (do not make Codex go explore for it — that, plus
  # session-memory recall, is what made this drown without ever emitting a verdict).
  CODE_DIFF="$(git -C "$REPO" diff "$BASE" 2>/dev/null)"
  DIFF_BYTES=${#CODE_DIFF}
  if [ "$DIFF_BYTES" -gt 600000 ]; then
    echo "codex-review.sh: diff is large (${DIFF_BYTES} bytes); review may be slow — consider a tighter --base or per-area passes." >&2
  fi
  cat > "$PROMPT_FILE" <<EOF
You are the REVIEWER in a coreview "shellrev" loop (PHASE 2: implementation review).
Review ONLY the unified diff at the END of this message. It is the COMPLETE change set
(base $BASE -> working tree of $REPO). Plan context: $PLAN.

HARD CONSTRAINTS — follow these or the review is useless:
- Do NOT broadly explore or grep the repository, and do NOT recall or reference past
  sessions or other repositories. Judge THIS diff on its own and answer promptly.
- You MAY open at most a couple of specific changed files in $REPO for surrounding
  context if strictly needed — but default to the diff; do not go hunting.
- Be concise. List each finding as: file:line - issue (CRITICAL/HIGH/MEDIUM/LOW).
- MANDATE: directly implement EVERY finding you can fix mechanically yourself, by editing
  source in $REPO (sandbox: $SANDBOX) — structural fixes included, not just one-liners. Never
  hand back a fixable finding for the implementer to apply. Reserve a description-without-a-fix
  ONLY for items that genuinely need architectural judgement the author must make, or user
  arbitration. A "$VERDICT_CHANGES" verdict MUST still carry your own self-fixes for everything
  that was mechanically fixable.
- TAG every source edit you make so the implementer reviews it before it lands: list each one
  in your reply under a block headed exactly:
      REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:
  as "file:line — what changed + why" (write "... : none" if you made no edits). Do NOT add
  marker comments into source — keep it clean; your edits + git diff are the record.
- Do not push, merge, or rebase — landing is the host's job.

Find real correctness bugs, regressions to existing callers, convention violations, or
missing tests IN THIS DIFF.
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
  echo "codex-review.sh: --phase must be 'plan' or 'code' (got '$PHASE')" >&2
  exit 2
fi

# Optional round context from the implementer (what changed since Codex's last verdict).
if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
  printf '\n--- ROUND CONTEXT FROM THE IMPLEMENTER ---\n' >> "$PROMPT_FILE"
  cat "$CONTEXT_FILE" >> "$PROMPT_FILE"
fi

# ---- run codex exec (blocking, non-interactive) ------------------------------
# Only pass -m when a model override is set; otherwise inherit Codex's config default.
MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(-m "$MODEL")
revshell_make_invocation_id "codex" "$PHASE"
REVIEW_INVOCATION_ID="$REVSHELL_CURRENT_INVOCATION_ID"

set +e
revshell_run_with_timeout "$REVIEW_INVOCATION_ID" "$TIMEOUT" codex exec \
  -C "$REPO" \
  --skip-git-repo-check \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  -s "$SANDBOX" \
  -c "approval_policy=$APPROVAL_POLICY" \
  -o "$LAST_MSG" \
  - < "$PROMPT_FILE"
RC=$?
set -e

if [ "$RC" -eq 124 ]; then
  echo "codex-review.sh[$REVIEW_INVOCATION_ID]: codex exec timed out after ${TIMEOUT}s" >&2
  exit 4
elif [ "$RC" -ne 0 ]; then
  echo "codex-review.sh[$REVIEW_INVOCATION_ID]: codex exec failed (exit=$RC)" >&2
  exit 5
fi

# ---- parse + normalize the verdict from the last message ---------------------
VERDICT_LINE="$(grep -ioE "VERDICT: *(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" "$LAST_MSG" | tail -1 || true)"
if [ -z "$VERDICT_LINE" ]; then
  # Fall back to a bare sentinel anywhere in the last message.
  BARE="$(grep -ioE "(${VERDICT_PLAN_GO}|${VERDICT_SHIP}|${VERDICT_CHANGES})" "$LAST_MSG" | tail -1 || true)"
  [ -n "$BARE" ] && VERDICT_LINE="VERDICT: $BARE"
fi
[ -z "$VERDICT_LINE" ] && VERDICT_LINE="VERDICT: ${VERDICT_CHANGES} (no explicit verdict parsed — treat as not converged)"

echo
echo "==== codex-review verdict (phase=$PHASE, model=${MODEL:-config-default}) ===="
echo "$VERDICT_LINE"
