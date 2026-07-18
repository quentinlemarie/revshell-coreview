#!/usr/bin/env bash
# finish.sh — guard-railed end-of-loop landing for coreview.
#
# Lands the converged work onto the integration branch in the MAIN checkout, then
# deletes the temp branch. Encodes the global golden-rule guardrails so the
# orchestrator cannot fat-finger a push or a protected-branch commit:
#   - target MUST be `dev` or `test` (never main/master/a production branch);
#   - NEVER pushes;
#   - re-verifies the branch in the same invocation (worktree-flip safety);
#   - deletes the temp branch only after its work is confirmed reachable on target.
#
# The CODE AUDIT + cross-commit compatibility check is the REVIEWER's job (parallel
# agents, described in SKILL.md) and must already have passed before calling this.
#
# Usage:
#   finish.sh --repo <main-checkout> --target <dev|test> --temp-branch <name> \
#             [--squash] [--message <commit-msg>] [--force-delete]
#
#   --squash         squash-merge the temp branch (one commit) instead of --no-ff merge.
#                    Requires --message.
#   --message        commit message (required for --squash; appended to merge commit otherwise).
#   --force-delete   use `git branch -D` for the temp branch (squash-merge case where the
#                    branch shows as un-merged even though its content landed). Default is
#                    safe `-d`, which refuses if the work is not reachable on target.
#   --allow-noisy    skip the review-process-subject refusal (user-approved exception only).
#                    Integration history carries APPROVED commits: subjects containing
#                    wip/checkpoint/fixup/revshell/codex round/round-N are refused otherwise
#                    (curate the temp branch first, or use --squash).
#
# Exit non-zero (and change nothing) on any guardrail violation.

set -euo pipefail

REPO="" ; TARGET="" ; TEMP_BRANCH="" ; SQUASH=0 ; MESSAGE="" ; FORCE_DELETE=0 ; ALLOW_NOISY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --temp-branch) TEMP_BRANCH="$2"; shift 2 ;;
    --squash) SQUASH=1; shift ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --force-delete) FORCE_DELETE=1; shift ;;
    --allow-noisy) ALLOW_NOISY=1; shift ;;
    *) echo "finish.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] && [ -n "$TARGET" ] && [ -n "$TEMP_BRANCH" ] || {
  echo "finish.sh: --repo, --target and --temp-branch are required" >&2; exit 2; }

# Guardrail 1: target must be an allowed integration branch.
case "$TARGET" in
  dev|test) : ;;
  *) echo "finish.sh: REFUSING — target '$TARGET' is not an allowed integration branch (dev|test). Never commit to main/master/a production branch here; use your dedicated promotion flow." >&2; exit 1 ;;
esac
[ "$SQUASH" = 1 ] && [ -z "$MESSAGE" ] && { echo "finish.sh: --squash requires --message" >&2; exit 2; }

cd "$REPO"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "finish.sh: $REPO is not a git work tree" >&2; exit 1; }

echo "finish.sh: checking out $TARGET in $REPO ..."
git checkout "$TARGET"
# Guardrail 2: re-verify the branch in the SAME invocation (worktree flip safety).
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CUR_BRANCH" != "$TARGET" ]; then
  echo "finish.sh: REFUSING — expected to be on '$TARGET' but HEAD is '$CUR_BRANCH'." >&2; exit 1
fi
git status --short --branch

# Record the pre-merge tip so we can print the exact landed commit list at the end.
BASE="$(git rev-parse HEAD)"

# Guardrail: integration history carries only APPROVED commits (2026-07-18).
# Refuse review-process subjects unless --squash collapses them or --allow-noisy overrides.
if [ "$SQUASH" != 1 ] && [ "$ALLOW_NOISY" != 1 ]; then
  NOISY="$(git log --no-merges --pretty='%h %s' "$TARGET..$TEMP_BRANCH" \
    | grep -iE '^[0-9a-f]+ +(wip|checkpoint[0-9]*|fixup)([(:! ]|$)|revshell|codex round|gemini round' || true)"
  if [ -n "$NOISY" ]; then
    echo "finish.sh: REFUSING — temp branch '$TEMP_BRANCH' carries review-process commits that must not reach '$TARGET':" >&2
    echo "$NOISY" >&2
    echo "finish.sh: curate first: git reset --soft \$(git merge-base $TARGET $TEMP_BRANCH) on the temp branch, then commit clean units. Or re-run with --squash --message '<msg>', or --allow-noisy (user-approved exception only)." >&2
    exit 1
  fi
fi

echo "finish.sh: merging temp branch '$TEMP_BRANCH' into '$TARGET' (no push) ..."
if [ "$SQUASH" = 1 ]; then
  git merge --squash "$TEMP_BRANCH"
  git commit -m "$MESSAGE"
else
  if [ -n "$MESSAGE" ]; then
    git merge --no-ff "$TEMP_BRANCH" -m "$MESSAGE"
  else
    git merge --no-ff "$TEMP_BRANCH"
  fi
fi

# Guardrail 3: NEVER push. (Intentionally no `git push` anywhere in this script.)
echo "finish.sh: NOT pushing (by design). Remote is untouched."

# Delete the temp branch now its work is on target.
if [ "$FORCE_DELETE" = 1 ]; then
  echo "finish.sh: force-deleting temp branch '$TEMP_BRANCH' (-D) ..."
  git branch -D "$TEMP_BRANCH"
else
  echo "finish.sh: deleting temp branch '$TEMP_BRANCH' (-d, safe) ..."
  git branch -d "$TEMP_BRANCH" || {
    echo "finish.sh: safe delete refused (branch not detected as merged). If this was a squash-merge and you've confirmed the content landed, re-run with --force-delete." >&2
    exit 1
  }
fi

echo "finish.sh: done. '$TARGET' now contains the work; temp branch '$TEMP_BRANCH' removed; nothing pushed."
echo
echo "finish.sh: ===== COMMIT LIST for the user to decide on (NOT pushed/promoted) ====="
echo "finish.sh: landed on '$TARGET' ($BASE..HEAD):"
git log --oneline "$BASE..HEAD"
echo "finish.sh: ahead of origin/$TARGET by:"
git rev-list --count "origin/$TARGET..$TARGET" 2>/dev/null || echo "(no origin/$TARGET ref)"
echo "finish.sh: ===== the user decides push / promote / further merge from this list ====="
