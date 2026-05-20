#!/usr/bin/env python3
"""ralph-loop-infinite-generator.py — typed GENERATOR subprocess runner.

This is an optional executor backend for the first-class GENERATE stage in
ralph-loop-infinite-ralph.py. It dispatches required roles and returns typed
stage outputs; success requires every required role artifact, not merely one
role exiting 0.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HOME = Path(os.environ.get("HOME", str(Path.home())))
STATE_DIR = HOME / ".claude" / "state"
SUB_AGENTS_DIR = HOME / ".sub-agents"
COUNCIL_DIR = SUB_AGENTS_DIR / "council"    # council-of-3 worker prompts: analyst-programmer, researcher, solutions-architect, qa-verifier, cleanup-agent, hos-orchestrator
HIERARCHY_DIR = SUB_AGENTS_DIR / "hierarchy"  # effort_cascade.yaml + role_matrix.yaml (effort scaling, role definitions)
LOG_FILE = STATE_DIR / "ralph-generator.jsonl"
ARTIFACT_DIR = STATE_DIR / "ralph-generator-artifacts"
REQUIRED_DEFAULT_ROLES = ("orchestrator", "coder", "tester")
ROLE_GCJ = {
    "orchestrator": "GENERATOR",
    "coder": "GENERATOR",
    "solution-architect": "GENERATOR",
    "researcher": "GENERATOR",
    "senior-sme": "GENERATOR",
    "analyst-generator": "GENERATOR",
    "analyst-programmer": "GENERATOR",  # council/analyst-programmer.md
    "cleanup-agent": "GENERATOR",        # council/cleanup-agent.md
    "tester": "CRITIC",
    "qa-verifier": "CRITIC",
    "analyst-critic": "CRITIC",
}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_mode_enabled() -> bool:
    return os.environ.get("RALPH_TEST_MODE", "0") == "1"


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
    candidates: list[Path] = []
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


def normalize_roles(raw: str) -> list[str]:
    roles = [r.strip() for r in raw.split(",") if r.strip()]
    return roles or list(REQUIRED_DEFAULT_ROLES)


def evidence_path(session_id: str, iteration: int, role: str) -> Path:
    safe_session = "".join(c if c.isalnum() or c in "_.-" else "-" for c in session_id)[:80] or "unknown"
    safe_role = "".join(c if c.isalnum() or c in "_.-" else "-" for c in role)[:40]
    return ARTIFACT_DIR / f"{safe_session}-iter{iteration}-{safe_role}.json"


def write_role_artifact(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass


def run_role(spawn: Path, role: str, task: str, timeout: int, dry_run: bool, session_id: str, iteration: int) -> dict[str, Any]:
    gcj = ROLE_GCJ.get(role, "UNKNOWN")
    ev_path = evidence_path(session_id, iteration, role)
    started = now()
    if dry_run:
        if not test_mode_enabled():
            result = {"role": role, "gcj": gcj, "exit_code": 2, "dry_run": True, "stdout": "", "stderr": "dry-run requires RALPH_TEST_MODE=1"}
        else:
            result = {"role": role, "gcj": gcj, "exit_code": 0, "dry_run": True, "stdout": task[:500], "stderr": ""}
    elif gcj == "UNKNOWN":
        result = {"role": role, "gcj": gcj, "exit_code": 2, "stdout": "", "stderr": f"unknown role: {role}"}
    elif not spawn.exists():
        result = {"role": role, "gcj": gcj, "exit_code": 127, "stdout": "", "stderr": f"spawn script missing: {spawn}"}
    else:
        env = os.environ.copy()
        env["RALPH_ROLE_EVIDENCE_FILE"] = str(ev_path)
        env["RALPH_ROLE"] = role
        env["RALPH_GCJ"] = gcj
        try:
            res = subprocess.run([str(spawn), role, task], text=True, capture_output=True, timeout=timeout, env=env)
            result = {"role": role, "gcj": gcj, "exit_code": res.returncode, "stdout": res.stdout[-4000:], "stderr": res.stderr[-4000:]}
        except subprocess.TimeoutExpired as exc:
            out = exc.stdout if isinstance(exc.stdout, str) else ""
            result = {"role": role, "gcj": gcj, "exit_code": 124, "stdout": out[-4000:], "stderr": "timeout"}
        except OSError as exc:
            result = {"role": role, "gcj": gcj, "exit_code": 126, "stdout": "", "stderr": str(exc)}
    artifact_payload = {
        "schema": "ralph.generator.role.v1",
        "session_id": session_id,
        "iteration": iteration,
        "role": role,
        "gcj": gcj,
        "started_at": started,
        "completed_at": now(),
        "exit_code": int(result.get("exit_code", 1)),
        "stdout_tail": str(result.get("stdout", ""))[-4000:],
        "stderr_tail": str(result.get("stderr", ""))[-4000:],
        "task_hash": __import__("hashlib").sha256(task.encode("utf-8", errors="replace")).hexdigest(),
    }
    # If an executor created a richer artifact at the requested path, preserve it
    # under executor_payload while still enforcing the common typed envelope.
    executor_payload = None
    if ev_path.exists():
        try:
            executor_payload = json.loads(ev_path.read_text(encoding="utf-8"))
        except Exception:
            executor_payload = {"raw": ev_path.read_text(encoding="utf-8", errors="replace")[:4000]}
    if executor_payload:
        artifact_payload["executor_payload"] = executor_payload
    write_role_artifact(ev_path, artifact_payload)
    result["evidence_file"] = str(ev_path)
    result["artifact_schema"] = artifact_payload["schema"]
    return result


def validate_results(results: list[dict[str, Any]], required_roles: list[str]) -> tuple[bool, list[str], list[str]]:
    missing: list[str] = []
    artifacts: list[str] = []
    by_role = {str(r.get("role")): r for r in results}
    for role in required_roles:
        r = by_role.get(role)
        if not r:
            missing.append(f"missing-stage:{role}")
            continue
        if int(r.get("exit_code", 1)) != 0:
            missing.append(f"stage-nonzero:{role}:{r.get('exit_code')}")
        ev = str(r.get("evidence_file") or "")
        if not ev or not Path(ev).is_file() or Path(ev).stat().st_size == 0:
            missing.append(f"stage-artifact-missing:{role}")
        else:
            artifacts.append(ev)
        if not r.get("artifact_schema"):
            missing.append(f"stage-schema-missing:{role}")
    return not missing, missing, artifacts


def main() -> int:
    ap = argparse.ArgumentParser(description="Run Ralph GENERATOR subprocess roles")
    ap.add_argument("--session-id", required=True)
    ap.add_argument("--iteration", type=int, required=True)
    ap.add_argument("--original-prompt-file", required=True)
    ap.add_argument("--remediation-file", default="")
    ap.add_argument("--agent-output-file", default="")
    ap.add_argument("--spawn-script", default="")
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("RALPH_GENERATOR_TIMEOUT", "120")))
    ap.add_argument("--roles", default=os.environ.get("RALPH_GENERATOR_ROLES", ",".join(REQUIRED_DEFAULT_ROLES)))
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("RALPH_GENERATOR_DRY_RUN", "0") == "1")
    args = ap.parse_args()

    original = read_text(args.original_prompt_file)
    remediation = read_text(args.remediation_file)
    prior = read_text(args.agent_output_file)
    roles = normalize_roles(args.roles)
    required_roles = roles[:]
    spawn = find_spawn(args.spawn_script)

    base_task = f"""Ralph-Loop-Infinite GENERATOR iteration {args.iteration} for session {args.session_id}.

