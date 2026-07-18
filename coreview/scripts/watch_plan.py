#!/usr/bin/env python3
"""Wait until the IMPLEMENTER writes a stable completion marker to a plan file.

Used by runtimes whose background-monitor mechanism is a long-lived process
(e.g. Codex). This helper intentionally has no quiet timeout. In coreview
implementation mode, "nothing happened yet" is not completion; the caller must
keep this process alive until a marker arrives or the user explicitly stops the
watcher.

Codex note: a Codex PTY/exec session is not a push notification channel. If this
script is launched as an ongoing Codex session, the host must poll the session
before every user-visible status/final response and must not leave the turn while
this watcher needed for the task is still running unpolled.

ROLE-NEUTRAL: the implementer's lines are matched as `<!-- impl: ... -->`
(canonical role lexeme) OR the legacy `<!-- claude: ... -->`; the reviewer's
status lines as `<!-- review: ... -->` OR legacy `<!-- codex: ... -->`. Whoever
the user assigned to each role writes the corresponding lines (Claude / Codex /
Gemini). The reviewer runs this watcher to detect the implementer's next round.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import signal
import sys
import time
from datetime import datetime
from pathlib import Path


# Phase 2 handoffs can be `impl: partial ... ready for review` when the only
# remaining partial work is an approved deferral. Treat those as review-ready
# markers in the scoped `coreview-impl-status` block; do not require the literal
# word `complete`. Both the new `ready for review` trigger and the legacy
# `ready for (coreview|codex|claude) review` / `ready for Codex re-review` forms
# are accepted. Some in-flight Phase 1 plans also use descriptive implementer
# statuses such as `claude: design v2 ... ready for Codex re-review`; match those
# when a timestamped implementer marker carries a live review trigger.
IMPLEMENTER_REVIEW_TRIGGER = (
    r"ready\s+for\s+(?:(?:coreview|codex|claude)\s+)?(?:re-?review|review)"
)

IMPL_COMPLETE_RE = re.compile(
    rf"^[ \t]*<!--\s*(?:impl|claude):\s*(?:complete\b|partial\b(?=.*\b{IMPLEMENTER_REVIEW_TRIGGER}\b)|(?=.*@\s*\d{{4}}-\d{{2}}-\d{{2}}T\d{{2}}:\d{{2}}:\d{{2}})(?=.*\b{IMPLEMENTER_REVIEW_TRIGGER}\b)).*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

STATUS_MARKER_RE = re.compile(
    r"^[ \t]*<!--\s*(coreview-impl-status|coreview-review-status|coreview-plan-status|codexreview-status|codex-plan-status)\s*-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

REVIEW_STATUS_RE = re.compile(
    r"^[ \t]*<!--\s*(?:review|codex):\s*(?P<status>ready for implementation|changes requested|ready to ship|implementation staged accepted|implementation changes requested|implementation reviewed)\b.*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

REVIEW_DETAIL_RE = re.compile(
    r"^[ \t]*<!--\s*(?:review|codex)-detail:.*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

TIMESTAMP_RE = re.compile(
    r"@\s*(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:?\d{2})?)"
)

NONTERMINAL_REVIEW_DETAIL_RE = re.compile(
    r"\b(uncommitted|nothing committed|staged(?:\s+index)?|not pushed|not merged)\b",
    re.IGNORECASE,
)


def stat_tuple(path: Path) -> tuple[int, int]:
    st = path.stat()
    return int(st.st_mtime), int(st.st_size)


def latest_match_offset(text: str, pattern: re.Pattern[str]) -> int:
    matches = list(pattern.finditer(text))
    return matches[-1].start() if matches else -1


def latest_match_text(text: str, pattern: re.Pattern[str]) -> str:
    matches = list(pattern.finditer(text))
    return matches[-1].group(0) if matches else ""


def status_marker_before(text: str, offset: int) -> str:
    latest = ""
    for match in STATUS_MARKER_RE.finditer(text):
        if match.start() >= offset:
            break
        latest = match.group(1).lower()
    return latest


def is_marker_for_phase(text: str, match: re.Match[str], phase: str) -> bool:
    if phase == "auto":
        return True
    status = status_marker_before(text, match.start())
    if phase == "implementation":
        return status == "coreview-impl-status"
    if phase == "plan":
        return status not in {"coreview-impl-status", "coreview-review-status"}
    raise ValueError(f"unknown phase: {phase}")


def latest_complete_match(text: str, phase: str) -> re.Match[str] | None:
    matches = [m for m in IMPL_COMPLETE_RE.finditer(text) if is_marker_for_phase(text, m, phase)]
    return matches[-1] if matches else None


def latest_complete_offset(text: str, phase: str) -> int:
    match = latest_complete_match(text, phase)
    return match.start() if match else -1


def latest_complete_marker(text: str, phase: str) -> str:
    match = latest_complete_match(text, phase)
    return match.group(0) if match else ""


def is_review_status_for_phase(text: str, match: re.Match[str], phase: str) -> bool:
    if phase == "auto":
        return True
    status = match.group("status").lower()
    block = status_marker_before(text, match.start())
    # `changes requested` is used in BOTH Phase 1 plan review and Phase 2
    # implementation review. The verdict text alone is ambiguous; use the
    # enclosing status block to classify it. Without this, `--phase
    # implementation --after-latest-review` ignores a Phase 2 `changes requested`
    # marker, then re-detects the previous implementer marker and the reviewer
    # misses the next fix round.
    if block == "coreview-review-status":
        is_impl = True
    elif block == "coreview-plan-status":
        is_impl = False
    else:
        is_impl = status.startswith("implementation ") or status == "ready to ship"
    if phase == "implementation":
        return is_impl
    if phase == "plan":
        return not is_impl
    raise ValueError(f"unknown phase: {phase}")


def latest_review_match(text: str, phase: str) -> re.Match[str] | None:
    matches = [
        m
        for m in REVIEW_STATUS_RE.finditer(text)
        if is_review_status_for_phase(text, m, phase) and not is_nonterminal_review_baseline(text, m, phase)
    ]
    return matches[-1] if matches else None


def latest_review_offset(text: str, phase: str) -> int:
    match = latest_review_match(text, phase)
    return match.start() if match else -1


def review_detail_after_status(text: str, status_match: re.Match[str] | None) -> str:
    if not status_match:
        return ""
    next_status = REVIEW_STATUS_RE.search(text, status_match.end())
    detail_limit = next_status.start() if next_status else len(text)
    detail = REVIEW_DETAIL_RE.search(text, status_match.end(), detail_limit)
    return detail.group(0) if detail else ""


def is_nonterminal_review_baseline(text: str, status_match: re.Match[str], phase: str) -> bool:
    """Bad historical markers should not hide a later commit handoff.

    coreview's terminal implementation marker is valid only after reviewing a
    committed SHA or explicit final artifact. If an older reviewer block says
    `implementation reviewed` but its detail admits the reviewed artifact was
    uncommitted/staged/not pushed/not merged, treat it like a staged acceptance
    for watcher baselining so a later implementer commit/SHA marker is detected.
    """
    if phase != "implementation":
        return False
    status = status_match.group("status").lower()
    if status != "implementation reviewed":
        return False
    detail = review_detail_after_status(text, status_match)
    return bool(NONTERMINAL_REVIEW_DETAIL_RE.search(detail))


def marker_hash(marker: str) -> str:
    return hashlib.sha256(marker.encode("utf-8")).hexdigest() if marker else ""


def timestamp_from_marker(marker: str) -> datetime | None:
    match = TIMESTAMP_RE.search(marker)
    if not match:
        return None
    raw = match.group(1)
    if raw.endswith("Z"):
        raw = f"{raw[:-1]}+00:00"
    if len(raw) >= 5 and (raw[-5] in "+-") and raw[-3] != ":":
        raw = f"{raw[:-2]}:{raw[-2:]}"
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # MULTI-FILE (2026-06-19): a coreview handoff can land in a sibling artifact,
    # not the single file you armed on (this exact miss happened). Pass EVERY file
    # that can carry an implementer completion marker; per-file state covers all of
    # them. Prefer keeping ALL markers in ONE canonical plan file (see SKILL.md) —
    # multi-file is the safety net, not a license to scatter markers.
    parser.add_argument("plan", type=Path, nargs="+", help="One or more coreview plan files")
    parser.add_argument(
        "--phase",
        choices=("auto", "plan", "implementation"),
        default="auto",
        help=(
            "Which implementer completion markers count. implementation means only "
            "markers in coreview-impl-status blocks; plan excludes coreview-impl-status "
            "and coreview-review-status blocks."
        ),
    )
    parser.add_argument("--after-offset", type=int, default=-1, help="Ignore implementer markers at or before this byte offset")
    parser.add_argument(
        "--after-latest-review",
        "--after-latest-codex",
        dest="after_latest_review",
        action="store_true",
        help="On startup, ignore implementer markers at or before the latest reviewer status marker",
    )
    parser.add_argument("--interval", type=float, default=15.0, help="Polling interval in seconds")
    parser.add_argument("--stable-polls", type=int, default=2, help="Required identical stat polls after marker detection")
    parser.add_argument(
        "--allow-interrupt",
        action="store_true",
        help="Allow a single SIGINT/SIGTERM to stop the watcher. Use only after an explicit user stop/pause request.",
    )
    args = parser.parse_args()

    if not args.allow_interrupt:

        def _guarded_stop(signum: int, _frame: object) -> None:
            signal_name = signal.Signals(signum).name
            print(
                f"coreview-watch: {signal_name} ignored; quiet watcher output is not terminal. "
                "Stop/restart this watcher only after an explicit user stop/pause request, "
                "or launch it with --allow-interrupt for a deliberately stoppable session.",
                flush=True,
            )
            return

        signal.signal(signal.SIGINT, _guarded_stop)
        signal.signal(signal.SIGTERM, _guarded_stop)

    plans: list[Path] = []
    for plan in args.plan:
        if not plan.exists():
            print(f"coreview-watch: plan not found: {plan}", file=sys.stderr)
            return 2
        plans.append(plan)

    # Independent per-file baseline + progress state so multiple watched files
    # never flap against each other. --after-offset / --after-latest-review apply
    # per file (offsets are within a file).
    states: dict[Path, dict[str, object]] = {}
    for plan in plans:
        initial_text = plan.read_text(encoding="utf-8", errors="replace")
        initial_marker_offset = latest_complete_offset(initial_text, args.phase)
        initial_marker_hash = marker_hash(latest_complete_marker(initial_text, args.phase))
        initial_review_match = latest_review_match(initial_text, args.phase)
        initial_review_offset = initial_review_match.start() if initial_review_match else -1
        initial_review_time = timestamp_from_marker(
            review_detail_after_status(initial_text, initial_review_match)
        )
        effective_after_offset = args.after_offset
        if args.after_latest_review:
            effective_after_offset = max(effective_after_offset, initial_review_offset)
        states[plan] = {
            "initial_marker_offset": initial_marker_offset,
            "initial_marker_hash": initial_marker_hash,
            "initial_review_time": initial_review_time,
            "effective_after_offset": effective_after_offset,
            "last_stat": stat_tuple(plan),
            "stable_seen": 0,
            "marker_seen": False,
        }
        print(
            f"coreview-watch: watching {plan} phase={args.phase} "
            f"impl_offset={initial_marker_offset} review_offset={initial_review_offset} "
            f"after_offset={effective_after_offset} impl_hash={initial_marker_hash[:12]}",
            flush=True,
        )
    print(
        f"coreview-watch: armed on {len(plans)} file(s); waiting_for=implementer-completion-marker "
        "reviewer-sentinel-ack-is-not-completion. codex/pty sessions are pull-only — poll before "
        "every status/final response.",
        flush=True,
    )

    while True:
        for plan in plans:
            st = states[plan]
            text = plan.read_text(encoding="utf-8", errors="replace")
            marker = latest_complete_marker(text, args.phase)
            marker_offset = latest_complete_offset(text, args.phase)
            current_marker_hash = marker_hash(marker)
            marker_time = timestamp_from_marker(marker)
            eff = st["effective_after_offset"]
            appended_marker = marker_offset > eff
            rewritten_latest_marker = (
                bool(current_marker_hash) and current_marker_hash != st["initial_marker_hash"]
            )
            moved_latest_marker = marker_offset != st["initial_marker_offset"] and marker_offset > eff
            newer_marker_timestamp = (
                marker_offset > eff
                and bool(marker_time)
                and bool(st["initial_review_time"])
                and marker_time > st["initial_review_time"]
            )
            has_new_marker = appended_marker or rewritten_latest_marker or moved_latest_marker or newer_marker_timestamp
            current_stat = stat_tuple(plan)

            if has_new_marker:
                if not st["marker_seen"]:
                    if appended_marker:
                        reason = "new implementer completion marker"
                    elif rewritten_latest_marker:
                        reason = "rewritten implementer completion marker"
                    elif newer_marker_timestamp:
                        reason = "newer implementer completion timestamp"
                    else:
                        reason = "moved implementer completion marker"
                    print(
                        f"coreview-watch: detected {reason} in {plan} at offset {marker_offset} "
                        f"marker_hash={current_marker_hash[:12]}",
                        flush=True,
                    )
                    st["marker_seen"] = True
                if current_stat == st["last_stat"]:
                    st["stable_seen"] = int(st["stable_seen"]) + 1
                else:
                    st["stable_seen"] = 0
                if int(st["stable_seen"]) >= args.stable_polls:
                    print(f"coreview-watch: stable completion in {plan} stat={current_stat[0]} size={current_stat[1]}", flush=True)
                    return 0
            elif current_stat != st["last_stat"]:
                print(f"coreview-watch: file changed {plan} stat={current_stat[0]} size={current_stat[1]}; waiting for implementer completion marker", flush=True)

            st["last_stat"] = current_stat
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
