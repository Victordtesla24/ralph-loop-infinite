#!/usr/bin/env python3
"""
ralph-loop-infinite-db.py — Minimal SQLite-backed state for Ralph Loop Infinite.

This helper provides a robust, Convex-compatible local database layer for
verifier PASS records, session IDs, and Ralph Loop state. It uses Python 3
stdlib only (sqlite3) and falls back gracefully on any error.

Design rationale:
- Local hook-critical path MUST be deterministic SQLite, not Docker/network.
- Convex self-hosted default is local SQLite, so this is Convex-compatible.
- Legacy state file (~/.claude/state/ralph-loop-infinite.local) remains as
  a compatibility mirror/fallback; writes update both DB and legacy.
- Any DB failure preserves current Ralph behavior by falling back to legacy.

Database: ~/.claude/state/ralph-loop-infinite.sqlite3
"""

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DB_PATH = Path.home() / ".claude" / "state" / "ralph-loop-infinite.sqlite3"
LEGACY_STATE_FILE = Path.home() / ".claude" / "state" / "ralph-loop-infinite.local"
VERIFIER_LOG = Path.home() / ".claude" / "state" / "ralph-verifier.jsonl"

SCHEMA_VERSION = 1

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    active INTEGER NOT NULL DEFAULT 1,
    started_at TEXT,
    armed_by TEXT,
    trigger TEXT,
    original_user_prompt_path TEXT,
    origin_workspace_path TEXT,
    contract TEXT,
verifier_pass INTEGER NOT NULL DEFAULT 0,
    verifier_attempts INTEGER NOT NULL DEFAULT 0,
    verifier_last_verdict TEXT DEFAULT '',
    verifier_last_reason TEXT DEFAULT '',
    verifier_last_score REAL,
    verifier_passed_at TEXT,
    pass_expires_at TEXT,
    pass_max_age_s INTEGER DEFAULT 120,
    resolved INTEGER DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS verifier_passes (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    iteration INTEGER NOT NULL,
    verdict TEXT NOT NULL,
    hmac TEXT,
    hmac_valid INTEGER NOT NULL DEFAULT 0,
    signed_payload_json TEXT NOT NULL,
    passed_at TEXT,
    expires_at TEXT,
    consumed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    UNIQUE(session_id, iteration)
);

