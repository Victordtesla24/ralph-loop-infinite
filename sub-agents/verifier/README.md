# verifier/ — JUDGE Role Contract (Not an Independently Running Agent)

> **Status: DOCUMENTATION ONLY — this directory contains the JUDGE role
> contract, not an independently running agent.**

The JUDGE role in Ralph-Loop-Infinite v4.x is fulfilled by a Python function,
**not** by a spawned sub-agent. This directory contains the role contract
used to document what the JUDGE does — the actual judging is performed by
`ralph-loop-infinite-ralph.py judge` (the `critique_and_judge()` function).

## Why the JUDGE is a Function, Not an Agent

Previous architectural iterations spawned the verifier as a separate sub-agent
with its own conversation context. This had two problems:

1. **Context bleed** — the verifier agent shared the same conversation history
   as the implementer, allowing self-referential validation instead of
   independent assessment
2. **Silent failures** — a failed LLM call in a spawned agent could fall through
   without the stop hook knowing whether validation actually ran

The v4.x architecture fixes both by making the JUDGE a first-class Python
function:

```
ralph-loop-infinite-verifier.sh (shell, HMAC signing)
    └── python3 ralph-loop-infinite-ralph.py judge
            └── critique_and_judge()  ← the actual JUDGE
                    ├── CRITIC: structured API call → Critique object
                    └── JUDGE:  structured API call → Judgement object
```

The shell script owns: API key loading, evidence bundle building, HMAC signing,
and verdict emission. The Python helper owns: prompt construction, model calls,
JSON parsing, threshold enforcement, and stage logging.

## What the JUDGE Contract Requires

The `*.system-prompt.md` and `JUDGE.md` files in this directory document the
JUDGE role contract:

1. **Five scoring dimensions**: completeness, correctness, clarity, depth,
   actionability — each 0.0-1.0
2. **Threshold**: 0.80 per dimension — any dimension below → decision='revise'
3. **No averaging**: individual dimensions never averaged together
4. **Missing artifacts**: force revise
5. **Evidence deviations**: force revise
6. **HMAC-signed PASS**: the only loop-exit mechanism

## Files in This Directory

- `AGENTS.md` — workspace template
- `BOOTSTRAP.md` — bootstrap marker
- `IDENTITY.md` — JUDGE identity
- `SOUL.md` — JUDGE soul/purpose
- `USER.md` — user interaction guidance
- `TOOLS.md` — tool specifications for the JUDGE role contract
- `BOOTSTRAP.md` — bootstrap marker

These files **document the role contract** — they are loaded into the system
prompt when a human or tool needs to understand what the JUDGE does, but the
actual JUDGE execution uses the Python function with its own structured prompts.

## Verifier vs. This Directory

- `verifier.SOUL.md` in `sub-agents/claude-roles/` — the production role
  contract (source of truth for the spawned prompt)
- `verifier/JUDGE.md` — the stage prompt for the JUDGE role (same content
  as the RALPH stage prompt in `sub-agents/verifier/JUDGE.md`)
- `ralph-loop-infinite-ralph.py judge` — the **actual execution path** (not a
  spawned agent)