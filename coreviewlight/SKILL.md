---
name: coreviewlight
description: Lightweight coreview loop — the REVIEWER only steers (sends findings/instructions) and the IMPLEMENTER writes ALL code (initial build + every fix). coreviewlight is now a MODE of the consolidated `coreview` skill, not a separate implementation. Use when the user says coreviewlight, asks for a lighter/less-redundant coreview, wants one agent to fix while the other reviews only, or "send my code to <agent> to fix while you review".
---

# coreviewlight — a mode of `coreview`

`coreviewlight` is no longer a separate skill body. It is the **`coreviewlight` mode** of the single
common `coreview` skill (shared by Claude, Codex and Gemini via symlinks to this repo's
`coreview/` directory).

**To run it:** load the `coreview` skill and follow its **"Mode: coreviewlight"** section. The canonical
file is `coreview/SKILL.md` in this repo (symlink it into `~/.claude/skills/`, `~/.codex/skills/`,
`~/.gemini/config/skills/`).

In short: do the **Upfront setup** (mode = `coreviewlight`, pick implementer + reviewer + commit target +
temp branch), then the reviewer steers only while the implementer writes everything — review rounds are
working-tree fixes, never commits — loop until the reviewer's `ready to ship`, then run the autonomous
**Finish sequence** (full-code audit → curated approved commits merged to dev/test no-push → delete temp
branch → ONE `docs(memory)` commit with goal/resolution/learnings + refreshed vectors). All marker,
watcher and finish mechanics live in the `coreview` file and `coreview/scripts/` in this repo.
