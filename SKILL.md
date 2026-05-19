---
name: ralph-loop-infinite
description: Ralph-Loop-Infinite — autonomous self-improving AI system. Arm with /ralph-loop-infinite. Enforced structure, HMAC-signed verifier PASS, no silent failures.
category: autonomous-ai-agents
trigger: /ralph-loop-infinite
---

# Ralph-Loop-Infinite Skill

## What This Does

Ralph-Loop-Infinite is a production-grade autonomous AI system that implements a four-stage self-improving loop:

```
GENERATE → CRITIQUE → JUDGE → REMEDIATE → (repeat until JUDGE PASS)
```

## Quick Start

```bash
# Arm the loop
/ralph-loop-infinite

# Monitor
python3 ~/.claude/hooks/ralph-loop-infinite-db.py sessions

# Run tests
bash ~/.claude/hooks/test-ralph-refactor.sh

# Disarm (requires user reason ≥10 chars)
/ralph-loop-infinite-disarm — reason here
```

## Architecture

**Three roles:**

| Role | Blog term | What it does |
|---|---|---|
| Orchestrator | GENERATOR | Drives loop, decomposes, delegates, collects evidence |
| analyst-generator | GENERATOR | Decomposes prompts into traceability maps |
| tester/analyst-critic | CRITIC | Identifies concrete issues (severity 1-5, actionable suggestions) |
| verifier | JUDGE | Scores 5 dimensions, issues HMAC-signed PASS |

**Key rules:**
- GENERATORs never stop the loop — only JUDGE HMAC-signed PASS exits
- CRITICs must produce concrete issues, not vague feedback
- JUDGE scores all 5 dims (completeness/correctness/clarity/depth/actionability) ≥ 0.80
- Any dimension < 0.80 → automatic revise
- Convergence → escalation NOT exit (Targeted Fix, not naive rewrite)

## Exit Conditions

```
HMAC-SIGNED PASS        MAX_ITERATIONS (3)       CONVERGENCE
all 5 dims ≥ 0.80      → hard BLOCKER            score ≤ prev →
+ all artifacts        user must re-arm         escalation only
```

## Provider Chain

```
Anthropic/claude-opus-4-7 (primary)
    ↓ FAIL
MiniMax/MiniMax-M2.7 (Opus/Deepseek fallback)
    ↓ FAIL
MiniMax/MiniMax-M2.7 (all other agents fallback)
    ↓ ALL FAIL
→ fail-closed (logged, never silent)
```

## Files

| File | Purpose |
|---|---|
| `~/.claude/hooks/ralph-loop-infinite-prompt.sh` | UserPromptSubmit — arms gate on explicit invocation |
| `~/.claude/hooks/ralph-loop-infinite-stop.sh` | Stop hook — calls verifier, enforces HMAC |
| `~/.claude/hooks/ralph-loop-infinite-ralph.py` | 4-stage thinking loop (Generate/Critique/Judge/Remediate) |
| `~/.claude/hooks/ralph-loop-infinite-verifier.sh` | Independent verifier call + HMAC signing |
| `~/.claude/hooks/ralph-loop-infinite-policy.py` | Provider/model policy |
| `~/.claude/hooks/ralph-loop-infinite-evidence.py` | Content-aware evidence precheck |
| `~/.claude/hooks/ralph-loop-infinite-db.py` | SQLite state DB |
| `~/.claude/hooks/generate-contract-hashes.sh` | Manifest registry |
| `~/.claude/hooks/test-ralph-refactor.sh` | Regression harness |
| `~/.claude/scripts/sync-ralph-config.sh` | Config sync script |

## Sub-Agents

Sub-agents are classified under three blog-aligned roles:

**GENERATOR** (produce output, cannot stop loop):
- orchestrator, coder, solution-architect, researcher, senior-sme, analyst-generator

**CRITIC** (identify issues, shape next iteration):
- tester, analyst-critic, qa-verifier

**JUDGE** (score + decide, independent):
- verifier

## State

- SQLite: `~/.claude/state/ralph-loop-infinite.db`
- State file: `~/.claude/state/ralph-loop-infinite.local`
- HMAC key: `~/.claude/secrets/ralph-hmac.key`
- Manifest: `~/.claude/manifest/contract-hashes.json`

## Key Constraints

1. Agent cannot self-approve or ask user for approval
2. Agent cannot modify contract files while gate is armed
3. Agent cannot declare done — only JUDGE HMAC-signed PASS exits
4. Convergence is escalation, not exit — loop continues with Targeted Fix
5. No partial credit — any dim < threshold = revise

## Installation

```bash
git clone https://github.com/Victordtesla24/ralph-loop-infinite.git
cd ralph-loop-infinite
bash bootstrap.sh
```