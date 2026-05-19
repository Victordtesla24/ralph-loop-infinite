#!/usr/bin/env bash
# ============================================================
# Ralph-Loop-Infinite — Configuration Sync Script
# Updates CLAUDE.md, AGENTS.md, agents.md, settings.json,
# settings.local.json to enforce maximum prompt execution
# accuracy and predictable output consistency.
# Run after any hook or config change.
# ============================================================

set -euo pipefail

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
AGENTS_MD="$HOME/.claude/AGENTS.md"
AGENTS_MD2="$HOME/.claude/agents.md"
SETTINGS_JSON="$HOME/.claude/settings.json"
SETTINGS_LOCAL="$HOME/.claude/settings.local.json"
MANIFEST_DIR="$HOME/.claude/manifest"
HOOKS_DIR="$HOME/.claude/hooks"
SECRETS_DIR="$HOME/.claude/secrets"

log(){ printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "ralph-sync" "$*"; }
die(){ log "FATAL: $*" >&2; exit 1; }

[[ -f "$CLAUDE_MD" ]] || die "CLAUDE.md not found at $CLAUDE_MD"
[[ -d "$HOOKS_DIR" ]] || die "Hooks directory not found at $HOOKS_DIR"

# ============================================================
# SECTION 1 — Update CLAUDE.md with prompt execution accuracy rules
# ============================================================

log "Updating CLAUDE.md with maximum prompt execution accuracy rules..."

# Append enforcement block to CLAUDE.md if not already present
CLAUDE_ACCURACY_BLOCK='
## §8 · Prompt Execution Accuracy & Output Predictability

When the gate is armed, the following rules are STRICTLY enforced to ensure
maximum prompt execution accuracy and consistent, predictable output:

### §8.1 · Iteration State Preservation

- The agent MUST carry forward the entire prior iteration context — not just the
  last output, but the critique, suggested fixes, scoring dimensions, threshold,
  and iteration number — into every subsequent turn.
- The agent MUST NOT start a new iteration from scratch or from a compressed summary.
  If the agent loses prior context, it must reconstruct it from the state file
  before proceeding.
- State is the single source of truth for current_output, iteration count,
  verifier_last_verdict, verifier_last_score, and remediation_target_session_id.

### §8.2 · Output Structure Predictability

- Every iteration output MUST follow the same structure:
  1. Current iteration number (stated explicitly)
  2. Prior verifier verdict and reason (verbatim from state)
  3. Prior scoring dimensions and scores (from verifier response)
  4. Concrete issues identified (from critique)
  5. Suggested fixes (from critique)
  6. What was changed in this iteration vs prior
  7. What remains incomplete
  8. Evidence of changes (real file paths, command outputs, line numbers)
- This structure is not optional. Missing any field = incomplete iteration.
- The agent MUST NOT skip fields even if they are unchanged from the prior iteration.

### §8.3 · Reasoning Traceability

- Every decision in the agent'"'"'s output must be traceable to:
  a) The original user prompt (exact quote)
  b) The prior iteration'"'"'s critique (specific issue + suggestion)
  c) The verifier'"'"'s scoring dimensions (which dimension, what score, why)
- The agent MUST NOT assert something as true unless it can point to the exact
  source in the above three inputs that justifies it.
- Vague assertions ("this is correct", "quality improved", "scope met") without
  traceable evidence are auto-FAIL.

### §8.4 · Iteration Number as Mandatory Prefix

- The agent MUST begin every response with the iteration counter:
  `[🔁 ITERATION N — verifier: FAIL/REVIEW | score: X.XX | issues: K | threshold: 0.80]`
- If the iteration counter is missing from the start of the response, the stop
  hook will reject the output and the loop continues without counting this as
  a completed iteration.
- The counter is not cosmetic. It is the mechanism by which convergence and
  MAX_ITERATIONS are tracked.

### §8.5 · No Compressed Summaries as Iteration Context

- The agent MUST NOT use a compressed summary of the session to replace the
  actual prior iterations. A compressed summary loses signal and violates the
  state preservation requirement.
- If the agent'"'"'s context window is exhausted, the agent MUST read the state file
  and DB to reconstruct the full iteration history before continuing.
- The agent CANNOT stop because "context is full". It must reconstruct and continue.

### §8.6 · Remediation Prompt Precision

- The remediation prompt fed to the next iteration MUST contain:
  a) The original output (verbatim, not paraphrased)
  b) The identified issues (each one, with severity)
  c) The suggested fixes (each one, concrete)
  d) The explicit instruction: "Address each issue, preserve what is correct"
  e) The explicit instruction: "Do NOT rewrite the entire response"
  f) The original user prompt (verbatim, unchanged)
