# R A L P H — Loop Infinite

### Self-Improving AI Systems Without the Chaos

---

```
┌─────────────────────────────────────────────────────────────┐
│  ┌───────┐  ┌────────┐  ┌──────┐  ┌───────────┐             │
│  │GENRT│──▶│CRITIQUE│──▶│JUDGE │──▶│REMEDIATE  │  ↺         │
│  └───────┘  └────────┘  └──────┘  └───────────┘             │
│       explicit contracts  │  HMAC-signed PASS                │
│                            ▼                                 │
│                    Independent Verifier                      │
└─────────────────────────────────────────────────────────────┘
```

---

## The Core Problem

Most AI agent pipelines look sophisticated in diagrams and fall apart in production.

```
String-in → String-out → Silent chaos

  • Critic returns a blob of text
  • Judge responds with another blob
  • You parse paragraphs trying to find what broke
  • No memory, no contracts, no enforceability

This is how "it worked yesterday" systems are born.
```

## The Solution — Enforced Structure

> *"Not optional structure. Not 'we'll clean it up later' structure.
>  Explicit contracts between each stage of the loop."*

The moment you move from:

```
"Here's some text" → "Figure it out" → "Looks OK maybe"
```

To:

```
"Here's a well-defined contract — adhere to it or fail explicitly."
```

Everything changes.

---

## Architecture

### The Four Stages

```
    ┌──────────────────────────────────────────────────────────┐
    │                                                          │
    │   ┌────────────┐                                        │
    │   │  GENERATE  │  Structured output + explicit contract  │
    │   │  content:  │  Every field typed, every assumption     │
    │   │  + state   │  stated. No guessing what was received. │
    │   └──────┬─────┘                                        │
    │          │                                              │
    │          ▼                                              │
    │   ┌────────────┐                                        │
    │   │  CRITIQUE  │  Concrete issues, severity, actionable │
    │   │  specific  │  suggestions. NOT vague feedback.      │
    │   │  + severity│  Weak criticism → weak remediation →    │
    │   └──────┬─────┘  same quality loop. Stopped here.       │
    │          │                                              │
    │          ▼                                              │
    │   ┌────────────┐                                        │
    │   │    JUDGE    │  Five dimensions. Every one scored.    │
    │   │  score &   │  All must ≥ threshold. Any below =     │
    │   │  decide    │  revise. No averaging out failures.   │
    │   └──────┬─────┘  Verifier is NOT your ally.            │
    │          │                                              │
    │          ▼                                              │
    │   ┌────────────┐                                        │
    │   │ REMEDIATE  │  Targeted fix — NOT a naive full rewrite│
    │   │  Targeted  │  Preserve what's correct. Apply only   │
    │   │  Fix       │  specific fixes. Loop continues.       │
    │   └──────┬─────┘                                        │
    │          │                                              │
    └──────────┼──────────────────────────────────────────────┘
               │
               ▼
        Only HMAC-signed
        verifier PASS exits.
```

---

## The Exit Contract

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   LOOP EXITS ONLY WHEN:                                         │
│                                                                  │
│   ┌──────────────────────────────────────────┐                  │
│   │  HMAC-Signed Verifier PASS                │                  │
│   │  all five dimensions ≥ threshold (0.80)  │                  │
│   │  + all required artifacts present        │                  │
│   └──────────────────────────────────────────┘                  │
│                                                                  │
│   ┌──────────────────────────────────────────┐                  │
│   │  MAX-ITERATIONS reached                  │ → BLOCKER        │
│   │  (default: 3)                            │   User must      │
│   │                                          │   explicitly     │
│   │                                          │   disarm or      │
│   │                                          │   re-arm         │
│   └──────────────────────────────────────────┘                  │
│                                                                  │
│   CONVERGENCE (score ≤ prev_score)      → ESCALATION NOT EXIT   │
│   NOT a blocker. NOT permission to quit. Loop continues with     │
│   Targeted Fix strategy. Naive rewrite loses granularity.        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Strong Typing — The Real Differentiator

Without structure, you have a loosely connected set of prompts hoping to behave.
Hope is not a strategy.

