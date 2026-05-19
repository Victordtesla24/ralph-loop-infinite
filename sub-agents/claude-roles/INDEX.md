# `.sub-agents/claude-roles/` — Ralph-Loop-Infinite Sub-Agent Registry

This directory holds 8 role definitions for the Ralph-Loop-Infinite orchestration ring.
Each role is classified under one of three blog-aligned roles:

| Blog Role | Ralph-Loop Role | Description |
|---|---|---|
| **GENERATOR** | Produce output | Cannot stop the loop. Repeats until JUDGE PASS. |
| **CRITIC** | Identify issues | Shapes the next GENERATOR iteration. Must be concrete. |
| **JUDGE** | Score + decide | Independent, read-only. HMAC-signed PASS exits the loop. |

Each role is defined by two files:
- `<role>.SOUL.md` — single-paragraph identity card + classification header
- `<role>.system-prompt.md` — full operating prompt

## Classification Summary

| Sub-Agent | Blog Role | Cannot Stop Loop | Must Receive Critique | Must Score 5 Dimensions |
|---|---|:---:|:---:|:---:|
| orchestrator | GENERATOR | ✓ | ✓ | — |
| coder | GENERATOR | ✓ | ✓ | — |
| solution-architect | GENERATOR | ✓ | ✓ | — |
| researcher | GENERATOR | ✓ | ✓ | — |
| senior-sme | GENERATOR | ✓ | ✓ | — |
| analyst | CRITIC | — | feeds JUDGE | — |
| tester | CRITIC | — | feeds JUDGE | — |
| verifier | JUDGE | — | receives from CRITIC | ✓ |

## Artifact Table

| File | Classification | Characters | Threshold | Status |
|---|---|---:|---:|:---:|
| `analyst.SOUL.md` | CRITIC | — | 500 | updated |
| `analyst.system-prompt.md` | CRITIC | 6150 | 50000 | PASS |
| `coder.SOUL.md` | GENERATOR | — | 500 | updated |
| `coder.system-prompt.md` | GENERATOR | 9177 | 50000 | PASS |
| `orchestrator.SOUL.md` | GENERATOR | — | 500 | updated |
| `orchestrator.system-prompt.md` | GENERATOR | 10050 | 50000 | PASS |
| `researcher.SOUL.md` | GENERATOR | — | 500 | updated |
| `researcher.system-prompt.md` | GENERATOR | 6595 | 50000 | PASS |
| `senior-sme.SOUL.md` | GENERATOR | — | 500 | updated |
| `senior-sme.system-prompt.md` | GENERATOR | 7015 | 50000 | PASS |
| `solution-architect.SOUL.md` | GENERATOR | — | 500 | updated |
| `solution-architect.system-prompt.md` | GENERATOR | 6793 | 50000 | PASS |
| `tester.SOUL.md` | CRITIC | — | 500 | updated |
| `tester.system-prompt.md` | CRITIC | 6820 | 50000 | PASS |
| `verifier.SOUL.md` | JUDGE | — | 500 | updated |
| `verifier.system-prompt.md` | JUDGE | 9735 | 50000 | PASS |

## Read Order

1. `<role>.SOUL.md` — classification + 3-second identity scan
2. `<role>.system-prompt.md` — full operational charter
3. `INDEX.md` (this file) — registry and validation status

## Dispatch Rules

- Orchestrator MUST load SOUL files and verify classification before dispatch
- Workers are spawned from `hierarchy/` or `council/` with SOUL classification attached
- Verifier (JUDGE) is NEVER spawned as a worker — it is always called directly by stop.sh
- No sub-agent may self-declare done; only JUDGE HMAC-signed PASS ends the loop
- Orchestrator cannot self-execute (cannot do the work it pretends to delegate)
- All dispatches inherit the Ralph-loop gate state

## Hash Registration

All SOUL.md files are hash-registered in `MANIFEST.sha256.json`.
Any modification to a SOUL.md must be followed by MANIFEST regeneration:
`bash ~/.claude/scripts/sync-ralph-config.sh`