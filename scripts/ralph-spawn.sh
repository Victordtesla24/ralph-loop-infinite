#!/bin/bash
# ralph-spawn.sh — Spawn a Ralph sub-agent with explicit GCJ classification.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null || pwd)"
LOCAL_MODE="${RALPH_REPO_LOCAL_MODE:-0}"
if [[ "$LOCAL_MODE" == "1" ]]; then
  SOUL_DIR="${RALPH_SOUL_DIR:-$REPO_ROOT/sub-agents/claude-roles}"
  PROMPT_DIR="${RALPH_PROMPT_DIR:-$REPO_ROOT/sub-agents/claude-roles}"
  COUNCIL_DIR="${RALPH_COUNCIL_DIR:-$REPO_ROOT/sub-agents/council}"
else
  SOUL_DIR="${RALPH_SOUL_DIR:-${HOME}/.sub-agents/claude-roles}"
  PROMPT_DIR="${RALPH_PROMPT_DIR:-${HOME}/.sub-agents/claude-roles}"
  COUNCIL_DIR="${RALPH_COUNCIL_DIR:-${HOME}/.sub-agents/council}"
fi
CLAUDE_CMD="${RALPH_SPAWN_CLAUDE_CMD:-claude}"

ROLE_TO_GCJ_JSON='{
  "orchestrator": "GENERATOR",
  "coder": "GENERATOR",
  "solution-architect": "GENERATOR",
  "researcher": "GENERATOR",
  "senior-sme": "GENERATOR",
  "analyst-generator": "GENERATOR",
  "analyst-programmer": "GENERATOR",
  "cleanup-agent": "GENERATOR",
  "tester": "CRITIC",
  "qa-verifier": "CRITIC",
  "analyst-critic": "CRITIC",
  "verifier": "JUDGE"
}'

usage() {
  cat <<USAGE
Ralph-Loop-Infinite Sub-Agent Spawner

USAGE:
  ralph-spawn.sh <role> <task> [--model <model>] [--provider <provider>] [--mode generator|critic]
  ralph-spawn.sh list
  ralph-spawn.sh validate

ROLE MODES:
  analyst is ambiguous and must be called as analyst-generator or analyst-critic,
  or as analyst --mode generator|critic. Call context controls classification.

LOCAL MODE:
  RALPH_REPO_LOCAL_MODE=1 uses repository-local sub-agents/claude-roles instead
  of ~/.sub-agents/claude-roles.
USAGE
}

list_roles() {
  usage
  echo
  echo "CURRENT CLASSIFICATION:"
  printf '%s' "$ROLE_TO_GCJ_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); [print(f"  {k}: {v}") for k,v in d.items()]'
}

role_prompt_name() {
  case "$1" in
    analyst-generator|analyst-critic) printf 'analyst' ;;
    analyst-programmer) printf 'analyst-programmer' ;;
    cleanup-agent) printf 'cleanup-agent' ;;
    *) printf '%s' "$1" ;;
  esac
}

