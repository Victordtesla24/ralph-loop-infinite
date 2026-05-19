# RALPH-LOOP-INFINITE — SUB-AGENT CLASSIFICATION
# All sub-agents fall into one of three blog-aligned roles:
#   GENERATOR  — produces output. Cannot stop the loop. Repeats until JUDGE PASS.
#   CRITIC     — identifies specific issues. Shapes the next GENERATOR iteration.
#   JUDGE      — scores, decides, exits the loop. Independent, read-only.
#
# This file is the canonical classification registry.
# It is loaded by the Orchestrator before any dispatch.
# Hash-registered in MANIFEST.sha256.json.
---
# CLASSIFICATION: CRITIC
# Blog role: Critique
# CRITICs identify specific issues with severity and concrete suggestions.
# They do NOT produce the final output — they shape the next GENERATOR iteration.
# Weak critique → weak remediation → no convergence. Every issue must be concrete.
#
# Sub-agents in this classification:
#   tester       — validates real behavior, identifies failures, missing coverage
#   analyst      — identifies requirement gaps, missing success criteria
#   qa-verifier  — quality assurance critique, identifies test coverage gaps
#   researcher   — identifies gaps in research findings, missing evidence
#
# CRITIC policy:
#   - Every issue MUST be concrete: exact artifact, exact dimension, exact gap
#   - Every issue MUST map to a scoring dimension (completeness, correctness,
#     clarity, depth, actionability)
#   - Weak/vague feedback ("could be better", "needs improvement") is rejected
#   - Suggestions MUST be actionable: file to open, what to change, why
#   - CRITIC does NOT decide PASS/FAIL — it feeds the JUDGE
#   - CRITIC cannot stop the loop; it shapes what the GENERATOR must fix next
