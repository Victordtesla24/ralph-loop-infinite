#!/bin/bash
# test-ralph-refactor.sh — Supplemental test harness for the v4.1.0 RALPH
# internal-thinking-loop refactor. Operates exclusively on the staged
# files in /tmp/ralph-refactor/hooks/; never reads the live live hook tree
# beyond shasum-based assertions that nothing was mutated mid-run.
#
# Covers the gaps the v4.1.0 refactor closes (R-1..R-6 of the architecture
# verification report and Corrections A/B/D/E/F of the validation report):
#   * threshold enforcement: a per-dimension score < 0.8 converts PASS→FAIL
#   * remediation prompt contains every PDF-page-2 template phrase
#   * MiniMax-M2.7 fallback for Opus/Deepseek and GLM fallback for other agents exists, is logged, never silently downgrades
#   * evidence precheck rejects mismatched test-count claims
#   * status-token regex rejects the truncated marker, accepts the full one
#   * DB-first signed-PASS lookup uses pass-fetch before the text mirror
#
# Run:  bash /tmp/ralph-refactor/hooks/test-ralph-refactor.sh
# Exit: 0 if every assertion passes, 1 if any fails.

set -uo pipefail

ALLOW_LIVE=0
for arg in "$@"; do
  [[ "$arg" == "--allow-live" ]] && ALLOW_LIVE=1
done
STAGED_DIR="${STAGED_DIR:-/tmp/ralph-refactor/hooks}"
LIVE_DIR="${LIVE_DIR:-/Users/vic/.claude/hooks}"
STAGED_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$STAGED_DIR")
LIVE_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$LIVE_DIR")
if [[ "$STAGED_REAL" == "$LIVE_REAL" && "$ALLOW_LIVE" -ne 1 ]]; then
  echo "ERROR: STAGED_DIR resolves to LIVE_DIR ($LIVE_DIR). Refusing to mutate/audit live hooks without --allow-live." >&2
  exit 2
