---
name: revshell
description: "REVSHELL — single-session in-shell review gate. The host agent implements a change, then drives a REVIEWER as a blocking subprocess to review the diff BEFORE it lands. ONE shared review contract used by BOTH backends — Codex (via scripts/codex-review.sh) and a Claude review subagent — so review logic is never forked. No second human session or cross-session handoff watcher: the subprocess return IS the handoff. Use when the user says revshell / shellrev, 'review this in shell', 'have codex review this', wants a one-session implement-then-review loop, or as the review gate consumed by other skills (a project fix-gate, coreview's shellrev mode). Review rounds never create commits; approval lands curated commits merged to dev, deletes the temp branch, and ends with ONE memory commit."
---

# revshell — in-shell review gate (shared, model-agnostic)

revshell is the standalone, **shared** review mechanism. The host (the agent in whose
session this runs) implements a change, then gates it through a REVIEWER before landing.
The reviewer runs as a **blocking subprocess in the same session** — its return is the
handoff. There is no second human-driven session or cross-session file watcher.

This is its own skill on purpose: project fix-gate skills and coreview's `shellrev` mode
both consume it. One hardened driver + one review contract that every agent **and** Codex
use — never a second, forked review implementation.

## The shared review contract (BOTH backends use this — do not fork it)

Every revshell review — whether the reviewer is **Codex** or a **Claude subagent** — uses
this exact contract:

- **Input:** the COMPLETE unified diff (base → working tree), **inlined**. The reviewer
  reviews ONLY that diff.
- **Constraints:** do NOT broadly explore/grep the repo; do NOT recall past sessions or
  other repos; judge the diff on its own and answer promptly. The reviewer MAY open a
  couple of the changed files for surrounding context, but must not go hunting.
- **Output:** concise findings, each as `file:line — issue (CRITICAL/HIGH/MEDIUM/LOW)`,
  then a final line that is EXACTLY one of:
  `VERDICT: ready to ship` / `VERDICT: changes requested`.
- **Direct implementation is the MANDATE (both phases).** The reviewer MUST directly
  implement EVERY finding it can fix mechanically itself — edit the plan in Phase 1, edit
  source in Phase 2 — structural fixes included, not just clear one-liners. It never hands
  back a fixable finding for the implementer to apply. It TAGS every edit it makes so the
  implementer reviews it (see *Reviewer direct-edit tagging* below). It reserves a
  *description-without-a-fix* ONLY for items that genuinely need architectural judgement the
  author must make, or user arbitration — those go in the findings. A `changes requested`
  verdict MUST still be accompanied by the reviewer's own self-fixes for everything that was
  mechanically fixable; it is never a substitute for doing the fixes the reviewer can do.

## Reviewer direct-edit tagging (the default — applies to BOTH backends)

When the reviewer corrects something directly, the implementer must be able to see, find,
and judge exactly what the reviewer changed before it lands. So every reviewer edit is
**tagged** two ways:

1. **In the reviewer's output**, a required block headed exactly
   `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` listing each edit as
   `file:line — what changed + why`. This is the canonical, scannable record. If the
   reviewer made no edits, it writes `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED: none`.
2. **Inline, in prose/plan/markdown the reviewer edits**, an ` [reviewer: <reason>]` marker
   on or beside the changed lines. (Do NOT inject marker comments into source code — keep
   source clean; for code the output block + `git diff` is the tag.) Never silently revert
   or rewrite the author's intent — tag, with a reason.

The implementer (the host — implementer and orchestrator are the same session here) then
**reviews every tagged reviewer edit** before landing: `git diff` the reviewer's changes,
re-run focused tests, and explicitly keep or revert each one. This is mandatory **even when
the verdict is `ready to ship`** — a tagged reviewer edit is an implementer-review gate, not
a fix to trust blind.

## Backend A — Codex reviewer (default driver)

