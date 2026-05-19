#!/bin/bash
# End-to-end Ralph loop smoke test: GENERATE→CRITIQUE→JUDGE→REMEDIATE forced FAIL→PASS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rli-e2e.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT INT TERM
mkdir -p "$SBX/.claude/hooks" "$SBX/.claude/state" "$SBX/.claude/secrets" "$SBX/.claude/scripts"
cp "$REPO_ROOT/hooks/"ralph-loop-infinite-*.py "$SBX/.claude/hooks/"
cp "$REPO_ROOT/hooks/ralph-loop-infinite-verifier.sh" "$SBX/.claude/hooks/"
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

export HOME="$SBX"
export SESSION_ID=e2e
export AGENT_OUTPUT_FILE="$SBX/.claude/state/agent-output.txt"
export TRANSCRIPT_PATH=""
export RALPH_GENERATOR_DRY_RUN=1
export RALPH_GENERATOR_DISABLE=1

ITERATION=1 RALPH_VERIFIER_FORCE_FAIL=1 "$SBX/.claude/hooks/ralph-loop-infinite-verifier.sh" > "$SBX/fail.json"
grep -q '"verdict":"FAIL"' "$SBX/fail.json"
test -s "$SBX/.claude/state/ralph-remediation-prompt.iter-1.txt"

ITERATION=2 RALPH_VERIFIER_FORCE_FAIL=0 RALPH_VERIFIER_FORCE_PASS=1 "$SBX/.claude/hooks/ralph-loop-infinite-verifier.sh" > "$SBX/pass.json"
grep -q '"verdict":"PASS"' "$SBX/pass.json"
grep -q '"hmac":"' "$SBX/pass.json"
test -s "$SBX/.claude/state/ralph-verifier.jsonl"

python3 - <<'PY' "$SBX/pass.json" "$SBX/.claude/state/ralph-verifier.jsonl"
import json, pathlib, sys
p=json.loads(pathlib.Path(sys.argv[1]).read_text())
rows=[json.loads(x) for x in pathlib.Path(sys.argv[2]).read_text().splitlines() if x.strip()]
assert p['verdict']=='PASS' and p.get('hmac')
assert any(r.get('verdict')=='PASS' and r.get('hmac') for r in rows)
print('{"status":"PASS","fail_then_pass":true,"remediation_file":true,"pass_store_row":true}')
PY