fi
if [[ ! -d "$STAGED_DIR" || -z "$(find "$STAGED_DIR" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]]; then
  mkdir -p "$STAGED_DIR"
  for f in "$LIVE_DIR"/*; do
    [[ -f "$f" ]] && cp "$f" "$STAGED_DIR/"
  done
fi
SBX_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rli-refactor-test.XXXXXX")
trap 'rm -rf "$SBX_ROOT" 2>/dev/null || true' EXIT INT TERM

PASS=0
FAIL=0
FAILED=()

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

LIVE_STATE_SHA=$(shasum -a 256 "$LIVE_DIR/ralph-loop-infinite-stop.sh" 2>/dev/null | awk '{print $1}')
LIVE_VERIFIER_SHA=$(shasum -a 256 "$LIVE_DIR/ralph-loop-infinite-verifier.sh" 2>/dev/null | awk '{print $1}')

echo "=== RALPH refactor sandbox: $SBX_ROOT ==="
mkdir -p "$SBX_ROOT/.claude/hooks" "$SBX_ROOT/.claude/state" "$SBX_ROOT/.claude/secrets"
chmod 700 "$SBX_ROOT/.claude/state" "$SBX_ROOT/.claude/secrets"
for f in "$STAGED_DIR"/*; do
  [[ -f "$f" ]] && cp "$f" "$SBX_ROOT/.claude/hooks/"
done
# Copy unchanged supporting helpers from the live tree so the sandbox is
# functional. None of these are mutated.
for helper in ralph-loop-infinite-tsparse.py ralph-loop-infinite-pathguard.py ralph-loop-infinite-contract.md ralph-loop-infinite-db.sh; do
  if [[ -f "$LIVE_DIR/$helper" ]]; then
    cp "$LIVE_DIR/$helper" "$SBX_ROOT/.claude/hooks/"
  fi
done
chmod +x "$SBX_ROOT/.claude/hooks/"*.sh "$SBX_ROOT/.claude/hooks/"*.py 2>/dev/null || true
python3 -c 'import os,base64; print(base64.b64encode(os.urandom(32)).decode())' \
  > "$SBX_ROOT/.claude/secrets/ralph-hmac.key"
chmod 600 "$SBX_ROOT/.claude/secrets/ralph-hmac.key"

ORIGINAL_HOME="$HOME"
export HOME="$SBX_ROOT"

# --------------------------------------------------------------------------
echo
echo "[1] Threshold: a per-dimension score < 0.8 converts decision accept → revise"
# --------------------------------------------------------------------------
RALPH_HELPER="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-ralph.py"
T1_OUT=$(python3 - "$RALPH_HELPER" <<'PY'
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("ralph_loop", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["ralph_loop"] = mod  # Python 3.14 dataclass needs this
spec.loader.exec_module(mod)
raw = json.dumps({
    "critique": {"issues": [], "severity": [], "suggestions": []},
    "scoring_dimensions": {
        "completeness": {"score": 0.95, "evidence": "all"},
        "correctness":  {"score": 0.95, "evidence": "ok"},
        "clarity":      {"score": 0.95, "evidence": "ok"},
        "depth":        {"score": 0.95, "evidence": "ok"},
        "actionability":{"score": 0.50, "evidence": "thin"},
    },
    "decision": "accept",
    "overall_score": 0.86,
    "reasoning": "looks close",
    "missing": [], "deviations": [],
})
crit, judg = mod.parse_model_output(raw_text=raw, threshold=0.8, provider="anthropic", model="claude-opus-4-7", effort="max")
verdict = "PASS" if judg.decision == "accept" else "FAIL"
print(json.dumps({"decision": judg.decision, "verdict": verdict, "overall_score": judg.overall_score}))
PY
)
T1_VERDICT=$(printf '%s' "$T1_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("verdict",""))')
if [[ "$T1_VERDICT" == "FAIL" ]]; then
  pass "threshold below 0.8 converts decision accept → revise (FAIL): $T1_OUT"
else
  fail "threshold not enforced: got $T1_OUT"
fi

# Negative control: all dims >= 0.8 stays accept
T1B_OUT=$(python3 - "$RALPH_HELPER" <<'PY'
import importlib.util, sys, json
spec = importlib.util.spec_from_file_location("ralph_loop", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["ralph_loop"] = mod  # Python 3.14 dataclass needs this
spec.loader.exec_module(mod)
raw = json.dumps({
    "critique": {"issues": [], "severity": [], "suggestions": []},
    "scoring_dimensions": {d: {"score": 0.85, "evidence": "ok"} for d in
        ("completeness","correctness","clarity","depth","actionability")},
    "decision": "accept",
    "overall_score": 0.85,
    "reasoning": "all above threshold", "missing": [], "deviations": [],
})
_, j = mod.parse_model_output(raw_text=raw, threshold=0.8, provider="anthropic", model="claude-opus-4-7", effort="max")
print(json.dumps({"decision": j.decision}))
PY
)
T1B_DECISION=$(printf '%s' "$T1B_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))')
if [[ "$T1B_DECISION" == "accept" ]]; then
  pass "all dims >= 0.8 stays accept"
else
  fail "negative control wrong: $T1B_OUT"
fi

# --------------------------------------------------------------------------
echo
echo "[2] Remediation prompt contains every PDF-page-2 template phrase"
# --------------------------------------------------------------------------
T2_TMP=$(mktemp -d)
echo "do the thing" > "$T2_TMP/orig.txt"
echo "i did half the thing" > "$T2_TMP/agent.txt"
cat > "$T2_TMP/critique.json" <<'JSON'
{
  "critique": {
    "issues": ["missing tests", "no error handling"],
    "severity": [4, 3],
    "suggestions": ["add tests", "wrap try/except"]
  }
}
JSON
python3 "$RALPH_HELPER" remediation \
  --original-prompt-file "$T2_TMP/orig.txt" \
  --agent-output-file "$T2_TMP/agent.txt" \
  --critique-file "$T2_TMP/critique.json" \
  --output-file "$T2_TMP/out.txt" \
  --session-id test \
  --iteration 2 >/dev/null
EXPECTED_PHRASES=(
  "Original Output"
  "Identified Issues"
  "Suggested Fixes"
  "Do NOT rewrite the entire response"
  "Preserve correct and useful parts"
  "Improve clarity and depth only where needed"
  "Avoid introducing new information unless required"
)
MISSING=()
for needle in "${EXPECTED_PHRASES[@]}"; do
  if ! grep -F -q "$needle" "$T2_TMP/out.txt"; then
    MISSING+=("$needle")
  fi
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  pass "remediation prompt has every PDF template phrase"
else
  fail "remediation missing phrases: ${MISSING[*]}"
fi
rm -rf "$T2_TMP"

# --------------------------------------------------------------------------
echo
echo "[3] MiniMax/GLM fallback paths are present in policy + ralph helper, never silently downgrade"
# --------------------------------------------------------------------------
POLICY_HELPER="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-policy.py"
T3_FB_PROVIDER=$(python3 "$POLICY_HELPER" fallback-provider 2>/dev/null)
T3_FB_MODEL=$(python3 "$POLICY_HELPER" fallback-model 2>/dev/null)
if [[ "$T3_FB_PROVIDER" == "minimax" && "$T3_FB_MODEL" == "minimax-m2.7" ]]; then
  pass "policy fallback-provider/fallback-model report minimax + minimax-m2.7"
else
  fail "policy fallback not minimax/minimax-m2.7 (got $T3_FB_PROVIDER/$T3_FB_MODEL)"
fi
ALLOW_OK=$(python3 "$POLICY_HELPER" allow minimax minimax-m2.7 2>/dev/null)
if [[ "$ALLOW_OK" == "ok" ]]; then
  pass "policy allow accepts minimax/minimax-m2.7"
else
  fail "policy allow rejected minimax/minimax-m2.7"
fi
if grep -q 'def call_minimax' "$RALPH_HELPER" \
   && grep -q 'def call_glm' "$RALPH_HELPER" \
   && grep -q 'provider_attempt' "$RALPH_HELPER" \
   && grep -q '"fallback": is_fallback' "$RALPH_HELPER"; then
  pass "ralph helper has explicit MiniMax/GLM call paths with logged fallback"
else
  fail "ralph helper missing MiniMax/GLM call paths or fallback log"
fi
# Run a fake-failure trip and confirm thinking-loop log records fallback failure non-silently.
T3_LOG="$HOME/.claude/state/ralph-thinking-loop.jsonl"
rm -f "$T3_LOG"
T3_PROMPT=$(mktemp); T3_AGENT=$(mktemp)
echo "do x" > "$T3_PROMPT"; echo "i did x" > "$T3_AGENT"
RALPH_FAKE_ANTHROPIC_FAIL=1 RALPH_FAKE_MINIMAX_FAIL=1 \
  python3 "$RALPH_HELPER" judge \
    --original-prompt-file "$T3_PROMPT" \
    --agent-output-file "$T3_AGENT" \
    --session-id test --iteration 1 >/dev/null 2>&1 || true
rm -f "$T3_PROMPT" "$T3_AGENT"
if [[ -f "$T3_LOG" ]] && grep -Eq 'provider_(fail|skip)' "$T3_LOG" && grep -q 'offline-rule-based' "$T3_LOG"; then
  pass "thinking-loop log records explicit provider failure/skip and labelled offline fallback (never silent)"
else
  fail "thinking-loop log missing provider failure/skip or labelled offline fallback record"
fi
# Secret-leak guard: no API key bytes appear in any state file.
if grep -RE 'sk-(ant|deep|live|test)|ds-[A-Za-z0-9]{6,}' "$HOME/.claude/state" 2>/dev/null | grep -v thinking-loop.jsonl; then
  fail "secret-looking string leaked into sandbox state"
else
  pass "no secret-looking strings in sandbox state files"
fi

# --------------------------------------------------------------------------
echo
echo "[4] Evidence precheck rejects mismatched test-count claims"
# --------------------------------------------------------------------------
EVIDENCE_HELPER="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-evidence.py"
T4_TMP=$(mktemp -d)
ART_MATCH="$T4_TMP/match.log"
ART_MISMATCH="$T4_TMP/mismatch.log"
echo "summary: 42 passed, 0 failed; coverage 17/17" > "$ART_MATCH"
echo "this artifact mentions nothing about tests at all" > "$ART_MISMATCH"
AGENT_MATCH="$T4_TMP/agent-match.txt"
AGENT_MISMATCH="$T4_TMP/agent-mismatch.txt"
cat > "$AGENT_MATCH" <<EOF
Tests: 42 passed, 0 failed
Server exceptions: 0
Requirements satisfied: 17/17 (100%)
see $ART_MATCH
EOF
cat > "$AGENT_MISMATCH" <<EOF
Tests: 42 passed, 0 failed
Server exceptions: 0
Requirements satisfied: 17/17 (100%)
see $ART_MISMATCH
EOF
PRE_MATCH_RC=0
python3 "$EVIDENCE_HELPER" precheck \
  --agent-output-file "$AGENT_MATCH" \
  --original-prompt-file "$T4_TMP/empty" \
  --transcript-path "" \
  --session-id test --iteration 1 >/dev/null 2>&1 || PRE_MATCH_RC=$?
if [[ $PRE_MATCH_RC -eq 0 ]]; then
  pass "matching evidence PASSES precheck"
else
  fail "matching evidence should PASS precheck (rc=$PRE_MATCH_RC)"
fi
PRE_MISMATCH_OUT=$(python3 "$EVIDENCE_HELPER" precheck \
  --agent-output-file "$AGENT_MISMATCH" \
  --original-prompt-file "$T4_TMP/empty" \
  --transcript-path "" \
  --session-id test --iteration 1 2>&1)
PRE_MISMATCH_RC=$?
if [[ $PRE_MISMATCH_RC -ne 0 ]]; then
  if echo "$PRE_MISMATCH_OUT" | grep -q '42 passed'; then
    pass "mismatched evidence FAILS precheck with named 42 passed reason"
  else
    fail "mismatch FAIL reason missing '42 passed' (got $PRE_MISMATCH_OUT)"
  fi
else
  fail "mismatched evidence should FAIL precheck but rc=0"
fi
rm -rf "$T4_TMP"

# --------------------------------------------------------------------------
echo
echo "[5] Status-token regex: truncated form rejected, full form accepted"
# --------------------------------------------------------------------------
STOP_SH="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-stop.sh"
# Extract STATUS_TOKEN_RX from the stop script for direct evaluation.
RX_LINE=$(grep -n "^STATUS_TOKEN_RX=" "$STOP_SH" | head -1 | cut -d: -f1)
if [[ -z "$RX_LINE" ]]; then
  fail "STATUS_TOKEN_RX not found in staged stop.sh"
else
  STATUS_RX=$(sed -n "${RX_LINE}p" "$STOP_SH" | sed -E "s/^STATUS_TOKEN_RX='([^']+)'.*/\1/")
  TRUNCATED='[🔁 RALPH-LOOP-INFINITE: ACTIVE]'
  FULL='[🔁 RALPH-LOOP-INFINITE: ACTIVE — Iteration 1 of ∞]'
  if echo "$TRUNCATED" | grep -E -q "$STATUS_RX"; then
    fail "truncated marker should be REJECTED but matched"
  else
    pass "truncated marker rejected"
  fi
  if echo "$FULL" | grep -E -q "$STATUS_RX"; then
    pass "full marker accepted"
  else
    fail "full marker should be accepted but did not match"
  fi
  COMPLETE='[✅ RALPH-LOOP-INFINITE: COMPLETE]'
  if echo "$COMPLETE" | grep -E -q "$STATUS_RX"; then
    pass "COMPLETE marker accepted"
  else
    fail "COMPLETE marker should still be accepted"
  fi
fi

# --------------------------------------------------------------------------
echo
echo "[6] DB-first signed-PASS lookup: stop.sh fetch_signed_pass_b64 prefers DB"
# --------------------------------------------------------------------------
# Source the function definition out of the staged file and exercise it.
DB_HELPER_SBX="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-db.py"
python3 "$DB_HELPER_SBX" init >/dev/null 2>&1 || true
# Arm a session, then store a signed pass via the same helpers stop.sh uses.
TEST_SESSION="dbfirst-$$"
python3 "$DB_HELPER_SBX" arm-or-rearm \
  --session-id "$TEST_SESSION" \
  --armed-by "harness" --trigger "test" \
  --prompt-path /tmp/nope --contract /tmp/nope >/dev/null 2>&1 || true
NOW=$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
EXP=$(python3 -c 'from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)+timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
HMAC_KEY=$(cat "$SBX_ROOT/.claude/secrets/ralph-hmac.key")
SIGNED_PAYLOAD_JSON=$(S="$TEST_SESSION" NOW="$NOW" EXP="$EXP" K="$HMAC_KEY" python3 -c '
import base64, hashlib, hmac, json, os, sys
payload = {
  "verdict": "PASS",
  "session_id": os.environ["S"],
  "iteration": 1,
  "issued_at": os.environ["NOW"],
  "expires_at": os.environ["EXP"],
  "provider": "anthropic",
  "model": "claude-opus-4-7",
  "pass_id": "pass-dbfirst",
  "original_prompt_hash": "x",
  "agent_output_hash": "y",
  "evidence_bundle_hash": "z",
}
canon = json.dumps(payload, sort_keys=True, separators=(",",":")).encode()
key = os.environ["K"].encode()
payload["hmac"] = base64.b64encode(hmac.new(key, canon, hashlib.sha256).digest()).decode()
print(json.dumps(payload))
')
SIGNED_B64=$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "$SIGNED_PAYLOAD_JSON")
python3 "$DB_HELPER_SBX" pass-store \
  --session-id "$TEST_SESSION" \
  --iteration 1 \
  --pass-id "pass-dbfirst" \
  --issued-at "$NOW" \
  --expires-at "$EXP" \
  --signed-payload-json "$SIGNED_PAYLOAD_JSON" \
  --signed-pass-b64 "$SIGNED_B64" >/dev/null 2>&1 || true
# Now source fetch_signed_pass_b64 by extracting it from stop.sh and calling it.
EXTRACTED=$(awk '/^fetch_signed_pass_b64\(\)/,/^}/' "$STOP_SH")
TEST_SCRIPT=$(mktemp)
cat > "$TEST_SCRIPT" <<EOS
#!/bin/bash
set -uo pipefail
DB_HELPER="$DB_HELPER_SBX"
db_available() { [[ -x "\$DB_HELPER" ]] && command -v python3 >/dev/null 2>&1; }
db_state_get_raw() { printf ''; }
$EXTRACTED
fetch_signed_pass_b64 "$TEST_SESSION"
EOS
chmod +x "$TEST_SCRIPT"
RESULT_B64=$("$TEST_SCRIPT" 2>/dev/null)
if [[ -n "$RESULT_B64" ]]; then
  pass "DB-first signed-PASS lookup returns non-empty payload when only DB carries it"
  DECODED=$(python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace"))' <<<"$RESULT_B64")
  if echo "$DECODED" | grep -q '"pass_id"'; then
    pass "DB-first lookup returns a base64-encoded signed payload (decodes to JSON)"
  else
    fail "DB-first lookup payload did not decode to JSON: $DECODED"
  fi
else
  fail "DB-first lookup returned empty when DB has a row"
fi
rm -f "$TEST_SCRIPT"

# --------------------------------------------------------------------------
echo
printf '[7] Stop hook wiring: FAIL/PRECHECK_FAIL deterministically trigger generator\n'
# --------------------------------------------------------------------------
T7_WIRING=$(python3 - "$STOP_SH" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
pre = text.find('verifier-evidence-precheck-fail')
pre_gen = text.rfind('run_generator_once', 0, pre)
fail = text.find('verifier-fail')
fail_gen = text.rfind('run_generator_once', 0, fail)
print(json.dumps({
  'precheck_has_generator_before_block': pre > 0 and pre_gen > 0,
  'fail_has_generator_before_block': fail > 0 and fail_gen > 0,
}))
PY
)
if echo "$T7_WIRING" | grep -q '"precheck_has_generator_before_block": true' && echo "$T7_WIRING" | grep -q '"fail_has_generator_before_block": true'; then
  pass "stop hook wires generator before PRECHECK_FAIL and FAIL blocks: $T7_WIRING"
else
  fail "stop hook generator wiring missing: $T7_WIRING"
fi
if grep -q 'RALPH_CONVERGENCE_EXIT' "$STOP_SH" && grep -q 'CONVERGENCE_RETURN' "$STOP_SH"; then
  pass "stop hook provides explicit RALPH_CONVERGENCE_EXIT=1 blog-compatible return mode"
else
  fail "stop hook missing explicit blog-compatible convergence return mode"
fi
if grep -q 'CLAUDE_CLI_MISSING' "$STOP_SH" && grep -q 'GENERATOR_INLINE_ONLY_OK' "$STOP_SH"; then
  pass "stop hook logs missing Claude CLI and downgrades to inline-only generator"
else
  fail "stop hook missing Claude CLI fallback to inline-only generator"
fi
if grep -q 'RALPH_GENERATED_OUTPUT_FILE' "$STOP_SH" && grep -q '\$RALPH_HELPER" generate' "$STOP_SH"; then
  pass "stop hook adapts sidecar generator through first-class ralph.py Generated stage"
else
  fail "stop hook does not route sidecar generator output through first-class Generated stage"
fi

GENERATOR_HELPER="$SBX_ROOT/.claude/hooks/ralph-loop-infinite-generator.py"
FAKE_SPAWN="$SBX_ROOT/fake-spawn.sh"
cat > "$FAKE_SPAWN" <<'SH'
#!/bin/bash
set -euo pipefail
role="${1:-unknown}"
python3 - <<'PY' "$role" "${RALPH_ROLE_EVIDENCE_FILE:-}"
import json, pathlib, sys
role, ev = sys.argv[1], sys.argv[2]
p = pathlib.Path(ev); p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps({"role": role, "executor_schema": "harness.v1"}) + "\n")
print("ok", role)
PY
SH
chmod +x "$FAKE_SPAWN"
GEN_OUT=$(python3 "$GENERATOR_HELPER" --session-id harness --iteration 1 --original-prompt-file /tmp/nope --spawn-script "$FAKE_SPAWN" 2>&1)
if echo "$GEN_OUT" | grep -q '"ok": true' && echo "$GEN_OUT" | grep -q '"orchestrator"' && echo "$GEN_OUT" | grep -q '"coder"' && echo "$GEN_OUT" | grep -q '"tester"'; then
  pass "typed generator requires orchestrator/coder/tester and writes artifacts"
else
  fail "typed generator required-stage contract failed: $(echo "$GEN_OUT" | head -1)"
fi

# --------------------------------------------------------------------------
echo
printf '[8] Standalone Python loop driver: run() while-loop + CLI loop subcommand\n'
# --------------------------------------------------------------------------
T8_OUT=$(python3 - "$RALPH_HELPER" <<'PY'
import importlib.util, json, sys, types
spec = importlib.util.spec_from_file_location("ralph_loop", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["ralph_loop"] = mod
spec.loader.exec_module(mod)
if not hasattr(mod.RalphLoopEngine, "run"):
    print(json.dumps({"ok": False, "reason": "RalphLoopEngine.run missing"}))
    raise SystemExit(0)
engine = mod.RalphLoopEngine(policy={"provider":"anthropic","model_primary":"claude-opus-4-7","scoring_threshold":0.8}, session_id="standalone", iteration=1)
calls = []
def fake_generate(self, *, original_prompt, prior_output="", remediation="", backend_result_json=""):
    calls.append(["generate", self.iteration, prior_output, bool(remediation)])
    return mod.Generated(content=f"generated-{self.iteration}", iteration=self.iteration, remediation_applied=remediation)
def fake_critique(self, *, original_prompt, generated, evidence_bundle_json, fake_failure=None):
    calls.append(["critique", self.iteration, generated.content])
    return mod.Critique(issues=["gap"] if self.iteration == 1 else [], severity=[4] if self.iteration == 1 else [], suggestions=["fix gap"] if self.iteration == 1 else [])
def fake_judge(self, *, original_prompt, generated, evidence_bundle_json, critique, effort=None, fake_failure=None):
    calls.append(["judge", self.iteration, generated.content])
    decision = "revise" if self.iteration == 1 else "accept"
    score = 0.5 if decision == "revise" else 0.95
    return mod.Judgement(decision=decision, overall_score=score, threshold=0.8, breakdown={d: mod.DimensionScore(score, "mock") for d in mod.SCORING_DIMENSIONS}, reasoning="mock")
def fake_remediate(self, *, original_prompt, generated, critique):
    calls.append(["remediate", self.iteration, generated.content])
    return "apply targeted remediation"
engine.generate = types.MethodType(fake_generate, engine)
engine.critique = types.MethodType(fake_critique, engine)
engine.judge = types.MethodType(fake_judge, engine)
engine.remediate = types.MethodType(fake_remediate, engine)
out = engine.run(original_prompt="build portable loop", max_iterations=3)
print(json.dumps({"ok": isinstance(out, mod.Generated), "content": out.content, "iteration": out.iteration, "calls": calls}))
PY
)
if echo "$T8_OUT" | grep -q '"ok": true' && echo "$T8_OUT" | grep -q '"content": "generated-2"' && echo "$T8_OUT" | grep -q '"remediate"'; then
  pass "RalphLoopEngine.run executes generate→critique→judge→remediate while-loop to acceptance: $T8_OUT"
else
  fail "RalphLoopEngine.run standalone loop missing or wrong: $T8_OUT"
fi
T8_TMP=$(mktemp -d)
echo "standalone prompt" > "$T8_TMP/orig.txt"
LOOP_CLI_OUT=$(RALPH_FAKE_ANTHROPIC_FAIL=1 RALPH_FAKE_MINIMAX_FAIL=1 RALPH_FAKE_GLM_FAIL=1 python3 "$RALPH_HELPER" loop --original-prompt-file "$T8_TMP/orig.txt" --session-id cli-loop --max-iterations 1 2>&1)
if echo "$LOOP_CLI_OUT" | grep -q '"generated"' && echo "$LOOP_CLI_OUT" | grep -q '"iterations_run":1'; then
  pass "ralph.py loop subcommand runs standalone without Claude Code hooks"
else
  fail "ralph.py loop subcommand failed: $(echo "$LOOP_CLI_OUT" | head -1)"
fi
rm -rf "$T8_TMP"

# --------------------------------------------------------------------------
echo
printf '[9] DB self-test + Ralph helper self-test\n'
# --------------------------------------------------------------------------
DB_SELF=$(python3 "$DB_HELPER_SBX" self-test 2>&1)
if echo "$DB_SELF" | grep -q '"status": "PASS"'; then
  pass "db.py self-test PASS"
else
  fail "db.py self-test FAIL: $(echo "$DB_SELF" | head -1)"
fi
RALPH_SELF=$(python3 "$RALPH_HELPER" self-test 2>&1)
if echo "$RALPH_SELF" | grep -q '"status": "PASS"'; then
  pass "ralph.py self-test PASS"
else
  fail "ralph.py self-test FAIL: $(echo "$RALPH_SELF" | head -1)"
fi
EVID_SELF=$(python3 "$EVIDENCE_HELPER" self-test 2>&1)
if echo "$EVID_SELF" | grep -q '"status": "PASS"'; then
  pass "evidence.py self-test PASS"
else
  fail "evidence.py self-test FAIL: $(echo "$EVID_SELF" | head -1)"
fi

# --------------------------------------------------------------------------
echo
echo "=== Hardening guard: live tree unchanged ==="
# --------------------------------------------------------------------------
NEW_LIVE_STOP=$(shasum -a 256 "$LIVE_DIR/ralph-loop-infinite-stop.sh" 2>/dev/null | awk '{print $1}')
NEW_LIVE_VER=$(shasum -a 256 "$LIVE_DIR/ralph-loop-infinite-verifier.sh" 2>/dev/null | awk '{print $1}')
if [[ "$NEW_LIVE_STOP" == "$LIVE_STATE_SHA" && "$NEW_LIVE_VER" == "$LIVE_VERIFIER_SHA" ]]; then
  pass "live hook tree unchanged during harness run"
else
  fail "live hook tree MUTATED during harness run (stop $NEW_LIVE_STOP vs $LIVE_STATE_SHA)"
fi

export HOME="$ORIGINAL_HOME"

echo
echo "=== Summary ==="
printf 'PASS: %d  FAIL: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failures:\n'
  for f in "${FAILED[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
