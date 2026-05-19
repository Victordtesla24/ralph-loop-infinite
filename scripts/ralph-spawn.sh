#!/bin/bash
# ralph-spawn.sh — Spawn a sub-agent with the correct SOUL + system-prompt
#
# Maps user preference to GENERATOR/CRITIC/JUDGE classification and spawns
# the appropriate sub-agent with the matching SOUL.md + system-prompt.md.
#
# Fix 7 of the Targeted Fixes list.
#
# USAGE:
#   ralph-spawn.sh <role> <task> [--model <model>] [--provider <provider>]
#   ralph-spawn.sh list
#
# ROLES:
#   GENERATOR (produces output, cannot stop the loop):
#     orchestrator  — drives the loop, decomposes, delegates, collects evidence
#     coder         — writes production code, zero placeholders
#     solution-architect  — designs systems, input→process→validation gate
#     researcher    — gathers verified evidence, primary sources only
#     senior-sme    — enforces Fortune 500 quality bar
#     analyst       — decomposes raw prompts into 1:1 traceability map
#
#   CRITIC (identifies concrete issues, shapes next iteration):
#     tester        — validates real behavior in real environments
#     qa-verifier   — quality assurance against requirements
#     analyst       — also acts as critic for structural issues
#
#   JUDGE (scores + decides, issues HMAC-signed PASS):
#     verifier      — independent scoring, all dims ≥ 0.80
#
# PROVIDER CHAIN (from settings):
#   Anthropic → MiniMax-M2.7 (fallback) → GLM (fallback) → fail-closed
#
# EXAMPLES:
#   ralph-spawn.sh coder "write a function that sorts a list"
#   ralph-spawn.sh tester "validate the sort function against edge cases"
#   ralph-spawn.sh verifier "score the sort implementation"
#   ralph-spawn.sh orchestrator "manage the loop for this task"
#   ralph-spawn.sh list

set -euo pipefail

SOUL_DIR="${HOME}/.sub-agents/claude-roles"
PROMPT_DIR="${HOME}/.sub-agents/claude-roles"
CLAUDE_CMD="${RALPH_SPAWN_CLAUDE_CMD:-claude}"

# ── Role to GCJ classification map ────────────────────────────
ROLE_TO_GCJ='{
  "orchestrator": "GENERATOR",
  "coder": "GENERATOR",
  "solution-architect": "GENERATOR",
  "researcher": "GENERATOR",
  "senior-sme": "GENERATOR",
  "analyst": "GENERATOR",
  "tester": "CRITIC",
  "qa-verifier": "CRITIC",
  "verifier": "JUDGE"
}'

# ── Parse arguments ──────────────────────────────────────────
ROLE="${1:-}"
TASK="${2:-}"

if [[ "$ROLE" == "list" ]] || [[ -z "$ROLE" ]]; then
  echo "Ralph-Loop-Infinite Sub-Agent Spawner"
  echo "======================================"
  echo ""
  echo "USAGE: ralph-spawn.sh <role> <task> [--model <model>] [--provider <provider>]"
  echo ""
  echo "ROLES:"
  echo ""
  echo "  GENERATOR (produces output, cannot stop the loop):"
  echo "    orchestrator       drives the loop, decomposes, delegates, collects evidence"
  echo "    coder              writes production code, zero placeholders"
  echo "    solution-architect designs systems, input→process→validation gate"
  echo "    researcher         gathers verified evidence, primary sources only"
  echo "    senior-sme         enforces Fortune 500 quality bar"
  echo "    analyst            decomposes raw prompts into 1:1 traceability map"
  echo ""
  echo "  CRITIC (identifies concrete issues, shapes next iteration):"
  echo "    tester             validates real behavior in real environments"
  echo "    qa-verifier        quality assurance against requirements"
  echo ""
  echo "  JUDGE (scores + decides, issues HMAC-signed PASS):"
  echo "    verifier           independent scoring, all dims ≥ 0.80"
  echo ""
  echo "EXAMPLES:"
  echo "  ralph-spawn.sh coder 'write a function that sorts a list'"
  echo "  ralph-spawn.sh tester 'validate the sort function'"
  echo "  ralph-spawn.sh verifier 'score the sort implementation'"
  echo ""
  echo "MODEL OVERRIDES:"
  echo "  --model <model>   Override model (default: from settings.json)"
  echo "  --provider <prov> Override provider"
  echo ""
  echo "CURRENT CLASSIFICATION:"
  echo "$ROLE_TO_GCJ" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {k}: {v}') for k,v in d.items()]"
  exit 0
