#!/usr/bin/env python3
"""ralph-loop-infinite-generator.py — autonomous GENERATOR subprocess runner.

Runs the GENERATOR body outside the Stop hook by dispatching explicit Ralph
roles through scripts/ralph-spawn.sh. Stop hook remains a monitor/enforcer: on
FAIL it records verifier state, invokes this runner, then emits remediation
state for the owning session.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
STATE_DIR = HOME / ".claude" / "state"
LOG_FILE = STATE_DIR / "ralph-generator.jsonl"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(event: str, **payload: object) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": now(), "event": event, **payload}, sort_keys=True) + "\n")
    except Exception:
        pass


def read_text(path: str) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8", errors="replace")


def find_spawn(explicit: str) -> Path:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    candidates.extend([
        HOME / ".claude" / "scripts" / "ralph-spawn.sh",
        Path(__file__).resolve().parents[1] / "scripts" / "ralph-spawn.sh",
    ])
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


def run_role(spawn: Path, role: str, task: str, timeout: int, dry_run: bool) -> dict[str, object]:
    if dry_run:
        return {"role": role, "exit_code": 0, "dry_run": True, "stdout": task[:500], "stderr": ""}
    if not spawn.exists():
        return {"role": role, "exit_code": 127, "stdout": "", "stderr": f"spawn script missing: {spawn}"}
    try:
        res = subprocess.run([str(spawn), role, task], text=True, capture_output=True, timeout=timeout)
        return {"role": role, "exit_code": res.returncode, "stdout": res.stdout[-4000:], "stderr": res.stderr[-4000:]}
    except subprocess.TimeoutExpired as exc:
        return {"role": role, "exit_code": 124, "stdout": (exc.stdout or "")[-4000:] if isinstance(exc.stdout, str) else "", "stderr": "timeout"}
    except OSError as exc:
        return {"role": role, "exit_code": 126, "stdout": "", "stderr": str(exc)}


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Ralph GENERATOR subprocess roles")
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--iteration", type=int, required=True)
    ap.add_argument("--original-prompt-file", required=True)
    ap.add_argument("--remediation-file", default="")
    ap.add_argument("--agent-output-file", default="")
    ap.add_argument("--spawn-script", default="")
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("RALPH_GENERATOR_TIMEOUT", "120")))
    ap.add_argument("--roles", default=os.environ.get("RALPH_GENERATOR_ROLES", "analyst,coder,tester"))
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("RALPH_GENERATOR_DRY_RUN", "0") == "1")
    args = ap.parse_args()

    original = read_text(args.original_prompt_file)
    remediation = read_text(args.remediation_file)
    prior = read_text(args.agent_output_file)
    roles = [r.strip() for r in args.roles.split(",") if r.strip()]
    spawn = find_spawn(args.spawn_script)

    base_task = f"""Ralph-Loop-Infinite GENERATOR iteration {args.iteration} for session {args.session_id}.

You are a GENERATOR role. Apply the critique/remediation precisely, create or update real artifacts, run validation, and produce evidence. Do not judge or declare PASS; only the independent JUDGE can exit.

=== ORIGINAL USER PROMPT ===
{original}

=== LAST REMEDIATION / CRITIQUE ===
{remediation}

=== PRIOR AGENT OUTPUT ===
{prior[-8000:]}
"""
    log("generator_start", session_id=args.session_id, iteration=args.iteration, roles=roles, spawn=str(spawn), dry_run=args.dry_run)
    results = []
    for role in roles:
        result = run_role(spawn, role, base_task, args.timeout, args.dry_run)
        results.append(result)
        log("role_complete", session_id=args.session_id, iteration=args.iteration, **result)
        if int(result.get("exit_code", 1)) != 0 and role in {"analyst", "coder"}:
            break
    ok = any(int(r.get("exit_code", 1)) == 0 for r in results)
    print(json.dumps({"session_id": args.session_id, "iteration": args.iteration, "ok": ok, "results": results}, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
