# revshell + coreview

Reviewer-gated development loops for CLI coding agents — Claude Code, Codex CLI, Gemini CLI.
One canonical copy, symlinked into every runtime's skills directory, so every agent follows
the exact same review contract. No forked prompts per model.

## What's inside

- **`revshell/`** — single-session in-shell review gate. The host agent implements a change,
  then drives a REVIEWER as a blocking subprocess that reviews the diff *before it lands*.
  The reviewer corrects the working tree directly (every edit tagged for implementer review)
  and returns findings + a parseable `VERDICT:` line. Backends behind one shared contract:
  Codex CLI, a Claude subagent, Qwen Code (local MLX or API), DeepSeek Coder (local Ollama,
  findings-only).
- **`coreview/`** — two-session, cross-model plan + implementation review loop. An
  IMPLEMENTER and a REVIEWER collaborate over one on-disk plan file (footer markers +
  background watchers are the whole handoff protocol). Modes: `coreview` (both sides may
  correct each other), `coreviewlight` (reviewer steers only), `shellrev` (single session,
  delegates to revshell). Ends with an autonomous finish sequence.
- **`coreviewlight/`** — pointer skill for the light mode (the implementation lives in
  `coreview/`).

## The commit discipline (the point of all this)

Review rounds **never create commits** — the working tree is the review artifact, and the
diff base is `git merge-base <target> HEAD`. A session lands as:

1. curated, approved commits only (messages describe the change, never the review process),
2. one `--no-ff` merge of the temp branch into the integration branch, then delete the branch,
3. exactly **one** `docs(memory):` commit carrying the session's goal, resolution, learnings.

Enforced mechanically, not just by prose: `coreview/scripts/finish.sh` refuses to merge
branches carrying `wip`/`checkpoint`/`fixup`/review-round subjects (`--squash` or
`--allow-noisy` are the escape hatches), and `coreview/scripts/save-learnings.sh` writes the
memory note, refreshes the project's memory index, and makes the single memory commit.

## Install

```bash
git clone <this-repo-url> ~/skills/revshell-coreview
cd ~/skills/revshell-coreview

# Claude Code
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.claude/skills/

# Codex CLI
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.codex/skills/

# Gemini CLI (adjust to your config's skills dir)
ln -s "$PWD/revshell" "$PWD/coreview" "$PWD/coreviewlight" ~/.gemini/config/skills/
```

Each skill's `SKILL.md` is the contract; `coreview/scripts/TOOLS.md` maps the abstract steps
to each runtime's tools (watchers, agent dispatch, marker appends).

## Configuration

Everything is env-overridable — `COREVIEW_CODEX_MODEL`, `COREVIEW_CODEX_SANDBOX`,
`COREVIEW_CODEX_TIMEOUT`, `QWEN_REVIEW_MODEL`, `DEEPSEEK_MODEL`, `OLLAMA_HOST`,
`REVSHELL_HEARTBEAT_SECONDS`. Defaults are sensible; nothing is hardcoded to a specific
account or model tier.

## Tests

```bash
bash revshell/scripts/test-review-drivers.sh
```

Deterministic and network-free (stubbed backends): concurrency isolation, verdict parsing,
timeout escalation, signal cleanup.