fi

if [[ -z "$TASK" ]]; then
  echo "ERROR: task argument required"
  echo "Usage: ralph-spawn.sh <role> <task>"
  echo "       ralph-spawn.sh list"
  exit 1
fi

shift 2 || true
MODEL_OVERRIDE=""
PROVIDER_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --provider) PROVIDER_OVERRIDE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Validate role ────────────────────────────────────────────
GCJ=$(echo "$ROLE_TO_GCJ" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$ROLE','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
if [[ "$GCJ" == "UNKNOWN" ]]; then
  echo "ERROR: Unknown role: $ROLE"
  echo "Valid roles: orchestrator, coder, solution-architect, researcher, senior-sme, analyst, tester, qa-verifier, verifier"
  echo "Run: ralph-spawn.sh list"
  exit 1
fi

# ── Load SOUL and system-prompt ──────────────────────────────
SOUL_FILE="${SOUL_DIR}/${ROLE}.SOUL.md"
PROMPT_FILE="${PROMPT_DIR}/${ROLE}.system-prompt.md"

if [[ ! -f "$SOUL_FILE" ]]; then
  echo "ERROR: SOUL file not found: $SOUL_FILE"
  echo "Is ~/.sub-agents/claude-roles/ installed? Run: bash bootstrap.sh"
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: system-prompt file not found: $PROMPT_FILE"
  exit 1
fi

SOUL_CONTENT=$(cat "$SOUL_FILE")
PROMPT_CONTENT=$(cat "$PROMPT_FILE")

# ── Load provider/model from settings if not overridden ───────
if [[ -z "$MODEL_OVERRIDE" ]]; then
  MODEL_OVERRIDE=$(python3 -c "
import json
from pathlib import Path
data = {}
for p in [Path.home() / '.claude' / 'settings.json', Path.home() / '.claude' / 'settings.local.json']:
    if p.exists():
        try: data.update(json.loads(p.read_text()))
        except: pass
policy = data.get('_ralphLoopInfiniteExitPolicy', {}) or {}
vp = policy.get('verifier_policy', {}) or {}
print(vp.get('model_primary', 'claude-opus-4-7'))
" 2>/dev/null || echo "claude-opus-4-7")
fi

# ── Build the combined system prompt with GCJ classification ──
SYSTEM_PROMPT="${SOUL_CONTENT}

$(echo "--- GCJ CLASSIFICATION ---")
echo "This sub-agent is classified as: $GCJ"
echo "- GENERATOR: produces output, cannot stop the loop, repeats until JUDGE PASS"
echo "- CRITIC: identifies concrete issues, shapes next GENERATOR iteration"
echo "- JUDGE: scores 5 dimensions, issues HMAC-signed PASS, only role that exits the loop"
echo "--- END GCJ CLASSIFICATION ---")

$(echo "--- SYSTEM PROMPT ---")
echo "$PROMPT_CONTENT"
echo "--- END SYSTEM PROMPT ---")"

# ── Spawn the sub-agent ──────────────────────────────────────
echo "[ralph-spawn] Spawning $ROLE ($GCJ) with model $MODEL_OVERRIDE"
echo "[ralph-spawn] Task: ${TASK:0:80}..."

# Build the claude command
CLAUDE_ARGS=(
  --system-prompt "$SYSTEM_PROMPT"
  --message "$TASK"
)

if [[ -n "$PROVIDER_OVERRIDE" ]]; then
  CLAUDE_ARGS+=(--provider "$PROVIDER_OVERRIDE")
fi

if [[ -n "$MODEL_OVERRIDE" ]]; then
  CLAUDE_ARGS+=(--model "$MODEL_OVERRIDE")
fi

# Execute
"$CLAUDE_CMD" "${CLAUDE_ARGS[@]}"
SPAWN_EXIT=$?

echo "[ralph-spawn] $ROLE exited with code $SPAWN_EXIT"
exit $SPAWN_EXIT