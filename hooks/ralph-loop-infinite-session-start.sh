#!/bin/bash
# ralph-loop-infinite-session-start.sh — SessionStart adapter.
# Validates runtime prerequisites and clears expired signed PASS mirrors so a new
# session cannot exit on stale verifier state.
set -uo pipefail

STATE_FILE="${HOME}/.claude/state/ralph-loop-infinite.local"
LOG_FILE="${HOME}/.claude/state/ralph-gate.log"
TSPARSE="${HOME}/.claude/hooks/ralph-loop-infinite-tsparse.py"
DB_HELPER="${HOME}/.claude/hooks/ralph-loop-infinite-db.py"
SPAWN_SCRIPT="${HOME}/.claude/scripts/ralph-spawn.sh"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
log() { printf '[%s] [session-start] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

age_seconds() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo -1; return; }
  if [[ -x "$TSPARSE" ]]; then
    python3 "$TSPARSE" age-seconds "$ts" 2>/dev/null || echo -1
  else
    python3 - "$ts" <<'PY' 2>/dev/null || echo -1
import sys, time
from datetime import datetime, timezone
raw=sys.argv[1].strip()
if raw.endswith('Z'): raw=raw[:-1] + '+00:00'
try:
    dt=datetime.fromisoformat(raw)
    if dt.tzinfo is None: dt=dt.replace(tzinfo=timezone.utc)
    print(int(time.time()-dt.astimezone(timezone.utc).timestamp()))
except Exception:
    print(-1)
PY
  fi
}

if [[ -x "$DB_HELPER" ]]; then
  python3 "$DB_HELPER" init >/dev/null 2>&1 || log "db init failed"
fi

if [[ -f "$STATE_FILE" ]]; then
  PASS_AT=$(grep '^verifier_passed_at:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_passed_at: *//' | head -1 || true)
  TTL=$(grep '^pass_max_age_s:' "$STATE_FILE" 2>/dev/null | sed 's/pass_max_age_s: *//' | tr -d '[:space:]' | head -1 || true)
  [[ "$TTL" =~ ^[0-9]+$ ]] || TTL=120
  AGE=$(age_seconds "$PASS_AT")
  if [[ "$AGE" =~ ^[0-9]+$ && "$AGE" -gt "$TTL" ]]; then
    TMP=$(mktemp 2>/dev/null || echo "/tmp/ralph-session-start.$$" )
    grep -v -E '^(verifier_pass|verifier_passed_at|pass_expires_at|signed_pass_b64|pass_id):' "$STATE_FILE" > "$TMP" 2>/dev/null || true
    {
      cat "$TMP" 2>/dev/null || true
      echo "verifier_pass: false"
      echo "verifier_last_verdict: PASS_EXPIRED_AT_SESSION_START"
    } > "${TMP}.new"
    mv "${TMP}.new" "$STATE_FILE" 2>/dev/null || true
    rm -f "$TMP" 2>/dev/null || true
    log "expired PASS purged age=${AGE}s ttl=${TTL}s"
  fi
fi

# Print one consolidated prerequisite report, but never block session start: Stop
# and PreTool hooks still fail closed when the gate is armed.
if [[ -x "$SPAWN_SCRIPT" ]]; then
  RALPH_REPO_LOCAL_MODE="${RALPH_REPO_LOCAL_MODE:-0}" bash "$SPAWN_SCRIPT" validate 2>&1 | sed 's/^/[ralph-session-start] /' >&2 || true
else
  echo "[ralph-session-start] MISSING: $SPAWN_SCRIPT" >&2
fi

log "session-start validation complete"
exit 0