- The remediation prompt MUST NOT contain:
  - "improve quality generally"
  - "make it better"
  - "clean up"
  - Any vague instruction that does not map to a specific issue

### §8.7 · Predictable Tool Usage

- The agent MUST use the same tool for the same purpose across all iterations:
  - read_file for reading files (not cat/head/tail in terminal)
  - patch for editing files (not sed/awk in terminal)
  - write_file for creating files (not echo/cat heredoc in terminal)
  - terminal for running commands (not Python scripts for file operations)
- Inconsistent tool usage = unpredictable output. This is a policy violation.
- Deviating from the standard tool for a specific purpose without documented
  reason = auto-FAIL on next verifier evaluation.

### §8.8 · Claude.md, AGENTS.md, and settings.* as Living Documents

- These files are updated by the sync script at `~/.claude/scripts/sync-ralph-config.sh`.
- After any hook update, run: bash ~/.claude/scripts/sync-ralph-config.sh
- The sync script ensures:
  a) CLAUDE.md and AGENTS.md are byte-for-byte identical in their ralph-loop sections
  b) settings.json has all required hook registrations
  c) settings.local.json has correct overrides
  d) All files are hash-registered in contract-hashes.json
  e) chmod 444 is applied to all contract files
'

# Check if section already exists
if grep -q '## §8 · Prompt Execution Accuracy' "$CLAUDE_MD"; then
    log "CLAUDE.md §8 already present — skipping"
else
    log "Appending §8 to CLAUDE.md"
    printf '%s\n' "$CLAUDE_ACCURACY_BLOCK" >> "$CLAUDE_MD"
fi

# ============================================================
# SECTION 2 — Sync AGENTS.md and agents.md with CLAUDE.md
# ============================================================

log "Syncing AGENTS.md and agents.md..."

if grep -q '## §8 · Prompt Execution Accuracy' "$AGENTS_MD"; then
    log "AGENTS.md §8 already present — skipping"
else
    cat "$CLAUDE_MD" > "$AGENTS_MD"
    log "AGENTS.md synced from CLAUDE.md"
fi

if grep -q '## §8 · Prompt Execution Accuracy' "$AGENTS_MD2"; then
    log "agents.md §8 already present — skipping"
else
    cat "$CLAUDE_MD" > "$AGENTS_MD2"
    log "agents.md synced from CLAUDE.md"
fi

# ============================================================
# SECTION 3 — Update settings.json with enforcement config
# ============================================================

log "Updating settings.json hook registrations..."

# Unlock before writing (chmod 444 from prior run blocks us)
chmod u+w "$SETTINGS_JSON" "$SETTINGS_LOCAL" 2>/dev/null || true

python3 - <<'PY'
import json, pathlib, copy

settings = json.load(open(pathlib.Path.home() / '.claude' / 'settings.json'))

# Ensure hooks section has all required Ralph registrations
ralph_hooks = {
    "PreToolUse": [
        {
            "matcher": "Write|Edit|Bash",
            "hooks": [
                {
                    "type": "command",
                    "command": "bash /Users/vic/.claude/hooks/ralph-loop-infinite-pretool.sh"
                }
            ]
        }
    ],
    "UserPromptSubmit": [
        {
            "matcher": ".*",
            "hooks": [
                {
                    "type": "command",
                    "command": "bash /Users/vic/.claude/hooks/ralph-loop-infinite-prompt.sh"
                }
            ]
        }
    ],
    "Stop": [
        {
            "matcher": ".*",
            "hooks": [
                {
                    "type": "command",
                    "command": "bash /Users/vic/.claude/hooks/ralph-loop-infinite-stop.sh"
                }
            ]
        }
    ],
    "SessionStart": [
        {
            "matcher": ".*",
            "hooks": [
                {
                    "type": "command",
                    "command": "bash /Users/vic/.claude/hooks/ralph-loop-infinite-bootstrap.sh"
                }
            ]
        }
    ]
}

if "hooks" not in settings:
    settings["hooks"] = {}

# Merge Ralph hooks without replacing existing ones
for hook_type, handlers in ralph_hooks.items():
    if hook_type not in settings["hooks"]:
        settings["hooks"][hook_type] = handlers
    else:
        existing_commands = [h.get("command","") for h in settings["hooks"][hook_type] if isinstance(h, dict)]
        for handler in handlers:
            if handler.get("command","") not in existing_commands:
                settings["hooks"][hook_type].append(handler)

