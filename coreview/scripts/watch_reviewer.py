#!/usr/bin/env python3
"""Wait until the REVIEWER writes a verdict after the latest implementer marker.

Codex implementer use-case: after appending an ``impl: ... ready for review``
marker, run this watcher instead of an ad-hoc background PTY. If a reviewer
marker already landed, it exits immediately; otherwise it blocks until the next
reviewer marker appears.
"""

from __future__ import annotations

import argparse
import re
import signal
import sys
import time
from pathlib import Path


IMPLEMENTER_RE = re.compile(
    r"^[ \t]*<!--\s*(?:impl|claude):\s*.*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

REVIEWER_RE = re.compile(
    r"^[ \t]*<!--\s*(?:review|codex|claude-review|codex-review|gemini-review):\s*.*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

REVIEWER_DETAIL_RE = re.compile(
    r"^[ \t]*<!--\s*(?:review|codex|claude-review|codex-review|gemini-review)-detail:\s*.*?-->[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)


def _latest(pattern: re.Pattern[str], text: str, *, after: int = -1) -> re.Match[str] | None:
    matches = [m for m in pattern.finditer(text) if m.start() > after]
    return matches[-1] if matches else None


def _signature(text: str, after: int) -> tuple[int, str, str]:
    marker = _latest(REVIEWER_RE, text, after=after)
    if marker is None:
        return -1, "", ""
    next_marker = REVIEWER_RE.search(text, marker.end())
    detail_limit = next_marker.start() if next_marker else len(text)
    detail = REVIEWER_DETAIL_RE.search(text, marker.end(), detail_limit)
    return marker.start(), marker.group(0), detail.group(0) if detail else ""


def _report_ready(sig: tuple[int, str, str]) -> None:
    print(f"REVIEWER-ROUND-READY: {sig[1]}", flush=True)
    if sig[2]:
        print(sig[2], flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # MULTI-FILE (2026-06-19): a handoff can land in a sibling artifact, not the
    # file you armed on. Pass EVERY file that can carry a sentinel; per-file state
    # below covers all of them. Prefer one canonical marker file (SKILL.md); this
    # is the safety net.
    parser.add_argument("plan", type=Path, nargs="+", help="One or more plan files to watch")
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument(
        "--allow-interrupt",
        action="store_true",
        help="Allow SIGINT/SIGTERM to stop the watcher.",
    )
    args = parser.parse_args()

    if not args.allow_interrupt:

        def _guarded_stop(signum: int, _frame: object) -> None:
            print(
                f"watch-reviewer: {signal.Signals(signum).name} ignored; "
                "use --allow-interrupt only for an explicit stop/pause.",
                flush=True,
            )

        signal.signal(signal.SIGINT, _guarded_stop)
        signal.signal(signal.SIGTERM, _guarded_stop)

    plans: list[Path] = []
    for plan in args.plan:
        if not plan.exists():
            print(f"watch-reviewer: plan not found: {plan}", file=sys.stderr)
            return 2
        plans.append(plan)

    # Per-file state: {path: {"impl_offset": int, "baseline": signature-tuple}}.
    # Tracked independently so multiple files never flap against each other.
    state: dict[Path, dict[str, object]] = {}
    for plan in plans:
        text = plan.read_text(encoding="utf-8", errors="replace")
        impl = _latest(IMPLEMENTER_RE, text)
        impl_offset = impl.start() if impl else -1
        baseline = _signature(text, impl_offset)
        state[plan] = {"impl_offset": impl_offset, "baseline": baseline}
        if baseline[0] > impl_offset:
            print(f"watch-reviewer: reviewer marker already present in {plan}", flush=True)
            _report_ready(baseline)
            return 0

    print(f"watch-reviewer: armed on {len(plans)} file(s)", flush=True)

    while True:
        time.sleep(args.interval)
        for plan in plans:
            text = plan.read_text(encoding="utf-8", errors="replace")
            st = state[plan]
            impl_offset = st["impl_offset"]  # type: ignore[assignment]
            last = st["baseline"]  # type: ignore[assignment]
            current_impl = _latest(IMPLEMENTER_RE, text)
            current_impl_offset = current_impl.start() if current_impl else -1
            # If the implementer appended another marker from another process, track
            # the new boundary. This avoids firing on stale reviewer text above it.
            if current_impl_offset != impl_offset:
                impl_offset = current_impl_offset
                last = _signature(text, impl_offset)
                st["impl_offset"] = impl_offset
                st["baseline"] = last
                if last[0] > impl_offset:
                    _report_ready(last)
                    return 0
                continue

            current = _signature(text, impl_offset)
            if current != last and current[0] > impl_offset:
                _report_ready(current)
                return 0


if __name__ == "__main__":
    raise SystemExit(main())
