#!/bin/bash
# ralph-loop-infinite-prompt.sh - UserPromptSubmit hook injecting the
# ralph-loop-infinite contract via hookSpecificOutput.additionalContext, only
# while the gate is active.
#
# v4.1.0 (RALPH internal-thinking-loop refactor):
#   * FAIL re-injection now embeds the canonical PDF remediation template
#     ("Original Output / Identified Issues / Suggested Fixes / Do NOT
#     rewrite the entire response / Preserve correct and useful parts /
#     Improve clarity and depth only where needed / Avoid introducing new
#     information unless required"). The verifier shell wrote a fully
#     anchored remediation prompt to ~/.claude/state/ralph-remediation-prompt.txt
#     containing the prior output + critique. The prompt hook prefers that
#     file; if it is absent or stale relative to the current iteration the
#     hook emits a self-contained fallback that still carries the template
#     phrases verbatim so the agent sees the same structure either way.
#   * Stage logging marks each gate-active turn with [prompt] STAGE=generate
#     iter=N so the RALPH four-stage trace (generate/critique/judge/
#     remediate) is visible in ~/.claude/state/ralph-gate.log.
#
# v4.0.0 (F-06, F-11 remediation, preserved):
#   * Explicit /ralph-loop-infinite invocation after a stored PASS resets
#     verifier_pass, attempts, timestamps, and signed_pass_b64.
#   * Every DB helper invocation has stdout suppressed so the hook output
#     is protocol-clean.

set -uo pipefail

STATE_FILE="$HOME/.claude/state/ralph-loop-infinite.local"
CONTRACT_FILE="$HOME/.claude/hooks/ralph-loop-infinite-contract.md"
LOG_FILE="$HOME/.claude/state/ralph-gate.log"
ALLOWLIST_FILE="$HOME/.claude/state/ralph-loop-outsiders.local"
LEGACY_MONITOR_FILE="$HOME/.claude/state/ralph-loop-monitors.local"
DB_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-db.py"
REMEDIATION_PROMPT_FILE="$HOME/.claude/state/ralph-remediation-prompt.txt"
REMEDIATION_PROMPT_GLOB="$HOME/.claude/state/ralph-remediation-prompt.iter-*.txt"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '[%s] [prompt] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

db_available() { [[ -x "$DB_HELPER" ]] && command -v python3 >/dev/null 2>&1; }

db_arm() {
  local session_id="$1" armed_by="$2" trigger="$3" prompt_path="$4" contract="$5"
  if db_available; then
    python3 "$DB_HELPER" arm-or-rearm \
      --session-id "$session_id" \
      --armed-by "$armed_by" \
      --trigger "$trigger" \
      --prompt-path "$prompt_path" \
      --contract "$contract" >/dev/null 2>&1 || true
  fi
}

db_ingest_state() {
  if db_available && [[ -f "$STATE_FILE" ]]; then
    python3 "$DB_HELPER" ingest-state --state-file "$STATE_FILE" >/dev/null 2>&1 || true
  fi
}

