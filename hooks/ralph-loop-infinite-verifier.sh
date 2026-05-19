#!/bin/bash
# ralph-loop-infinite-verifier.sh — Independent verifier (production-only).
#
# v4.1.0 (RALPH internal-thinking-loop refactor):
#   * The judge stage is now performed by the explicit Python helper
#     ``ralph-loop-infinite-ralph.py judge``. The helper handles:
#       - Anthropic/Deepseek lineages fall back to MiniMax-M2.7;
#         all other AI-agent lineages fall back to GLM
#       - Explicit scoring dimensions: completeness, correctness, clarity,
#         depth, actionability (each 0.0-1.0, threshold 0.8)
#       - Provider/model/effort metadata recorded in every verdict
#       - Stage logs at ~/.claude/state/ralph-thinking-loop.jsonl
#     The shell remains the HMAC-signing surface so signed-pass storage and
#     legacy stop-hook validation are unchanged.
#   * API keys are loaded explicitly from ~/.claude/.env.production (the
#     user's global env file) via the Python helper. The shell preserves the
#     opt-in env mechanisms (RALPH_VERIFIER_ENV_FILE, RALPH_VERIFIER_ANTHROPIC_API_KEY)
#     and never echoes a key value.
#   * Signed verdict now carries scoring_dimensions, overall_score, threshold,
#     and decision in addition to the previous fields.
#   * The legacy /Users/vic/claude/General-Work paths are gone (carried over
#     from v4.0.0).

set -uo pipefail