validate_runtime() {
  local missing=0
  echo "ralph-spawn runtime validation"
  echo "repo_root=$REPO_ROOT"
  echo "local_mode=$LOCAL_MODE"
  echo "soul_dir=$SOUL_DIR"
  echo "prompt_dir=$PROMPT_DIR"
  echo "council_dir=$COUNCIL_DIR"
  if [[ ! -d "$SOUL_DIR" ]]; then echo "MISSING: SOUL_DIR $SOUL_DIR"; missing=1; fi
  if [[ ! -d "$PROMPT_DIR" ]]; then echo "MISSING: PROMPT_DIR $PROMPT_DIR"; missing=1; fi
  if [[ ! -d "$COUNCIL_DIR" ]]; then echo "MISSING: COUNCIL_DIR $COUNCIL_DIR"; missing=1; fi
  if ! command -v python3 >/dev/null 2>&1; then echo "MISSING: python3"; missing=1; fi
  if ! command -v "$CLAUDE_CMD" >/dev/null 2>&1; then echo "MISSING: claude command ($CLAUDE_CMD)"; missing=1; fi
  for role in orchestrator coder tester verifier; do
    local base; base=$(role_prompt_name "$role")
    [[ -f "$SOUL_DIR/${base}.SOUL.md" ]] || { echo "MISSING: $SOUL_DIR/${base}.SOUL.md"; missing=1; }
    [[ -f "$PROMPT_DIR/${base}.system-prompt.md" ]] || { echo "MISSING: $PROMPT_DIR/${base}.system-prompt.md"; missing=1; }
  done
  # Validate RALPH stage files
  [[ -f "$REPO_ROOT/sub-agents/orchestrator/RALPH.md" ]] || { echo "MISSING: orchestrator/RALPH.md"; missing=1; }
  [[ -f "$REPO_ROOT/sub-agents/tester/CRITIC.md" ]]     || { echo "MISSING: tester/CRITIC.md"; missing=1; }
  [[ -f "$REPO_ROOT/sub-agents/verifier/JUDGE.md" ]]    || { echo "MISSING: verifier/JUDGE.md"; missing=1; }
  # Validate key council deliberation docs
  if [[ -d "$COUNCIL_DIR" ]]; then
    [[ -f "$COUNCIL_DIR/hos-orchestrator.md" ]] || { echo "MISSING: council/hos-orchestrator.md"; missing=1; }
    [[ -f "$COUNCIL_DIR/analyst_programmer.md" ]] || { echo "MISSING: council/analyst_programmer.md"; missing=1; }
    [[ -f "$COUNCIL_DIR/qa-verifier.md" ]]        || { echo "MISSING: council/qa-verifier.md"; missing=1; }
    [[ -f "$COUNCIL_DIR/researcher.md" ]]         || { echo "MISSING: council/researcher.md"; missing=1; }
    [[ -f "$COUNCIL_DIR/solutions_architect.md" ]] || { echo "MISSING: council/solutions_architect.md"; missing=1; }
  fi
  # Validate hierarchy files — removed in Fix 2; hierarchy/ was an unused architectural layer
  if [[ $missing -eq 0 ]]; then
    echo "OK: all required runtime prerequisites present"
  else
    echo "FAIL: one or more runtime prerequisites missing"
  fi
  return "$missing"
}

ROLE="${1:-}"
TASK="${2:-}"
if [[ "$ROLE" == "list" || -z "$ROLE" ]]; then list_roles; exit 0; fi
if [[ "$ROLE" == "validate" ]]; then validate_runtime; exit $?; fi
if [[ -z "$TASK" ]]; then echo "ERROR: task argument required" >&2; usage >&2; exit 1; fi
shift 2 || true
MODEL_OVERRIDE=""
PROVIDER_OVERRIDE=""
MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --provider) PROVIDER_OVERRIDE="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$ROLE" == "analyst" ]]; then
  case "$MODE" in
    generator) ROLE="analyst-generator" ;;
    critic) ROLE="analyst-critic" ;;
    *) echo "ERROR: analyst role requires --mode generator or --mode critic, or use analyst-generator/analyst-critic" >&2; exit 2 ;;
  esac
fi

GCJ=$(printf '%s' "$ROLE_TO_GCJ_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$ROLE','UNKNOWN'))" 2>/dev/null || echo UNKNOWN)
if [[ "$GCJ" == "UNKNOWN" ]]; then
  echo "ERROR: Unknown role: $ROLE" >&2
  echo "Run: ralph-spawn.sh list" >&2
  exit 1
fi

BASE_ROLE=$(role_prompt_name "$ROLE")
SOUL_FILE="${SOUL_DIR}/${BASE_ROLE}.SOUL.md"
PROMPT_FILE="${PROMPT_DIR}/${BASE_ROLE}.system-prompt.md"
if [[ ! -f "$SOUL_FILE" || ! -f "$PROMPT_FILE" ]]; then
  # Council fallback: council-only roles (analyst-programmer, cleanup-agent) have no
  # claude-roles SOUL/prompt — use council/<role>.md as the system prompt directly.
  COUNCIL_FILE="${COUNCIL_DIR}/${BASE_ROLE}.md"
  if [[ -f "$COUNCIL_FILE" ]]; then
    echo "[ralph-spawn] No claude-roles files for '$ROLE' — using council/$BASE_ROLE.md as system prompt"
    SOUL_CONTENT=""
    PROMPT_CONTENT=$(<"$COUNCIL_FILE")
  else
    echo "ERROR: role prompt prerequisites missing" >&2
    [[ -f "$SOUL_FILE" ]] || echo "MISSING: $SOUL_FILE" >&2
    [[ -f "$PROMPT_FILE" ]] || echo "MISSING: $PROMPT_FILE" >&2
    [[ -f "$COUNCIL_FILE" ]] || echo "MISSING: $COUNCIL_FILE" >&2
    echo "Run: RALPH_REPO_LOCAL_MODE=1 scripts/ralph-spawn.sh validate" >&2
    exit 1
  fi
