#!/bin/bash
# End-to-end Ralph loop smoke test: typed GENERATE backend + CRITIQUE/JUDGE + REMEDIATE forced FAIL→PASS in explicit test mode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rli-e2e.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$SBX/.claude/hooks" "$SBX/.claude/state" "$SBX/.claude/secrets" "$SBX/.claude/scripts"
cp "$REPO_ROOT/hooks/"ralph-loop-infinite-*.py "$SBX/.claude/hooks/"
cp "$REPO_ROOT/hooks/ralph-loop-infinite-verifier.sh" "$SBX/.claude/hooks/"
cp "$REPO_ROOT/hooks/ralph-loop-infinite-generator.py" "$SBX/.claude/hooks/"
cp "$REPO_ROOT/scripts/ralph-spawn.sh" "$SBX/.claude/scripts/"
chmod +x "$SBX/.claude/hooks/"* "$SBX/.claude/scripts/ralph-spawn.sh" 2>/dev/null || true
python3 - <<'PY' > "$SBX/.claude/secrets/ralph-hmac.key"
import base64, os
print(base64.b64encode(os.urandom(32)).decode())
PY
chmod 600 "$SBX/.claude/secrets/ralph-hmac.key"
cat > "$SBX/.claude/state/original-user-prompt.txt" <<'TXT'
Implement a tiny artifact and validate it.
TXT
cat > "$SBX/.claude/state/agent-output.txt" <<'TXT'
§3 Production Validation report: generated artifact exists; tests pending.
TXT
cat > "$SBX/.claude/state/ralph-loop-infinite.local" <<TXT
active: true
session_id: e2e
original_user_prompt_path: $SBX/.claude/state/original-user-prompt.txt
TXT

cat > "$SBX/fake-spawn.sh" <<'SH'
#!/bin/bash
set -euo pipefail
role="${1:-unknown}"
task="${2:-}"
python3 - <<'PY' "$role" "$task" "${RALPH_ROLE_EVIDENCE_FILE:-}"
import hashlib, json, pathlib, sys, time
role, task, ev = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(ev)
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps({
  "executor_schema": "fake-spawn.v1",
  "role": role,
  "gcj": {"orchestrator":"GENERATOR","coder":"GENERATOR","tester":"CRITIC"}.get(role,"UNKNOWN"),
  "task_sha256": hashlib.sha256(task.encode()).hexdigest(),
  "validated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}, indent=2) + "\n")
print(f"fake spawn completed role={role} evidence={ev}")
PY
SH
chmod +x "$SBX/fake-spawn.sh"

export HOME="$SBX"
export SESSION_ID=e2e
export AGENT_OUTPUT_FILE="$SBX/.claude/state/agent-output.txt"
export TRANSCRIPT_PATH=""
export RALPH_TEST_MODE=1
export RALPH_GENERATOR_ROLES=orchestrator,coder,tester

python3 "$SBX/.claude/hooks/ralph-loop-infinite-generator.py" \
  --session-id e2e \
  --iteration 1 \
  --original-prompt-file "$SBX/.claude/state/original-user-prompt.txt" \
  --agent-output-file "$SBX/.claude/state/agent-output.txt" \
  --spawn-script "$SBX/fake-spawn.sh" > "$SBX/generator.json"
grep -q '"ok": true' "$SBX/generator.json"
grep -q '"orchestrator"' "$SBX/generator.json"
grep -q '"coder"' "$SBX/generator.json"
grep -q '"tester"' "$SBX/generator.json"
test -s "$SBX/.claude/state/ralph-generator-artifacts/e2e-iter1-orchestrator.json"
test -s "$SBX/.claude/state/ralph-generator-artifacts/e2e-iter1-coder.json"
test -s "$SBX/.claude/state/ralph-generator-artifacts/e2e-iter1-tester.json"

# Force flags are fenced: without RALPH_TEST_MODE they must not force a PASS.
RALPH_TEST_MODE=0 ITERATION=1 RALPH_VERIFIER_FORCE_PASS=1 "$SBX/.claude/hooks/ralph-loop-infinite-verifier.sh" > "$SBX/no-force-pass.json"
if grep -q '"model":"forced-e2e"' "$SBX/no-force-pass.json"; then
  echo "force-pass escaped test-mode fence" >&2
  exit 1
fi

ITERATION=1 RALPH_TEST_MODE=1 RALPH_VERIFIER_FORCE_FAIL=1 "$SBX/.claude/hooks/ralph-loop-infinite-verifier.sh" > "$SBX/fail.json"
grep -q '"verdict":"FAIL"' "$SBX/fail.json"
test -s "$SBX/.claude/state/ralph-remediation-prompt.iter-1.txt"

ITERATION=2 RALPH_TEST_MODE=1 RALPH_VERIFIER_FORCE_FAIL=0 RALPH_VERIFIER_FORCE_PASS=1 "$SBX/.claude/hooks/ralph-loop-infinite-verifier.sh" > "$SBX/pass.json"
grep -q '"verdict":"PASS"' "$SBX/pass.json"
grep -q '"hmac":"' "$SBX/pass.json"
test -s "$SBX/.claude/state/ralph-verifier.jsonl"

python3 - <<'PY' "$SBX/pass.json" "$SBX/.claude/state/ralph-verifier.jsonl" "$SBX/generator.json"
import json, pathlib, sys
p=json.loads(pathlib.Path(sys.argv[1]).read_text())
rows=[json.loads(x) for x in pathlib.Path(sys.argv[2]).read_text().splitlines() if x.strip()]
g=json.loads(pathlib.Path(sys.argv[3]).read_text())
assert p['verdict']=='PASS' and p.get('hmac')
assert any(r.get('verdict')=='PASS' and r.get('hmac') for r in rows)
assert g['ok'] is True and set(g['required_roles']) == {'orchestrator','coder','tester'}
assert len(g['artifacts']) == 3
print('{"status":"PASS","typed_generator":true,"fail_then_pass":true,"remediation_file":true,"pass_store_row":true,"force_flags_fenced":true}')
PY
