#!/usr/bin/env python3
"""ralph-loop-infinite-tsparse.py — Shared UTC timestamp parser.

F-05 remediation: BSD date on macOS parses literal ``Z`` ISO timestamps as
local time, causing fresh PASS records to look ~10h expired. This helper
treats the trailing ``Z`` as UTC on every platform, returns POSIX epoch
seconds, and exposes a within-TTL helper used by stop/session hooks.

Subcommands
-----------
* ``epoch-from-iso ISO_TS``
* ``within-ttl ISO_TS MAX_AGE_SECONDS`` -> prints ``yes`` or ``no``
* ``age-seconds ISO_TS`` -> prints integer seconds since the timestamp
* ``now-iso`` -> prints current UTC ISO 8601 with trailing ``Z``

All subcommands are pure stdlib and never write to disk.
"""

from __future__ import annotations

import sys
import time
from datetime import datetime, timezone


def parse_iso_utc(ts: str) -> float:
    """Return POSIX epoch seconds for an ISO 8601 timestamp string.

    Accepted forms (always interpreted as UTC):
        - 2026-05-19T00:00:00Z
        - 2026-05-19T00:00:00.123456Z
        - 2026-05-19T00:00:00+00:00 / +HH:MM offsets honoured

    Returns 0.0 on parse failure so callers can treat "unknown" as "expired".
    """
    if not ts:
        return 0.0
    raw = ts.strip()
    if not raw:
        return 0.0

    # Normalise trailing Z -> +00:00 so fromisoformat works on every platform.
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"

    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        # Fall back to strict formats Python's fromisoformat may have rejected.
        for fmt in (
            "%Y-%m-%dT%H:%M:%S%z",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S.%f",
        ):
            try:
                dt = datetime.strptime(raw, fmt)
                break
            except ValueError:
                continue
        else:
            return 0.0

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).timestamp()


def within_ttl(ts: str, max_age_seconds: int) -> bool:
    if not ts:
        return False
    issued = parse_iso_utc(ts)
    if issued == 0.0:
        return False
    age = time.time() - issued
    return 0 <= age <= max_age_seconds


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: ralph-loop-infinite-tsparse.py <epoch-from-iso|within-ttl|age-seconds|now-iso>", file=sys.stderr)
        return 2

    cmd = argv[1]
    try:
        if cmd == "epoch-from-iso":
            if len(argv) < 3:
                print("0")
                return 1
            print(int(parse_iso_utc(argv[2])))
            return 0
        if cmd == "within-ttl":
            if len(argv) < 4:
                print("no")
                return 1
            print("yes" if within_ttl(argv[2], int(argv[3])) else "no")
            return 0
        if cmd == "age-seconds":
            if len(argv) < 3:
                print("0")
                return 1
            issued = parse_iso_utc(argv[2])
            if issued == 0.0:
                print("0")
                return 1
            print(int(time.time() - issued))
            return 0
        if cmd == "now-iso":
            print(now_iso())
            return 0
    except Exception as exc:
        print(f"tsparse-error: {exc}", file=sys.stderr)
        return 1

    print(f"unknown subcommand: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