else
  SOUL_CONTENT=$(<"$SOUL_FILE")
  PROMPT_CONTENT=$(<"$PROMPT_FILE")
fi

# Load council deliberation doc for multi-agent context
COUNCIL_DELIBERATION=""
COUNCIL_DOC="$COUNCIL_DIR/hos-orchestrator.md"
if [[ -f "$COUNCIL_DOC" ]]; then
  COUNCIL_DELIBERATION=$(<"$COUNCIL_DOC")
fi

if [[ -z "$MODEL_OVERRIDE" ]]; then
  MODEL_OVERRIDE=$(python3 - <<'PY' 2>/dev/null || echo "claude-opus-4-7"
import json
from pathlib import Path
data = {}
for p in [Path.home()/'.claude'/'settings.json', Path.home()/'.claude'/'settings.local.json']:
    if p.exists():
        try: data.update(json.loads(p.read_text()))
        except Exception: pass
policy = data.get('_ralphLoopInfiniteExitPolicy', {}) or {}
vp = policy.get('verifier_policy', {}) or {}
print(vp.get('model_primary', 'claude-opus-4-7'))
PY
)
fi

SYSTEM_PROMPT="${SOUL_CONTENT}

--- GCJ CLASSIFICATION ---
This sub-agent is classified as: ${GCJ}
- GENERATOR: produces output, cannot stop the loop, repeats until JUDGE PASS.
- CRITIC: identifies concrete issues and shapes the next GENERATOR iteration.
- JUDGE: scores five dimensions and only exits via HMAC-signed PASS.
Analyst split is context-enforced: analyst-generator may generate traceability; analyst-critic may critique structural gaps.
--- END GCJ CLASSIFICATION ---

--- RALPH STAGE PROMPT ---
$([[ -f "$REPO_ROOT/sub-agents/orchestrator/RALPH.md" && "$ROLE" == "orchestrator" ]] && cat "$REPO_ROOT/sub-agents/orchestrator/RALPH.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/tester/CRITIC.md" && "$ROLE" == "tester" ]] && cat "$REPO_ROOT/sub-agents/tester/CRITIC.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/verifier/JUDGE.md" && "$ROLE" == "verifier" ]] && cat "$REPO_ROOT/sub-agents/verifier/JUDGE.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/claude-roles/coder.RALPH.md" && "$ROLE" == "coder" ]] && cat "$REPO_ROOT/sub-agents/claude-roles/coder.RALPH.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/claude-roles/researcher.RALPH.md" && "$ROLE" == "researcher" ]] && cat "$REPO_ROOT/sub-agents/claude-roles/researcher.RALPH.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/claude-roles/solution-architect.RALPH.md" && "$ROLE" == "solution-architect" ]] && cat "$REPO_ROOT/sub-agents/claude-roles/solution-architect.RALPH.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/claude-roles/analyst.RALPH.md" && "$ROLE" == "analyst-generator" ]] && cat "$REPO_ROOT/sub-agents/claude-roles/analyst.RALPH.md" 2>/dev/null || true)
$([[ -f "$REPO_ROOT/sub-agents/claude-roles/senior-sme.RALPH.md" && "$ROLE" == "senior-sme" ]] && cat "$REPO_ROOT/sub-agents/claude-roles/senior-sme.RALPH.md" 2>/dev/null || true)
--- END RALPH STAGE PROMPT ---

--- COUNCIL DELIBERATION ---
${COUNCIL_DELIBERATION}
--- END COUNCIL DELIBERATION ---

--- SYSTEM PROMPT ---
${PROMPT_CONTENT}
--- END SYSTEM PROMPT ---"

echo "[ralph-spawn] Spawning $ROLE ($GCJ) with model $MODEL_OVERRIDE"
echo "[ralph-spawn] Task: ${TASK:0:80}..."
CLAUDE_ARGS=(--system-prompt "$SYSTEM_PROMPT" --message "$TASK")
[[ -n "$PROVIDER_OVERRIDE" ]] && CLAUDE_ARGS+=(--provider "$PROVIDER_OVERRIDE")
[[ -n "$MODEL_OVERRIDE" ]] && CLAUDE_ARGS+=(--model "$MODEL_OVERRIDE")
"$CLAUDE_CMD" "${CLAUDE_ARGS[@]}"
SPAWN_EXIT=$?
echo "[ralph-spawn] $ROLE exited with code $SPAWN_EXIT"
exit "$SPAWN_EXIT"
