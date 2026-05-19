---
name: ralph-config
description: "Configure Ralph-Loop-Infinite parameters — scoring threshold, max iterations, models, provider chain, convergence, anti-criticism rules. Run `ralph-config list` to see all options."
argument-hint: "<get|set|list|defaults|show> [key] [value]"
model-invocation: enabled
---

## Ralph-Loop-Infinite Configuration Tool

View or change loop dynamics, parameters, thresholds, and scoping.
Safe — only modifies the policy block in `settings.json`. Does NOT touch hooks or HMAC key.

### Quick Reference

| Parameter | Default | What it does |
|---|---|---|
| `scoring_threshold` | 0.80 | Min score per dimension for PASS |
| `max_iterations` | 3 | Hard cap before blocker |
| `pass_ttl_seconds` | 120 | How long PASS remains valid |
| `primary_model` | claude-opus-4-7 | Primary verifier model |
| `fallback_model` | minimax-m2.7 | Fallback model |
| `anti_weak_criticism` | true | Force concrete critique issues |
| `anti_leniency` | true | Strict scoring, no partial credit |
| `convergence_escalation` | true | Convergence → escalation not exit |
| `generator_infinite` | true | GENERATOR cannot self-declare done |

### Commands

```
/ralph-config list                   Show current configuration
/ralph-config get scoring_threshold  Get one parameter
/ralph-config set scoring_threshold 0.85  Set one parameter
/ralph-config show                  Show full active policy
/ralph-config defaults              Show all defaults
```

### Example: Increase threshold to 0.85

```
/ralph-config set scoring_threshold 0.85
```

### Example: Increase max iterations to 5

```
/ralph-config set max_iterations 5
```

### Example: Switch to deepseek fallback

```
/ralph-config set fallback_model deepseek-v4-pro
```