# ── S-1: API key loading (three-source fallback) ─────────────────────────────
# Kept for backwards compatibility with any consumer that exec()s this script
# directly and expects ANTHROPIC_API_KEY in the environment. The Python helper
# does its own loading and never reads from this shell's env unless we export
# the key, so we still call this so ad-hoc bash users see a clear error.
ralph_verifier_load_key() {
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && return 0
  if [[ -n "${RALPH_VERIFIER_ANTHROPIC_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY="$RALPH_VERIFIER_ANTHROPIC_API_KEY"
    printf "[verifier] key loaded from RALPH_VERIFIER_ANTHROPIC_API_KEY\n" >&2
    return 0
  fi
  if [[ -n "${RALPH_VERIFIER_ENV_FILE:-}" && -r "${RALPH_VERIFIER_ENV_FILE}" ]]; then
    set -a && . "${RALPH_VERIFIER_ENV_FILE}" && set +a
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { printf "[verifier] key loaded from RALPH_VERIFIER_ENV_FILE=%s\n" "$RALPH_VERIFIER_ENV_FILE" >&2; return 0; }
  fi
  local default_env="${HOME}/.claude/.env.production"
  if [[ -r "$default_env" ]]; then
    set -a && . "$default_env" && set +a
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && { printf "[verifier] key loaded from %s\n" "$default_env" >&2; return 0; }
  fi
  # Not fatal: the Python helper will look again and use the policy fallback
  # chain (MiniMax-M2.7 for Opus/Deepseek; GLM for all other agent lineages).
  printf "[verifier] note: ANTHROPIC_API_KEY not loaded in shell; helper will retry\n" >&2
  return 0
}
ralph_verifier_load_key
# ── END S-1 ───────────────────────────────────────────────────────────────────

STATE_FILE="$HOME/.claude/state/ralph-loop-infinite.local"
HMAC_KEY_FILE="$HOME/.claude/secrets/ralph-hmac.key"
LOG_FILE="$HOME/.claude/state/ralph-gate.log"
VERIFIER_LOG="$HOME/.claude/state/ralph-verifier.jsonl"
REPORT_DIR="$HOME/.claude/state/verifier-reports"
POLICY_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-policy.py"
EVIDENCE_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-evidence.py"
RALPH_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-ralph.py"
DB_HELPER="$HOME/.claude/hooks/ralph-loop-infinite-db.py"

mkdir -p "$(dirname "$LOG_FILE")" "$REPORT_DIR"

log() { printf '[%s] [verifier] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

db_available() { [[ -x "$DB_HELPER" ]] && command -v python3 >/dev/null 2>&1; }
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
      --hook "verifier" \
      --session-id "${1:-}" \
      --event-type "${2:-}" \
      --data-json "${3:-{}}" >/dev/null 2>&1 || true
  fi
}

if [[ ! -f "$HMAC_KEY_FILE" ]]; then
  log "FATAL: HMAC key missing at $HMAC_KEY_FILE"
  echo '{"verdict":"FAIL","missing":["HMAC key missing"],"deviations":[],"iteration":0,"session_id":"","ts":"","provider":"","model":"","hmac":""}'
  exit 0
fi
HMAC_KEY=$(cat "$HMAC_KEY_FILE" 2>/dev/null || echo "")
if [[ -z "$HMAC_KEY" ]]; then
  log "FATAL: HMAC key empty"
  echo '{"verdict":"FAIL","missing":["HMAC key empty"],"deviations":[],"iteration":0,"session_id":"","ts":"","provider":"","model":"","hmac":""}'
  exit 0
fi

ITERATION="${ITERATION:-1}"
SESSION_ID="${SESSION_ID:-unknown}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

POLICY_PROVIDER=$(python3 "$POLICY_HELPER" provider 2>/dev/null || echo "anthropic")
POLICY_MODEL=$(python3 "$POLICY_HELPER" model 2>/dev/null || echo "claude-opus-4-7")
POLICY_EFFORT=$(python3 "$POLICY_HELPER" effort 2>/dev/null || echo "max")
[[ -z "$POLICY_PROVIDER" ]] && POLICY_PROVIDER="anthropic"
[[ -z "$POLICY_MODEL" ]] && POLICY_MODEL="claude-opus-4-7"
[[ -z "$POLICY_EFFORT" ]] && POLICY_EFFORT="max"

ORIGINAL_PROMPT_PATH=""
if [[ -f "$STATE_FILE" ]]; then
  ORIGINAL_PROMPT_PATH=$(grep '^original_user_prompt_path:' "$STATE_FILE" 2>/dev/null | sed 's/original_user_prompt_path: *//' || true)
fi
if [[ -z "$ORIGINAL_PROMPT_PATH" || ! -f "$ORIGINAL_PROMPT_PATH" ]]; then
  ORIGINAL_PROMPT_PATH="$(dirname "$STATE_FILE")/original-user-prompt.txt"
fi

# Capture agent output to a temporary file the Python helper can read.
AGENT_OUTPUT_FILE_PATH="${AGENT_OUTPUT_FILE:-}"
AGENT_OUTPUT_TMP=""
if [[ -z "$AGENT_OUTPUT_FILE_PATH" || ! -f "$AGENT_OUTPUT_FILE_PATH" ]]; then
  AGENT_OUTPUT_TMP=$(mktemp 2>/dev/null || echo "/tmp/ralph-agent-out.$$")
  cat > "$AGENT_OUTPUT_TMP"
  AGENT_OUTPUT_FILE_PATH="$AGENT_OUTPUT_TMP"
fi
if [[ ! -s "$AGENT_OUTPUT_FILE_PATH" ]]; then
  printf '%s' "(empty agent output -- FAIL)" > "$AGENT_OUTPUT_FILE_PATH"
fi

# Build the sealed evidence bundle as a temp file (the Python helper hashes it).
EVIDENCE_BUNDLE_FILE=$(mktemp 2>/dev/null || echo "/tmp/ralph-bundle.$$")
EVIDENCE_BUNDLE_HASH=""
if [[ -x "$EVIDENCE_HELPER" ]]; then
  python3 "$EVIDENCE_HELPER" build \
    --agent-output-file "$AGENT_OUTPUT_FILE_PATH" \
    --original-prompt-file "$ORIGINAL_PROMPT_PATH" \
    --transcript-path "${TRANSCRIPT_PATH:-}" \
    --session-id "$SESSION_ID" \
    --iteration "$ITERATION" \
    --state-file "$STATE_FILE" > "$EVIDENCE_BUNDLE_FILE" 2>/dev/null || echo '{}' > "$EVIDENCE_BUNDLE_FILE"
  EVIDENCE_BUNDLE_HASH=$(python3 -c 'import json,sys
try:
  data=json.load(open(sys.argv[1], encoding="utf-8"))
  print(data.get("bundle_sha256",""))
except Exception:
  print("")' "$EVIDENCE_BUNDLE_FILE" 2>/dev/null)
else
  echo '{}' > "$EVIDENCE_BUNDLE_FILE"
fi

# ── Stage 2-3: Critique + Judge via the explicit Python helper ───────────────
RAW_JUDGEMENT=""
if [[ "${RALPH_VERIFIER_FORCE_FAIL:-0}" == "1" ]]; then
  log "FORCED_FAIL: RALPH_VERIFIER_FORCE_FAIL=1"
  RALPH_FORCE_FAIL=1 RAW_JUDGEMENT=$(RALPH_FORCE_FAIL=1 python3 "$RALPH_HELPER" judge \
    --original-prompt-file "$ORIGINAL_PROMPT_PATH" \
    --agent-output-file "$AGENT_OUTPUT_FILE_PATH" \
    --evidence-bundle-file "$EVIDENCE_BUNDLE_FILE" \
    --session-id "$SESSION_ID" \
    --iteration "$ITERATION" 2>/dev/null)
elif [[ "${RALPH_VERIFIER_FORCE_PASS:-0}" == "1" ]]; then
  log "FORCED_PASS: RALPH_VERIFIER_FORCE_PASS=1"
  RAW_JUDGEMENT='{"verdict":"PASS","decision":"accept","overall_score":1,"threshold":0.8,"scoring_dimensions":{"completeness":{"score":1,"evidence":"forced e2e pass"},"correctness":{"score":1,"evidence":"forced e2e pass"},"clarity":{"score":1,"evidence":"forced e2e pass"},"depth":{"score":1,"evidence":"forced e2e pass"},"actionability":{"score":1,"evidence":"forced e2e pass"}},"missing":[],"deviations":[],"critique":{"issues":[],"severity":[],"suggestions":[]},"reasoning":"forced e2e pass","provider":"offline-rule-based","model":"forced-e2e","effort":"max"}'
elif [[ ! -x "$RALPH_HELPER" ]]; then
  log "FATAL: RALPH helper missing at $RALPH_HELPER"
  RAW_JUDGEMENT='{"verdict":"FAIL","decision":"revise","overall_score":0,"threshold":0.8,"scoring_dimensions":{"completeness":{"score":0,"evidence":"helper missing"},"correctness":{"score":0,"evidence":"helper missing"},"clarity":{"score":0,"evidence":"helper missing"},"depth":{"score":0,"evidence":"helper missing"},"actionability":{"score":0,"evidence":"helper missing"}},"missing":["ralph helper missing"],"deviations":[],"provider":"","model":"","effort":""}'
else
  RAW_JUDGEMENT=$(python3 "$RALPH_HELPER" judge \
    --original-prompt-file "$ORIGINAL_PROMPT_PATH" \
    --agent-output-file "$AGENT_OUTPUT_FILE_PATH" \
    --evidence-bundle-file "$EVIDENCE_BUNDLE_FILE" \
    --session-id "$SESSION_ID" \
    --iteration "$ITERATION" 2>/dev/null)
fi

if [[ -z "$RAW_JUDGEMENT" ]]; then
  log "FATAL: empty judgement from RALPH helper"
  RAW_JUDGEMENT='{"verdict":"FAIL","decision":"revise","overall_score":0,"threshold":0.8,"scoring_dimensions":{"completeness":{"score":0,"evidence":"empty"},"correctness":{"score":0,"evidence":"empty"},"clarity":{"score":0,"evidence":"empty"},"depth":{"score":0,"evidence":"empty"},"actionability":{"score":0,"evidence":"empty"}},"missing":["empty judgement"],"deviations":[],"provider":"","model":"","effort":""}'
fi

# Extract a few fields for logging / signing.
USED_PROVIDER=$(printf '%s' "$RAW_JUDGEMENT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("provider","") or "")
except Exception: print("")' 2>/dev/null || echo "")
USED_MODEL=$(printf '%s' "$RAW_JUDGEMENT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("model","") or "")
except Exception: print("")' 2>/dev/null || echo "")
USED_EFFORT=$(printf '%s' "$RAW_JUDGEMENT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("effort","") or "")
except Exception: print("")' 2>/dev/null || echo "")
[[ -z "$USED_PROVIDER" ]] && USED_PROVIDER="$POLICY_PROVIDER"
[[ -z "$USED_MODEL" ]] && USED_MODEL="$POLICY_MODEL"
[[ -z "$USED_EFFORT" ]] && USED_EFFORT="$POLICY_EFFORT"

log "RALPH_JUDGE iter=$ITERATION sess=$SESSION_ID provider=$USED_PROVIDER model=$USED_MODEL effort=$USED_EFFORT bundle=$EVIDENCE_BUNDLE_HASH"

# Persist a defensive report (parallel to the v4.0.0 format).
VERDICT_TMP="$(mktemp 2>/dev/null || echo /tmp/ralph-verdict.$$)"
printf '%s' "$RAW_JUDGEMENT" > "$VERDICT_TMP"
REPORT_META=$(python3 - "$VERDICT_TMP" "$REPORT_DIR" "$ITERATION" "$SESSION_ID" "$TS" "$ORIGINAL_PROMPT_PATH" "$AGENT_OUTPUT_FILE_PATH" <<'PY'
import json, pathlib, re, sys

verdict_path = pathlib.Path(sys.argv[1])
report_dir = pathlib.Path(sys.argv[2])
iteration = int(sys.argv[3])
session_id = sys.argv[4]
ts = sys.argv[5]
orig_path = pathlib.Path(sys.argv[6])
out_path = pathlib.Path(sys.argv[7])

report_dir.mkdir(parents=True, exist_ok=True)
base = re.sub(r"[^A-Za-z0-9_.-]+", "-", f"{ts}-iter{iteration}-{session_id}")[:180]
json_path = report_dir / f"{base}.json"
md_path = report_dir / f"{base}.md"

try:
    obj = json.loads(verdict_path.read_text(encoding="utf-8"))
except Exception:
    obj = {"verdict": "FAIL", "missing": ["verdict JSON parse failed"]}

original_prompt = orig_path.read_text(encoding="utf-8", errors="ignore") if orig_path.exists() else ""
agent_output = out_path.read_text(encoding="utf-8", errors="ignore") if out_path.exists() else ""

report = {
    "ts": ts,
    "iteration": iteration,
    "session_id": session_id,
    "verdict": obj.get("verdict", "FAIL"),
    "decision": obj.get("decision", "revise"),
    "overall_score": obj.get("overall_score", 0.0),
    "threshold": obj.get("threshold", 0.8),
    "scoring_dimensions": obj.get("scoring_dimensions", {}),
    "missing": obj.get("missing", []),
    "deviations": obj.get("deviations", []),
    "provider": obj.get("provider", ""),
    "model": obj.get("model", ""),
    "effort": obj.get("effort", ""),
    "critique": obj.get("critique", {}),
    "original_prompt_excerpt": original_prompt[:12000],
    "agent_output_excerpt": agent_output[:12000],
}
json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
lines = [
    "# Verifier Defense Report",
    "",
    f"- Verdict: **{report['verdict']}**",
    f"- Decision: **{report['decision']}**",
    f"- Overall score: **{report['overall_score']}** (threshold {report['threshold']})",
    f"- Provider/model: **{report['provider']} / {report['model']}**",
    f"- Iteration: **{iteration}**",
    f"- Session: `{session_id}`",
    "",
    "## Scoring dimensions",
]
sd = report.get("scoring_dimensions") or {}
if isinstance(sd, dict):
    for dim, cell in sd.items():
        if isinstance(cell, dict):
            lines.append(f"- {dim}: {cell.get('score','?')} — {cell.get('evidence','')}")
md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps({"report_path": str(json_path), "report_markdown_path": str(md_path)}))
PY
)
rm -f "$VERDICT_TMP" 2>/dev/null || true
REPORT_PATH=$(printf '%s' "$REPORT_META" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("report_path",""))
except Exception: print("")' 2>/dev/null || true)
REPORT_MD_PATH=$(printf '%s' "$REPORT_META" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("report_markdown_path",""))
except Exception: print("")' 2>/dev/null || true)

# ── Stage 4 (deferred + immediate): build a remediation prompt persistently so
# the next iteration of the same implementation session is anchored to the
# prior output + critique. The Stop hook also injects this file into its block
# systemMessage on FAIL, so remediation happens in the same lineage without
# waiting for orchestration to spawn a disconnected helper.
REMEDIATION_OUT="$HOME/.claude/state/ralph-remediation-prompt.iter-${ITERATION}.txt"
REMEDIATION_LATEST="$HOME/.claude/state/ralph-remediation-prompt.txt"
CRITIQUE_TMP=$(mktemp 2>/dev/null || echo "/tmp/ralph-critique.$$")
printf '%s' "$RAW_JUDGEMENT" > "$CRITIQUE_TMP"
python3 "$RALPH_HELPER" remediation \
  --original-prompt-file "$ORIGINAL_PROMPT_PATH" \
  --agent-output-file "$AGENT_OUTPUT_FILE_PATH" \
  --critique-file "$CRITIQUE_TMP" \
  --output-file "$REMEDIATION_OUT" \
  --session-id "$SESSION_ID" \
  --iteration "$ITERATION" >/dev/null 2>&1 || true
if [[ -s "$REMEDIATION_OUT" ]]; then
  cp "$REMEDIATION_OUT" "$REMEDIATION_LATEST" 2>/dev/null || true
  chmod 600 "$REMEDIATION_OUT" "$REMEDIATION_LATEST" 2>/dev/null || true
  if db_available; then
    HISTORY_JSON=$(python3 - "$HOME/.claude/state" <<'PY'
import json, pathlib, re, sys
state=pathlib.Path(sys.argv[1])
items=[]
for p in sorted(state.glob('ralph-remediation-prompt.iter-*.txt'), key=lambda x: int(re.search(r'iter-(\d+)', x.name).group(1)) if re.search(r'iter-(\d+)', x.name) else 0):
    m=re.search(r'iter-(\d+)', p.name)
    items.append({"iteration": int(m.group(1)) if m else 0, "path": str(p)})
print(json.dumps(items[-20:], separators=(',', ':')))
PY
)
    python3 "$DB_HELPER" state-update \
      --session-id "$SESSION_ID" \
      --set "remediation_prompt_path=$REMEDIATION_OUT" \
      --set "remediation_history=$HISTORY_JSON" >/dev/null 2>&1 || true
  fi
fi
rm -f "$CRITIQUE_TMP" 2>/dev/null || true

# ── HMAC signing ─────────────────────────────────────────────────────────────
SIGNED=$(JUDGEMENT_JSON="$RAW_JUDGEMENT" \
  ITERATION="$ITERATION" \
  SESSION_ID="$SESSION_ID" \
  TS="$TS" \
  POLICY_PROVIDER="$POLICY_PROVIDER" \
  USED_PROVIDER="$USED_PROVIDER" \
  USED_MODEL="$USED_MODEL" \
  USED_EFFORT="$USED_EFFORT" \
  EVIDENCE_BUNDLE_HASH="$EVIDENCE_BUNDLE_HASH" \
  REPORT_PATH="$REPORT_PATH" \
  REPORT_MD_PATH="$REPORT_MD_PATH" \
  HMAC_KEY_FILE="$HMAC_KEY_FILE" \
  python3 <<'PY'
import base64, hashlib, hmac, json, os, sys

raw = os.environ["JUDGEMENT_JSON"]
try:
    obj = json.loads(raw)
except Exception:
    obj = {"verdict": "FAIL", "missing": ["unparseable judgement json"], "deviations": []}

verdict = obj.get("verdict") or ("PASS" if obj.get("decision") == "accept" else "FAIL")
if verdict not in ("PASS", "FAIL"):
    verdict = "FAIL"
decision = obj.get("decision", "revise" if verdict == "FAIL" else "accept")
overall_score = float(obj.get("overall_score") or 0.0)
threshold = float(obj.get("threshold") or 0.8)
scoring = obj.get("scoring_dimensions") or {}
missing = list(obj.get("missing") or [])
deviations = list(obj.get("deviations") or [])
critique = obj.get("critique") or {}
reasoning = str(obj.get("reasoning") or "")

# Enforce validation-result presence and threshold strictly on signing side too
# — never trust the model alone and never allow PASS without a complete
# critique/judge result.
def numeric(score):
    try:
        return float(score)
    except (TypeError, ValueError):
        return 0.0

required_dims = ("completeness", "correctness", "clarity", "depth", "actionability")
if decision not in ("accept", "revise") or not isinstance(scoring, dict):
    verdict = "FAIL"
    decision = "revise"
    missing.append("validation-result")
else:
    absent = [d for d in required_dims if d not in scoring or not isinstance(scoring.get(d), dict)]
    if absent:
        verdict = "FAIL"
        decision = "revise"
        missing.append("scoring-dimensions:" + ",".join(absent))
    elif any(numeric(scoring[d].get("score")) < threshold for d in required_dims):
        verdict = "FAIL"
        decision = "revise"
if missing or deviations:
    verdict = "FAIL"
    decision = "revise"

payload = {
    "verdict": verdict,
    "decision": decision,
    "overall_score": round(overall_score, 4),
    "threshold": round(threshold, 4),
    "scoring_dimensions": scoring,
    "missing": missing,
    "deviations": deviations,
    "critique": critique,
    "reasoning": reasoning,
    "strict_x_equals_x": verdict == "PASS",
    "iteration": int(os.environ.get("ITERATION", "0") or 0),
    "session_id": os.environ.get("SESSION_ID", ""),
    "ts": os.environ.get("TS", ""),
    "provider": os.environ.get("USED_PROVIDER", "") or os.environ.get("POLICY_PROVIDER", ""),
    "model": os.environ.get("USED_MODEL", ""),
    "effort": os.environ.get("USED_EFFORT", ""),
    "evidence_bundle_hash": os.environ.get("EVIDENCE_BUNDLE_HASH", ""),
    "report_path": os.environ.get("REPORT_PATH", ""),
    "report_markdown_path": os.environ.get("REPORT_MD_PATH", ""),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
key = open(os.environ["HMAC_KEY_FILE"], "rb").read().strip()
payload["hmac"] = base64.b64encode(hmac.new(key, canonical, hashlib.sha256).digest()).decode("ascii")
print(json.dumps(payload, separators=(",", ":")))
PY
)

if [[ -z "$SIGNED" ]]; then
  log "FATAL: signing failure"
  SIGNED="{\"verdict\":\"FAIL\",\"decision\":\"revise\",\"missing\":[\"signing-failure\"],\"deviations\":[],\"iteration\":${ITERATION},\"session_id\":\"${SESSION_ID}\",\"ts\":\"${TS}\",\"provider\":\"${USED_PROVIDER}\",\"model\":\"${USED_MODEL}\",\"effort\":\"${USED_EFFORT}\",\"evidence_bundle_hash\":\"${EVIDENCE_BUNDLE_HASH}\",\"report_path\":\"${REPORT_PATH}\",\"report_markdown_path\":\"${REPORT_MD_PATH}\",\"hmac\":\"\"}"
fi

printf '%s\n' "$SIGNED" >> "$VERIFIER_LOG" 2>/dev/null || true
VERDICT=$(printf '%s' "$SIGNED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict','FAIL'))" 2>/dev/null || echo "FAIL")
log "VERDICT [iter=$ITERATION sess=$SESSION_ID provider=$USED_PROVIDER model=$USED_MODEL]: $VERDICT bundle=$EVIDENCE_BUNDLE_HASH report=${REPORT_PATH:-n/a}"

SIGNED_HMAC=$(printf '%s' "$SIGNED" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hmac',''))" 2>/dev/null || echo "")
if [[ -n "$SIGNED_HMAC" ]]; then
  db_record_verifier "$SESSION_ID" "$ITERATION" "$SIGNED" "yes"
else
  db_record_verifier "$SESSION_ID" "$ITERATION" "$SIGNED" "no"
fi
db_event "$SESSION_ID" "verdict_emitted" "$(printf '{"verdict":"%s","iteration":%s,"provider":"%s","model":"%s"}' "$VERDICT" "$ITERATION" "$USED_PROVIDER" "$USED_MODEL")"

# Clean up temp files (never the evidence bundle file we wrote to)
rm -f "$EVIDENCE_BUNDLE_FILE" 2>/dev/null || true
[[ -n "$AGENT_OUTPUT_TMP" ]] && rm -f "$AGENT_OUTPUT_TMP" 2>/dev/null || true

printf '%s\n' "$SIGNED"
exit 0