This skill OWNS the driver `scripts/codex-review.sh`. It implements the contract above for
Codex and is hardened against the failure modes that made naive `codex exec` unusable:

1. **Session-memory recall flood** — disabled globally in `~/.codex/config.toml`
   (`[features] memories = false`), so Codex no longer recalls thousands of lines of
   unrelated cross-repo history every run. Kept at config level, not per-invocation.
2. **Repo-paging instead of concluding** — fixed by **inlining the diff** with a strict
   "review ONLY this diff, don't explore" prompt and a forced terminal `VERDICT:` line.
3. **Healthy concurrent reviews looking hung** — fixed with per-invocation IDs plus periodic
   elapsed-time heartbeats on stderr while the safely isolated reviewer output is buffered.

```
bash <revshell-skill-dir>/scripts/codex-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <m>] [--sandbox <mode>] [--context <file>] [--timeout <secs>]
```

`<revshell-skill-dir>` resolves from the host runtime's own skills dir (e.g.
`~/.claude/skills/revshell`, `~/.codex/skills/revshell`). It prints the reviewer's findings
then a parseable final `VERDICT: …` line. Defaults: Codex's own configured model (no `-m`
override — hardcoding a model breaks ChatGPT-account Codex), `workspace-write`, portable
timeout. Override the model with `COREVIEW_CODEX_MODEL` / `--model` only when needed.

All script-backed reviewer calls block only their caller; they do **not** acquire a global
lock. Multiple shells or agents can run revshell concurrently. Every invocation gets a unique
ID and reports start, elapsed-time heartbeats, and completion on stderr while preserving stdout
for the review and terminal verdict. Reviewer output is intentionally buffered in a private
per-invocation file until the backend exits, which prevents escaped tool children from holding
a caller's pipe open; that buffering is not serialization or a stalled reviewer. Heartbeats
default to 30 seconds; set `REVSHELL_HEARTBEAT_SECONDS=0` to disable them or another integer to
tune them.

## Backend B — Claude (or other) subagent reviewer

When the reviewer should be a **Claude subagent** — Codex unavailable, or you want a second
perspective / adversarial pass — dispatch the review subagent with the **same contract**:
hand it the inlined diff, the same constraints (review only the diff, no broad exploration,
no cross-session recall), and require the same `file:line — issue (severity)` findings plus
the terminal `VERDICT:` line. Do **not** invent a different review shape — the contract is
shared so a Codex verdict and a Claude verdict mean the same thing.

## Backend C — Qwen Code reviewer (local MLX or API)

When the reviewer should be **Qwen Code** — for a faster local review round on Apple Silicon
via MLX, or to get a second model's perspective without burning Claude quota — use:

```
bash <revshell-skill-dir>/scripts/qwen-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <mlx-model-name>] [--context <file>] [--timeout <secs>]
```

Same flags and contract as `codex-review.sh`; the `--sandbox` flag is omitted (Qwen Code
manages its own tool permissions). Qwen runs from `$REPO` as its working directory.

**MLX local model**: set `--model <name>` to the MLX model identifier (e.g.
`qwen3-30b-a3b-mlx`). If Qwen Code is configured with a local MLX server endpoint
(`QWEN_API_BASE`), the model name routes there automatically. Without `--model`, Qwen Code
uses its own configured default (`qwen3.6`).

Override the default model via `QWEN_REVIEW_MODEL` env var to avoid repeating `--model`
on every call (useful when pinning to a local MLX variant for all review rounds).

## Backend D — DeepSeek Coder reviewer (local Ollama)

When the reviewer should be **DeepSeek Coder** — fully local via Ollama, zero API cost,
good second-opinion on algorithmic correctness and low-level code issues — use:

```
bash <revshell-skill-dir>/scripts/deepseek-review.sh \
     --plan "$PLAN" --phase <plan|code> --repo "$REPO" --base <ref> \
     [--model <ollama-tag>] [--host <url>] [--context <file>] [--timeout <secs>]
```

