#!/bin/bash
# ralph-loop-infinite-progress-check.sh — PostToolUse mid-session progress check
#
# Injects a mid-session critique prompt every N tool invocations to prevent
# the loop from going dark mid-session without verification.
#
# Registered as PostToolUse hook in settings.json:
#   PostToolUse: Bash|Write|Edit → ralph-loop-infinite-progress-check.sh
#
# Fix 4 of the Targeted Fixes list.

set -uo pipefail

STATE_FILE="${HOME}/.claude/state/ralph-loop-infinite.local"
DB_HELPER="${HOME}/.claude/hooks/ralph-loop-infinite-db.py"
HOOKS_DIR="${HOME}/.claude/hooks"

# Check every N tool invocations
CHECK_EVERY="${RALPH_PROGRESS_CHECK_EVERY:-5}"

# ── Check if loop is armed ────────────────────────────────────
is_armed() {
  [[ -f "$STATE_FILE" ]] || return 1
  grep -q 'arm_timestamp:' "$STATE_FILE" 2>/dev/null || return 1
  return 0
}

is_armed || exit 0  # Silent NOOP if not armed

# ── Get current iteration and tool-use count ──────────────────
ITERATION=0
db_init 2>/dev/null || true
ITERATION=$(python3 "$DB_HELPER" state-get "verifier_attempts" --state-file "$STATE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "0")

TOOL_COUNT_FILE="${HOME}/.claude/state/ralph-tool-use-count"
TOOL_COUNT=$(cat "$TOOL_COUNT_FILE" 2>/dev/null || echo "0")
NEXT_TOOL_COUNT=$((TOOL_COUNT + 1))
echo "$NEXT_TOOL_COUNT" > "$TOOL_COUNT_FILE"

# ── Check if this is a milestone invocation ──────────────────
if (( NEXT_TOOL_COUNT % CHECK_EVERY != 0 )); then
  exit 0  # Not a milestone — silent NOOP
fi

# ── Milestone reached: check iteration progress ───────────────
log() {
  printf '[%s] [progress-check] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${HOME}/.claude/state/ralph-gate.log" 2>/dev/null || true
}

log "Mid-session progress check: iteration=${ITERATION} tool_count=${NEXT_TOOL_COUNT}"

# ── If iteration >= 3 and no PASS: inject critique reminder ──
VERIFIER_PASS=$(python3 "$DB_HELPER" state-get "verifier_pass" --state-file "$STATE_FILE" 2>/dev/null | tr -d '[:space:]' || echo "false")

if [[ "$VERIFIER_PASS" != "true" ]] && [[ "$ITERATION" -ge 3 ]]; then
  log "ESCALATION: iteration=${ITERATION} with no PASS at tool ${NEXT_TOOL_COUNT} — GCJ stage enforcement"
  # Emit a structured reminder to the transcript that the next tool call
  # should be a targeted remediation targeting only the failed dimensions
  # rather than continuing unchecked
  emit_progress_reminder() {
    python3 - <<'PY'
import json, sys
iteration = "$ITERATION"
tool_count = "$NEXT_TOOL_COUNT"
reminder = {
    "type": "ralph-progress-check",
    "iteration": int(iteration),
    "tool_count": int(tool_count),
    "status": "mid-session-critique-required",
    "message": (
        f"[Ralph mid-session check at tool {tool_count}, iteration {iteration}] "
        "The GENERATOR has been running without verifier PASS for too long. "
        "Before continuing, produce a targeted critique of the current state. "
        "Identify: (1) what is missing, (2) what is wrong, (3) what to fix next. "
        "Do not continue without a concrete issue list."
    ),
    "gcj_stage": "critique",
    "required_action": "produce_critique_before_next_generation"
}
print(json.dumps(reminder))
PY
  }
  REMINDER_JSON=$(emit_progress_reminder)
  # Write to a mid-session feedback file for the Orchestrator to pick up
  FEEDBACK_FILE="${HOME}/.claude/state/ralph-mid-session-critique.json"
  echo "$REMINDER_JSON" > "$FEEDBACK_FILE"
  log "Critique reminder written to $FEEDBACK_FILE"
fi

# ── Max iterations check: warn if approaching limit ──────────
MAX_ITERS="${RALPH_MAX_ITERATIONS:-3}"
if [[ "$ITERATION" -ge "$MAX_ITERS" ]] && [[ "$VERIFIER_PASS" != "true" ]]; then
  log "CONVERGENCE-WARNING: iteration=${ITERATION} >= max=${MAX_ITERS}, no PASS — loop will converge"
fi

exit 0