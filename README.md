# R A L P H — Loop Infinite

### Self-Improving AI Systems Without the Chaos

---

## Overview

Ralph-Loop-Infinite is a production-grade autonomous AI system built on enforced structure — not wishful prompts hoping to behave. It is an infinite verifier-gate framework inspired by the Ralph Loop architecture from [gowrishankar.info](https://gowrishankar.info/blog/ralph-loop-building-self-improving-ai-systems-without-claude/), with a bounded explicit engine inside the gate (`GENERATE → CRITIQUE → JUDGE → REMEDIATE`) and an additional HMAC-signed PASS requirement for operational safety.

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   ┌────────────┐    ┌───────────┐    ┌──────────┐           │
│   │  GENERATE  │───▶│  CRITIQUE  │───▶│   JUDGE   │──┐      │
│   └────────────┘    └───────────┘    └──────────┘  │      │
│       │                  │                │        │      │
│       ▼                  ▼                ▼        │      │
│   Produce output    Identify issues  Score + decide       │
│   + state contract  concrete issues  all dims ≥ 0.80      │
│                                        │        ▼          │
│                                        │   HMAC-signed     │
│                                        │   verifier PASS   │
│                                        └── exits loop     │
└─────────────────────────────────────────────────────────────┘
```

**Three roles, precisely defined:**

| Role | Function | Stops the loop? |
|---|---|---|
| **GENERATOR** | Produces output. Repeats until JUDGE PASS. | Never |
| **CRITIC** | Identifies concrete issues. Shapes next GENERATOR iteration. | No |
| **JUDGE** | Scores 5 dimensions. Issues HMAC-signed PASS. | Only via PASS |

---

## Installation

### One-Command Setup

```bash
git clone https://github.com/Victordtesla24/ralph-loop-infinite.git
cd ralph-loop-infinite
bash bootstrap.sh
```

### What Bootstrap Does

```
[1/6] Installing Ralph hooks to ~/.claude/hooks/
[2/6] Generating HMAC signing key (~/.claude/secrets/ralph-hmac.key)
[3/6] Registering contract hashes (~/.claude/manifest/contract-hashes.json)
[4/6] Creating state directory (~/.claude/state/)
[5/6] Initializing SQLite database
[6/6] Running self-test (PASS 26 / FAIL 0)
```

### Runtime Dependencies

- `python3`, `bash`, and `jq` are required for hook enforcement, evidence checks, and JSON signing paths.
- The optional sub-agent fan-out path uses the Claude CLI binary from `RALPH_SPAWN_CLAUDE_CMD` or `claude` on `PATH`.
- If the Claude CLI is absent (common in CI), the Stop hook logs `CLAUDE_CLI_MISSING` and downgrades generator retry to the repository-local inline `RalphLoopEngine.generate(...)` path instead of silently failing the whole loop.

### Post-Install Configuration

Copy API keys to `~/.claude/.env.production`:

```bash
cat >> ~/.claude/.env.production << 'EOF'
ANTHROPIC_API_KEY=your-anthropic-key-here
ANTHROPIC_VERIFIER_API_KEY=your-anthropic-verifier-key-here
RALPH_HMAC_KEY=$(openssl rand -hex 64)
EOF
```

> HMAC key is auto-generated. The `RALPH_HMAC_KEY` above is only for the signing mechanism — the actual HMAC key is stored at `~/.claude/secrets/ralph-hmac.key` and never printed.

---

## How to Use

### Arm the Loop

```
/ralph-loop-infinite
```

The loop activates **only** on explicit invocation. Ship/deploy/done language does NOT arm the gate.

### Monitor State

```bash
# View sessions
python3 ~/.claude/hooks/ralph-loop-infinite-db.py sessions

# View current state
python3 ~/.claude/hooks/ralph-loop-infinite-db.py state-get verifier_last_verdict

# View event log
python3 ~/.claude/hooks/ralph-loop-infinite-db.py events

# Run regression harness
bash ~/.claude/hooks/test-ralph-refactor.sh
```

### Disarm (Manual Exit — Only With User Reason)

```
/ralph-loop-infinite-disarm — I want to stop this loop now and continue manually
```

Requires ≥ 10 character reason. Agent cannot self-disarm.

---

## Architecture

### The Four Stages

```
GENERATE → CRITIQUE → JUDGE → REMEDIATE → (repeat until JUDGE PASS)
```

**Generate:** First-class `Generated` typed object owned by `hooks/ralph-loop-infinite-ralph.py` (`RalphLoopEngine.generate()`). The optional `ralph-loop-infinite-generator.py` sidecar is an executor backend that returns typed role artifacts; hooks adapt to the engine, they do not own the loop.

**Critique:** Concrete issues with severity (1-5) and actionable suggestions. NOT vague feedback.

**Judge:** Scores all five dimensions (completeness, correctness, clarity, depth, actionability) — each 0.0-1.0. Any dimension < 0.80 → automatic revise. No partial credit, no averaging.

**Remediate:** Targeted fix — preserve correct parts, address only identified issues. NOT a naive full rewrite. The blog says: *"treat this like an editor with a red pen, NOT a writer."*

### Exit Conditions

```
HMAC-SIGNED PASS              MAX_ITERATIONS (default: 3)      CONVERGENCE
all 5 dims ≥ 0.80            → best-iteration output,          score ≤ prev
+ all artifacts present      verifier_last_verdict=            → strict default:
                              MAX_REACHED_RETURN, allow          targeted escalation,
                                                                 NOT blocker
                                                                 blog mode:
                                                                 RALPH_CONVERGENCE_EXIT=1
                                                                 returns current output
```

### Sub-Agent Hierarchy

```
Orchestrator (GENERATOR) ──▶ Worker/Coder (GENERATOR) ──▶ Evidence
                │
                ▼
            CRITIC (tester, analyst, qa-verifier)
                │
                ▼
            JUDGE (verifier) ── HMAC-signed PASS
```

Workers do NOT self-assess. Orchestrator routes to JUDGE. Only JUDGE can stop the loop.
On verifier FAIL or evidence PRECHECK_FAIL, `ralph-loop-infinite-stop.sh` deterministically invokes `ralph-loop-infinite-generator.py`, which dispatches explicit `orchestrator,coder,tester` stages through `scripts/ralph-spawn.sh` (configurable via `RALPH_GENERATOR_ROLES`). Success requires every required stage to exit 0 and write an evidence artifact. The Stop hook monitors and records state; the generator subprocess is the autonomous executor backend.

---

## Provider Chain

```
┌────────────────────────────────────────────────────────────┐
│                                                             │
│   Ralph Helper (ralph-loop-infinite-ralph.py)              │
│                                                             │
│   [Anthropic / claude-opus-4-7]         ← Primary          │
│                  ↓  FAIL                                     │
│   [MiniMax / MiniMax-M2.7]               ← Opus / Deepseek  │
│                  ↓  FAIL                                     │
│   [MiniMax / MiniMax-M2.7]               ← All other agents │
│                  ↓  ALL FAIL                                 │
│   [offline-rule-based / deterministic]    ← diagnostic FAIL only          │
│                  checks, clearly labelled provider           │
│                                                             │
│   Every skip and failure is logged.                         │
│   Fallback is NEVER silent.                                 │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

Fallback model: **MiniMax-M2.7** via MinMax OAuth (MiniMax.io) — see `.env.production` keys.

---

## Sub-Agents — GENERATOR / CRITIC / JUDGE Classification

All sub-agents are classified under one of three roles from the blog:

```
~/.sub-agents/
├── claude-roles/           ← 8 role definitions (blog-aligned)
│   ├── orchestrator.SOUL.md   GENERATOR  (produces output, cannot stop loop)
│   ├── coder.SOUL.md          GENERATOR
│   ├── solution-architect.SOUL.md  GENERATOR
│   ├── researcher.SOUL.md     GENERATOR
│   ├── senior-sme.SOUL.md     GENERATOR
│   ├── analyst.SOUL.md        dual-mode prompt: use analyst-generator or analyst-critic
│   ├── tester.SOUL.md         CRITIC
│   └── verifier.SOUL.md       JUDGE     (scores + HMAC-signed PASS)
├── council/                ← Worker prompts (GENERATOR + CRITIC)
├── hierarchy/              ← Role effort/matrix definitions
├── orchestrator/           ← Orchestrator prompts (GENERATOR)
└── verifier/               ← Verifier prompts (JUDGE)
```

Installed by bootstrap to `~/.sub-agents/` — preserved on re-runs (not overwritten).

---

## Files

```
ralph-loop-infinite/
├── bootstrap.sh                  ← One-command install
├── README.md
├── CLAUDE.md                      ← Canonical contract (hash-registered)
├── AGENTS.md                      ← Agent persona (synced from CLAUDE.md)
├── hooks/
│   ├── ralph-loop-infinite-prompt.sh      ← UserPromptSubmit hook
│   ├── ralph-loop-infinite-stop.sh        ← Stop hook (verifier invocation)
│   ├── ralph-loop-infinite-session-start.sh ← SessionStart hook (PASS expiry + prerequisite report)
│   ├── ralph-loop-infinite-bootstrap.sh   ← Bootstrap / install
│   ├── ralph-loop-infinite-pretool.sh     ← Pre-tool deny guard
│   ├── ralph-loop-infinite-ralph.py      ← explicit loop engine + first-class Generated stage
│   ├── ralph-loop-infinite-generator.py  ← optional typed generator executor backend
│   ├── ralph-loop-infinite-policy.py      ← Provider/model policy
│   ├── ralph-loop-infinite-evidence.py    ← Evidence precheck
│   ├── ralph-loop-infinite-db.py          ← SQLite state DB
│   ├── ralph-loop-infinite-tsparse.py     ← Timestamp parsing
│   ├── ralph-loop-infinite-pathguard.py   ← Path deny guard
│   ├── generate-contract-hashes.sh        ← Manifest registry
│   └── test-ralph-refactor.sh             ← Regression harness
├── scripts/
│   ├── sync-ralph-config.sh        ← Update CLAUDE.md + settings.json
│   └── install-sub-agents-to-root.sh ← Install sub-agents to VPS
└── sub-agents/
    ├── claude-roles/               ← 8 role definitions (GENERATOR/CRITIC/JUDGE)
    ├── council/                    ← Council worker prompts
    ├── hierarchy/                  ← Hierarchy worker prompts
    ├── orchestrator/               ← Orchestrator prompts
    ├── verifier/                   ← Verifier prompts
    └── MANIFEST.sha256.json        ← Prompt integrity registry
```

---

## Regression Test

```bash
bash ~/.claude/hooks/test-ralph-refactor.sh
```

Expected: **PASS 26 / FAIL 0**

Tests enforce:
- Threshold ≥ 0.80 on all five dimensions
- Targeted fix remediation (not naive rewrite)
- Non-silent provider fallback
- Content-aware evidence validation
- Status-token regex enforcement
- DB-first signed-PASS lookup
- Anti-weak-criticism rules
- Anti-leniency rules

---

## Key Properties

| Property | Value |
|---|---|
| Threshold | 0.80 per dimension |
| MAX_ITERATIONS | 3 (hard blocker) |
| PASS TTL | 120 seconds |
| State DB | SQLite at `~/.claude/state/ralph-loop-infinite.db` |
| HMAC key | `~/.claude/secrets/ralph-hmac.key` |
| Manifest | `~/.claude/manifest/contract-hashes.json` |
| Verifier model | `claude-opus-4-7` (primary) / `MiniMax-M2.7` (fallback) |

---

## Final Take

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   A loop doesn't guarantee improvement.                     │
│   A system doesn't guarantee reliability.                   │
│                                                              │
│   You earn both by:                                          │
│     enforcing structure                                      │
│     defining quality                                         │
│     handling failure like an adult system                   │
│                                                              │
│   That's the difference between:                             │
│     a cool demo  ───────────  production-grade system         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

The Ralph Loop forces the shift:

```
single-pass answers    →  iterative reasoning
implicit behavior      →  explicit evaluation
hopeful outputs        →  measured decisions
```

---

*Ralph-Loop-Infinite v4.2.1 — Production Implementation*
*https://github.com/Victordtesla24/ralph-loop-infinite*
*Independent verifier · HMAC-signed PASS · Explicit contracts · No silent failures*