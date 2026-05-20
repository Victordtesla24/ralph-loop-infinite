# council/ — Legacy / Obsolete

> **Status: OBSOLETE — not used in v4.x production paths**

This directory contains worker prompts from the pre-v4.0 era (HOS orchestration
prototype). It is kept for historical reference only.

**Current production paths:**

- `sub-agents/claude-roles/` — the canonical role definitions (GENERATOR/CRITIC/JUDGE)
- `sub-agents/orchestrator/` — orchestrator-stage prompts (GENERATOR)
- `sub-agents/verifier/` — verifier-stage prompts (JUDGE role contract; actual
  judging is performed by `ralph-loop-infinite-ralph.py judge`)

**Why council/ is not used:**

The council/ directory was designed for a multi-agent deliberation model where
workers debated in a shared context. The Ralph-Loop-Infinite v4.x architecture
replaced this with:

1. A typed generator (`ralph-loop-infinite-generator.py`) that dispatches
   explicit `orchestrator,coder,tester` stages via `scripts/ralph-spawn.sh`
2. An explicit Python loop engine (`ralph-loop-infinite-ralph.py`) that owns
   the GENERATE→CRITIQUE→JUDGE→REMEDIATE state machine
3. An independent verifier-as-function (not a spawned sub-agent) for the JUDGE role

The `hos-orchestrator.md`, `analyst_programmer.md`, `qa-verifier.md`,
`researcher.md`, and `solutions_architect.md` files in this directory served
as early deliberation prompts — they predate the GCJ classification system
and the per-dimension threshold enforcement.

**Files in this directory (do not use in new work):**

- `AGENTS.md` — workspace template (not role-specific)
- `BOOTSTRAP.md` — historical bootstrap marker
- `HEARTBEAT.md` — heartbeat prompt template
- `IDENTITY.md` — worker identity
- `SOUL.md`, `TOOLS.md`, `USER.md` — workspace files
- `hos-orchestrator.md` — HOS orchestrator prompt (obsolete)
- `analyst_programmer.md` / `analyst-programmer.md` — analyst worker (obsolete)
- `qa-verifier.md` — QA verifier worker (obsolete)
- `researcher.md` — researcher worker (obsolete)
- `solutions_architect.md` / `solutions-architect.md` — solutions architect (obsolete)
- `cleanup-agent.md` — cleanup agent (obsolete)

**Maintaining this directory:** Do not add new files here. If a new role is
needed, define it in `sub-agents/claude-roles/` with a `*.SOUL.md` and
`*.system-prompt.md` pair and the corresponding RALPH stage prompt
(`*.RALPH.md` for GENERATOR, `*.CRITIC.md` for CRITIC, `*.JUDGE.md` for JUDGE).