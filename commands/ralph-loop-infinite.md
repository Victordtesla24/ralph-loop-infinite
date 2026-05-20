---
name: ralph-loop-infinite
description: "Infinite production validation loop — no exit until 100% requirement match across programmatic, visual, and traceability checks. Globally binding — cannot be skipped, bypassed, or deferred when explicitly invoked."
argument-hint: "[reconstructed-system-prompt-reference]"
model-invocation: enabled
---

> **v3.5.0 supersedence (binding):** Loop exits ONLY when the independent AI verifier returns an HMAC-signed PASS verdict from `~/.claude/hooks/ralph-loop-infinite-verifier.sh`. User-typed approval phrases NO LONGER exit the loop — they are feedback only. Canonical contract: `~/.opencode/CLAUDE.md`. Manual disarm requires `/ralph-loop-infinite-disarm` with a user-typed reason of at least 30 characters.


## Overview

This command is the user-facing invoker for the installed `ralph-loop-infinite` skill at `~/.claude/skills/ralph-loop-infinite/SKILL.md`.

Verify that the production deployment delivers — programmatically, visually, and experientially — exactly what the user originally requested. No iteration cap. No exit until every validation item passes simultaneously.

This step eliminates the gap that causes users to spend hours debugging system integration issues, UI/UX regressions, server and browser exceptions, and functional-but-broken experiences after deployment.

## ⛓️ GLOBAL BINDING CONTRACT

This command is globally binding across every Claude Code session and every project where it is invoked. It is enforced by **four programmatic layers** plus prose:

| Layer | Mechanism | File |
|---|---|---|
| 1. Prompt-level contract | This command document (interpreted by the LLM) | `~/.claude/commands/ralph-loop-infinite.md` |
| 2. Memory file contract | `~/.claude/CLAUDE.md` MANDATORY OVERRIDE block (loaded at session start) | `~/.claude/CLAUDE.md` |
| 3. Stop hook (Claude Code) | Detects completion claims without §3 exit report → returns `{"decision":"block"}` → forces continued iteration | `~/.claude/hooks/ralph-loop-infinite-stop.sh` |
| 4. PreToolUse hook (Claude Code) | `permissionDecision: "deny"` for `git push` / `npm publish` / `vercel --prod` / `gh release create` / `terraform apply` / `rsync*production*` while gate active | `~/.claude/hooks/ralph-loop-infinite-pretool.sh` |
| 5. UserPromptSubmit hook (Claude Code) | Injects the full §1–§5 contract via `hookSpecificOutput.additionalContext` before every user prompt while gate active | `~/.claude/hooks/ralph-loop-infinite-prompt.sh` |
| 6. SessionStart hook (Claude Code) | Injects the contract at session boot if gate carried over from prior session | `~/.claude/hooks/ralph-loop-infinite-session.sh` |
| 7. OpenCode parity | `ralph-gate.ts` plugin enforces the same contract via `message.updated` / `tool.execute.before` / `session.stop` | `~/.opencode/plugins/ralph-gate.ts` |

**You cannot skip, bypass, defer, or self-exempt from this loop when it is explicitly invoked.** Layers 3–6 are programmatic and exit-code-binding; the LLM cannot reason past them.

## Gate activation

Activation is automatic: the UserPromptSubmit hook (`~/.claude/hooks/ralph-loop-infinite-prompt.sh`) detects `/ralph-loop-infinite` or equivalent invocation phrases in the user's prompt and writes `~/.opencode/state/ralph-loop-infinite.local` with the current `session_id`. Hooks run unsandboxed with full user permissions, so activation works from every project workspace. A previous revision activated via an inline `!`…` shell snippet from the slash command, but Claude Code's slash-command inline-bash executor ran under a CWD-restricted shell and denied writes to `$HOME/.opencode/` with `operation not permitted` from some project workspaces (e.g. `~/claude/General-Work/jarvis/jarvis-build`). The hook-based activation path is not subject to that restriction.

While this file exists, all enforcement hooks above are armed. A §3 exit report is only a verifier request; it is not an exit. The gate resolves only when `~/.claude/hooks/ralph-loop-infinite-verifier.sh` returns an HMAC-signed PASS verdict, or when the user explicitly invokes `/ralph-loop-infinite-disarm` with a reason. Do not remove the state file manually.

### Git repository requirement — OPTIONAL

`/ralph-loop-infinite` does NOT require a git repository. The git status/branch checks are informative only. The loop functions identically in git and non-git projects. If you are not in a git repo, proceed with the loop normally — do not stop or declare NOT APPLICABLE just because git is unavailable.

## When to Use

- Step 5 of the `/compound-agentic-dev` pipeline
- After production deployment (Step 4) when validating live deliverables
- **Mandatory when explicitly invoked by the user** — every time, without exception
- When the user says "invoke ralph-loop-infinite", "run ralph-loop-infinite", or equivalent
- Mandatory when a production deployment exists in the deliverables map

## Invocation

```
/ralph-loop-infinite
```

Receives the original Step 1 reconstructed system prompt as context. Validates the full traceability chain from raw user prompt to live production deliverable.

## Validation Checklist

ALL items must be TRUE simultaneously to exit the loop.

### Programmatic Correctness