Available Ollama tags: `deepseek-coder:33b` (18 GB, higher quality) or `deepseek-coder:latest`
(776 MB, fast). Default is `deepseek-coder:33b`; override via `DEEPSEEK_MODEL` env var.

**Key difference from Backends A/C**: DeepSeek via Ollama is **text-in / text-out only** —
it cannot edit files directly. The `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block
will always be `none`; all findings are descriptive. Use Backends A or C when you want the
reviewer to apply fixes; use Backend D for a cheap, fast second opinion.

Override host via `OLLAMA_HOST` (default: `http://localhost:11434`).

## Loop

1. **Phase 1 (optional) — plan review:** `--phase plan` until the verdict is
   `ready for implementation`. The reviewer edits the **plan file** directly by default
   (tagged, per above); no *source* edits / no mutating git in Phase 1.
2. **Implement** the converged change on the temp worktree branch — including
   reviewing/accepting any tagged reviewer edits to the plan. **Do not commit:** the working
   tree is the review artifact; the stable diff base is `$(git merge-base <target> HEAD)`
   (stays correct across mid-loop reconcile merges).
3. **Phase 2 — code review:** `--phase code --base "$(git merge-base <target> HEAD)"` →
   read findings AND the `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:` block → review every
   tagged reviewer edit (`git diff` + focused tests, keep or revert each) → address remaining
   findings as **working-tree edits, never a per-round commit** (subagents for non-trivial
   scope, direct edits for 1–3 mechanical files) → re-verify → re-run.
4. **Ends when the verdict is `ready to ship`.** Then land per the discipline below; never
   push/promote without explicit user ask.

**Convergence guard:** three consecutive `changes requested` on the *same* unresolved point
is a genuine user-arbitration stop — surface it and ask.

## Commit & landing discipline (NON-NEGOTIABLE — all backends/runtimes; 2026-07-18)

- **Review rounds never create commits.** The reviewer corrects the working tree and hands
  it back corrected; the implementer folds fixes in place. No "checkpoint"/"round-N"
  commits — for crash safety keep at most ONE local WIP commit, refreshed with
  `git commit --amend` (temp branches are private, never pushed), squashed away before landing.
- **Land only approved commits.** At `ready to ship`, shape the branch into clean commits
  (`git reset --soft $(git merge-base <target> HEAD)`, then commit coherent units) whose
  messages describe the CHANGE — subjects with `wip`/`checkpoint`/`revshell`/`codex round`
  are refused by finish.sh. Then merge into dev/test and delete the temp branch:
  `bash <revshell-skill-dir>/../coreview/scripts/finish.sh --repo <main-checkout> --target dev
  --temp-branch <name>` (`--squash --message` for a single-unit change).
- **End with exactly ONE memory commit.** After the merge, save the session summary (goal,
  resolution, learnings) via `<revshell-skill-dir>/../coreview/scripts/save-learnings.sh` —
  it writes the note, refreshes vectors, and commits ONLY the memory store as one
  `docs(memory):` commit on the target branch (the sanctioned docs-only exception to "never
  commit directly on the base branch"). No mid-loop `docs(memory)` commits.
- Net history per session: approved commit(s) + one merge + one memory commit.

## Notes

- A host waits for its own blocking review round before consuming that verdict, but independent
  hosts can run rounds concurrently. A round can take minutes; the invocation-ID heartbeat
  distinguishes healthy work from a stall. If it exceeds the timeout the driver returns
  non-zero; re-run or tighten scope (`--base`, or per-area passes for very large diffs — the
  driver warns above ~600 KB).
- The reviewer corrects clear issues directly by default (workspace-write) and tags each
  edit. Treat tagged edits like a subagent's: `git diff` to confirm what changed and re-run
  focused tests before trusting them — the `REVIEWER EDITS — IMPLEMENTER REVIEW REQUIRED:`
  block is your checklist of what to review.
