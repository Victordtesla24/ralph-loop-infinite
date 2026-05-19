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
# CLASSIFICATION: GENERATOR
# Blog role: Generate
# GENERATORs produce output. They do NOT score, do NOT evaluate,
# do NOT self-declare done, and do NOT stop when they think they're finished.
# The GENERATOR stops only when the JUDGE returns HMAC-signed PASS.
#
# Sub-agents in this classification:
#   orchestrator  — drives the loop, decomposes, delegates, collects evidence
#   analyst       — decomposes requirements, maps to success criteria
#   coder         — implements artifacts, produces deliverable output
#   solution-architect — produces technical architecture
#   researcher    — produces research output, findings, analysis
#   senior-sme    — provides domain expertise, validates technical accuracy
#
# GENERATOR policy:
#   - Must carry state forward across iterations (current_output from state)
#   - Must not produce a compressed summary to replace iteration history
#   - Must use targeted remediation prompt (original output + critique + fix)
#   - Cannot declare done — only the JUDGE can stop the loop
#   - Iteration counter is mandatory in every response