- [ ] All functions, APIs, integrations, and data flows operate as specified in Step 1 §2
- [ ] All unit, integration, and E2E tests pass in the production environment (not just local)
- [ ] Zero server-side exceptions in production logs
- [ ] Zero unhandled promise rejections or uncaught exceptions in browser console
- [ ] All environment variables and secrets are correctly provisioned in production

### Visual Correctness

- [ ] UI/UX matches the quality bar defined in Step 1 §7 — indistinguishable from Fortune 500 tech company equivalent
- [ ] Zero layout breaks at 375px (mobile), 768px (tablet), 1280px (desktop), and 1920px (wide)
- [ ] Zero unstyled or partially-rendered elements
- [ ] Zero broken images, broken icons, or missing assets
- [ ] Zero browser console errors (including network 4xx/5xx)
- [ ] Dark mode renders correctly (if applicable)
- [ ] Animations and transitions are smooth (no jank, no layout shift)
- [ ] WCAG AA colour contrast requirements met for all text

### Requirement Traceability (Full End-to-End)

- [ ] Every requirement from the user's original raw prompt is satisfied in the deployed product
- [ ] Every deduced/derived requirement from Step 1 §2 is satisfied
- [ ] Every Success Criterion from Step 1 §3 passes as binary PASS
- [ ] Every deliverable in Step 1 §6 is present, functional, and accessible via its production URL or path
- [ ] The product is scalable, robust, and accessible to the end user
- [ ] The product functions correctly end-to-end without any missing piece

## Traceability Chain

```
Original User Prompt (raw)
     ↓
Deduced & Derived Requirements + SCs  [Step 1 output]
     ↓
Implementation — all deliverables      [Step 2 output]
     ↓
Tested & verified — all SCs pass       [Step 3 output]
     ↓
Deployed, accessible, usable           [Step 4 output]
     ↓
MATCHES EXACTLY, FULLY & COMPLETELY    [ralph-loop-infinite validates]
```

## Failure Path

If even ONE item in the validation checklist fails:

1. The agent receives the original Step 1 reconstructed system prompt again
2. The agent works through the FULL pipeline (Steps 2 → 3 → 4 → 5) again
3. This repeats until EACH AND EVERY user demand, request, requirement, and Success Criterion is met
4. No partial completion accepted
5. No "good enough" accepted
6. No self-exemption accepted
7. 100% match, or the loop repeats

## Anti-Bypass Provisions

The following behaviors are explicitly PROHIBITED and constitute violations:
- ❌ Skipping the loop with "I'll skip ralph-loop-infinite", "skipping", "not needed"
- ❌ Claiming "NOT APPLICABLE" when the user explicitly invoked the command
- ❌ Claiming "NOT APPLICABLE" because "there's no production deployment" when the user said to run it
- ❌ Claiming the loop "isn't required" when it was explicitly invoked
- ❌ Producing the exit report without real evidence (fabricating numbers)
- ❌ Declaring exit on partial pass
- ❌ Using softening language: "should be working", "appears to pass", "good enough"
- ❌ Terminating the session while unresolved
- ❌ Substituting a finite iteration cap for the infinite loop

**The only valid exit is an HMAC-signed verifier PASS.** A model's own belief that all checklist items are true is not sufficient.

## Execution Protocol

### Iteration Structure

Each iteration executes in this order:

1. **Programmatic validation.** Run all test suites against production. Check logs for exceptions. Verify API responses match specifications.

2. **Visual validation.** Open production URL at all breakpoints (375px, 768px, 1280px, 1920px). Verify rendering, assets, styles, animations. Check browser console for errors.

3. **Traceability audit.** Walk through every requirement in Step 1 §2. For each requirement, verify the corresponding SC from §3 passes. For each deliverable in §6, confirm it is present and accessible.

4. **Decision gate.**
   - IF all checklist items appear TRUE → produce the complete §3 evidence report as a verifier request, then end the turn so the Stop hook can invoke the independent verifier
   - IF the verifier returns HMAC-signed PASS → the gate is resolved
   - IF any item is FALSE, the verifier returns FAIL, verifier output is unsigned, or the verifier is not invoked → identify the failing items, re-enter pipeline from Step 2 with the original Step 1 system prompt, execute Steps 2 → 3 → 4 → 5 again

### No Iteration Cap

This loop has no maximum iteration count. It runs until every checklist item passes. The rationale: if the product does not match what the user asked for, the product is not done. There is no acceptable partial delivery.

### Success Report

When ready for verifier review, produce a structured evidence report:

```markdown
## Production Validation — PASSED

### Programmatic
- Tests: [count] passed, 0 failed
- Server exceptions: 0
- Browser console errors: 0

### Visual
- Breakpoints verified: 375px, 768px, 1280px, 1920px
- Layout breaks: 0
- Missing assets: 0
- WCAG AA: PASS

### Traceability
- Requirements satisfied: [count]/[total] (100%)
- Success criteria passed: [count]/[total] (100%)
- Deliverables verified: [count]/[total] (100%)

### Iterations Required: [N]
```

## Exit Condition

The loop exits ONLY when the independent verifier returns an HMAC-signed PASS verdict. No partial completion. No self-exemption. No user-approval shortcut. No bypass. A terminal/session/IDE/app close only pauses enforcement; persistent state resumes the gate in the next session.