db_state_get() {
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

db_event() {
  if db_available; then
    python3 "$DB_HELPER" event \
      --hook "prompt" \
      --session-id "${1:-}" \
      --event-type "${2:-}" \
      --data-json "${3:-{}}" >/dev/null 2>&1 || true
  fi
}

HOOK_INPUT=$(cat 2>/dev/null || echo "{}")

RAW_PROMPT_TEXT=$(echo "$HOOK_INPUT" | jq -r '
  (
    .prompt // .user_prompt // .text // .message // .content // .input // .userInput //
    .last_user_message // .lastUserMessage // .payload.prompt // .payload.text // ""
  )
  | if type == "array" then (map(if type == "object" then (.text // .content // "") else tostring end) | join(" ")) else tostring end
' 2>/dev/null || echo "")

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '
  .session_id // .sessionId // .sessionID // .metadata.session_id // .metadata.sessionId // ""
' 2>/dev/null || echo "")
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
fi
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
TRANSCRIPT_SESSION_ID=$(echo "$TRANSCRIPT_PATH" \
  | sed -E 's|.*/projects/[^/]+/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*|\1|' \
  | grep -E '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' || echo "")
if [[ -n "$TRANSCRIPT_SESSION_ID" ]]; then
  SESSION_ID="$TRANSCRIPT_SESSION_ID"
fi
HELPER_SESSION=0
if [[ "$TRANSCRIPT_PATH" == */projects/-private-tmp/* ]] || \
   [[ "$TRANSCRIPT_PATH" == */projects/-tmp/* ]] || \
   [[ "$HOOK_CWD" == /tmp/* ]] || \
   [[ "$HOOK_CWD" == /private/tmp/* ]]; then
  HELPER_SESSION=1
fi
{
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] prompt-hook session_id resolution"
  echo "  json.session_id=$(echo "$HOOK_INPUT" | jq -r '.session_id // "<none>"' 2>/dev/null)"
  echo "  transcript_path=$TRANSCRIPT_PATH"
  echo "  cwd=$HOOK_CWD"
  echo "  helper_session=$HELPER_SESSION"
  echo "  TRANSCRIPT_SESSION_ID=$TRANSCRIPT_SESSION_ID"
  echo "  final SESSION_ID=$SESSION_ID"
} >> "$HOME/.claude/state/prompt-hook-debug.log" 2>/dev/null || true
if [[ $HELPER_SESSION -eq 1 ]]; then
  log "HELPER-SESSION-SKIP: ephemeral helper claude detected (transcript=$TRANSCRIPT_PATH cwd=$HOOK_CWD)"
  exit 0
fi

PROMPT_TEXT=$(printf '%s' "$RAW_PROMPT_TEXT" | python3 -c '
import sys, unicodedata, re
text = sys.stdin.read()
text = unicodedata.normalize("NFKC", text)
text = re.sub(r"<!--[\s\S]*?-->", " ", text)
text = re.sub(r"/\*[\s\S]*?\*/", " ", text)
text = re.sub(r"//[^\n]*", " ", text)
text = re.sub(r"^#[^\n]*", " ", text, flags=re.MULTILINE)
text = re.sub(r"\s+", " ", text)
print(text)
' 2>/dev/null || printf '%s' "$RAW_PROMPT_TEXT")

TRIGGER_AUTO_ARM_RX='(^|[[:space:]])/ralph-loop-infinite($|[[:space:]\[])|(^|[[:space:]])ralph-loop-infinite($|[[:space:]\[])|(^|[[:space:]])ralph[[:space:]]+loop[[:space:]]+infinite($|[[:space:]\[])|(^|[[:space:]])invoke[[:space:]]+ralph-loop-infinite($|[[:space:]\[])'
SHIP_LANG_RX='\b(ship(ping|ped|-out)?|deploy(ing|ed|ment)?|production[-[:space:]]?(ready|deployment)|prod[-[:space:]]?ready|100[[:space:]]*%[[:space:]]*(pass|complete|done|match|coverage)|validate(d|s)?[[:space:]]+end[-[:space:]]?to[-[:space:]]?end|merged?[[:space:]]+to[[:space:]]+main|cut[[:space:]]+(a[[:space:]]+)?release|go[-[:space:]]+live|publish(ing)?|launch(ing)?|push[[:space:]]+(to[[:space:]]+)?(prod|production|live)|(perfect|exact)[[:space:]]+match|final[[:space:]]+(approval|validation)|wrapped[[:space:]]+up|all[[:space:]]+delivered|fully[[:space:]]+(complete|done|delivered))\b'
DISARM_RX='\bdisarm[[:space:]]+ralph[-[:space:]]?loop[-[:space:]]?infinite[[:space:]]*[-:—][[:space:]]*'
GATE_DIAGNOSTIC_RX='^Ralph-loop-infinite[[:space:]]+(gate[[:space:]]+ARMED|evidence[[:space:]]+acknowledgement[[:space:]]+detected|gate:[[:space:]]+NOT[[:space:]]+APPLICABLE)\b'

PROMPT_TRIGGERED_INVOCATION=0
PROMPT_TRIGGERED_SHIP=0
PROMPT_HAS_DISARM=0
PROMPT_IS_GATE_DIAGNOSTIC=0

if echo "$PROMPT_TEXT" | grep -E -i -q "$DISARM_RX"; then PROMPT_HAS_DISARM=1; fi
if echo "$PROMPT_TEXT" | grep -E -i -q "$GATE_DIAGNOSTIC_RX"; then PROMPT_IS_GATE_DIAGNOSTIC=1; fi
if [[ $PROMPT_HAS_DISARM -eq 0 && $PROMPT_IS_GATE_DIAGNOSTIC -eq 0 ]]; then
  if echo "$PROMPT_TEXT" | grep -E -i -q "$TRIGGER_AUTO_ARM_RX"; then PROMPT_TRIGGERED_INVOCATION=1; fi
  if echo "$PROMPT_TEXT" | grep -E -i -q "$SHIP_LANG_RX"; then PROMPT_TRIGGERED_SHIP=1; fi
fi

SEALED_PROMPT_PATH="$HOME/.claude/state/original-user-prompt.txt"
SEAL_PROMPT() {
  printf '%s' "$RAW_PROMPT_TEXT" > "$SEALED_PROMPT_PATH" 2>/dev/null || true
  chmod 600 "$SEALED_PROMPT_PATH" 2>/dev/null || true
}

WRITE_FRESH_STATE() {
  local armed_by="$1" trigger="$2"
  db_arm "$SESSION_ID" "$armed_by" "$trigger" "$SEALED_PROMPT_PATH" "$CONTRACT_FILE"
  local target="$STATE_FILE"
  if [[ -f "$STATE_FILE" ]]; then
    target=$(mktemp 2>/dev/null) || target="/tmp/ralph-state.$$"
  fi
  {
    echo "active: true"
    echo "session_id: $SESSION_ID"
    echo "started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "contract: $CONTRACT_FILE"
    echo "armed_by: $armed_by"
    echo "trigger: $trigger"
    echo "original_user_prompt_path: $SEALED_PROMPT_PATH"
    echo "verifier_attempts: 0"
    echo "verifier_pass: false"
  } > "$target" 2>/dev/null || true
  if [[ "$target" != "$STATE_FILE" && -s "$target" ]]; then
    mv "$target" "$STATE_FILE" 2>/dev/null || true
  fi
  : > "$ALLOWLIST_FILE" 2>/dev/null || true
  chmod 600 "$ALLOWLIST_FILE" 2>/dev/null || true
  : > "$LEGACY_MONITOR_FILE" 2>/dev/null || true
  chmod 600 "$LEGACY_MONITOR_FILE" 2>/dev/null || true
  # Re-arm clears any stale remediation prompt from a prior loop.
  rm -f "$REMEDIATION_PROMPT_FILE" $REMEDIATION_PROMPT_GLOB 2>/dev/null || true
}

REARM_RESET_SAME_SESSION() {
  db_arm "$SESSION_ID" "prompt-hook-rearm" "explicit-invocation" "$SEALED_PROMPT_PATH" "$CONTRACT_FILE"
  local target
  target=$(mktemp 2>/dev/null) || target="/tmp/ralph-state.$$"
  {
    grep -v -E '^(verifier_pass|verifier_attempts|verifier_last_verdict|verifier_last_reason|verifier_passed_at|pass_expires_at|pass_max_age_s|pass_id|signed_pass_b64|approval_pending|exit_report_at|resolved|approved|started_at|trigger|original_user_prompt_path):' \
      "$STATE_FILE" 2>/dev/null || true
    echo "started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "trigger: explicit-invocation"
    echo "original_user_prompt_path: $SEALED_PROMPT_PATH"
    echo "verifier_attempts: 0"
    echo "verifier_pass: false"
  } > "$target" 2>/dev/null
  if [[ -s "$target" ]]; then
    mv "$target" "$STATE_FILE" 2>/dev/null || true
  fi
  db_event "$SESSION_ID" "explicit-rearm-reset" '{}'
  rm -f "$REMEDIATION_PROMPT_FILE" $REMEDIATION_PROMPT_GLOB 2>/dev/null || true
}

if [[ ! -f "$STATE_FILE" ]]; then
  if [[ $PROMPT_TRIGGERED_INVOCATION -eq 1 ]]; then
    if [[ -z "$SESSION_ID" ]]; then
      log "WARN: explicit invocation seen but session id missing; skipping state arm"
    else
      SEAL_PROMPT
      WRITE_FRESH_STATE "prompt-hook-auto-arm" "explicit-invocation"
      log "AUTO-ARM: gate armed by explicit invocation (session=$SESSION_ID)"
    fi
  elif [[ $PROMPT_TRIGGERED_SHIP -eq 1 ]]; then
    log "SHIP-LANGUAGE-IGNORED: gate disarmed; only explicit /ralph-loop-infinite arms a fresh gate"
  fi
else
  db_ingest_state
  CURRENT_SESSION=$(db_state_get "session_id")
  [[ -z "$CURRENT_SESSION" ]] && CURRENT_SESSION=$(grep '^session_id:' "$STATE_FILE" 2>/dev/null | sed 's/session_id: *//' | tr -d '[:space:]' || true)
  if [[ $PROMPT_TRIGGERED_INVOCATION -eq 1 ]]; then
    if [[ -z "$SESSION_ID" ]]; then
      log "WARN: explicit invocation seen but session id missing; refusing rebind"
    elif [[ -n "$CURRENT_SESSION" && "$SESSION_ID" != "$CURRENT_SESSION" ]]; then
      log "BLOCKED-SESSION-TRANSFER: cannot rebind owner $CURRENT_SESSION -> $SESSION_ID"
    else
      SEAL_PROMPT
      REARM_RESET_SAME_SESSION
      log "REINVOKE: explicit invocation resealed prompt + reset PASS state (session=$SESSION_ID)"
    fi
  else
    STATE_VERIFIER_PASS=$(db_state_get "verifier_pass")
    [[ -z "$STATE_VERIFIER_PASS" ]] && STATE_VERIFIER_PASS=$(grep '^verifier_pass:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_pass: *//' | tr -d '[:space:]' || true)
    STATE_RESOLVED=$(db_state_get "resolved")
    [[ -z "$STATE_RESOLVED" ]] && STATE_RESOLVED=$(grep '^resolved:' "$STATE_FILE" 2>/dev/null | sed 's/resolved: *//' | tr -d '[:space:]' || true)
    if [[ ( "$STATE_VERIFIER_PASS" == "true" || "$STATE_RESOLVED" == "true" ) && $PROMPT_TRIGGERED_SHIP -eq 1 ]]; then
      log "SHIP-LANGUAGE-REARM-IGNORED: only explicit /ralph-loop-infinite re-arms the gate"
    fi
  fi
fi

if echo "$PROMPT_TEXT" | grep -E -i -q "$DISARM_RX"; then
  REASON_LEN=$(echo "$PROMPT_TEXT" | grep -E -i -o "${DISARM_RX}.+" | head -c 200 | wc -c | tr -d ' ')
  if [[ ${REASON_LEN:-0} -gt 30 && -f "$STATE_FILE" ]]; then
    log "DISARM: user-typed disarm phrase detected (session=$SESSION_ID)"
    HMAC_KEY_FILE="$HOME/.claude/secrets/ralph-hmac.key"
    if [[ -f "$HMAC_KEY_FILE" ]]; then
      DISARM_SIG=$(echo -n "disarm:$SESSION_ID:$(date -u +%Y-%m-%dT%H:%M:%SZ)" | openssl dgst -sha256 -hmac "$(cat "$HMAC_KEY_FILE")" | awk '{print $2}')
      echo "{\"event\":\"disarm\",\"session_id\":\"$SESSION_ID\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"hmac_sha256\":\"$DISARM_SIG\"}" >> "$HOME/.claude/state/violations.jsonl" 2>/dev/null || true
    fi
    rm -f "$STATE_FILE" 2>/dev/null || true
    rm -f "$ALLOWLIST_FILE" 2>/dev/null || true
    rm -f "$LEGACY_MONITOR_FILE" 2>/dev/null || true
    rm -f "$REMEDIATION_PROMPT_FILE" $REMEDIATION_PROMPT_GLOB 2>/dev/null || true
  fi
fi

BANNER='[NON-NEGOTIABLE] ALL AI provider APIs are in .env - ZERO dummy/fallback/placeholder/simulated code under any scope. Invoked skills are binding and must be fully executed. Real APIs. Real keys. No exceptions. [ralph-loop-infinite v4.2.0] When the gate is armed it is GLOBALLY BINDING - cannot be skipped, bypassed, deferred, or self-exempted by any agent reasoning. The ONLY valid exit is an HMAC-signed verifier-PASS verdict from the independent AI verifier (Anthropic claude-opus-4-7 primary; MiniMax-M2.7 fallback for Opus 4.7 and Deepseek; GLM fallback for all other AI agents; every dimension >= 0.8). Producing a §3 exit report triggers the verifier automatically; if PASS the loop exits; if FAIL the loop continues in the same implementation session with the validation critique injected as remediation context. Agent MUST NOT ask the user for approval. User phrases like "approved", "looks good", "ship it" are FEEDBACK, not exits. Every assistant response while armed MUST start with: [STATUS-TOKEN] [owner_session:<state_session_id>] [hook_session:<current_hook_session_id>].'

# Canonical PDF remediation template phrases. The verifier shell wrote a
# fully-anchored remediation prompt to $REMEDIATION_PROMPT_FILE that quotes
# the prior generated output and the critique items verbatim. If that file
# is present we prepend the FAIL block with its contents. If absent, we
# still emit the canonical template phrases below so the agent always sees
# the same structural cues.
REMEDIATION_TEMPLATE_HEADER='You are improving an existing output based on a critique.

Original Output:
(see prior assistant turn -- it is the §3 exit report that just FAILED verifier review; treat its content as the anchor and reuse the parts that are still correct)

Identified Issues:
(see verifier_last_reason and the missing/deviations enumerated above)

Suggested Fixes:
(see the verifier defense report under ~/.claude/state/verifier-reports/ for per-dimension evidence and explicit suggestions)

Instructions:
- Fix each issue explicitly
- Do NOT rewrite the entire response
- Preserve correct and useful parts
- Improve clarity and depth only where needed
- Avoid introducing new information unless required

Return the improved version.'

GATE_STATE_BLOCK=""
if [[ -f "$STATE_FILE" ]]; then
  CURRENT_VERIFIER_PASS=$(db_state_get "verifier_pass")
  [[ -z "$CURRENT_VERIFIER_PASS" ]] && CURRENT_VERIFIER_PASS=$(grep '^verifier_pass:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_pass: *//' | tr -d '[:space:]' || true)
  CURRENT_LAST_VERDICT=$(db_state_get "verifier_last_verdict")
  [[ -z "$CURRENT_LAST_VERDICT" ]] && CURRENT_LAST_VERDICT=$(grep '^verifier_last_verdict:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_last_verdict: *//' | tr -d '[:space:]' || true)
  CURRENT_ATTEMPTS=$(db_state_get "verifier_attempts")
  [[ -z "$CURRENT_ATTEMPTS" ]] && CURRENT_ATTEMPTS=$(grep '^verifier_attempts:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_attempts: *//' | tr -d '[:space:]' || echo "0")
  [[ -z "$CURRENT_ATTEMPTS" ]] && CURRENT_ATTEMPTS="0"
  CURRENT_LAST_REASON=$(db_state_get "verifier_last_reason")
  [[ -z "$CURRENT_LAST_REASON" ]] && CURRENT_LAST_REASON=$(grep '^verifier_last_reason:' "$STATE_FILE" 2>/dev/null | sed 's/verifier_last_reason: *//' || true)
  REMEDIATION_TARGET=$(db_state_get "remediation_target_session_id")
  [[ -z "$REMEDIATION_TARGET" ]] && REMEDIATION_TARGET=$(grep '^remediation_target_session_id:' "$STATE_FILE" 2>/dev/null | sed 's/remediation_target_session_id: *//' || true)
  CURRENT_SESSION=$(db_state_get "session_id")
  [[ -z "$CURRENT_SESSION" ]] && CURRENT_SESSION=$(grep '^session_id:' "$STATE_FILE" 2>/dev/null | sed 's/session_id: *//' || true)

  if [[ -z "$CURRENT_SESSION" || -z "$SESSION_ID" || "$CURRENT_SESSION" != "$SESSION_ID" ]]; then
    log "NON-OWNER-PROMPT-BLOCK: state_session=${CURRENT_SESSION:-missing} hook_session=${SESSION_ID:-missing} — non-owner prompt denied; same-session remediation required"
    exit 0
  fi

  log "STAGE=generate iter=$CURRENT_ATTEMPTS sess=$CURRENT_SESSION"

  if [[ "$CURRENT_VERIFIER_PASS" == "true" ]]; then
    GATE_STATE_BLOCK=$'\n\n=== GATE STATE ===\nverifier_pass: true (signed PASS valid). The current loop iteration is closed. Proceed normally; new explicit invocation will re-arm a fresh cycle.'
  elif [[ "$CURRENT_LAST_VERDICT" == "FAIL" || "$CURRENT_LAST_VERDICT" == "PRECHECK_FAIL" ]]; then
    REMEDIATION_BODY=$(python3 - "$HOME/.claude/state" "$REMEDIATION_TEMPLATE_HEADER" <<'PY'
import pathlib, re, sys
state = pathlib.Path(sys.argv[1])
fallback = sys.argv[2]
files = []
for p in state.glob('ralph-remediation-prompt.iter-*.txt'):
    m = re.search(r'iter-(\d+)', p.name)
    files.append((int(m.group(1)) if m else 0, p))
parts = []
for it, p in sorted(files)[-2:]:
    try:
        parts.append(f"=== REMEDIATION HISTORY iteration {it} ===\n" + p.read_text(encoding='utf-8', errors='replace'))
    except OSError:
        pass
if not parts:
    latest = state / 'ralph-remediation-prompt.txt'
    if latest.exists():
        try:
            parts.append(latest.read_text(encoding='utf-8', errors='replace'))
        except OSError:
            pass
print('\n\n'.join(parts) if parts else fallback)
PY
)
    GATE_STATE_BLOCK=$"\n\n=== GATE STATE ===\nactive: true · session_id: $CURRENT_SESSION · verifier_attempts: $CURRENT_ATTEMPTS · last_verdict: $CURRENT_LAST_VERDICT · remediation_target_session_id: ${REMEDIATION_TARGET:-$CURRENT_SESSION}\nLast verifier reason: $CURRENT_LAST_REASON\n\n=== RALPH STAGE 4 / REMEDIATE (anchored to prior output + critique; same implementation session required) ===\n$REMEDIATION_BODY\n\nWhen you have applied the fixes above, produce a NEW §3 exit report with NEW evidence (cited artifacts whose bytes corroborate every numeric claim). End the turn — the Stop hook will call the verifier again. DO NOT ask the user. DO NOT spawn a disconnected implementation agent unless remediation_explicit_blocker is true in gate state."
  else
    GATE_STATE_BLOCK=$"\n\n=== GATE STATE ===\nactive: true · session_id: $CURRENT_SESSION · no verifier call yet this cycle, attempts=$CURRENT_ATTEMPTS.\nWhen work that triggers §1 is complete, produce the §3 exit report and end the turn. The Stop hook calls the verifier; if PASS the loop exits, if FAIL the loop iterates with a targeted remediation prompt anchored to the critique."
  fi
fi

if [[ -f "$STATE_FILE" ]] && [[ -f "$CONTRACT_FILE" ]]; then
  CONTRACT=$(cat "$CONTRACT_FILE")
  CONTEXT=$(printf '%s%s\n\n=== RALPH-LOOP-INFINITE CONTRACT (gate active - re-injected each turn) ===\n%s' "$BANNER" "$GATE_STATE_BLOCK" "$CONTRACT")
  jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$ctx}}'
fi
exit 0