# Ensure Ralph exit policy
settings["_ralphLoopInfiniteExitPolicy"] = {
    "mode": "verifier-pass-required (v4.2.1)",
    "version": "4.2.1",
    "generator_infinite_by_design": True,
    "convergence_escalation_not_exit": True,
    "anti_weak_criticism": True,
    "anti_leniency": True,
    "no_self_approve": True,
    "hmac_signed_pass_only": True,
    "prompt_execution_accuracy": True,
    "output_predictability": True,
    "state_preservation_mandatory": True,
    "iteration_prefix_required": True
}

# Ensure high effort
settings["effortLevel"] = "xhigh"

# Ensure dangerous mode skip
settings["skipDangerousModePermissionPrompt"] = True

out = pathlib.Path.home() / '.claude' / 'settings.json'
with open(out, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

print("settings.json updated")
PY

# ============================================================
# SECTION 4 — Update settings.local.json
# ============================================================

log "Updating settings.local.json..."

python3 - <<'PY'
import json, pathlib

local = {}
lf = pathlib.Path.home() / '.claude' / 'settings.local.json'
if lf.exists():
    local = json.load(open(lf))

local["_ralphLoopInfinite"] = {
    "config_version": "4.2.1",
    "active": True,
    "generator": "infinite_by_design",
    "convergence": "escalation_not_exit",
    "anti_weak_criticism": True,
    "anti_leniency": True,
    "provider_chain": {
        "primary": "anthropic/claude-opus-4-7",
        "fallback_opus_deepseek": "minimax/MiniMax-M2.7",
        "fallback_all_others": "minimax/MiniMax-M2.7",
        "non_silent": True
    },
    "threshold": 0.80,
    "max_iterations_default": 3,
    "pass_ttl_seconds": 120,
    "hmac_key_path": "~/.claude/secrets/ralph-hmac.key",
    "manifest_path": "~/.claude/manifest/contract-hashes.json",
    "db_path": "~/.claude/state/ralph-loop-infinite.db"
}

with open(lf, 'w') as f:
    json.dump(local, f, indent=2)
    f.write('\n')

print("settings.local.json updated")
PY

# ============================================================
# chmod 444 applied AFTER all content updates are complete
# (sections 8-10 append to CLAUDE.md so lock must come last)
# ============================================================

# chmod 444 deferred — runs AFTER §9 appends to CLAUDE.md
# (section 5 in original ordering was too early)

# ============================================================
# SECTION 6 — Regenerate contract hashes manifest
# ============================================================

log "Regenerating contract hashes manifest..."

if [[ -x "$HOOKS_DIR/generate-contract-hashes.sh" ]]; then
    bash "$HOOKS_DIR/generate-contract-hashes.sh"
    bash "$HOOKS_DIR/generate-contract-hashes.sh" --verify
    log "  manifest regenerated and verified"
else
    log "  SKIPPED — generate-contract-hashes.sh not found or not executable"
fi

# ============================================================
# SECTION 7 — Verify syntax
# ============================================================

log "Verifying shell syntax..."

for f in "$HOOKS_DIR"/*.sh; do
    if [[ -f "$f" && -x "$f" ]]; then
        bash -n "$f" 2>&1 | while read line; do
            log "  shell syntax error in $f: $line"
        done || log "  shell syntax OK: $(basename $f)"
    fi
done

log "Verifying Python syntax..."

for f in "$HOOKS_DIR"/*.py; do
    if [[ -f "$f" ]]; then
        python3 -B -m py_compile "$f" 2>&1 | while read line; do
            log "  py syntax error in $f: $line"
        done || log "  py compile OK: $(basename $f)"
    fi
done

# ============================================================
# SECTION 9 — Sub-Agent Architecture Enforcement
# ============================================================

SUBAGENT_BLOCK='
## §9 · Sub-Agent Architecture — Enforcement

The Ralph-Loop-Infinite sub-agent structure is MANDATORY and ENFORCED.
All work delegation must follow this hierarchy:

### §9.1 · Sub-Agent Roles

| Role | Purpose | CanDelegate |
|------|---------|-------------|
| Orchestrator | Decomposes task, spawns workers, coordinates | Yes (hierarchy workers) |
| Worker / Leaf | Executes specific work item, returns evidence | No |
| Verifier | Independent evaluation, HMAC-signed PASS only | No |

The system is NOT a flat pool of equal agents. The Orchestrator owns the loop;
workers are disposable tools; the Verifier is outside and independent.

### §9.2 · Orchestrator Responsibilities

1. **Task decomposition** — break the user prompt into discrete work items
2. **Worker assignment** — assign each work item to exactly one worker
3. **Evidence collection** — collect worker outputs; verify against original prompt
4. **Convergence check** — after each worker iteration, check convergence before continuing
5. **Remediation routing** — if verifier FAILs, the Orchestrator (not the worker) feeds
   the critique back to the same worker lineage with anchored remediation

### §9.3 · Sub-Agent Delegation Rules

- Orchestrator MUST use prompts from `~/.sub-agents/` (VPS: `/root/.sub-agents/`)
- Worker manifests must be SHA-256 verified via `MANIFEST.sha256.json`
- Workers CANNOT delegate further (leaf-only unless Orchestrator)
- Orchestrator MUST track which worker produced which artifact
- The Orchestrator is responsible for the quality of all worker outputs
- Workers do NOT self-assess. Workers return evidence. Orchestrator routes to Verifier.

### §9.4 · Work Item Tracking

Every work item MUST be tracked end-to-end:

```
session_id → work_request_id → requirement → success_criteria
  → theme → feature_id → epic → story → task
  → test → defect/risk → sub-agent → orchestrator → verifier
  → verifier_pass (120s TTL) → delivery → outcome to user
```

The Orchestrator MUST seed this chain into the Kanban board before work begins.
No work item may be marked complete without Verifier PASS.

### §9.5 · Orchestrator Cannot Self-Execute

The Orchestrator MUST NOT do the work itself while pretending to delegate.
If a work item requires implementation, the Orchestrator spawns a worker,
monitors the worker, collects evidence, and routes to Verifier.
The Orchestrator doing the work directly without a worker = anti-pattern.
The Verifier will FAIL this as "orchestrator self-execution detected".

### §9.6 · Worker Exit Rules

Workers do NOT declare completion. Workers return:
- Artifact paths (real, not claimed)
- Evidence of changes (diff, test output, line counts)
- What was done and what remains
- Explicit statement of what the Orchestrator should verify next

The Orchestrator, not the worker, decides if the work item is done.

### §9.7 · Sub-Agent Prompt Registry

All sub-agent prompts MUST be loaded from:
- Local: `~/.sub-agents/`
- VPS: `/root/.sub-agents/`

Prompts are versioned and hash-registered. The Orchestrator MUST verify
prompt integrity before dispatch. Using a prompt not in the registry
= security violation, loop continues without that dispatch.

Install: `bash ~/.claude/scripts/install-sub-agents-to-root.sh`
with `SUB_AGENTS_HOST=root@<vps>`
'

if grep -q '## §9 · Sub-Agent Architecture' "$CLAUDE_MD"; then
    log "CLAUDE.md §9 already present — skipping"
else
    printf '%s\n' "$SUBAGENT_BLOCK" >> "$CLAUDE_MD"
    log "Appended §9 sub-agent architecture to CLAUDE.md"
fi

# ============================================================
# Deferred chmod 444 — after CLAUDE.md §9 has been appended
# ============================================================
log "Applying chmod 444 to contract files..."
for f in "$CLAUDE_MD" "$AGENTS_MD" "$AGENTS_MD2" "$SETTINGS_JSON" "$SETTINGS_LOCAL"; do
    if [[ -f "$f" ]]; then
        chmod 444 "$f" 2>/dev/null && log "  chmod 444 $f" || log "  chmod 444 skipped (root only) $f"
    fi
done
for f in "$HOOKS_DIR"/*.sh "$HOOKS_DIR"/*.py; do
    if [[ -f "$f" ]]; then
        chmod 444 "$f" 2>/dev/null && log "  chmod 444 $f" || log "  chmod 444 skipped (root only) $f"
    fi
done

# ============================================================
# SECTION 10 — Final report
# ============================================================

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Ralph Config Sync — Complete"
echo "══════════════════════════════════════════════════════"
echo "  CLAUDE.md:       $(wc -c < "$CLAUDE_MD") bytes"
echo "  AGENTS.md:       $(wc -c < "$AGENTS_MD") bytes"
echo "  agents.md:       $(wc -c < "$AGENTS_MD2") bytes"
echo "  settings.json:   $(wc -c < "$SETTINGS_JSON") bytes"
echo "  settings.local:  $(wc -c < "$SETTINGS_LOCAL") bytes"
echo ""
echo "  Run: bash ~/.claude/hooks/test-ralph-refactor.sh"
echo "  to validate after this sync."
echo "══════════════════════════════════════════════════════"