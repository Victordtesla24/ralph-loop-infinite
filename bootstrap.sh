#!/bin/bash
# ralph-loop-infinite — Production Bootstrap
# Clone this repo, run bootstrap.sh, the system is live.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$REPO_ROOT/hooks"
STATE_DIR="${HOME}/.claude/state"
MANIFEST_DIR="${HOME}/.claude/manifest"
SECRETS_DIR="${HOME}/.claude/secrets"
DB_PATH="${STATE_DIR}/ralph-loop-infinite.db"
echo "══════════════════════════════════════════════════════"
echo "  Ralph-Loop-Infinite — Production Bootstrap"
echo "══════════════════════════════════════════════════════"
if [[ ! -d "$HOOKS_DIR" ]] || [[ ! -f "$HOOKS_DIR/ralph-loop-infinite-bootstrap.sh" ]]; then
  echo "[1/6] Installing Ralph hooks to ~/.claude/hooks/ ..."
  mkdir -p ~/.claude/hooks
  cp -r "$REPO_ROOT/hooks/"* ~/.claude/hooks/
  chmod +x ~/.claude/hooks/*.sh
  echo "  → hooks installed"
else
  echo "[1/6] Hooks already present — skipping copy"
fi
mkdir -p "$SECRETS_DIR"
if [[ ! -f "$SECRETS_DIR/ralph-hmac.key" ]]; then
  echo "[2/6] Generating HMAC signing key ..."
  openssl rand -hex 64 > "$SECRETS_DIR/ralph-hmac.key"
  chmod 600 "$SECRETS_DIR/ralph-hmac.key"
  echo "  → HMAC key generated at ~/.claude/secrets/ralph-hmac.key"
else
  echo "[2/6] HMAC key already present — skipping"
fi
mkdir -p "$MANIFEST_DIR"
if [[ -x ~/.claude/hooks/generate-contract-hashes.sh ]]; then
  echo "[3/6] Registering contract hashes ..."
  bash ~/.claude/hooks/generate-contract-hashes.sh
  bash ~/.claude/hooks/generate-contract-hashes.sh --verify
  echo "  → manifest generated and verified"
else
  echo "[3/6] SKIPPED — generate-contract-hashes.sh not found"
fi
mkdir -p "$STATE_DIR"
echo "[4/6] State directory ready at $STATE_DIR"
if [[ -x ~/.claude/hooks/ralph-loop-infinite-db.py ]]; then
  echo "[5/6] Initializing SQLite database ..."
  python3 ~/.claude/hooks/ralph-loop-infinite-db.py init >/dev/null 2>&1 && echo "  → DB initialized" || echo "  → DB init failed (non-fatal)"
else
  echo "[5/6] SKIPPED — db helper not found"
fi
echo "[6/6] Running self-test ..."
TEST_LOG=$(mktemp)
bash ~/.claude/hooks/test-ralph-refactor.sh > "$TEST_LOG" 2>&1 || true
PASS_COUNT=$(grep -c "^  PASS" "$TEST_LOG" 2>/dev/null || echo "0")
FAIL_COUNT=$(grep -c "^  FAIL" "$TEST_LOG" 2>/dev/null || echo "0")
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Self-test result: PASS $PASS_COUNT / FAIL $FAIL_COUNT"
echo "══════════════════════════════════════════════════════"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "⚠ Some tests failed — review $TEST_LOG"
  cat "$TEST_LOG" | tail -20
  exit 1
fi
echo ""
echo "Ralph-Loop-Infinite is live."
echo "Invoke with: /ralph-loop-infinite"
echo "Docs: $REPO_ROOT/README.md"