Typed stage contract:
- Each required role must complete and write evidence to $RALPH_ROLE_EVIDENCE_FILE.
- Orchestrator: decompose next iteration and coordinate artifacts.
- Coder: apply remediation to concrete implementation/docs.
- Tester/Critic: validate behavior and produce evidence; do not judge PASS.
- Only the independent JUDGE can exit.

=== ORIGINAL USER PROMPT ===
{original}

=== LAST REMEDIATION / CRITIQUE ===
{remediation}

=== PRIOR AGENT OUTPUT ===
{prior[-8000:]}
"""
    log("generator_start", session_id=args.session_id, iteration=args.iteration, roles=roles, required_roles=required_roles, spawn=str(spawn), dry_run=args.dry_run)
    results: list[dict[str, Any]] = []
    for role in roles:
        result = run_role(spawn, role, base_task, args.timeout, args.dry_run, args.session_id, args.iteration)
        results.append(result)
        log("role_complete", session_id=args.session_id, iteration=args.iteration, **result)
        if int(result.get("exit_code", 1)) != 0:
            # Continue collecting typed failure artifacts for remaining roles? No:
            # downstream stages need deterministic fail-fast semantics.
            break
    ok, missing, artifacts = validate_results(results, required_roles)
    payload = {
        "schema": "ralph.generator.run.v1",
        "backend": "sidecar",
        "session_id": args.session_id,
        "iteration": args.iteration,
        "ok": ok,
        "required_roles": required_roles,
        "missing": missing,
        "artifacts": artifacts,
        "results": results,
    }
    log("generator_complete", session_id=args.session_id, iteration=args.iteration, ok=ok, missing=missing, artifacts=artifacts)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
