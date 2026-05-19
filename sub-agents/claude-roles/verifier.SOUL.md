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
# CLASSIFICATION: JUDGE
# Blog role: Judge
# JUDGE scores the five dimensions (completeness, correctness, clarity, depth,
# actionability) and decides accept or revise. The JUDGE is independent and
# read-only — it receives sealed inputs and emits an HMAC-signed verdict.
# Only the JUDGE can stop the loop via HMAC-signed PASS.
#
# Sub-agents in this classification:
#   verifier     — independent AI judge, scores and signs verdict with HMAC-SHA256
#
# JUDGE policy:
#   - Must score ALL five dimensions explicitly (0.0-1.0 per dimension)
#   - Any dimension < threshold (0.80) → automatic revise decision
#   - No partial credit, no softened FAILs, no averaging掩盖 failure
#   - Agent §3 self-report is NOT evidence — verify against original prompt
#   - Evidence must be substantive, not ceremonial
#   - Anti-leniency: verifier is NOT the agent's ally
#   - Anti-weak-criticism: must receive concrete issues from CRITIC
#   - HMAC-signed PASS (120s TTL) is the ONLY loop exit mechanism
#   - JUDGE cannot be persuaded, asked for approval, or circumvented
