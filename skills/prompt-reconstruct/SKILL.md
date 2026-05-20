---
name: prompt-reconstruct
description: Reconstruct any user prompt into a precise, execution-ready system prompt with explicit requirements, success criteria, constraints, traceability, and validation plan.
category: prompt-engineering
trigger: /prompt-reconstruct
---

# Prompt-Reconstruct Skill

## Goal

Convert ambiguous prompts into deterministic execution specs so if the user asks `X`, the working agent reliably delivers `X`.

## Output Contract

Every run produces:

1. Reconstructed system prompt
2. Requirement map (explicit + deduced)
3. Success criteria (binary pass/fail)
4. Deliverables map
5. Validation plan
6. Risk/ambiguity log

## Rules

- Preserve user intent exactly
- No scope drift and no silent substitutions
- Mark unknowns explicitly as assumptions
- Use measurable language and verifiable checks
- Keep implementation constraints explicit

## Invocation

```text
/prompt-reconstruct <raw user prompt>
```

## Example

```text
/prompt-reconstruct Build an AI code review bot that catches security issues before merge.
```

Expected outcome: a structured, production-ready prompt package that downstream implementation agents can execute with minimal interpretation error.
