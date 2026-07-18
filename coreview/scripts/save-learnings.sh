#!/usr/bin/env bash
# save-learnings.sh — persist coreview session learnings to the project's VECTORISED
# memory store and refresh the index. Auto-detects the store + refresh command per
# project; improves/creates one if none exists.
#
# Detection priority for the store:
#   1. internal/agents/memory/        (default convention — read by all agents)
#   2. internal/memories/             (alternate convention; writes under internal/memories/coreview/v1/)
#   3. any top-level */memory/ dir that already contains a MEMORY.md
#   4. else CREATE internal/agents/memory/ (+ MEMORY.md) and say no indexer was found
#
# Detection for the refresh/index command:
#   - an npm script named memory:index / memory:reindex / reindex:memory / vectorize
#   - else a runnable indexer at scripts/memory/index.* or <store>/index.*
#   - else warn that no indexer was found (note is still written, just not vectorised)
#
# Usage:
#   save-learnings.sh --repo R --slug kebab-slug --title "Title" \
#       --description "one-line hook" --body-file /path/to/body.md \
#       [--type feedback|project|reference|user] [--dry-run] [--no-commit]
#
#   --dry-run   print the resolved store + index command and exit WITHOUT writing/indexing.
#   --no-commit write + index only; skip the final single docs(memory) commit.
#
# By default this ends the session with EXACTLY ONE `docs(memory):` commit on the current
# branch (dev/test only; docs-only — the sanctioned exception to "never commit directly on
# the base branch", 2026-07-18). It stages and commits ONLY the memory store.

set -euo pipefail

REPO="" ; SLUG="" ; TITLE="" ; DESCRIPTION="" ; BODY_FILE="" ; MTYPE="feedback" ; DRY=0 ; NO_COMMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --body-file) BODY_FILE="$2"; shift 2 ;;
    --type) MTYPE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-commit) NO_COMMIT=1; shift ;;
    *) echo "save-learnings.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$REPO" ] || { echo "save-learnings.sh: --repo required" >&2; exit 2; }
[ -d "$REPO" ] || { echo "save-learnings.sh: repo not found: $REPO" >&2; exit 1; }
cd "$REPO"

# ---- resolve store dir ----
STORE="" ; CREATED=0
if [ -d "internal/agents/memory" ]; then
  STORE="internal/agents/memory"
elif [ -d "internal/memories" ]; then
  STORE="internal/memories/coreview/v1"
else
  # look for any top-level */memory dir with a MEMORY.md index
  while IFS= read -r d; do
    if [ -f "$d/MEMORY.md" ]; then STORE="$d"; break; fi
  done < <(find . -maxdepth 3 -type d -name memory 2>/dev/null | sed 's|^\./||')
  if [ -z "$STORE" ]; then
    STORE="internal/agents/memory"
    CREATED=1
  fi
fi

# ---- resolve index/refresh command ----
INDEX_CMD=""
if [ -f package.json ]; then
  for s in memory:index memory:reindex reindex:memory vectorize memory:vectorize; do
    if grep -qE "\"$s\"[[:space:]]*:" package.json; then INDEX_CMD="npm run $s"; break; fi
  done
fi
if [ -z "$INDEX_CMD" ]; then
  for cand in scripts/memory/index.py scripts/memory/index.js scripts/memory/index.ts "$STORE/index.py" "$STORE/index.js"; do
    if [ -f "$cand" ]; then
      case "$cand" in
        *.py) INDEX_CMD="python3 $cand" ;;
        *.ts) INDEX_CMD="npx tsx $cand" ;;
        *)    INDEX_CMD="node $cand" ;;
      esac
      break
    fi
  done
fi

echo "save-learnings.sh: repo=$REPO"
echo "save-learnings.sh: store=$STORE$([ "$CREATED" = 1 ] && echo ' (will be CREATED)')"
echo "save-learnings.sh: index_cmd=${INDEX_CMD:-<none found — note will be written but NOT vectorised>}"

if [ "$DRY" = 1 ]; then
  echo "save-learnings.sh: --dry-run, nothing written."
  exit 0
fi

[ -n "$SLUG" ] && [ -n "$TITLE" ] && [ -n "$DESCRIPTION" ] && [ -n "$BODY_FILE" ] || {
  echo "save-learnings.sh: --slug, --title, --description and --body-file are required (unless --dry-run)" >&2; exit 2; }
[ -f "$BODY_FILE" ] || { echo "save-learnings.sh: body file not found: $BODY_FILE" >&2; exit 1; }

mkdir -p "$STORE"
NOTE="$STORE/$SLUG.md"
{
  printf -- '---\n'
  printf 'name: %s\n' "$SLUG"
  printf 'description: %s\n' "$DESCRIPTION"
  printf 'metadata:\n  type: %s\n' "$MTYPE"
  printf -- '---\n\n'
  cat "$BODY_FILE"
} > "$NOTE"
echo "save-learnings.sh: wrote $NOTE"

# Maintain the MEMORY.md index (one line per note).
INDEX_MD="$STORE/MEMORY.md"
[ -f "$INDEX_MD" ] || printf '# Memory Index\n\n' > "$INDEX_MD"
if ! grep -qF "($SLUG.md)" "$INDEX_MD"; then
  printf -- '- [%s](%s.md) — %s\n' "$TITLE" "$SLUG" "$DESCRIPTION" >> "$INDEX_MD"
  echo "save-learnings.sh: appended index entry to $INDEX_MD"
fi

# Refresh the vectors.
if [ -n "$INDEX_CMD" ]; then
  echo "save-learnings.sh: refreshing vectors with: $INDEX_CMD"
  eval "$INDEX_CMD"
  echo "save-learnings.sh: vectors refreshed."
else
  echo "save-learnings.sh: NOTE — no indexer found; the note is saved but NOT vectorised. Consider adding a memory:index script to this project." >&2
fi

# The session's single memory commit (docs-only: stages and commits ONLY the store).
if [ "$NO_COMMIT" = 1 ]; then
  echo "save-learnings.sh: --no-commit — memory files left uncommitted."
elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "save-learnings.sh: not a git work tree — nothing to commit."
else
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  case "$BRANCH" in
    dev|test)
      git add -A -- "$STORE"
      if git diff --cached --quiet -- "$STORE"; then
        echo "save-learnings.sh: no memory-store changes to commit."
      else
        git commit -m "docs(memory): $TITLE" -- "$STORE"
        echo "save-learnings.sh: single docs(memory) commit created on '$BRANCH' (NOT pushed)."
      fi
      ;;
    *)
      echo "save-learnings.sh: NOT committing — branch '$BRANCH' is not dev/test. Files are written; commit them (docs-only) from the integration branch." >&2
      ;;
  esac
fi
