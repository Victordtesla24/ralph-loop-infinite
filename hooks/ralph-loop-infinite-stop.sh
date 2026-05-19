#!/bin/bash
# ralph-loop-infinite-stop.sh — Stop hook enforcing the ralph-loop-infinite
# contract.
#
# v4.1.0 (RALPH internal-thinking-loop refactor):
#   * Status-token regex now requires the iteration suffix
#     "ACTIVE — Iteration N of ∞" so the bare "ACTIVE]" form is rejected.
#     This matches the contract examples and prevents partial markers from
#     satisfying the gate header check.
#   * Signed-PASS revalidation queries SQLite first via
#     ``ralph-loop-infinite-db.py pass-fetch``; the legacy text mirror is
#     only consulted when the DB has no row (DB-first doctrine, fully
#     applied to the cached fast-path).
#   * verifier_attempts increments and state mutations go through the new
#     atomic ``increment-attempts`` / ``state-update`` DB subcommands.
#     When the DB update fails the hook fails CLOSED with an emit_block
#     so the gate cannot silently lose attempt counters or carry stale
#     verifier_pass rows forward.
#   * Stage logs ([stop] STAGE=judge / STAGE=remediate iter=N) surface
#     the four explicit RALPH stages in ralph-gate.log.
#
# v4.0.0 (F-04..F-07, F-10, F-12, F-14 remediation, preserved):
#   * Every allow path revalidates an HMAC-signed stored-pass row before exit.
#     verifier_pass:true with no signed_pass_b64 record now BLOCKS (F-04).
#   * Timestamp parsing delegates to ralph-loop-infinite-tsparse.py so UTC Z
#     ISO strings are interpreted as UTC on macOS and Linux alike (F-05).
#   * All DB helper invocations have stdout suppressed; the hook only emits
#     intended block JSON on the block path and nothing on allow paths (F-06).
#   * The verifier is preceded by a deterministic evidence-bundle precheck;
#     fabricated artifact citations FAIL before any HMAC is signed (F-07).
#   * SQLite is the sole state authority. Legacy state.local is treated as a
#     display-only mirror written AFTER signed DB commits (F-10).
#   * Provider/model from the signed verdict is verified against the central
#     policy file before any cached PASS is allowed (F-12).
#   * Second-verifier-FAIL no longer terminates the host process by default
#     (F-14). Loop semantics remain infinite-iteration; a kill mode is only
#     available behind RALPH_ENABLE_SESSION_KILL=1.

set -uo pipefail

STATE_FILE="$HOME/.claude/state/ralph-loop-infinite.local"
LOG_FILE="$HOME/.claude/state/ralph-gate.log"
VIOLATIONS_FILE="$HOME/.claude/state/violations.jsonl"
PROVIDER_FEEDBACK_FILE="$HOME/.claude/state/provider-feedback.jsonl"
VERIFIER_SCRIPT="$HOME/.claude/hooks/ralph-loop-infinite-verifier.sh"
HMAC_KEY_FILE="$HOME/.claude/secrets/ralph-hmac.key"
ALLOWLIST_FILE="$HOME/.claude/state/ralph-loop-outsiders.local"
LEGACY_MONITOR_FILE="$HOME/.claude/state/ralph-loop-monitors.local"
DB_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-db.py"
GENERATOR_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-generator.py"
REMEDIATION_PROMPT_FILE="$HOME/.claude/state/ralph-remediation-prompt.txt"
TSPARSE="$HOME/.claude/hooks/ralph-loop-infinite-tsparse.py"
POLICY_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-policy.py"
EVIDENCE_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-evidence.py"
REMEDIATION_PROMPT_FILE="$HOME/.claude/state/ralph-remediation-prompt.txt"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$VIOLATIONS_FILE")"