CREATE TABLE IF NOT EXISTS hook_events (
    id TEXT PRIMARY KEY,
    ts TEXT NOT NULL,
    hook TEXT NOT NULL,
    session_id TEXT,
    event_type TEXT NOT NULL,
    data_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ids (
    kind TEXT NOT NULL,
    id TEXT NOT NULL,
    session_id TEXT,
    ts TEXT NOT NULL,
    data_json TEXT NOT NULL,
    PRIMARY KEY (kind, id)
);

CREATE TABLE IF NOT EXISTS kv (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_active ON sessions(active);
CREATE INDEX IF NOT EXISTS idx_verifier_passes_session ON verifier_passes(session_id);
CREATE INDEX IF NOT EXISTS idx_hook_events_session ON hook_events(session_id);
CREATE INDEX IF NOT EXISTS idx_hook_events_ts ON hook_events(ts);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_from_iso(ts: str) -> float:
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def ensure_db_dir() -> None:
    db_dir = DB_PATH.parent
    if not db_dir.exists():
        db_dir.mkdir(parents=True, mode=0o700)
    elif db_dir.stat().st_mode & 0o077:
        os.chmod(db_dir, 0o700)


def ensure_db_mode() -> None:
    if DB_PATH.exists():
        mode = DB_PATH.stat().st_mode & 0o777
        if mode != 0o600:
            os.chmod(DB_PATH, 0o600)


@contextmanager
def get_db():
    ensure_db_dir()
    conn = sqlite3.connect(str(DB_PATH), timeout=5.0)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
        ensure_db_mode()


def init_schema(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    cur.executescript(SCHEMA_SQL)
    cur.execute("SELECT MAX(version) FROM schema_migrations")
    row = cur.fetchone()
    current_version = row[0] if row and row[0] else 0
    if current_version < SCHEMA_VERSION:
        cur.execute(
            "INSERT OR REPLACE INTO schema_migrations (version, applied_at) VALUES (?, ?)",
            (SCHEMA_VERSION, now_iso()),
        )
    # Migration: add verifier_last_score column if missing (existing DBs)
    try:
        cur.execute("SELECT verifier_last_score FROM sessions LIMIT 1")
    except sqlite3.OperationalError:
        cur.execute("ALTER TABLE sessions ADD COLUMN verifier_last_score REAL")
        conn.commit()


def parse_legacy_state(state_file: Path) -> Dict[str, str]:
    result = {}
    if not state_file.exists():
        return result
    try:
        for line in state_file.read_text().splitlines():
            line = line.strip()
            if not line or ":" not in line:
                continue
            key, _, value = line.partition(":")
            result[key.strip()] = value.strip()
    except Exception:
        pass
    return result


def ingest_state(conn: sqlite3.Connection, state_file: Path) -> None:
    state = parse_legacy_state(state_file)
    if not state:
        return

    session_id = state.get("session_id", "")
    if not session_id:
        return

    cur = conn.cursor()
    now = now_iso()

    cur.execute(
        """
        INSERT OR REPLACE INTO sessions (
            session_id, active, started_at, armed_by, trigger,
            original_user_prompt_path, origin_workspace_path, contract,
            verifier_attempts, verifier_pass, verifier_last_verdict,
            verifier_last_reason, verifier_passed_at, pass_expires_at,
            pass_max_age_s, resolved, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id,
            1 if state.get("active", "true").lower() == "true" else 0,
            state.get("started_at", now),
            state.get("armed_by", ""),
            state.get("trigger", ""),
            state.get("original_user_prompt_path", ""),
            state.get("origin_workspace_path", ""),
            state.get("contract", ""),
            int(state.get("verifier_attempts", 0) or 0),
            1 if state.get("verifier_pass", "false").lower() == "true" else 0,
            state.get("verifier_last_verdict", ""),
            state.get("verifier_last_reason", ""),
            state.get("verifier_passed_at", ""),
            state.get("pass_expires_at", ""),
            int(state.get("pass_max_age_s", 120) or 120),
            1 if state.get("resolved", "false").lower() == "true" else 0,
            now,
        ),
    )

    known_keys = {
        "session_id", "active", "started_at", "armed_by", "trigger",
        "original_user_prompt_path", "origin_workspace_path", "contract",
        "verifier_attempts", "verifier_pass", "verifier_last_verdict",
        "verifier_last_reason", "verifier_passed_at", "pass_expires_at",
        "pass_max_age_s", "resolved", "approved",
    }
    for key, value in state.items():
        if key not in known_keys:
            cur.execute(
                "INSERT OR REPLACE INTO kv (key, value, updated_at) VALUES (?, ?, ?)",
                (f"state:{session_id}:{key}", value, now),
            )


def cmd_init(args: argparse.Namespace) -> int:
    try:
        with get_db() as conn:
            init_schema(conn)
        print(json.dumps({"status": "ok", "db_path": str(DB_PATH)}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_ingest_state(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).expanduser()
    try:
        with get_db() as conn:
            init_schema(conn)
            ingest_state(conn, state_file)
        print(json.dumps({"status": "ok", "ingested_from": str(state_file)}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


# ---------------------------------------------------------------------------
# Composable capability blocks for session key lookups
# Follows code-structure skill: each block is independently composable,
# accepts explicit params, returns structured output.
# ---------------------------------------------------------------------------

SESSION_KEY_COLUMN_MAP: dict[str, str] = {
    "session_id": "session_id",
    "active": "active",
    "verifier_pass": "verifier_pass",
    "verifier_attempts": "verifier_attempts",
    "verifier_last_verdict": "verifier_last_verdict",
    "verifier_last_reason": "verifier_last_reason",
    "verifier_passed_at": "verifier_passed_at",
    "pass_expires_at": "pass_expires_at",
    "original_user_prompt_path": "original_user_prompt_path",
    "started_at": "started_at",
    "armed_by": "armed_by",
    "trigger": "trigger",
    "contract": "contract",
}


def get_session_key(conn: sqlite3.Connection, key: str) -> Optional[str]:
    """Composable capability block: look up a single session column value.

    Args:
        conn: Active SQLite connection
        key: Session key name (must exist in SESSION_KEY_COLUMN_MAP)

    Returns:
        Column value as string, or None if not found.
    """
    if key not in SESSION_KEY_COLUMN_MAP:
        return None
    column = SESSION_KEY_COLUMN_MAP[key]
    cur = conn.cursor()
    cur.execute(
        f"SELECT {column} FROM sessions WHERE active = 1 ORDER BY updated_at DESC LIMIT 1"
    )
    row = cur.fetchone()
    return row[0] if row and row[0] is not None else None


def get_kv_value(conn: sqlite3.Connection, session_id: str, key: str) -> str:
    """Composable capability block: look up a kv-stored session value.

    Args:
        conn: Active SQLite connection
        session_id: Session identifier
        key: Key name (without state:{session_id}: prefix)

    Returns:
        Value string, or empty string if not found.
    """
    if not session_id:
        return ""
    cur = conn.cursor()
    cur.execute("SELECT value FROM kv WHERE key = ?", (f"state:{session_id}:{key}",))
    row = cur.fetchone()
    return row[0] if row else ""


def normalize_session_value(key: str, raw: Optional[str]) -> str:
    """Composable capability block: normalize DB raw value for CLI output.

    Args:
        key: Session key name (determines normalization rules)
        raw: Raw value from DB (may be None)

    Returns:
        Normalized string suitable for CLI output.
    """
    if raw is None:
        return ""
    raw = str(raw)
    if key == "active" or key == "verifier_pass":
        return "true" if raw == "1" else "false"
    return raw


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------

def cmd_state_get(args: argparse.Namespace) -> int:
    key = args.key
    state_file = Path(args.state_file).expanduser() if args.state_file else LEGACY_STATE_FILE

    # F-10 remediation: SQLite is authoritative. The legacy file is read-only
    # fallback. We do NOT auto-ingest the legacy file on every state-get
    # because doing so allowed stale legacy `verifier_pass:false` to
    # overwrite a newer DB PASS row. Explicit ingestion happens only via
    # ``ingest-state`` and arm/record paths.
    value = None
    try:
        with get_db() as conn:
            init_schema(conn)

            # Try session column first (known keys)
            raw = get_session_key(conn, key)
            if raw is not None:
                value = normalize_session_value(key, raw)
            else:
                # Fall back to kv table for custom/extended keys
                raw_session_id = get_session_key(conn, "session_id")
                value = get_kv_value(conn, raw_session_id or "", key)

    except Exception:
        state = parse_legacy_state(state_file)
        value = state.get(key, "")

    print(value or "")
    return 0


def cmd_state_json(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).expanduser() if args.state_file else LEGACY_STATE_FILE
    result = {}

    # F-10: no auto-ingest on read paths (see cmd_state_get for rationale).
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute("SELECT * FROM sessions WHERE active = 1 ORDER BY updated_at DESC LIMIT 1")
            row = cur.fetchone()
            if row:
                result = dict(row)
                result["active"] = bool(result.get("active"))
                result["verifier_pass"] = bool(result.get("verifier_pass"))
                result["resolved"] = bool(result.get("resolved"))

                session_id = result.get("session_id", "")
                if session_id:
                    cur.execute("SELECT key, value FROM kv WHERE key LIKE ?", (f"state:{session_id}:%",))
                    for kv_row in cur.fetchall():
                        short_key = kv_row[0].split(":", 2)[-1]
                        result[short_key] = kv_row[1]
    except Exception:
        result = parse_legacy_state(state_file)
        for bool_key in ["active", "verifier_pass", "resolved"]:
            if bool_key in result:
                result[bool_key] = result[bool_key].lower() == "true"

    print(json.dumps(result, indent=2))
    return 0


def cmd_arm(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).expanduser() if args.state_file else LEGACY_STATE_FILE
    now = now_iso()

    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT OR REPLACE INTO sessions (
                    session_id, active, started_at, armed_by, trigger,
                    original_user_prompt_path, contract,
                    verifier_attempts, verifier_pass, updated_at
                ) VALUES (?, 1, ?, ?, ?, ?, ?, 0, 0, ?)
                """,
                (
                    args.session_id,
                    now,
                    args.armed_by,
                    args.trigger,
                    args.prompt_path,
                    args.contract,
                    now,
                ),
            )
            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, 'prompt', ?, 'arm', ?)
                """,
                (
                    str(uuid.uuid4()),
                    now,
                    args.session_id,
                    json.dumps({"armed_by": args.armed_by, "trigger": args.trigger}),
                ),
            )
        print(json.dumps({"status": "ok", "session_id": args.session_id, "armed_at": now}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_arm_or_rearm(args: argparse.Namespace) -> int:
    """F-10/F-11: SQLite-authoritative arm or re-arm.

    Use this for both first-arm and explicit re-arm. On re-arm of an existing
    session row this clears verifier_pass/attempts/timestamps/pass metadata.
    Caller is responsible for mirroring to the legacy file *after* the DB
    commit succeeds.
    """
    now = now_iso()
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()

            cur.execute("SELECT session_id FROM sessions WHERE session_id = ?", (args.session_id,))
            exists = cur.fetchone() is not None

            if exists:
                cur.execute(
                    """
                    UPDATE sessions SET
                        active = 1,
                        armed_by = ?,
                        trigger = ?,
                        original_user_prompt_path = ?,
                        contract = ?,
                        started_at = ?,
                        verifier_attempts = 0,
                        verifier_pass = 0,
                        verifier_last_verdict = NULL,
                        verifier_last_reason = NULL,
                        verifier_passed_at = NULL,
                        pass_expires_at = NULL,
                        resolved = 0,
                        updated_at = ?
                    WHERE session_id = ?
                    """,
                    (
                        args.armed_by,
                        args.trigger,
                        args.prompt_path,
                        args.contract,
                        now,
                        now,
                        args.session_id,
                    ),
                )
                event_type = "rearm"
            else:
                cur.execute(
                    """
                    INSERT INTO sessions (
                        session_id, active, started_at, armed_by, trigger,
                        original_user_prompt_path, contract,
                        verifier_attempts, verifier_pass, updated_at
                    ) VALUES (?, 1, ?, ?, ?, ?, ?, 0, 0, ?)
                    """,
                    (
                        args.session_id,
                        now,
                        args.armed_by,
                        args.trigger,
                        args.prompt_path,
                        args.contract,
                        now,
                    ),
                )
                event_type = "arm"

            session_id = args.session_id
            cur.execute(
                "DELETE FROM kv WHERE key LIKE ?",
                (f"state:{session_id}:signed_pass_b64",),
            )
            cur.execute(
                "DELETE FROM kv WHERE key LIKE ?",
                (f"state:{session_id}:pass_id",),
            )

            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, 'prompt', ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    now,
                    args.session_id,
                    event_type,
                    json.dumps({"armed_by": args.armed_by, "trigger": args.trigger}),
                ),
            )
        print(json.dumps({"status": "ok", "session_id": args.session_id, "event": event_type, "ts": now}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_pass_fetch(args: argparse.Namespace) -> int:
    """F-04/F-10: return the latest valid signed verifier_passes row for a session.

    "Valid" means verdict=PASS, hmac_valid=1, consumed=0, and (if expires_at
    is set) not past expiration. Returns the signed payload JSON for the
    Stop hook to validate.
    """
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                SELECT id, session_id, iteration, verdict, hmac, hmac_valid,
                       signed_payload_json, passed_at, expires_at, consumed,
                       created_at
                FROM verifier_passes
                WHERE session_id = ?
                  AND verdict = 'PASS'
                  AND hmac_valid = 1
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (args.session_id,),
            )
            row = cur.fetchone()
            if not row:
                print(json.dumps({"has_row": False}))
                return 0
            out = {
                "has_row": True,
                "id": row["id"],
                "session_id": row["session_id"],
                "iteration": row["iteration"],
                "verdict": row["verdict"],
                "hmac": row["hmac"],
                "hmac_valid": bool(row["hmac_valid"]),
                "signed_payload_json": row["signed_payload_json"],
                "passed_at": row["passed_at"] or "",
                "expires_at": row["expires_at"] or "",
                "consumed": bool(row["consumed"]),
                "created_at": row["created_at"],
            }
            now_ts = time.time()
            if out["expires_at"]:
                exp_ts = epoch_from_iso(out["expires_at"])
                out["expired"] = exp_ts and now_ts > exp_ts
            else:
                out["expired"] = False
            print(json.dumps(out))
            return 0
    except Exception as e:
        print(json.dumps({"has_row": False, "error": str(e)}))
        return 1


def cmd_pass_store(args: argparse.Namespace) -> int:
    """F-04: persist a fresh signed verifier PASS payload to verifier_passes.

    Called by stop hook AFTER verifier returns a HMAC-signed PASS verdict.
    The signed payload (base64) is stored in verifier_passes.signed_payload_json
    plus the session row is updated. This is the DB-authoritative record
    that stop hook must consult on every cached fast-path Stop.
    """
    now = now_iso()
    try:
        payload_obj = json.loads(args.signed_payload_json) if args.signed_payload_json.startswith("{") else {}
    except Exception:
        payload_obj = {}
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT OR REPLACE INTO verifier_passes (
                    id, session_id, iteration, verdict, hmac, hmac_valid,
                    signed_payload_json, passed_at, expires_at, consumed, created_at
                ) VALUES (?, ?, ?, 'PASS', ?, 1, ?, ?, ?, 0, ?)
                """,
                (
                    args.pass_id,
                    args.session_id,
                    args.iteration,
                    payload_obj.get("hmac", ""),
                    args.signed_payload_json,
                    args.issued_at,
                    args.expires_at,
                    now,
                ),
            )
            cur.execute(
                """
                UPDATE sessions SET
                    verifier_pass = 1,
                    verifier_attempts = ?,
                    verifier_last_verdict = 'PASS',
                    verifier_last_reason = NULL,
                    verifier_passed_at = ?,
                    pass_expires_at = ?,
                    updated_at = ?
                WHERE session_id = ?
                """,
                (args.iteration, args.issued_at, args.expires_at, now, args.session_id),
            )
            cur.execute(
                "INSERT OR REPLACE INTO kv (key, value, updated_at) VALUES (?, ?, ?)",
                (f"state:{args.session_id}:signed_pass_b64", args.signed_pass_b64, now),
            )
            cur.execute(
                "INSERT OR REPLACE INTO kv (key, value, updated_at) VALUES (?, ?, ?)",
                (f"state:{args.session_id}:pass_id", args.pass_id, now),
            )
        print(json.dumps({"status": "ok", "pass_id": args.pass_id}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_list_sessions(args: argparse.Namespace) -> int:
    """F-01: enumerate sessions; used by harness/live invariant checks."""
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                SELECT session_id, active, started_at, updated_at,
                       verifier_pass, verifier_attempts, verifier_last_verdict
                FROM sessions ORDER BY rowid
                """
            )
            rows = [dict(r) for r in cur.fetchall()]
        print(json.dumps({"sessions": rows}))
        return 0
    except Exception as e:
        print(json.dumps({"sessions": [], "error": str(e)}))
        return 1


def cmd_record_verifier(args: argparse.Namespace) -> int:
    now = now_iso()

    try:
        if args.verdict_json.startswith("{"):
            verdict_obj = json.loads(args.verdict_json)
        elif Path(args.verdict_json).exists():
            verdict_obj = json.loads(Path(args.verdict_json).read_text())
        else:
            verdict_obj = {"verdict": "FAIL", "error": "unparseable verdict input"}
    except Exception as e:
        verdict_obj = {"verdict": "FAIL", "error": str(e)}

    verdict = verdict_obj.get("verdict", "FAIL")
    hmac_valid = 1 if args.hmac_valid.lower() in ("yes", "true", "1") else 0

    passed_at = ""
    expires_at = ""
    if verdict == "PASS" and hmac_valid:
        passed_at = now
        expires_at = datetime.fromtimestamp(
            time.time() + 120, tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()

            pass_id = str(uuid.uuid4())
            cur.execute(
                """
                INSERT INTO verifier_passes (
                    id, session_id, iteration, verdict, hmac, hmac_valid,
                    signed_payload_json, passed_at, expires_at, consumed, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                """,
                (
                    pass_id,
                    args.session_id,
                    args.iteration,
                    verdict,
                    verdict_obj.get("hmac", ""),
                    hmac_valid,
                    json.dumps(verdict_obj),
                    passed_at,
                    expires_at,
                    now,
                ),
            )

            if verdict == "PASS" and hmac_valid:
                cur.execute(
                    """
                    UPDATE sessions SET
                        verifier_pass = 1,
                        verifier_attempts = ?,
                        verifier_last_verdict = 'PASS',
                        verifier_passed_at = ?,
                        pass_expires_at = ?,
                        updated_at = ?
                    WHERE session_id = ?
                    """,
                    (args.iteration, passed_at, expires_at, now, args.session_id),
                )
            else:
                reason = "; ".join(
                    (verdict_obj.get("missing") or []) + (verdict_obj.get("deviations") or [])
                )[:500]
                cur.execute(
                    """
                    UPDATE sessions SET
                        verifier_attempts = ?,
                        verifier_last_verdict = ?,
                        verifier_last_reason = ?,
                        updated_at = ?
                    WHERE session_id = ?
                    """,
                    (args.iteration, verdict, reason, now, args.session_id),
                )

            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, 'verifier', ?, 'verdict', ?)
                """,
                (
                    str(uuid.uuid4()),
                    now,
                    args.session_id,
                    json.dumps({"iteration": args.iteration, "verdict": verdict, "hmac_valid": bool(hmac_valid)}),
                ),
            )

        print(json.dumps({
            "status": "ok",
            "pass_id": pass_id,
            "verdict": verdict,
            "hmac_valid": bool(hmac_valid),
            "passed_at": passed_at,
            "expires_at": expires_at,
        }))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_pass_status(args: argparse.Namespace) -> int:
    now_ts = time.time()

    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()

            cur.execute(
                """
                SELECT session_id, verifier_pass, verifier_passed_at, pass_expires_at, pass_max_age_s
                FROM sessions WHERE session_id = ?
                """,
                (args.session_id,),
            )
            row = cur.fetchone()

            if not row:
                print(json.dumps({
                    "has_pass": False,
                    "expired": False,
                    "duplicate_block_reason": "",
                    "passed_at": "",
                    "expires_at": "",
                    "error": "session not found",
                }))
                return 0

            verifier_pass = bool(row["verifier_pass"])
            passed_at = row["verifier_passed_at"] or ""
            expires_at = row["pass_expires_at"] or ""
            max_age = row["pass_max_age_s"] or 120

            expired = False
            duplicate_block_reason = ""

            if passed_at:
                passed_epoch = epoch_from_iso(passed_at)
                age = now_ts - passed_epoch

                if expires_at:
                    expires_epoch = epoch_from_iso(expires_at)
                    if now_ts > expires_epoch:
                        expired = True
                elif age > max_age:
                    expired = True

                if verifier_pass and not expired:
                    duplicate_block_reason = f"existing pass at {passed_at} (age={int(age)}s <= {max_age}s)"

            print(json.dumps({
                "has_pass": verifier_pass and not expired,
                "expired": expired,
                "duplicate_block_reason": duplicate_block_reason,
                "passed_at": passed_at,
                "expires_at": expires_at,
            }))
            return 0
    except Exception as e:
        print(json.dumps({"has_pass": False, "expired": False, "error": str(e)}))
        return 1


def cmd_purge_expired(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file).expanduser() if args.state_file else LEGACY_STATE_FILE
    verifier_log = Path(args.verifier_log).expanduser() if args.verifier_log else VERIFIER_LOG
    now_ts = time.time()
    purged_count = 0

    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()

            cur.execute(
                """
                SELECT session_id, verifier_passed_at, pass_expires_at, pass_max_age_s
                FROM sessions WHERE verifier_pass = 1
                """
            )
            rows = cur.fetchall()

            for row in rows:
                session_id = row["session_id"]
                passed_at = row["verifier_passed_at"] or ""
                expires_at = row["pass_expires_at"] or ""
                max_age = row["pass_max_age_s"] or 120

                if not passed_at:
                    continue

                passed_epoch = epoch_from_iso(passed_at)
                expired = False

                if expires_at:
                    if now_ts > epoch_from_iso(expires_at):
                        expired = True
                elif now_ts - passed_epoch > max_age:
                    expired = True

                if expired:
                    cur.execute(
                        """
                        UPDATE sessions SET
                            verifier_pass = 0,
                            verifier_passed_at = NULL,
                            pass_expires_at = NULL,
                            updated_at = ?
                        WHERE session_id = ?
                        """,
                        (now_iso(), session_id),
                    )
                    purged_count += 1

        if state_file.exists():
            lines = state_file.read_text().splitlines()
            passed_at = ""
            expires_at = ""
            for line in lines:
                if line.startswith("verifier_passed_at:"):
                    passed_at = line.split(":", 1)[1].strip()
                elif line.startswith("pass_expires_at:"):
                    expires_at = line.split(":", 1)[1].strip()

            if passed_at:
                passed_epoch = epoch_from_iso(passed_at)
                expired = False
                if expires_at:
                    if now_ts > epoch_from_iso(expires_at):
                        expired = True
                elif now_ts - passed_epoch > 120:
                    expired = True

                if expired:
                    keep = [
                        l for l in lines
                        if not l.startswith((
                            "verifier_pass:", "verifier_passed_at:",
                            "pass_expires_at:", "pass_max_age_s:",
                            "resolved:", "approved:",
                        ))
                    ]
                    state_file.write_text("\n".join(keep) + ("\n" if keep else ""))
                    purged_count += 1

        if verifier_log.exists():
            kept = []
            for line in verifier_log.read_text().splitlines():
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                    ts = obj.get("ts", "")
                    if obj.get("verdict") == "PASS" and ts:
                        if now_ts - epoch_from_iso(ts) > 120:
                            purged_count += 1
                            continue
                except json.JSONDecodeError:
                    pass
                kept.append(line)
            verifier_log.write_text("\n".join(kept) + ("\n" if kept else ""))

        print(json.dumps({"status": "ok", "purged_count": purged_count}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_event(args: argparse.Namespace) -> int:
    now = now_iso()

    try:
        data = json.loads(args.data_json) if args.data_json else {}
    except json.JSONDecodeError:
        data = {"raw": args.data_json}

    session_id = args.session_id or ""
    payload = data if isinstance(data, dict) else {"value": data}
    if isinstance(data, dict) and data.get("schema") == "ralph.event.v1" and data.get("correlation_id"):
        normalized = data
    else:
        iter_val = payload.get("iteration") if isinstance(payload, dict) else None
        try:
            iter_num = int(iter_val)
        except Exception:
            iter_num = 0
        seed = f"{session_id}:{args.hook}:{args.event_type}:{iter_num}:{now}"
        correlation_id = payload.get("correlation_id") if isinstance(payload, dict) else ""
        if not correlation_id:
            correlation_id = hashlib.sha256(seed.encode("utf-8", errors="replace")).hexdigest()[:16]
        normalized = {
            "schema": "ralph.event.v1",
            "ts": now,
            "hook": args.hook,
            "session_id": session_id,
            "event_type": args.event_type,
            "correlation_id": correlation_id,
            "payload": payload,
        }

    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            event_id = str(uuid.uuid4())
            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (event_id, now, args.hook, session_id, args.event_type, json.dumps(normalized)),
            )
        print(json.dumps({"status": "ok", "event_id": event_id}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_increment_attempts(args: argparse.Namespace) -> int:
    """RALPH-refactor remediation: atomic verifier-attempts increment.

    Stop hook previously incremented attempts via a non-atomic
    ``grep | sed | mv`` dance on the legacy text file. With concurrent
    Stop invocations (e.g. user disarm racing the verifier) two iterations
    could land with the same attempt count. This subcommand performs the
    increment atomically inside a SQLite transaction and returns the new
    value to the caller. On any DB failure it returns a structured error
    so the caller can fail closed.
    """
    now = now_iso()
    verdict = args.verdict or ""
    reason = (args.reason or "")[:500]
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                "SELECT verifier_attempts FROM sessions WHERE session_id = ?",
                (args.session_id,),
            )
            row = cur.fetchone()
            if not row:
                cur.execute(
                    """
                    INSERT INTO sessions (session_id, active, started_at, verifier_attempts, updated_at)
                    VALUES (?, 1, ?, 1, ?)
                    """,
                    (args.session_id, now, now),
                )
                new_value = 1
            else:
                new_value = int(row[0] or 0) + 1
                cur.execute(
                    """
                    UPDATE sessions
                       SET verifier_attempts = ?,
                           verifier_last_verdict = COALESCE(NULLIF(?, ''), verifier_last_verdict),
                           verifier_last_reason  = COALESCE(NULLIF(?, ''), verifier_last_reason),
                           updated_at = ?
                     WHERE session_id = ?
                    """,
                    (new_value, verdict, reason, now, args.session_id),
                )
            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, 'stop', ?, 'attempts-increment', ?)
                """,
                (
                    str(uuid.uuid4()),
                    now,
                    args.session_id,
                    json.dumps({
                        "new_attempts": new_value,
                        "verdict": verdict,
                        "reason": reason,
                    }),
                ),
            )
        print(json.dumps({"status": "ok", "verifier_attempts": new_value}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_state_update(args: argparse.Namespace) -> int:
    """RALPH-refactor remediation: atomic, fail-closed state mutation.

    Stop hook previously rewrote the legacy state file with a
    grep-v / echo / mv sequence and silently swallowed every failure
    (``|| true``). If the rewrite failed the gate could end up with stale
    verifier_attempts or a leftover verifier_pass row from a prior run.
    This subcommand applies the same mutation atomically through the DB
    and reports failure to the caller so stop.sh can fail closed.

    Inputs are repeated --set KEY=VALUE pairs limited to the known
    session columns. Unknown columns are stored in the kv table so the
    helper is forward-compatible without DDL changes.
    """
    now = now_iso()
    pairs: list[tuple[str, str]] = []
    for raw in (args.set_pairs or []):
        if "=" not in raw:
            print(json.dumps({"status": "error", "error": f"bad --set value: {raw}"}))
            return 1
        k, v = raw.split("=", 1)
        pairs.append((k.strip(), v))
    if not pairs:
        print(json.dumps({"status": "error", "error": "no --set pairs provided"}))
        return 1
    column_keys = {
        "verifier_attempts": "int",
        "verifier_pass": "bool",
        "verifier_last_verdict": "text",
        "verifier_last_reason": "text",
        "verifier_passed_at": "text",
        "pass_expires_at": "text",
        "pass_max_age_s": "int",
        "resolved": "bool",
    }
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                "SELECT session_id FROM sessions WHERE session_id = ?",
                (args.session_id,),
            )
            if not cur.fetchone():
                cur.execute(
                    """
                    INSERT INTO sessions (session_id, active, started_at, updated_at)
                    VALUES (?, 1, ?, ?)
                    """,
                    (args.session_id, now, now),
                )
            for key, raw in pairs:
                if key in column_keys:
                    kind = column_keys[key]
                    if kind == "int":
                        try:
                            value: Any = int(raw)
                        except ValueError:
                            print(json.dumps({
                                "status": "error",
                                "error": f"int expected for {key}, got {raw!r}",
                            }))
                            return 1
                    elif kind == "bool":
                        value = 1 if raw.strip().lower() in ("1", "true", "yes") else 0
                    else:
                        value = raw
                    cur.execute(
                        f"UPDATE sessions SET {key} = ?, updated_at = ? WHERE session_id = ?",
                        (value, now, args.session_id),
                    )
                else:
                    cur.execute(
                        "INSERT OR REPLACE INTO kv (key, value, updated_at) VALUES (?, ?, ?)",
                        (f"state:{args.session_id}:{key}", raw, now),
                    )
            cur.execute(
                """
                INSERT INTO hook_events (id, ts, hook, session_id, event_type, data_json)
                VALUES (?, ?, 'stop', ?, 'state-update', ?)
                """,
                (
                    str(uuid.uuid4()),
                    now,
                    args.session_id,
                    json.dumps({"keys": [k for k, _ in pairs]}),
                ),
            )
        print(json.dumps({"status": "ok", "updated": [k for k, _ in pairs]}))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_snapshot(args: argparse.Namespace) -> int:
    try:
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()

            snapshot = {
                "ts": now_iso(),
                "sessions": [],
                "verifier_passes": [],
                "recent_events": [],
            }

            cur.execute("SELECT * FROM sessions ORDER BY updated_at DESC LIMIT 10")
            for row in cur.fetchall():
                snapshot["sessions"].append(dict(row))

            cur.execute("SELECT * FROM verifier_passes ORDER BY created_at DESC LIMIT 20")
            for row in cur.fetchall():
                snapshot["verifier_passes"].append(dict(row))

            cur.execute("SELECT * FROM hook_events ORDER BY ts DESC LIMIT 50")
            for row in cur.fetchall():
                snapshot["recent_events"].append(dict(row))

        print(json.dumps(snapshot, indent=2))
        return 0
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return 1


def cmd_self_test(args: argparse.Namespace) -> int:
    tests_passed = 0
    tests_failed = 0
    results = []

    def test(name: str, fn):
        nonlocal tests_passed, tests_failed
        try:
            fn()
            tests_passed += 1
            results.append({"test": name, "status": "PASS"})
        except AssertionError as e:
            tests_failed += 1
            results.append({"test": name, "status": "FAIL", "error": str(e)})
        except Exception as e:
            tests_failed += 1
            results.append({"test": name, "status": "ERROR", "error": str(e)})

    def test_init():
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute("SELECT version FROM schema_migrations")
            row = cur.fetchone()
            assert row and row[0] == SCHEMA_VERSION, f"schema version mismatch: {row}"

    def test_arm_and_get():
        test_session = f"test-{uuid.uuid4()}"
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO sessions (session_id, active, started_at, armed_by, trigger, updated_at)
                VALUES (?, 1, ?, 'self-test', 'test', ?)
                """,
                (test_session, now_iso(), now_iso()),
            )
            cur.execute("SELECT session_id FROM sessions WHERE session_id = ?", (test_session,))
            row = cur.fetchone()
            assert row and row[0] == test_session, "failed to insert/retrieve session"
            cur.execute("DELETE FROM sessions WHERE session_id = ?", (test_session,))

    def test_verifier_pass_record():
        test_session = f"test-{uuid.uuid4()}"
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO sessions (session_id, active, started_at, updated_at)
                VALUES (?, 1, ?, ?)
                """,
                (test_session, now_iso(), now_iso()),
            )
            cur.execute(
                """
                INSERT INTO verifier_passes (
                    id, session_id, iteration, verdict, hmac_valid,
                    signed_payload_json, passed_at, expires_at, created_at
                ) VALUES (?, ?, 1, 'PASS', 1, '{}', ?, ?, ?)
                """,
                (
                    str(uuid.uuid4()),
                    test_session,
                    now_iso(),
                    now_iso(),
                    now_iso(),
                ),
            )
            cur.execute("SELECT COUNT(*) FROM verifier_passes WHERE session_id = ?", (test_session,))
            row = cur.fetchone()
            assert row and row[0] == 1, "verifier pass not recorded"
            cur.execute("DELETE FROM verifier_passes WHERE session_id = ?", (test_session,))
            cur.execute("DELETE FROM sessions WHERE session_id = ?", (test_session,))

    def test_kv_store():
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                "INSERT OR REPLACE INTO kv (key, value, updated_at) VALUES (?, ?, ?)",
                ("test:key", "test_value", now_iso()),
            )
            cur.execute("SELECT value FROM kv WHERE key = ?", ("test:key",))
            row = cur.fetchone()
            assert row and row[0] == "test_value", "kv store failed"
            cur.execute("DELETE FROM kv WHERE key = ?", ("test:key",))

    def test_db_path_mode():
        if DB_PATH.exists():
            mode = DB_PATH.stat().st_mode & 0o777
            assert mode == 0o600, f"DB file mode is {oct(mode)}, expected 0o600"

    def test_parent_dir_mode():
        db_dir = DB_PATH.parent
        if db_dir.exists():
            mode = db_dir.stat().st_mode & 0o077
            assert mode == 0, f"DB parent dir has group/other permissions: {oct(db_dir.stat().st_mode)}"

    def test_increment_attempts():
        test_session = f"test-{uuid.uuid4()}"
        with get_db() as conn:
            init_schema(conn)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO sessions (session_id, active, started_at, verifier_attempts, updated_at)
                VALUES (?, 1, ?, 0, ?)
                """,
                (test_session, now_iso(), now_iso()),
            )
        ns1 = argparse.Namespace(session_id=test_session, verdict="FAIL", reason="r1")
        rc1 = cmd_increment_attempts(ns1)
        assert rc1 == 0, "increment-attempts first call should succeed"
        ns2 = argparse.Namespace(session_id=test_session, verdict="FAIL", reason="r2")
        rc2 = cmd_increment_attempts(ns2)
        assert rc2 == 0, "increment-attempts second call should succeed"
        with get_db() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT verifier_attempts FROM sessions WHERE session_id = ?",
                (test_session,),
            )
            row = cur.fetchone()
            assert row and row[0] == 2, f"attempts should be 2, got {row}"
            cur.execute("DELETE FROM sessions WHERE session_id = ?", (test_session,))

    def test_state_update():
        test_session = f"test-{uuid.uuid4()}"
        ns = argparse.Namespace(
            session_id=test_session,
            set_pairs=[
                "verifier_pass=true",
                "verifier_last_verdict=PASS",
                "verifier_attempts=4",
            ],
        )
        rc = cmd_state_update(ns)
        assert rc == 0, "state-update should succeed"
        with get_db() as conn:
            cur = conn.cursor()
            cur.execute(
                "SELECT verifier_pass, verifier_last_verdict, verifier_attempts FROM sessions WHERE session_id = ?",
                (test_session,),
            )
            row = cur.fetchone()
            assert row, "session row should exist"
            assert row[0] == 1, f"verifier_pass should be 1, got {row[0]}"
            assert row[1] == "PASS", f"verifier_last_verdict should be PASS, got {row[1]}"
            assert row[2] == 4, f"verifier_attempts should be 4, got {row[2]}"
            cur.execute("DELETE FROM sessions WHERE session_id = ?", (test_session,))

    test("init_schema", test_init)
    test("arm_and_get", test_arm_and_get)
    test("verifier_pass_record", test_verifier_pass_record)
    test("kv_store", test_kv_store)
    test("db_path_mode", test_db_path_mode)
    test("parent_dir_mode", test_parent_dir_mode)
    test("increment_attempts", test_increment_attempts)
    test("state_update", test_state_update)

    print(json.dumps({
        "status": "PASS" if tests_failed == 0 else "FAIL",
        "tests_passed": tests_passed,
        "tests_failed": tests_failed,
        "results": results,
    }, indent=2))

    return 0 if tests_failed == 0 else 1


def main():
    parser = argparse.ArgumentParser(
        description="Ralph Loop Infinite SQLite DB helper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    subparsers.add_parser("init", help="Initialize the database schema")

    ingest_parser = subparsers.add_parser("ingest-state", help="Ingest legacy state file into DB")
    ingest_parser.add_argument("--state-file", required=True, help="Path to legacy state file")

    get_parser = subparsers.add_parser("state-get", help="Get a state value (DB first, legacy fallback)")
    get_parser.add_argument("key", help="State key to retrieve")
    get_parser.add_argument("--state-file", help="Path to legacy state file for fallback")

    json_parser = subparsers.add_parser("state-json", help="Get full state as JSON")
    json_parser.add_argument("--state-file", help="Path to legacy state file")

    arm_parser = subparsers.add_parser("arm", help="Arm the gate for a session")
    arm_parser.add_argument("--state-file", help="Path to legacy state file")
    arm_parser.add_argument("--session-id", required=True, help="Session ID")
    arm_parser.add_argument("--armed-by", required=True, help="What armed the gate")
    arm_parser.add_argument("--trigger", required=True, help="Trigger type")
    arm_parser.add_argument("--prompt-path", required=True, help="Path to sealed prompt")
    arm_parser.add_argument("--contract", required=True, help="Path to contract file")

    record_parser = subparsers.add_parser("record-verifier", help="Record a verifier verdict")
    record_parser.add_argument("--session-id", required=True, help="Session ID")
    record_parser.add_argument("--iteration", type=int, required=True, help="Iteration number")
    record_parser.add_argument("--verdict-json", required=True, help="Verdict JSON or path to file")
    record_parser.add_argument("--hmac-valid", required=True, help="HMAC valid: yes/no")

    pass_parser = subparsers.add_parser("pass-status", help="Check verifier pass status")
    pass_parser.add_argument("--session-id", required=True, help="Session ID")

    purge_parser = subparsers.add_parser("purge-expired", help="Purge expired verifier passes")
    purge_parser.add_argument("--state-file", help="Path to legacy state file")
    purge_parser.add_argument("--verifier-log", help="Path to verifier log")

    event_parser = subparsers.add_parser("event", help="Record a hook event")
    event_parser.add_argument("--hook", required=True, help="Hook name")
    event_parser.add_argument("--session-id", help="Session ID")
    event_parser.add_argument("--event-type", required=True, help="Event type")
    event_parser.add_argument("--data-json", help="Event data as JSON")

    subparsers.add_parser("snapshot", help="Dump a snapshot of DB state")
    subparsers.add_parser("self-test", help="Run self-tests")

    arm_or_rearm_parser = subparsers.add_parser(
        "arm-or-rearm",
        help="SQLite-authoritative arm/re-arm; clears verifier state on existing rows",
    )
    arm_or_rearm_parser.add_argument("--session-id", required=True)
    arm_or_rearm_parser.add_argument("--armed-by", required=True)
    arm_or_rearm_parser.add_argument("--trigger", required=True)
    arm_or_rearm_parser.add_argument("--prompt-path", required=True)
    arm_or_rearm_parser.add_argument("--contract", required=True)

    pf_parser = subparsers.add_parser(
        "pass-fetch",
        help="Fetch the latest signed verifier PASS row for a session",
    )
    pf_parser.add_argument("--session-id", required=True)

    ps_parser = subparsers.add_parser(
        "pass-store",
        help="Persist a freshly-signed PASS into verifier_passes + sessions",
    )
    ps_parser.add_argument("--session-id", required=True)
    ps_parser.add_argument("--iteration", type=int, required=True)
    ps_parser.add_argument("--pass-id", required=True)
    ps_parser.add_argument("--issued-at", required=True)
    ps_parser.add_argument("--expires-at", required=True)
    ps_parser.add_argument(
        "--signed-payload-json",
        required=True,
        help="Decoded signed payload as JSON (object with hmac field)",
    )
    ps_parser.add_argument(
        "--signed-pass-b64",
        required=True,
        help="Base64-encoded signed payload (mirrors the legacy state line)",
    )

    subparsers.add_parser("list-sessions", help="List all sessions (audit)")

    inc_parser = subparsers.add_parser(
        "increment-attempts",
        help="Atomic verifier_attempts increment with optional verdict/reason",
    )
    inc_parser.add_argument("--session-id", required=True)
    inc_parser.add_argument("--verdict", default="", help="optional verifier verdict to record")
    inc_parser.add_argument("--reason", default="", help="optional reason string (<=500 chars)")

    upd_parser = subparsers.add_parser(
        "state-update",
        help="Atomic, fail-closed state mutation (repeatable --set KEY=VALUE)",
    )
    upd_parser.add_argument("--session-id", required=True)
    upd_parser.add_argument(
        "--set",
        dest="set_pairs",
        action="append",
        default=[],
        help="KEY=VALUE state field (repeatable)",
    )

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    commands = {
        "init": cmd_init,
        "ingest-state": cmd_ingest_state,
        "state-get": cmd_state_get,
        "state-json": cmd_state_json,
        "arm": cmd_arm,
        "arm-or-rearm": cmd_arm_or_rearm,
        "pass-fetch": cmd_pass_fetch,
        "pass-store": cmd_pass_store,
        "list-sessions": cmd_list_sessions,
        "record-verifier": cmd_record_verifier,
        "pass-status": cmd_pass_status,
        "purge-expired": cmd_purge_expired,
        "event": cmd_event,
        "snapshot": cmd_snapshot,
        "self-test": cmd_self_test,
        "increment-attempts": cmd_increment_attempts,
        "state-update": cmd_state_update,
    }

    return commands[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