```python
from pydantic import BaseModel
from typing import List

class GeneratedOutput(BaseModel):
    content: str
    assumptions: List[str]
    model: str
    provider: str
    iteration: int

class Critique(BaseModel):
    issues: List[str]          # Specific, not vague
    severity: List[int]        # 1–5 scale
    suggestions: List[str]     # Actionable, not general

class Judgement(BaseModel):
    decision: str             # "accept" | "revise"
    overall_score: float       # 0.0–1.0
    scoring_dimensions: Dict[str, DimScore]
    threshold: float           # Configurable, default 0.80
    missing: List[str]         # What was absent
    deviations: List[str]       # What diverged from spec
```

Each stage now knows exactly what it received.
You can validate. You can log. You can measure. You can debug.

---

## Provider Chain — Autonomous Fallback

```
┌─────────────────────────────────────────────────────────────┐
│                                                              │
│   Ralph Helper (ralph-loop-infinite-ralph.py)               │
│                                                              │
│   [Anthropic / claude-opus-4-7]         ← Primary           │
│                  ↓  FAIL                                      │
│   [MiniMax / MiniMax-M2.7]              ← OpUS / Deepseek   │
│                  ↓  FAIL                                      │
│   [MiniMax / MiniMax-M2.7]              ← GLM agents        │
│                  ↓  ALL FAIL                                  │
│   → log "all providers failed" → fail-closed                 │
│                                                              │
│   Every skip and failure is logged.                          │
│   Fallback is NEVER silent.                                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Evidence Validation — Content-Aware

Before the verifier judges, evidence is prechecked:

```
┌──────────────────────────────────────────────────────┐
│                                                       │
│   evidence.py precheck:                               │
│                                                       │
│   1. Test count claims vs actual artifact content    │
│      (not just file existence)                       │
│                                                       │
│   2. Structural ratio validation:                   │
│      requirements ↔ success criteria ↔ deliverables │
│      Count mismatch → evidence FAIL                   │
│                                                       │
│   3. Hash + metadata preserved for audit trail       │
│                                                       │
│   Evidence must be substantive, not ceremonial.      │
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

## Anti-Weak-Criticism Rules

The verifier CANNOT produce vague feedback.

```
Weak criticism  →  Weak remediation  →  Same quality loop  →  Never converges
```

Every issue MUST be:
- **Concrete** — name the exact artifact, exact requirement, exact dimension
- **Actionable** — a skilled developer reading it knows exactly what to change
- **Mapped** — every issue corresponds to at least one dimension that scored < threshold

Every suggestion MUST be:
- **Specific** — file to open, what to change, and why
- **Non-vague** — "improve quality" is rejected and replaced

---

## Anti-Leniency Rules

The verifier is NOT your ally. It is your quality gate.

```
Leniency  →  Partial delivery passes  →  System degrades  →  Collapse
```

Strictly enforced:

- **No partial credit** — any dimension < threshold → `revise`. No "mostly complete."
- **No softened wording** — dimension below threshold is FAIL, not a "minor concern."
- **Self-assessment rejected** — the agent's §3 exit report is not evidence. Verify against the original user prompt.
- **No average掩盖 failure** — two or more dimensions below threshold → automatic `revise`
- **Claimed work must be in evidence** — tests claimed but not in artifact bundle = deviation

---

## State Architecture

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   ~/.claude/state/ralph-loop-infinite.local         │
│   ~/.claude/state/ralph-loop-infinite.db (SQLite)   │
│                                                     │
│   Per-session tracked fields:                       │
│                                                     │
│     session_id                     Owner binding   │
│     iteration                      Attempt count   │
│     verifier_last_verdict          PASS/FAIL/etc   │
│     verifier_last_score             Float          │
│     verifier_last_reason            Specifics      │
│     remediation_target_session_id   Same-session   │
│     remediation_explicit_blocker    Bool           │
│                                                     │
│   DB is authoritative.                             │
│   Legacy state file mirrors it.                     │
│   State is hash-chained + HMAC-signed.              │
│                                                     │
└─────────────────────────────────────────────────────┘
```

---

## Hook Architecture

```
~/.claude/hooks/
│
├── ralph-loop-infinite-prompt.sh     UserPromptSubmit hook
│                                     Injects contract, enforces owner session
│
├── ralph-loop-infinite-stop.sh       Stop hook (verifier invocation)
│                                     Calls verifier, enforces HMAC, manages exit
│
├── ralph-loop-infinite-bootstrap.sh  Bootstrap / install
│                                     Copies hooks, generates HMAC key, runs self-test
│
├── ralph-loop-infinite-pretool.sh    Pre-tool deny guard
│                                     Blocks dangerous commands while gate is armed
│
├── ralph-loop-infinite-ralph.py      Four-stage thinking loop
│                                     Generate / Critique / Judge / Remediate
│
├── ralph-loop-infinite-policy.py     Provider/model policy
│                                     Centralised provider configuration
│
├── ralph-loop-infinite-evidence.py    Evidence precheck
│                                     Content-aware validation
│
├── ralph-loop-infinite-db.py         SQLite state DB
│                                     Atomic state mutation, fail-closed
│
├── ralph-loop-infinite-tsparse.py    Timestamp parsing
│                                     UTC-consistent across platforms
│
├── ralph-loop-infinite-pathguard.py  Path deny guard
│                                     Classifies and denies dangerous paths
│
├── generate-contract-hashes.sh       Manifest registry
│                                     Hash-registers all contracts
│
└── test-ralph-refactor.sh            Regression harness
                                      Sandbox run, live tree integrity preserved
