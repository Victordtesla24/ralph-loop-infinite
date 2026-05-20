# hierarchy/ — Legacy / Obsolete

> **Status: OBSOLETE — not used in v4.x production paths**

This directory contains role effort matrices and role relationship definitions
from the pre-v4.0 era. It is kept for historical reference only.

**Current production paths:**

- `sub-agents/claude-roles/` — the canonical role definitions (GENERATOR/CRITIC/JUDGE)
- `scripts/ralph-spawn.sh` — the authoritative GCJ classification mapping
  (`ROLE_TO_GCJ_JSON`) that maps roles to their GCJ stage

**Why hierarchy/ is not used:**

The `role_matrix.yaml` and `effort_cascade.yaml` files were designed for a
resource-allocation model where different agent types had different effort
budgets. The Ralph-Loop-Infinite v4.x architecture replaced this with:

1. Explicit GCJ classification enforced by `scripts/ralph-spawn.sh`
2. Per-dimension scoring (completeness, correctness, clarity, depth,
   actionability) with 0.8 threshold enforced by the Python engine
3. Provider/model policy centralized in `ralph-loop-infinite-policy.py`

The effort cascade concept (orchestrator high-effort → coder medium →
tester low) is now handled by the `effort` parameter passed to the judge
function and the per-stage logging in `ralph-thinking-loop.jsonl`.

**Files in this directory:**

- `role_matrix.yaml` — role classification matrix (obsolete)
- `effort_cascade.yaml` — effort allocation per role (obsolete)

**Maintaining this directory:** Do not modify or add files here. If role
relationships need to be redefined, update `scripts/ralph-spawn.sh` and
the corresponding `*.RALPH.md` / `*.CRITIC.md` / `*.JUDGE.md` stage prompt
files in `sub-agents/claude-roles/`.