log() {
  printf '[%s] [stop] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

db_available() { [[ -x "$DB_HELPER" ]] && command -v python3 >/dev/null 2>&1; }
run_generator_once() {
  if [[ "${RALPH_GENERATOR_DISABLE:-0}" == "1" ]]; then
    if [[ "${RALPH_TEST_MODE:-0}" == "1" ]]; then
      log "GENERATOR_SKIP disabled_in_test_mode=1"
      return 0
    fi
    log "GENERATOR_DISABLE_REJECTED requires_RALPH_TEST_MODE=1"
  fi
  [[ -x "$GENERATOR_HELPER" ]] || { log "GENERATOR_SKIP helper_missing=$GENERATOR_HELPER"; return 1; }
  local gen_log="$HOME/.claude/state/ralph-generator-last.json"
  local dry_arg=()
  [[ "${RALPH_GENERATOR_DRY_RUN:-0}" == "1" ]] && dry_arg=(--dry-run)
  if python3 "$GENERATOR_HELPER" \
    --session-id "${HOOK_SESSION:-unknown}" \
    --iteration "$ITERATION" \
    --original-prompt-file "${ORIGINAL_PROMPT_PATH:-$HOME/.claude/state/original-user-prompt.txt}" \
    --remediation-file "$REMEDIATION_PROMPT_FILE" \
    --agent-output-file "${AGENT_OUTPUT_FILE:-}" \
    "${dry_arg[@]}" > "$gen_log" 2>&1; then
    log "GENERATOR_RUN_OK iter=$ITERATION sess=${HOOK_SESSION:-unknown} log=$gen_log"
    return 0
  fi
  local rc=$?
  log "GENERATOR_RUN_FAIL iter=$ITERATION sess=${HOOK_SESSION:-unknown} rc=$rc log=$gen_log"
  return "$rc"
}

db_init() {
  if db_available; then
    python3 "$DB_HELPER" init >/dev/null 2>&1 || true
  fi
}

db_state_get() {
  # F-06: silence stdout from helper. F-10: SQLite is authoritative; legacy
  # mirror is read only when the DB has no value.
  local key="$1"
  local value=""
  if db_available; then
    value=$(python3 "$DB_HELPER" state-get "$key" --state-file "$STATE_FILE" 2>/dev/null | grep -v '^{' | head -1 | tr -d '[:space:]') || true
  fi
  if [[ -z "$value" && -f "$STATE_FILE" ]]; then
    value=$(grep "^${key}:" "$STATE_FILE" 2>/dev/null | sed "s/${key}: *//" | tr -d '[:space:]') || true
  fi
  printf '%s' "$value"
}

db_state_get_raw() {
  # Same as db_state_get but does NOT strip whitespace (used for opaque payloads).
  local key="$1"
  local value=""
  if [[ -f "$STATE_FILE" ]]; then
    value=$(grep "^${key}:" "$STATE_FILE" 2>/dev/null | sed "s/${key}: *//" | head -1) || true
  fi
  printf '%s' "$value"
}

db_record_verifier() {
  local session_id="$1" iteration="$2" verdict_json="$3" hmac_valid="$4"
  if db_available; then
    python3 "$DB_HELPER" record-verifier \
      --session-id "$session_id" \
      --iteration "$iteration" \
      --verdict-json "$verdict_json" \
      --hmac-valid "$hmac_valid" >/dev/null 2>&1 || true
  fi
}

db_event() {
  if db_available; then
    python3 "$DB_HELPER" event \
      --hook "stop" \
      --session-id "${1:-}" \
      --event-type "${2:-}" \
      --data-json "${3:-{}}" >/dev/null 2>&1 || true
  fi
}

# F-05: shared UTC parser
ts_age_seconds() {
  local ts="$1"
  [[ -z "$ts" ]] && { echo "-1"; return; }
  if [[ -x "$TSPARSE" ]]; then
    python3 "$TSPARSE" age-seconds "$ts" 2>/dev/null || echo "-1"
  else
    python3 - "$ts" <<'PY'
import sys, time
from datetime import datetime, timezone
raw = sys.argv[1].strip()
if raw.endswith("Z"): raw = raw[:-1] + "+00:00"
try:
    issued = datetime.fromisoformat(raw)
    if issued.tzinfo is None:
        issued = issued.replace(tzinfo=timezone.utc)
    print(int(time.time() - issued.astimezone(timezone.utc).timestamp()))
except Exception:
    print(-1)
PY
  fi
}

emit_block() {
  local reason="$1" vtype="$2" sysmsg="$3"
  local sess="${HOOK_SESSION:-unknown}"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sess "$sess" --arg t "$vtype" \
    '{ts:$ts, sessionId:$sess, type:$t}' >> "$VIOLATIONS_FILE" 2>/dev/null || true
  jq -n --arg r "$reason" --arg sm "$sysmsg" \
    '{decision:"block", reason:$r, systemMessage:$sm}'
  log "BLOCK [$vtype]: $reason"
}

remediation_block_message() {
  local verdict="$1" hmac_valid="$2" reason="$3" iteration="$4" session_id="$5"
  local remediation=""
  if [[ -f "$REMEDIATION_PROMPT_FILE" && -s "$REMEDIATION_PROMPT_FILE" ]]; then
    remediation=$(python3 - "$REMEDIATION_PROMPT_FILE" <<'PY' 2>/dev/null || true
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
# Keep hook payload bounded while preserving the mandatory remediation fields.
print(text[:24000])
PY
)
  fi
  if [[ -z "$remediation" ]]; then
    remediation=$'You are improving an existing output based on a critique.\n\nOriginal Output:\n(Use the prior assistant output in this same session.)\n\nIdentified Issues:\n- '"$reason"$'\n\nSuggested Fixes:\n- Address every verifier missing/deviation item and produce fresh evidence.\n\nInstructions:\n- Fix each issue explicitly\n- Do NOT rewrite the entire response\n- Preserve correct and useful parts\n- Improve clarity and depth only where needed\n- Avoid introducing new information unless required\n\nReturn the improved version.'
  fi
  cat <<EOF
ralph-gate: SESSION STOP BLOCKED — verifier did not sign PASS

Validation result: $verdict (HMAC valid: $hmac_valid), iteration $iteration, implementation_session_id=$session_id.

The next implementation pass MUST continue in this same session lineage. Do not spawn a disconnected implementation agent unless an explicit blocker is recorded. Apply the verifier critique below, then produce a new §3 exit report; the Stop hook will re-run validation until signed PASS.

=== RALPH STAGE 4 / REMEDIATE — SAME IMPLEMENTATION SESSION ===
$remediation
EOF
}

# v4.1.0: DB-first signed PASS lookup. Returns the base64-encoded payload
# from verifier_passes (preferred) or falls back to the legacy text mirror.
# Empty if neither carries one.
fetch_signed_pass_b64() {
  local session_id="$1"
  local payload_b64=""
  if db_available && [[ -n "$session_id" ]]; then
    payload_b64=$(python3 "$DB_HELPER" pass-fetch --session-id "$session_id" 2>/dev/null \
      | python3 -c '
import base64, json, os, sqlite3, sys
from pathlib import Path
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not obj.get("has_row") or obj.get("expired"):
    sys.exit(0)
sid = obj.get("session_id", "") or ""
kv_key = "state:" + sid + ":signed_pass_b64"
db_path = Path(os.environ.get("HOME", "")) / ".claude" / "state" / "ralph-loop-infinite.sqlite3"
if db_path.exists():
    try:
        conn = sqlite3.connect(str(db_path), timeout=5.0)
        cur = conn.execute("SELECT value FROM kv WHERE key = ?", (kv_key,))
        row = cur.fetchone()
        conn.close()
        if row and row[0]:
            print(row[0])
            sys.exit(0)
    except Exception:
        pass
sp = obj.get("signed_payload_json", "")
if not sp:
    sys.exit(0)
try:
    print(base64.b64encode(sp.encode("utf-8")).decode("ascii"))
except Exception:
    pass
' 2>/dev/null)
  fi
  if [[ -z "$payload_b64" ]]; then
    payload_b64=$(db_state_get_raw "signed_pass_b64")
  fi
  printf '%s' "$payload_b64"
}

# F-04: validate a stored signed PASS record exists and matches the live HMAC key.
# F-12: also verify provider/model match central policy.
# v4.1.0: DB-first lookup; legacy text mirror is the fallback only.
# Returns 0 on valid signed PASS (and sets PASS_INFO), 1 otherwise.
validate_signed_pass() {
  local expected_session="$1"
  local payload_b64
  payload_b64=$(fetch_signed_pass_b64 "$expected_session")
  [[ -z "$payload_b64" ]] && { log "BLOCK: signed_pass_b64 missing in DB and legacy state"; return 1; }
  if [[ ! -f "$HMAC_KEY_FILE" ]]; then
    log "BLOCK: HMAC key missing while validating stored pass"
    return 1
  fi
  PASS_INFO=$(HMAC_KEY_FILE="$HMAC_KEY_FILE" \
    TSPARSE="$TSPARSE" \
    POLICY_HELPER="$POLICY_HELPER" \
    EXPECTED_SESSION="$expected_session" \
    python3 - "$payload_b64" <<'PY'
import base64, hashlib, hmac, json, os, subprocess, sys, time
b64 = sys.argv[1]
expected_session = os.environ.get("EXPECTED_SESSION", "")
try:
    raw = base64.b64decode(b64)
    obj = json.loads(raw)
except Exception as exc:
    print(json.dumps({"ok": False, "reason": f"payload decode error: {exc}"}))
    raise SystemExit(0)
sig = obj.pop("hmac", "")
if not sig:
    print(json.dumps({"ok": False, "reason": "no hmac field in stored pass"}))
    raise SystemExit(0)
required = [
    "verdict", "session_id", "iteration", "issued_at", "expires_at",
    "provider", "model", "original_prompt_hash", "agent_output_hash",
    "evidence_bundle_hash", "pass_id",
]
missing = [k for k in required if k not in obj]
if missing:
    print(json.dumps({"ok": False, "reason": f"stored pass missing fields: {missing}"}))
    raise SystemExit(0)
if obj.get("verdict") != "PASS":
    print(json.dumps({"ok": False, "reason": "stored pass verdict != PASS"}))
    raise SystemExit(0)
canonical = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()
try:
    key = open(os.environ["HMAC_KEY_FILE"], "rb").read().strip()
except OSError as exc:
    print(json.dumps({"ok": False, "reason": f"hmac key unreadable: {exc}"}))
    raise SystemExit(0)
expected_sig = base64.b64encode(hmac.new(key, canonical, hashlib.sha256).digest()).decode()
if not hmac.compare_digest(expected_sig, sig):
    print(json.dumps({"ok": False, "reason": "HMAC mismatch on stored pass"}))
    raise SystemExit(0)
if expected_session and obj.get("session_id") != expected_session:
    print(json.dumps({"ok": False, "reason": f"session mismatch: pass={obj['session_id']} state={expected_session}"}))
    raise SystemExit(0)

# Use shared TS parser for TTL
tsparse = os.environ.get("TSPARSE", "")
def age(ts):
    try:
        out = subprocess.run([sys.executable, tsparse, "age-seconds", ts], capture_output=True, text=True, timeout=5)
        return int(out.stdout.strip() or "-1")
    except Exception:
        return -1
age_now = age(obj.get("issued_at", ""))
# TTL configurable via env var; expired pass triggers re-sign, not hard block
TTL_SECONDS="${RALPH_PASS_TTL_SECONDS:-120}"
ttl = TTL_SECONDS
if age_now < 0:
    print(json.dumps({"ok": False, "reason": f"issued_at unparseable: {obj.get('issued_at')}"})  )
    raise SystemExit(0)
if age_now > ttl:
    print(json.dumps({
        "ok": False,
        "reason": f"pass expired age={age_now}s > {ttl}s — re-verification triggered",
        "re_sign": True,
        "expired_age_s": age_now,
        "ttl_s": ttl
    }))
    raise SystemExit(0)

# Provider/model policy
try:
    policy_check = subprocess.run([sys.executable, os.environ["POLICY_HELPER"], "allow", obj.get("provider", ""), obj.get("model", "")], capture_output=True, text=True, timeout=5)
    if policy_check.returncode != 0:
        print(json.dumps({"ok": False, "reason": f"provider/model not in policy: {policy_check.stderr.strip()}"}))
        raise SystemExit(0)
except Exception as exc:
    print(json.dumps({"ok": False, "reason": f"policy helper failure: {exc}"}))
    raise SystemExit(0)

print(json.dumps({"ok": True, "age_s": age_now, "pass_id": obj.get("pass_id"), "provider": obj.get("provider"), "model": obj.get("model")}))
PY
)
  if echo "$PASS_INFO" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)' >/dev/null 2>&1; then
    return 0
  fi
  log "BLOCK signed-pass-validation: $(echo "$PASS_INFO" | head -c 200)"
  return 1
}

HOOK_INPUT=$(cat)

# Fix 3: Fail-closed on missing state file — only exit 0 if loop was never armed
if [[ ! -f "$STATE_FILE" ]]; then
  # Check DB: is a Ralph session active?
  db_init 2>/dev/null || true
  DB_SESSION=$(python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        for row in d if isinstance(d, list) else [d]:
            print(row.get('session_id','') or row.get('value',''), flush=True)
    except: pass
" < /dev/null 2>/dev/null || echo "")

  if [[ -n "$DB_SESSION" && "$DB_SESSION" != "None" ]]; then
    # Loop was armed via DB but state file is missing — fail closed
    echo "ralph-gate: STOP BLOCKED — state file missing while Ralph session active in DB" >&2
    exit 0
  fi
  # Loop never armed — nothing to do
  exit 0
fi

db_init

STATE_SESSION=$(db_state_get "session_id")
[[ -z "$STATE_SESSION" ]] && STATE_SESSION=$(grep '^session_id:' "$STATE_FILE" 2>/dev/null | sed 's/session_id: *//' | tr -d '[:space:]' || true)
if [[ "$STATE_SESSION" == '$CLAUDE_CODE_SESSION_ID' || "$STATE_SESSION" == '${CLAUDE_CODE_SESSION_ID:-}' ]]; then
  STATE_SESSION=""
fi

HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '
  .session_id // .sessionId // .sessionID // .metadata.session_id // .metadata.sessionId // ""
' 2>/dev/null || echo "")

TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // .transcriptPath // ""' 2>/dev/null || echo "")

# ── Fix 2: Allowlist file HMAC integrity check ─────────────────
verify_allowlist_integrity() {
  local ALLOWLIST_FILE="${HOME}/.claude/state/allowed_workers"
  local ALLOWLIST_HMAC_FILE="${HOME}/.claude/secrets/ralph-allowlist.hmac"
  [[ ! -f "$ALLOWLIST_FILE" ]] && return 0
  [[ ! -f "$ALLOWLIST_HMAC_FILE" ]] && { log "BLOCK: allowlist exists but has no HMAC file"; return 1; }
  local expected actual
  expected=$(cat "$ALLOWLIST_HMAC_FILE" 2>/dev/null | tr -d '[:space:]' || echo "")
  actual=$(python3 -c "
import hmac, hashlib
with open('$ALLOWLIST_FILE','rb') as f:
    with open('$HOME/.claude/secrets/ralph-hmac.key','rb') as k:
        digest = hmac.new(k.read(), f.read(), hashlib.sha256).hexdigest()
        print(digest)
" 2>/dev/null || echo "")
  [[ "\$expected" == "\$actual" ]] || { log "BLOCK: allowlist file tampered"; return 1; }
  return 0
}

# Run allowlist HMAC check on every Stop hook invocation
if ! verify_allowlist_integrity; then
  emit_block     "Ralph-loop-infinite gate ARMED: allowlist file integrity check failed (HMAC mismatch). File may have been tampered with. The gate fails closed."     "allowlist-hmac-fail"     "ralph-gate: STOP BLOCKED — allowlist integrity check failed"
  exit 0
fi

SESSION_MISMATCH=0
if [[ -n "$STATE_SESSION" && -n "$HOOK_SESSION" && "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  SESSION_MISMATCH=1
fi

STATE_VERIFIER_PASS=$(db_state_get "verifier_pass")
[[ -z "$STATE_VERIFIER_PASS" ]] && STATE_VERIFIER_PASS=$(grep '^verifier_pass:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_pass: *//' | tr -d '[:space:]' || true)

IS_ALLOWLISTED_SESSION=0
if [[ -f "$ALLOWLIST_FILE" ]] && grep -F -x -q "$HOOK_SESSION" "$ALLOWLIST_FILE" 2>/dev/null; then
  IS_ALLOWLISTED_SESSION=1
elif [[ -f "$LEGACY_MONITOR_FILE" ]] && grep -F -x -q "$HOOK_SESSION" "$LEGACY_MONITOR_FILE" 2>/dev/null; then
  IS_ALLOWLISTED_SESSION=1
fi

# Non-owner sessions: helper allowlists pass through, unknown sessions block.
if [[ $SESSION_MISMATCH -eq 1 ]]; then
  if [[ $IS_ALLOWLISTED_SESSION -eq 1 ]]; then
    log "ALLOW non-owner Stop (helper allowlisted): state_session=$STATE_SESSION hook_session=$HOOK_SESSION"
    exit 0
  fi
  log "BLOCK unknown session Stop attempt: state_session=$STATE_SESSION hook_session=$HOOK_SESSION"
  emit_block \
    "Ralph-loop-infinite gate ARMED: unknown session $HOOK_SESSION attempted to stop. Only the owner session or allowlisted helpers may control the gate. Continue autonomously." \
    "unknown-session-stop-attempt" \
    "ralph-gate: SESSION STOP BLOCKED — unknown session denied"
  exit 0
fi

# Owner session with a claimed PASS: revalidate HMAC-signed record on every allow.
if [[ "$STATE_VERIFIER_PASS" == "true" ]]; then
  if validate_signed_pass "$STATE_SESSION"; then
    AGE_S=$(echo "$PASS_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("age_s", -1))' 2>/dev/null || echo "-1")
    log "ALLOW owner Stop (signed pass valid, age=${AGE_S}s)"
    db_event "$HOOK_SESSION" "owner-pass-allow" "$(printf '{"age_s":%s}' "$AGE_S")"
    exit 0
  fi
  REASON_TEXT=$(echo "$PASS_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("reason","unsigned or expired"))' 2>/dev/null || echo "unsigned or expired")
  # Fix 1: TTL Race — re-sign trigger instead of hard block
  IS_RE_SIGN=$(echo "$PASS_INFO" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("re_sign","false"))' 2>/dev/null || echo "false")
  if [[ "$IS_RE_SIGN" == "True" ]]; then
    # Re-verification triggered — invalidate current pass and let loop continue
    python3 "$DB_HELPER" state-update --key verifier_pass --value false --state-file "$STATE_FILE" 2>/dev/null || true
    log "RE-SIGN TRIGGERED: pass expired, verifier_pass cleared — loop continues with fresh verifier call"
    emit_block \
      "Ralph-loop-infinite gate: verifier PASS expired (age > ${RALPH_PASS_TTL_SECONDS:-120}s). Pass invalidated for re-sign. A fresh HMAC-signed verifier verdict is required. Loop continues." \
      "pass-expired-re-sign" \
      "ralph-gate: RE-SIGN TRIGGERED — PASS invalidated, re-verification required"
    exit 0
  fi
  emit_block \
    "Ralph-loop-infinite gate ARMED: verifier_pass state present but signed pass record is invalid (${REASON_TEXT}). A fresh HMAC-signed verifier verdict is required to exit." \
    "verifier-pass-unsigned-or-invalid" \
    "ralph-gate: SESSION STOP BLOCKED — signed verifier PASS missing/invalid"
  exit 0
fi

if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED but transcript is missing or unreadable. The gate fails closed; keep working and produce a complete evidence report for verifier review." \
    "transcript-missing-while-armed" \
    "ralph-gate: SESSION STOP BLOCKED — transcript unreadable, gate armed"
  exit 0
fi

LAST_TEXT=$(jq -rs '
  [
    .[]
    | select((.message.role // .role // "") == "assistant")
    | (.message.content // .content // [])
    | .[]?
    | select((.type // "text") == "text")
    | (.text // empty)
  ]
  | last // ""
' "$TRANSCRIPT" 2>/dev/null)
JQ_EXIT=$?

if [[ $JQ_EXIT -ne 0 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED but transcript parsing failed. The gate fails closed; keep working and produce a complete evidence report for verifier review." \
    "transcript-parse-error-while-armed" \
    "ralph-gate: SESSION STOP BLOCKED — transcript parse failed"
  exit 0
fi

if [[ -z "$LAST_TEXT" ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED and no assistant output is available for verifier review. Stop is blocked until a complete verifier-reviewed report is produced." \
    "empty-assistant-output-while-armed" \
    "ralph-gate: SESSION STOP BLOCKED — no assistant output available"
  exit 0
fi

set +e
printf '%s' "$LAST_TEXT" | python3 -c '
import json
import re
import sys

text = sys.stdin.read()

def has(pattern: str) -> bool:
    return re.search(pattern, text, re.IGNORECASE | re.DOTALL) is not None

softening = r"\b(should be working|appears to pass|good enough|broadly OK|likely satisfies|minor issues remain but|in[-\s]process verification|simulated end[-\s]?to[-\s]?end|not yet user[-\s]?observed|behaviorally untested|not behaviorally verified|user not yet observed|patch verified only)\b"
placeholders = r"(<N>|<TOTAL>|\[count\]|\[total\]|\[N\])"

json_valid = False
for match in re.finditer(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", text, re.IGNORECASE):
    try:
        obj = json.loads(match.group(1))
    except Exception:
        continue
    payload = obj.get("ralph_loop_infinite") if isinstance(obj, dict) else None
    if not isinstance(payload, dict):
        payload = obj if isinstance(obj, dict) else None
    if not isinstance(payload, dict):
        continue
    status = str(payload.get("status", "")).lower()
    gate = str(payload.get("gate", "")).upper()
    prog = payload.get("programmatic", {}) or {}
    visu = payload.get("visual", {}) or {}
    trace = payload.get("traceability", {}) or {}
    iters = payload.get("iterations_required", payload.get("iterations"))
    try:
        tests_failed = int(prog.get("tests_failed", -1))
        tests_passed = int(prog.get("tests_passed", -1))
    except Exception:
        tests_failed = -1
        tests_passed = -1
    server_exc = prog.get("server_exceptions", -1)
    console_err = prog.get("browser_console_errors", -1)
    prog_ok = (
        status in {"passed", "pass"}
        and tests_failed == 0
        and tests_passed >= 0
        and (server_exc in (0, "0") or str(server_exc).upper().startswith("N/A"))
        and (console_err in (0, "0") or str(console_err).upper().startswith("N/A"))
    )
    visual_na = bool(visu.get("not_applicable")) or str(visu.get("status", "")).upper() == "N/A"
    if visual_na:
        visual_ok = bool(str(visu.get("reason", "")).strip()) or bool(str(visu.get("replacement_evidence", "")).strip())
    else:
        bps = visu.get("breakpoints", [])
        visual_ok = (
            isinstance(bps, list)
            and {"375px", "768px", "1280px", "1920px"}.issubset(set(map(str, bps)))
            and visu.get("layout_breaks", -1) in (0, "0")
            and visu.get("missing_assets", -1) in (0, "0")
            and str(visu.get("wcag_aa", "")).upper() in {"PASS", "N/A"}
        )
    def full_count(container, key):
        value = container.get(key)
        if isinstance(value, dict):
            try:
                return int(value.get("satisfied", 0)) == int(value.get("total", -1)) and int(value.get("total", -1)) > 0
            except Exception:
                return False
        if isinstance(value, str):
            return "100" in value and "%" in value
        return False
    trace_ok = full_count(trace, "requirements") and full_count(trace, "success_criteria") and full_count(trace, "deliverables")
    iter_ok = isinstance(iters, int) and iters >= 1
    if prog_ok and visual_ok and trace_ok and iter_ok and gate in {"VERIFIER_PASS_PENDING", "PASSED"}:
        json_valid = True
        break

programmatic = (
    has(r"###\s*Programmatic")
    and has(r"Tests:\s*.*\b\d+\b.*passed,\s*0\s*failed")
    and has(r"Server exceptions(?:\s*\([^)]*\))?:\s*(?:0\b|N/A\b.*\b(replaced|no server|artifact|not applicable)\b)")
    and has(r"Browser console errors:\s*(?:0\b|N/A\b.*\b(replaced|no UI|strict-JSON|jq|artifact|not applicable)\b)")
)
visual_na = has(r"###\s*Visual.*\bN/A\b.*\b(no UI|documentation-artifact|replaced|artifact|non-visual)\b")
visual = (
    has(r"###\s*Visual")
    and (has(r"Breakpoints verified:.*375px.*768px.*1280px.*1920px") or visual_na)
    and (has(r"Layout breaks:\s*0\b") or visual_na)
    and (has(r"Missing assets:\s*0\b") or visual_na)
    and (has(r"WCAG AA:\s*PASS\b") or has(r"WCAG AA:\s*N/A\b") or visual_na)
)
traceability = (
    has(r"###\s*Traceability")
    and has(r"Requirements satisfied:\s*\d+\s*/\s*\d+\s*\(100%\)")
    and has(r"Success criteria passed:\s*\d+\s*/\s*\d+\s*\(100%\)")
    and has(r"Deliverables verified:\s*\d+\s*/\s*\d+\s*\(100%\)")
)
prose_valid = (
    has(r"Production\s+Validation\s*[-—]\s*PASSED")
    and programmatic
    and visual
    and traceability
    and has(r"Iterations Required:\s*\d+")
    and has(r"Ralph[-\s]?loop[-\s]?infinite\s+gate:\s*PASSED")
)
contradiction = r"\b(?:Success criteria|Requirements|Deliverables) (?:satisfied|passed|verified):\s*\d+\s*/\s*\d+\s*\(100%\)[\s\S]{0,4000}\b(?:not\s+yet\s+(?:user[-\s]?observed|verified|tested|behaviorally|observed[-\s]?in[-\s]?production))"
if has(placeholders) or has(softening) or has(contradiction):
    sys.exit(1)
sys.exit(0 if (prose_valid or json_valid) else 1)
' 2>/dev/null
FULL_EXIT_EXIT=$?
set -e

HAS_FULL_EXIT_REPORT=0
if [[ $FULL_EXIT_EXIT -eq 0 ]]; then
  HAS_FULL_EXIT_REPORT=1
fi

HAS_STATUS_TOKEN=0
# v4.1.0: the ACTIVE marker MUST include the iteration suffix
# "— Iteration N of ∞" so partial markers like "[🔁 RALPH-LOOP-INFINITE: ACTIVE]"
# are rejected. NOT YET ACTIVE and COMPLETE are accepted as-is (no suffix).
STATUS_TOKEN_RX='\[(🔁|⛔|✅)[[:space:]]+RALPH-LOOP-INFINITE:[[:space:]]+(ACTIVE[[:space:]]+(—|--|-)[[:space:]]+Iteration[[:space:]]+[0-9]+[[:space:]]+of[[:space:]]+(∞|infinity|inf)|NOT[[:space:]]+YET[[:space:]]+ACTIVE|COMPLETE)'
LEADING=$(printf '%s' "$LAST_TEXT" | head -c 400)
if echo "$LEADING" | grep -E -q "$STATUS_TOKEN_RX"; then
  HAS_STATUS_TOKEN=1
fi

FIRST_LINE=$(printf '%s' "$LAST_TEXT" | python3 -c 'import sys; s=sys.stdin.read(); print(s.splitlines()[0] if s.splitlines() else "")' 2>/dev/null || echo "")
EXPECTED_OWNER_TAG="[owner_session:${STATE_SESSION}]"
EXPECTED_HOOK_TAG="[hook_session:${HOOK_SESSION}]"
HAS_SESSION_HEADER=0
if echo "$FIRST_LINE" | grep -E -q "$STATUS_TOKEN_RX" \
  && echo "$FIRST_LINE" | grep -F -q "$EXPECTED_OWNER_TAG" \
  && echo "$FIRST_LINE" | grep -F -q "$EXPECTED_HOOK_TAG"; then
  HAS_SESSION_HEADER=1
fi

TRIGGER_RX='<promise>[[:space:]]*(DONE|COMPLETE)[[:space:]]*</promise>|(^|[^[:alnum:]_])(ship(ping|ped)?|deploy(ed|ing|ment)?|production[-[:space:]]?ready|production[[:space:]]+deployment|cut[[:space:]]+(a[[:space:]]+)?release|go[-[:space:]]+live|push[[:space:]]+(to[[:space:]]+)?(prod|production|live))($|[^[:alnum:]_])|(^|[^[:alnum:]_])(task|build|feature|work|deployment|release|implementation|pipeline|delivery)[[:space:]]+(is[[:space:]]+)?(complete|done|finished|finalised|finalized|shipped|wrapped[[:space:]]+up|all[[:space:]]+delivered|delivered)($|[^[:alnum:]_])|(^|[^[:alnum:]_])100[[:space:]]*%[[:space:]]*(pass|complete|done|match|coverage)($|[^[:alnum:]_])|\bvalidate(d|s)?[[:space:]]+end[-[:space:]]?to[-[:space:]]?end\b|\bStatus:[[:space:]]*ALL[[:space:]]+CRITERIA[[:space:]]+MET\b|\bI[[:space:]]+(have|'"'"'ve)[[:space:]]+(delivered|completed|finished|shipped)\b|\b(everything|all)[[:space:]]+(is|has[[:space:]]+been)[[:space:]]+(complete|done|finished|delivered)\b'

ASK_OR_REQUEST_RX='\b(let[[:space:]]+me[[:space:]]+know)\b|\b(is[[:space:]]+this[[:space:]]+(ok|okay|fine|good|right|correct|what[[:space:]]+you[[:space:]]+want(ed)?))\b|\bshall[[:space:]]+i[[:space:]]+proceed\b|\bwould[[:space:]]+you[[:space:]]+like[[:space:]]+me[[:space:]]+to\b|\b(does[[:space:]]+this[[:space:]]+look[[:space:]]+(good|right|ok))\b|\b(please[[:space:]]+)?confirm[[:space:]]+(if|that)?\b|\b(can|could)[[:space:]]+you[[:space:]]+(verify|approve|confirm|check|provide|send|share|upload|review)\b|\boutput[[:space:]]+approved\b|\bgate[[:space:]]+approved\b|\b(loop|ralph)[[:space:]]+approved\b|\bapproval[[:space:]]+required\b|\b(need|require)[[:space:]]+(more|additional|some)?[[:space:]]*(info|information|details|clarification|input|feedback|review|verification)\b|\b(please|kindly)[[:space:]]+(provide|send|share|upload|review|verify|confirm|check)\b|\bI[[:space:]]+(can'\''t|cannot|won'\''t|will[[:space:]]+not)[[:space:]]+(continue|proceed|finish|complete)[[:space:]]+(until|without)\b|\b(blocked|waiting)[[:space:]]+(on|for)[[:space:]]+(you|user|feedback|input|confirmation|verification|review|approval)\b|\bI[[:space:]]+need[[:space:]]+you[[:space:]]+to\b|\?'

NA_RX='Ralph[-[:space:]]?loop[-[:space:]]?infinite[[:space:]]+gate:[[:space:]]*NOT[[:space:]]+APPLICABLE'
PASSED_ACK_RX='Production[[:space:]]+Validation[[:space:]]*[-—][[:space:]]*PASSED|Ralph[-[:space:]]?loop[-[:space:]]?infinite[[:space:]]+gate:[[:space:]]*PASSED'
STATE_TAMPER_ADVICE_RX='(allowed_workers|ralph-loop-(outsiders|monitors)|ralph-loop-infinite\.local|\.claude/state/ralph-loop-infinite|echo[^\n]{0,160}>>[^\n]{0,160}\.claude/state|modify[^\n]{0,120}(state|allowlist)|edit[^\n]{0,120}(state|allowlist))'
RECLASSIFY_OR_SCRIPT_ONLY_RX='(reclassif(y|ying|ied)|adjust(ing)?[[:space:]]+verification|reflect[[:space:]]+actual[[:space:]]+purpose|treat[^\n]{0,120}[[:space:]]+as[[:space:]]+(NA|PASS)|mark[^\n]{0,120}[[:space:]]+(NA|PASS)|convert[^\n]{0,120}FAIL[^\n]{0,120}(NA|PASS)|scripts?[[:space:]]+(exist|created)[^\n]{0,160}(but[[:space:]]+)?(not[[:space:]]+)?executed)'

HAS_TRIGGER=0
HAS_ASK_OR_REQUEST=0
HAS_STATE_TAMPER_ADVICE=0
HAS_RECLASSIFY_OR_SCRIPT_ONLY=0
HAS_NA=0
HAS_PASSED_ACK=0

if echo "$LAST_TEXT" | grep -E -q -i "$TRIGGER_RX"; then HAS_TRIGGER=1; fi
if echo "$LAST_TEXT" | grep -E -q -i "$ASK_OR_REQUEST_RX"; then HAS_ASK_OR_REQUEST=1; fi
if echo "$LAST_TEXT" | grep -E -q -i "$STATE_TAMPER_ADVICE_RX"; then HAS_STATE_TAMPER_ADVICE=1; fi
if echo "$LAST_TEXT" | grep -E -q -i "$RECLASSIFY_OR_SCRIPT_ONLY_RX"; then HAS_RECLASSIFY_OR_SCRIPT_ONLY=1; fi
if echo "$LAST_TEXT" | grep -E -q -i "$NA_RX"; then HAS_NA=1; fi
if echo "$LAST_TEXT" | grep -E -q -i "$PASSED_ACK_RX"; then HAS_PASSED_ACK=1; fi

LEN=${#LAST_TEXT}
if [[ $HAS_STATUS_TOKEN -eq 0 && $LEN -gt 120 && $HAS_FULL_EXIT_REPORT -eq 0 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED but assistant message lacks the mandatory status token. Re-issue with the active status token at the start and continue the loop." \
    "completion-without-status-token" \
    "ralph-gate: SESSION STOP BLOCKED — missing status token"
  exit 0
fi

if [[ $HAS_SESSION_HEADER -eq 0 && $LEN -gt 0 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED and assistant response is missing mandatory top header with status + owner/hook session IDs. First line must include '$EXPECTED_OWNER_TAG' and '$EXPECTED_HOOK_TAG' with a valid loop status token." \
    "missing-status-session-header" \
    "ralph-gate: SESSION STOP BLOCKED — missing status/session header"
  exit 0
fi

if [[ $HAS_NA -eq 1 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED: NOT APPLICABLE is not an exit path after invocation. Continue implementing and validating until the independent verifier returns signed PASS." \
    "not-applicable-while-armed" \
    "ralph-gate: SESSION STOP BLOCKED — NOT APPLICABLE rejected"
  exit 0
fi

if [[ $HAS_STATE_TAMPER_ADVICE -eq 1 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED: assistant output contains state/allowlist tampering advice. Agents must never tell users or helper sessions to edit ~/.claude/state, allowed_workers, monitor allowlists, or gate state files. Continue from the owner session or produce evidence for verifier review without state mutation advice." \
    "state-tamper-advice-while-gate-armed" \
    "ralph-gate: SESSION STOP BLOCKED — state/allowlist tamper advice forbidden"
  exit 0
fi

if [[ $HAS_RECLASSIFY_OR_SCRIPT_ONLY -eq 1 && $HAS_FULL_EXIT_REPORT -eq 0 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED: assistant output attempts to reclassify explicit requirements or rely on scripts existing instead of executed evidence. Do not convert FAIL to NA/PASS by redefining scope. Execute the required deliverables and cite concrete evidence." \
    "requirement-reclassification-or-script-only-while-gate-armed" \
    "ralph-gate: SESSION STOP BLOCKED — execute requirements, do not reclassify"
  exit 0
fi

if [[ $HAS_ASK_OR_REQUEST -eq 1 && $HAS_FULL_EXIT_REPORT -eq 0 ]]; then
  emit_block \
    "Ralph-loop-infinite gate ARMED: agent attempted to ask the user for approval, information, feedback, review, verification, or confirmation. Continue autonomously; do not contact the user between iterations." \
    "ask-user-or-request-info-while-gate-armed" \
    "ralph-gate: SESSION STOP BLOCKED — user request/question forbidden while armed"
  exit 0
fi

if [[ $HAS_PASSED_ACK -eq 1 && $HAS_FULL_EXIT_REPORT -eq 0 ]]; then
  emit_block \
    "Ralph-loop-infinite evidence acknowledgement detected, but the report is structurally incomplete or contains placeholders/softening language. Continue iterating and provide concrete evidence." \
    "incomplete-exit-report" \
    "ralph-gate: SESSION STOP BLOCKED — incomplete evidence report"
  exit 0
fi

if [[ $HAS_TRIGGER -eq 1 && $HAS_FULL_EXIT_REPORT -eq 0 ]]; then
  emit_block \
    "Ralph-loop-infinite completion claim detected without a complete evidence report. Do not exit, ask the user, or claim not applicable. Continue iterating." \
    "completion-claim-without-complete-exit-report" \
    "ralph-gate: SESSION STOP BLOCKED — completion claim without evidence"
  exit 0
fi

if [[ $HAS_FULL_EXIT_REPORT -eq 1 ]]; then
  # v4.1.0: STAGE=judge — about to invoke the verifier.
  log "STAGE=judge iter=pending sess=${HOOK_SESSION:-unknown}"
  # v4.1.0: atomic attempts-increment via the DB. Falls back to the legacy
  # grep|sed only if the DB is unavailable; on DB failure we fail closed
  # with a block rather than silently corrupting the counter.
  ITERATION=0
  if db_available; then
    INC_OUT=$(python3 "$DB_HELPER" increment-attempts \
      --session-id "${HOOK_SESSION:-unknown}" \
      --verdict "PENDING" \
      --reason "stop-hook iteration about to run" 2>/dev/null)
    ITERATION=$(printf '%s' "$INC_OUT" | python3 -c 'import json,sys
try:
  obj=json.load(sys.stdin)
  if obj.get("status") != "ok": sys.exit(0)
  print(obj.get("verifier_attempts", 0))
except Exception:
  sys.exit(0)' 2>/dev/null)
    if [[ -z "$ITERATION" || "$ITERATION" == "0" ]]; then
      log "WARN: DB increment-attempts returned no value, falling back to legacy counter"
      ITERATION=$(grep '^verifier_attempts:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_attempts: *//' | tr -d '[:space:]' || echo "0")
      [[ -z "$ITERATION" ]] && ITERATION=0
      ITERATION=$((ITERATION + 1))
    fi
  else
    ITERATION=$(grep '^verifier_attempts:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_attempts: *//' | tr -d '[:space:]' || echo "0")
    [[ -z "$ITERATION" ]] && ITERATION=0
    ITERATION=$((ITERATION + 1))
  fi

  AGENT_OUT_TMP=$(mktemp 2>/dev/null) || AGENT_OUT_TMP="/tmp/ralph-agent-out.$$"
  printf '%s' "$LAST_TEXT" > "$AGENT_OUT_TMP"

  ORIGINAL_PROMPT_PATH=$(db_state_get "original_user_prompt_path")
  [[ -z "$ORIGINAL_PROMPT_PATH" || ! -f "$ORIGINAL_PROMPT_PATH" ]] && ORIGINAL_PROMPT_PATH="$HOME/.claude/state/original-user-prompt.txt"

  # F-07: deterministic evidence precheck BEFORE invoking the verifier.
  PRECHECK_OUT=""
  PRECHECK_EXIT=0
  if [[ -f "$EVIDENCE_HELPER" ]]; then
    set +e
    PRECHECK_OUT=$(python3 "$EVIDENCE_HELPER" precheck \
      --agent-output-file "$AGENT_OUT_TMP" \
      --original-prompt-file "$ORIGINAL_PROMPT_PATH" \
      --transcript-path "$TRANSCRIPT" \
      --session-id "${HOOK_SESSION:-unknown}" \
      --iteration "$ITERATION" \
      --state-file "$STATE_FILE" 2>/dev/null)
    PRECHECK_EXIT=$?
    set -e
  fi

  if [[ -f "$EVIDENCE_HELPER" && $PRECHECK_EXIT -ne 0 ]]; then
    REASONS=$(echo "$PRECHECK_OUT" | python3 -c 'import sys,json
try:
  obj=json.load(sys.stdin)
  print("; ".join(obj.get("precheck",{}).get("reasons",[]))[:400])
except Exception:
  print("evidence precheck failed without parsable output")' 2>/dev/null)
    log "EVIDENCE_PRECHECK_FAIL [iter=$ITERATION] STAGE=critique sess=${HOOK_SESSION:-unknown}: $REASONS"
    db_event "$HOOK_SESSION" "evidence-precheck-fail" "$(python3 -c 'import json,sys; print(json.dumps({"reasons": sys.argv[1][:400]}))' "$REASONS")"
    rm -f "$AGENT_OUT_TMP" 2>/dev/null || true
    REASON_TRIM=$(printf '%s' "$REASONS" | tr '\n' ' ' | head -c 500)
    # v4.1.0: atomic state mutation via DB; fall back to legacy file rewrite
    # and fail closed (emit_block) if both surfaces fail.
    STATE_UPDATE_OK=0
    if db_available; then
      python3 "$DB_HELPER" state-update \
        --session-id "${HOOK_SESSION:-unknown}" \
        --set "verifier_attempts=$ITERATION" \
        --set "verifier_last_verdict=PRECHECK_FAIL" \
        --set "verifier_last_reason=$REASON_TRIM" >/dev/null 2>&1 && STATE_UPDATE_OK=1
    fi
    if [[ $STATE_UPDATE_OK -ne 1 ]]; then
      TMP_STATE=$(mktemp 2>/dev/null) || TMP_STATE="/tmp/ralph-state.$$"
      {
        grep -v -E '^(verifier_attempts|verifier_last_verdict|verifier_last_reason):' "$STATE_FILE" 2>/dev/null || true
        echo "verifier_attempts: $ITERATION"
        echo "verifier_last_verdict: PRECHECK_FAIL"
        echo "verifier_last_reason: $REASON_TRIM"
      } > "$TMP_STATE" 2>/dev/null
      if [[ -s "$TMP_STATE" ]] && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null; then
        STATE_UPDATE_OK=1
      fi
    fi
    if [[ $STATE_UPDATE_OK -ne 1 ]]; then
      log "FATAL: failed to record PRECHECK_FAIL state update (DB+file). Failing closed."
    fi
    # A PRECHECK_FAIL is a real loop failure: deterministically trigger the
    # machine-driven generator before blocking the Stop hook. This proves the
    # autonomy path does not depend on the main assistant deciding to retry.
    log "STAGE=generate iter=$ITERATION sess=${HOOK_SESSION:-unknown} after=PRECHECK_FAIL"
    run_generator_once || log "GENERATOR_PRECHECK_FAIL_PATH_NONZERO iter=$ITERATION sess=${HOOK_SESSION:-unknown}"
    emit_block \
      "Ralph-loop-infinite verifier-precheck FAILED: $REASONS. The report cites artifacts/logs that do not exist or makes claims without anchoring evidence. Produce a new §3 report with real, existing artifacts and re-run." \
      "verifier-evidence-precheck-fail" \
      "ralph-gate: SESSION STOP BLOCKED — evidence precheck rejected report"
    exit 0
  fi

  VERIFIER_OUT=$(AGENT_OUTPUT_FILE="$AGENT_OUT_TMP" \
    EVIDENCE_BUNDLE_HELPER="$EVIDENCE_HELPER" \
    TRANSCRIPT_PATH="$TRANSCRIPT" \
    ITERATION="$ITERATION" \
    SESSION_ID="${HOOK_SESSION:-unknown}" \
    bash "$VERIFIER_SCRIPT" 2>/dev/null)
  rm -f "$AGENT_OUT_TMP" 2>/dev/null || true

  VERDICT=$(printf '%s' "$VERIFIER_OUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("verdict",""))
except Exception: print("")' 2>/dev/null)

  HMAC_VALID=$(printf '%s' "$VERIFIER_OUT" | HOME="$HOME" HMAC_KEY_FILE="$HMAC_KEY_FILE" python3 -c '
import base64, hashlib, hmac, json, os, sys
try:
    obj = json.loads(sys.stdin.read())
    sig_b64 = obj.pop("hmac", "")
    if not sig_b64:
        print("no")
        raise SystemExit
    canonical = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    key = open(os.environ["HMAC_KEY_FILE"], "rb").read().strip()
    expected = base64.b64encode(hmac.new(key, canonical, hashlib.sha256).digest()).decode("ascii")
    print("yes" if hmac.compare_digest(expected, sig_b64) else "no")
except Exception:
    print("no")
' 2>/dev/null)

  SIGNED_STRICT_OK=$(printf '%s' "$VERIFIER_OUT" | python3 -c '
import json, sys
required = ("completeness", "correctness", "clarity", "depth", "actionability")
try:
    obj = json.load(sys.stdin)
    threshold = float(obj.get("threshold", 0.8))
    scoring = obj.get("scoring_dimensions")
    if obj.get("verdict") != "PASS" or obj.get("decision") != "accept" or not isinstance(scoring, dict):
        print("no"); raise SystemExit
    for d in required:
        cell = scoring.get(d)
        if not isinstance(cell, dict) or float(cell.get("score", 0.0)) < threshold:
            print("no"); raise SystemExit
    print("yes")
except Exception:
    print("no")
' 2>/dev/null)

  if [[ "$VERDICT" == "PASS" && "$HMAC_VALID" == "yes" && "$SIGNED_STRICT_OK" == "yes" ]]; then
    # Provider/model policy enforcement on the freshly signed verdict.
    PV=$(printf '%s' "$VERIFIER_OUT" | python3 -c 'import sys,json; o=json.load(sys.stdin); print(o.get("provider",""))' 2>/dev/null)
    MD=$(printf '%s' "$VERIFIER_OUT" | python3 -c 'import sys,json; o=json.load(sys.stdin); print(o.get("model",""))' 2>/dev/null)
    if ! python3 "$POLICY_HELPER" allow "$PV" "$MD" >/dev/null 2>&1; then
      log "BLOCK fresh verdict provider/model policy mismatch: provider=$PV model=$MD"
      db_record_verifier "${HOOK_SESSION:-unknown}" "$ITERATION" "$VERIFIER_OUT" "no"
      emit_block \
        "Ralph-loop-infinite verifier returned PASS but provider/model not in policy (provider=$PV model=$MD). Verifier must use the central provider/model. Continue iterating." \
        "verifier-pass-provider-policy-violation" \
        "ralph-gate: SESSION STOP BLOCKED — verifier provider/model not authorised"
      exit 0
    fi

    db_record_verifier "${HOOK_SESSION:-unknown}" "$ITERATION" "$VERIFIER_OUT" "yes"

    # Issue a freshly-signed stored pass record (F-04).
    NEW_ISSUED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NEW_EXPIRES=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    STORED=$(HOME="$HOME" \
      HMAC_KEY_FILE="$HMAC_KEY_FILE" \
      ORIGINAL_PROMPT_PATH="$ORIGINAL_PROMPT_PATH" \
      VERIFIER_OUT="$VERIFIER_OUT" \
      SESSION_ID="${HOOK_SESSION:-unknown}" \
      ITERATION="$ITERATION" \
      NEW_ISSUED="$NEW_ISSUED" \
      NEW_EXPIRES="$NEW_EXPIRES" \
      PROVIDER="$PV" \
      MODEL="$MD" \
      python3 - "$LAST_TEXT" <<'PY'
import base64, hashlib, hmac, json, os, sys, uuid
agent_output = sys.argv[1]
verdict = json.loads(os.environ["VERIFIER_OUT"]) if os.environ.get("VERIFIER_OUT") else {}
prompt = ""
prompt_path = os.environ.get("ORIGINAL_PROMPT_PATH", "")
if prompt_path and os.path.exists(prompt_path):
    try:
        prompt = open(prompt_path, encoding="utf-8", errors="replace").read()
    except Exception:
        prompt = ""
payload = {
    "verdict": "PASS",
    "session_id": os.environ.get("SESSION_ID", ""),
    "iteration": int(os.environ.get("ITERATION", "0")),
    "issued_at": os.environ.get("NEW_ISSUED", ""),
    "expires_at": os.environ.get("NEW_EXPIRES", ""),
    "provider": os.environ.get("PROVIDER", ""),
    "model": os.environ.get("MODEL", ""),
    "pass_id": f"pass-{uuid.uuid4()}",
    "original_prompt_hash": hashlib.sha256(prompt.encode("utf-8", errors="replace")).hexdigest(),
    "agent_output_hash": hashlib.sha256(agent_output.encode("utf-8", errors="replace")).hexdigest(),
    "evidence_bundle_hash": str(verdict.get("evidence_bundle_hash", verdict.get("report_path", ""))),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
key = open(os.environ["HMAC_KEY_FILE"], "rb").read().strip()
payload["hmac"] = base64.b64encode(hmac.new(key, canonical, hashlib.sha256).digest()).decode()
print(base64.b64encode(json.dumps(payload).encode()).decode())
PY
)
    log "STAGE=judge iter=$ITERATION sess=${HOOK_SESSION:-unknown} VERIFIER_PASS provider=$PV model=$MD"
    # v4.1.0: legacy mirror update with fail-closed semantics. DB-side
    # state mutation also happens via pass-store below; this preserves the
    # text mirror so existing tools that still read it stay consistent.
    TMP_STATE=$(mktemp 2>/dev/null) || TMP_STATE="/tmp/ralph-state.$$"
    {
      grep -v -E '^(verifier_pass|verifier_attempts|verifier_last_verdict|verifier_last_reason|approval_pending|exit_report_at|resolved|approved|verifier_passed_at|pass_expires_at|pass_max_age_s|pass_id|signed_pass_b64|remediation_target_session_id|remediation_from_iteration|remediation_explicit_blocker):' "$STATE_FILE" 2>/dev/null || true
      echo "verifier_pass: true"
      echo "verifier_attempts: $ITERATION"
      echo "verifier_last_verdict: PASS"
      echo "verifier_passed_at: $NEW_ISSUED"
      echo "pass_expires_at: $NEW_EXPIRES"
      echo "pass_max_age_s: 120"
      echo "signed_pass_b64: $STORED"
    } > "$TMP_STATE" 2>/dev/null
    LEGACY_MIRROR_OK=0
    if [[ -s "$TMP_STATE" ]] && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null; then
      LEGACY_MIRROR_OK=1
    fi
    if [[ $LEGACY_MIRROR_OK -ne 1 ]]; then
      log "WARN: failed to rewrite legacy state mirror on PASS; DB is authoritative"
    fi

    # Mirror the signed PASS into SQLite (verifier_passes + kv) so the DB
    # is forensically consistent with the legacy mirror. validate_signed_pass
    # reads from the legacy file for the fast path; this mirror keeps the
    # "SQLite is authoritative" doctrine truthful for auditors.
    if db_available; then
      DECODED_PAYLOAD=$(printf '%s' "$STORED" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace"))' 2>/dev/null || echo "")
      PASS_ID_DB=$(printf '%s' "$DECODED_PAYLOAD" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pass_id",""))
except Exception: print("")' 2>/dev/null)
      if [[ -n "$DECODED_PAYLOAD" && -n "$PASS_ID_DB" ]]; then
        python3 "$DB_HELPER" pass-store \
          --session-id "${HOOK_SESSION:-unknown}" \
          --iteration "$ITERATION" \
          --pass-id "$PASS_ID_DB" \
          --issued-at "$NEW_ISSUED" \
          --expires-at "$NEW_EXPIRES" \
          --signed-payload-json "$DECODED_PAYLOAD" \
          --signed-pass-b64 "$STORED" >/dev/null 2>&1 || true
      fi
    fi
    db_event "$HOOK_SESSION" "verifier-pass-stored" '{"provider":"'"$PV"'","model":"'"$MD"'"}'
    rm -f "$REMEDIATION_PROMPT_FILE" 2>/dev/null || true
    exit 0
  fi

  db_record_verifier "${HOOK_SESSION:-unknown}" "$ITERATION" "$VERIFIER_OUT" "$HMAC_VALID"

  # ── Convergence check (blog: "if iteration > 0 and judgement.score <= prev_score: break") ──
  # Run AFTER recording state so prev_score is available. Only meaningful when iteration > 0.
  CURRENT_SCORE=$(printf '%s' "$VERIFIER_OUT" | python3 -c 'import sys,json; obj=json.load(sys.stdin); print(float(obj.get("overall_score",obj.get("score",-1))))' 2>/dev/null || echo "-1")
  PREV_SCORE=$(db_state_get "verifier_last_score")
  [[ -z "$PREV_SCORE" ]] && PREV_SCORE=$(grep '^verifier_last_score:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_last_score: *//' | tr -d '[:space:]' || echo "")
  CONVERGENCE_BLOCK=0
  if [[ "$ITERATION" =~ ^[0-9]+$ && "$ITERATION" -gt 0 && -n "$PREV_SCORE" && "$PREV_SCORE" =~ ^-?[0-9.]+$ ]]; then
    python3 - <<'PY' "${CURRENT_SCORE}" "${PREV_SCORE}"
    import sys
    try:
        cur=float(sys.argv[1]); prev=float(sys.argv[2])
        # Stagnation: score not improving
        if cur <= prev and cur >= 0:
            print("STAGNATION")
        # Regression: score actually got worse
        elif cur < prev:
            print("REGRESSION")
        else:
            print("IMPROVING")
    except:
        print("UNKNOWN")
PY
    CONV_STATUS=$(python3 - "${CURRENT_SCORE}" "${PREV_SCORE}" 2>/dev/null)
    if [[ "$CONV_STATUS" == "STAGNATION" || "$CONV_STATUS" == "REGRESSION" ]]; then
      CONVERGENCE_BLOCK=1
      TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      jq -n --arg ts "$TS_NOW" --arg sess "${HOOK_SESSION:-unknown}" --arg iter "$ITERATION" --arg cur "$CURRENT_SCORE" --arg prev "$PREV_SCORE" --arg status "$CONV_STATUS" \
        '{ts:$ts, sessionId:$sess, type:"verifier-convergence-escalation", iteration:($iter|tonumber), current_score:($cur|tonumber), prev_score:($prev|tonumber), status:$status}' >> "$VIOLATIONS_FILE" 2>/dev/null || true
      python3 "$DB_HELPER" state-update \
        --session-id "${HOOK_SESSION:-unknown}" \
        --set "verifier_last_score=${CURRENT_SCORE}" \
        --set "verifier_last_verdict=CONVERGENCE" \
        --set "remediation_explicit_blocker=false" >/dev/null 2>&1 || true
      # NOT a blocker — escalation only. Agent cannot exit via convergence.
      # Blog rule: loop continues with escalated remediation. Only HMAC-signed
      # PASS exits. Convergence is a signal to change strategy, not permission to quit.
      python3 "$DB_HELPER" event \
        --hook "stop" \
        --session-id "${HOOK_SESSION:-unknown}" \
        --event-type "convergence-escalation" \
        --data-json '{"reason":"convergence","iteration":'"$ITERATION"',"current_score":'"$CURRENT_SCORE"',"prev_score":'"$PREV_SCORE"',"status":"'"$CONV_STATUS"'"}' >/dev/null 2>&1 || true
      REMEDIATE_MSG=$(remediation_block_message "$VERDICT" "$HMAC_VALID" "convergence-escalation: score $CURRENT_SCORE <= previous $PREV_SCORE on iteration $ITERATION — escalating remediation strategy; loop continues" "$ITERATION" "${HOOK_SESSION:-unknown}")
      # Blog convergence rule: NOT a rewrite, NOT a blocker.
      # Targeted Fix: preserve what's right, converge from there.
      # Escalation means the remediation prompt now carries:
      #   - Original Output (prior)
      #   - Identified Issues (convergence plateau)
      #   - Suggested Fixes (targeted, not wholesale)
      #   - Do NOT rewrite; preserve correct parts
      emit_block \
        "Ralph-loop-infinite convergence detected: score $CURRENT_SCORE <= previous $PREV_SCORE (iteration $ITERATION). This is NOT a blocker and NOT permission to exit. The loop continues with a Targeted Fix strategy: preserve correct and useful parts, apply only specific fixes where the prior output fell short. A naive full rewrite loses granularity and must be avoided. Only the HMAC-signed verifier PASS exits." \
        "verifier-convergence-escalation" \
        "$REMEDIATE_MSG"
      exit 0
    fi
  fi
  # Always record current score as prev for next iteration
  python3 "$DB_HELPER" state-update \
    --session-id "${HOOK_SESSION:-unknown}" \
    --set "verifier_last_score=${CURRENT_SCORE}" >/dev/null 2>&1 || true

  REASON=$(printf '%s' "$VERIFIER_OUT" | python3 -c 'import sys,json
try:
    obj=json.load(sys.stdin)
    parts=(obj.get("missing") or [])+(obj.get("deviations") or [])
    print("; ".join(parts) if parts else "verifier returned no specifics")
except Exception:
    print("verifier output unparseable")' 2>/dev/null)
  [[ -z "$REASON" ]] && REASON="verifier returned VERDICT=$VERDICT HMAC=$HMAC_VALID"

  REASON_TRIM=$(printf '%s' "$REASON" | tr '\n' ' ' | head -c 500)
  log "STAGE=remediate iter=$ITERATION sess=${HOOK_SESSION:-unknown} verdict=$VERDICT hmac=$HMAC_VALID"
  # v4.1.0: atomic state mutation via DB; fall back to legacy rewrite,
  # log FATAL if both fail (gate still blocks via emit_block below).
  STATE_UPDATE_OK=0
  if db_available; then
    python3 "$DB_HELPER" state-update \
      --session-id "${HOOK_SESSION:-unknown}" \
      --set "verifier_attempts=$ITERATION" \
      --set "verifier_last_verdict=$VERDICT" \
      --set "verifier_last_reason=$REASON_TRIM" \
      --set "remediation_target_session_id=${HOOK_SESSION:-unknown}" \
      --set "remediation_from_iteration=$ITERATION" \
      --set "remediation_explicit_blocker=false" >/dev/null 2>&1 && STATE_UPDATE_OK=1
  fi
  if [[ $STATE_UPDATE_OK -ne 1 ]]; then
    TMP_STATE=$(mktemp 2>/dev/null) || TMP_STATE="/tmp/ralph-state.$$"
    {
      grep -v -E '^(verifier_attempts|verifier_last_verdict|verifier_last_reason|remediation_target_session_id|remediation_from_iteration|remediation_explicit_blocker|verifier_last_score):' "$STATE_FILE" 2>/dev/null || true
      echo "verifier_attempts: $ITERATION"
      echo "verifier_last_verdict: $VERDICT"
      echo "verifier_last_reason: $REASON_TRIM"
      echo "remediation_target_session_id: ${HOOK_SESSION:-unknown}"
      echo "remediation_from_iteration: $ITERATION"
      echo "remediation_explicit_blocker: false"
      echo "verifier_last_score: ${CURRENT_SCORE}"
    } > "$TMP_STATE" 2>/dev/null
    if [[ -s "$TMP_STATE" ]] && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null; then
      STATE_UPDATE_OK=1
    fi
  fi
  if [[ $STATE_UPDATE_OK -ne 1 ]]; then
    log "FATAL: failed to record verifier-FAIL state update (DB+file). Failing closed."
  fi

  # Blog MAX_ITERATIONS=3; F3: cap is graceful return, not a blocker.
  MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-3}"
  if [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ && "$MAX_ITERATIONS" -gt 0 && "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n --arg ts "$TS_NOW" --arg sess "${HOOK_SESSION:-unknown}" --arg iter "$ITERATION" --arg max "$MAX_ITERATIONS" --arg reason "$REASON" \
      '{ts:$ts, sessionId:$sess, type:"max-reached-return", iteration:($iter|tonumber), max_iterations:($max|tonumber), reason:$reason, decision:"allow"}' >> "$VIOLATIONS_FILE" 2>/dev/null || true
    if db_available; then
      python3 "$DB_HELPER" state-update \
        --session-id "${HOOK_SESSION:-unknown}" \
        --set "verifier_last_verdict=MAX_REACHED_RETURN" \
        --set "verifier_last_reason=max iterations exhausted; returning best iteration: $REASON_TRIM" \
        --set "remediation_explicit_blocker=false" >/dev/null 2>&1 || true
    fi
    TMP_STATE=$(mktemp 2>/dev/null) || TMP_STATE="/tmp/ralph-state.$$"
    {
      grep -v -E '^(verifier_last_verdict|verifier_last_reason|remediation_explicit_blocker):' "$STATE_FILE" 2>/dev/null || true
      echo "verifier_last_verdict: MAX_REACHED_RETURN"
      echo "verifier_last_reason: max iterations exhausted; returning best iteration: $REASON_TRIM"
      echo "remediation_explicit_blocker: false"
    } > "$TMP_STATE" 2>/dev/null && mv "$TMP_STATE" "$STATE_FILE" 2>/dev/null || true
    jq -n --arg msg "Ralph-loop-infinite reached max iterations ($ITERATION/$MAX_ITERATIONS). Returning best-iteration output gracefully; no integrity blocker was raised." '{decision:"allow", reason:$msg}'
    exit 0
  fi

  # F2/F4: Stop is a monitor; the autonomous GENERATOR body runs as an explicit
  # subprocess through ralph-spawn.sh roles (orchestrator,coder,tester by default).
  run_generator_once

  if [[ "$ITERATION" -ge 2 ]]; then
    TS_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n --arg ts "$TS_NOW" --arg sess "${HOOK_SESSION:-unknown}" --arg iter "$ITERATION" --arg reason "$REASON" \
      '{ts:$ts, sessionId:$sess, type:"verifier-second-fail-block", iteration:($iter|tonumber), reason:$reason}' >> "$VIOLATIONS_FILE" 2>/dev/null || true
    jq -n --arg ts "$TS_NOW" --arg provider "anthropic" --arg sess "${HOOK_SESSION:-unknown}" --arg iter "$ITERATION" --arg reason "$REASON" \
      '{ts:$ts, provider:$provider, sessionId:$sess, severity:"high", event:"ralph-loop-infinite-second-fail", iteration:($iter|tonumber), reason:$reason}' >> "$PROVIDER_FEEDBACK_FILE" 2>/dev/null || true

    # F-14: do NOT terminate the host process by default. Loop continues
    # blocking the Stop until verifier PASS or explicit user disarm. An
    # opt-in kill mode is preserved only behind RALPH_ENABLE_SESSION_KILL=1.
    if [[ "${RALPH_ENABLE_SESSION_KILL:-0}" == "1" ]]; then
      TARGET_PID=$(echo "$HOOK_INPUT" | jq -r '.pid // .process_id // .metadata.pid // .metadata.process_id // ""' 2>/dev/null || echo "")
      if [[ "$TARGET_PID" =~ ^[0-9]+$ ]]; then
        kill -TERM "$TARGET_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$TARGET_PID" 2>/dev/null || true
        log "SESSION_TERMINATION (opt-in): TERM/KILL pid=$TARGET_PID after verifier second fail"
      fi
    fi
    REMEDIATE_MSG=$(remediation_block_message "$VERDICT" "$HMAC_VALID" "$REASON" "$ITERATION" "${HOOK_SESSION:-unknown}")
    emit_block \
      "Ralph-loop-infinite verifier failed again on iteration $ITERATION. The loop remains infinite; continue iterating in the same implementation session from the sealed prompt and remediation critique. Reason: $REASON" \
      "verifier-second-fail-block" \
      "$REMEDIATE_MSG"
    exit 0
  fi

  REMEDIATE_MSG=$(remediation_block_message "$VERDICT" "$HMAC_VALID" "$REASON" "$ITERATION" "${HOOK_SESSION:-unknown}")
  emit_block \
    "Ralph-loop-infinite verifier returned $VERDICT on iteration $ITERATION. HMAC valid: $HMAC_VALID. Missing/deviations: $REASON. Continue autonomously in the same implementation session from the sealed original prompt and injected remediation critique; do not contact the user." \
    "verifier-fail" \
    "$REMEDIATE_MSG"
  exit 0
fi

emit_block \
  "Ralph-loop-infinite gate remains active. Owner session stop is denied until a complete §3 report is produced and independently verified with signed PASS (or the loop is explicitly disarmed)." \
  "owner-stop-without-verifier-pass" \
  "ralph-gate: SESSION STOP BLOCKED — verifier PASS required while armed"
exit 0
