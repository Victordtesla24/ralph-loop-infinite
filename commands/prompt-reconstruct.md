---
name: prompt-reconstruct
description: Reconstruct raw prompts into precise, execution-ready system prompts with requirements, success criteria, and validation.
argument-hint: "<raw user prompt>"
model-invocation: enabled
---

Use this command to transform a raw user ask into a deterministic execution specification.

Installed skill reference:

- `~/.claude/skills/prompt-reconstruct/SKILL.md`

Invocation:

```text
/prompt-reconstruct <raw user prompt>
```

Return format:

1. Reconstructed system prompt
2. Requirements map (explicit + deduced)
3. Success criteria (binary)
4. Deliverables map
5. Validation checklist
6. Open assumptions and risks
