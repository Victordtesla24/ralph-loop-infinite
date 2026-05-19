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

# ── Step 1: Config files ──────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "  Ralph-Loop-Infinite — Production Bootstrap"
echo "══════════════════════════════════════════════════════"

echo "[1/8] Installing config files (CLAUDE.md, AGENTS.md, .claude.json) ..."

# CLAUDE.md — canonical contract
if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
  cp "$REPO_ROOT/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"
  chmod 444 "${HOME}/.claude/CLAUDE.md"
  echo "  → CLAUDE.md installed"
else
  echo "  → CLAUDE.md not in repo (skipping)"
fi

# AGENTS.md — agent personas
if [[ -f "$REPO_ROOT/AGENTS.md" ]]; then
  cp "$REPO_ROOT/AGENTS.md" "${HOME}/.claude/AGENTS.md"
  chmod 444 "${HOME}/.claude/AGENTS.md"
  echo "  → AGENTS.md installed"
else
  echo "  → AGENTS.md not in repo (skipping)"
fi

# .claude.json — runtime state (tips, flags, features)
if [[ -f "$REPO_ROOT/.claude.json" ]]; then
  # Merge: existing ~/.claude/.claude.json is preserved; repo version adds keys
  if [[ -f "${HOME}/.claude/.claude.json" ]]; then
    echo "  → .claude.json already exists — preserving (repo version is additive only)"
  else
    cp "$REPO_ROOT/.claude.json" "${HOME}/.claude/.claude.json"
    chmod 444 "${HOME}/.claude/.claude.json"
    echo "  → .claude.json installed"
  fi
else
  echo "  → .claude.json not in repo (skipping)"
fi

# settings.json — hook registrations
# Handled in step 7 via sync-ralph-config.sh

# ── Step 2: Hook files ────────────────────────────────────────
echo "[2/8] Installing Ralph hooks to ~/.claude/hooks/ ..."
mkdir -p ~/.claude/hooks
if [[ -d "$HOOKS_DIR" ]]; then
  cp -r "$HOOKS_DIR/"* ~/.claude/hooks/
  chmod +x ~/.claude/hooks/*.sh 2>/dev/null || true
  chmod +x ~/.claude/hooks/generate-contract-hashes.sh 2>/dev/null || true
  echo "  → hooks installed"
else
  echo "  → ERROR: hooks/ directory not found in repo"
  exit 1
fi

# ── Step 3: HMAC signing key ─────────────────────────────────
mkdir -p "$SECRETS_DIR"
if [[ ! -f "$SECRETS_DIR/ralph-hmac.key" ]]; then
  echo "[3/8] Generating HMAC signing key ..."
  openssl rand -hex 64 > "$SECRETS_DIR/ralph-hmac.key"
  chmod 600 "$SECRETS_DIR/ralph-hmac.key"
  echo "  → HMAC key generated at ~/.claude/secrets/ralph-hmac.key"
else
  echo "[3/8] HMAC key already present — skipping"
fi

# ── Step 4: Contract hash manifest ──────────────────────────
mkdir -p "$MANIFEST_DIR"
if [[ -x ~/.claude/hooks/generate-contract-hashes.sh ]]; then
  echo "[4/8] Registering contract hashes ..."
  bash ~/.claude/hooks/generate-contract-hashes.sh
  bash ~/.claude/hooks/generate-contract-hashes.sh --verify
  echo "  → manifest generated and verified"
else
  echo "[4/8] SKIPPED — generate-contract-hashes.sh not found"
fi

# ── Step 5: State directory ──────────────────────────────────
mkdir -p "$STATE_DIR"
echo "[5/8] State directory ready at $STATE_DIR"

# ── Step 6: SQLite database ──────────────────────────────────
if [[ -x ~/.claude/hooks/ralph-loop-infinite-db.py ]]; then
  echo "[6/8] Initializing SQLite database ..."
  python3 ~/.claude/hooks/ralph-loop-infinite-db.py init >/dev/null 2>&1 && echo "  → DB initialized" || echo "  → DB init failed (non-fatal)"
else
  echo "[6/8] SKIPPED — db helper not found"
fi

# ── Step 7: Settings.json hook registration ──────────────────
if [[ -f "$REPO_ROOT/scripts/sync-ralph-config.sh" ]]; then
  echo "[7/8] Registering hooks in settings.json ..."
  chmod +x "$REPO_ROOT/scripts/sync-ralph-config.sh"
  bash "$REPO_ROOT/scripts/sync-ralph-config.sh" >/dev/null 2>&1 && echo "  → settings.json updated" || echo "  → settings.json update failed (non-fatal — check manually)"
else
  echo "[7/8] SKIPPED — sync-ralph-config.sh not in repo"
fi

# ── Step 8: Sub-agents (GENERATOR / CRITIC / JUDGE classification) ──
echo "[8/9] Installing sub-agents to ~/.sub-agents/ ..."
if [[ -d "$REPO_ROOT/sub-agents" ]]; then
  if [[ -d "${HOME}/.sub-agents" ]]; then
    echo "  → ~/.sub-agents already exists — preserving (repo is additive on new install)"
    echo "  → To force-reinstall: rm -rf ~/.sub-agents && re-run bootstrap"
  else
    cp -r "$REPO_ROOT/sub-agents" "${HOME}/.sub-agents"
    chmod -R a-w "${HOME}/.sub-agents"
    FILE_COUNT=$(find "${HOME}/.sub-agents" -type f | wc -l | tr -d ' ')
    echo "  → $FILE_COUNT sub-agent files installed"
  fi
else
  echo "  → sub-agents/ not in repo (skipping)"
fi

# ── Step 9: Commands (slash commands for Claude Code / VS Code) ──
echo "[9/9] Installing slash commands to ~/.claude/commands/ ..."
if [[ -d "$REPO_ROOT/commands" ]]; then
  mkdir -p "${HOME}/.claude/commands"
  cp -r "$REPO_ROOT/commands/"* "${HOME}/.claude/commands/"
  chmod 444 "${HOME}/.claude/commands/"*.md 2>/dev/null || true
  echo "  → $(find "$REPO_ROOT/commands" -name '*.md' | wc -l | tr -d ' ') commands installed"
else
  echo "  → commands/ not in repo (skipping)"
fi

# ── Step 10: Ralph config script ──
if [[ -f "$REPO_ROOT/scripts/ralph-config.sh" ]]; then
  mkdir -p "${HOME}/.claude/scripts"
  cp "$REPO_ROOT/scripts/ralph-config.sh" "${HOME}/.claude/scripts/"
  chmod +x "${HOME}/.claude/scripts/ralph-config.sh"
  echo "  → ralph-config.sh installed"
fi
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
echo ""
echo "  Invoke the loop:    /ralph-loop-infinite"
echo "  Configure params:   /ralph-config list"
echo "  Run tests:          bash ~/.claude/hooks/test-ralph-refactor.sh"
echo "  Docs:               $REPO_ROOT/README.md"