```

All contracts hash-registered in `~/.claude/manifest/contract-hashes.json`.

---

## Installation

```bash
git clone https://github.com/Victordtesla24/ralph-loop-infinite.git
cd ralph-loop-infinite
bash bootstrap.sh
```

Bootstrap performs:
1. Copies hooks to `~/.claude/hooks/`
2. Generates HMAC signing key at `~/.claude/secrets/ralph-hmac.key`
3. Registers contract hashes in `~/.claude/manifest/contract-hashes.json`
4. Initialises SQLite state database
5. Runs self-test (target: PASS ≥ 19 / FAIL = 0)

---

## Usage

```bash
# Arm the loop — explicit invocation only
/ralph-loop-infinite

# Inspect state
python3 ~/.claude/hooks/ralph-loop-infinite-db.py sessions
python3 ~/.claude/hooks/ralph-loop-infinite-db.py state-get verifier_last_verdict
python3 ~/.claude/hooks/ralph-loop-infinite-db.py events

# Run regression harness
bash ~/.claude/hooks/test-ralph-refactor.sh
```

---

## Autonomous Operation

Once armed, the system runs without human in the loop:

```
User prompt → Sealed state → Generate → Critique → Judge
                                               ↓
                                         PASS? → HMAC signed → Loop exits
                                         FAIL? → Anchored remediation
                                                 Same session continues
                                                 Targeted Fix (not a rewrite)
                                                 Escalation if convergence
                                                 Loop continues
```

The implementation agent cannot:
- Self-approve
- Ask for user confirmation
- Exit except through HMAC-signed verifier PASS
- Use convergence as an exit route (escalation, not escape)
- Claim credit for work not in the evidence bundle

---

## Regression Harness

```bash
bash ~/.claude/hooks/test-ralph-refactor.sh
```

Tests run in a sandboxed state directory. Live tree integrity is preserved.

```
[1]  Threshold ≥ 0.80 — all dimensions enforced on signing side
[2]  Remediation prompt — canonical template phrases present
[3]  MiniMax/GLM fallback — provider chain always logged, never silent
[4]  Evidence precheck — content-aware validation
[5]  Status-token regex — truncated rejected, full accepted
[6]  DB-first signed-PASS lookup — DB preferred over file
[7]  DB self-test + Ralph helper self-test
[8]  Live tree unchanged during harness run
[9]  Anti-weak-criticism rules in system prompt
[10] Anti-leniency rules in system prompt
```

**Current result: PASS 19 / FAIL 0**

---

## Final Take

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   A loop doesn't guarantee improvement.                      │
│   A system doesn't guarantee reliability.                    │
│                                                              │
│   You earn both by:                                          │
│                                                              │
│     enforcing structure                                      │
│     defining quality                                         │
│     handling failure like an adult system                    │
│                                                              │
│   That's the difference between:                             │
│                                                              │
│     a cool demo  ──────────────────  production-grade system  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

The Ralph Loop forces the shift from:

```
single-pass answers    →  iterative reasoning
implicit behavior      →  explicit evaluation
hopeful outputs        →  measured decisions
```

You stop asking *"Which model should I use?"* and start asking *"How does my system improve its own answers?"*

That's a much more durable question.

---

*Ralph-Loop-Infinite — Production Implementation v4.2.0*
*Independent verifier · HMAC-signed PASS · Explicit contracts · No silent failures*

`https://github.com/Victordtesla24/ralph-loop-infinite`