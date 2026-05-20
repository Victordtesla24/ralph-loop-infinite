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

# ── Step 1: Config files ──────────────────────────────────────
echo "[1/11] Installing config files (CLAUDE.md, AGENTS.md, .claude.json) ..."

if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
  cp "$REPO_ROOT/CLAUDE.md" "${HOME}/.claude/CLAUDE.md"
  chmod 444 "${HOME}/.claude/CLAUDE.md"
  echo "  → CLAUDE.md installed"
fi

if [[ -f "$REPO_ROOT/AGENTS.md" ]]; then
  cp "$REPO_ROOT/AGENTS.md" "${HOME}/.claude/AGENTS.md"
  chmod 444 "${HOME}/.claude/AGENTS.md"
  echo "  → AGENTS.md installed"
fi

if [[ -f "$REPO_ROOT/.claude.json" ]]; then
  if [[ -f "${HOME}/.claude/.claude.json" ]]; then
    echo "  → .claude.json already exists — preserving"
  else
    cp "$REPO_ROOT/.claude.json" "${HOME}/.claude/.claude.json"
    chmod 444 "${HOME}/.claude/.claude.json"
    echo "  → .claude.json installed"
  fi
fi

# ── Step 2: Hook files ────────────────────────────────────────
echo "[2/11] Installing Ralph hooks to ~/.claude/hooks/ ..."
mkdir -p ~/.claude/hooks
if [[ -d "$HOOKS_DIR" ]]; then
  cp -r "$HOOKS_DIR/"* ~/.claude/hooks/
  chmod +x ~/.claude/hooks/*.sh 2>/dev/null || true
  chmod +x ~/.claude/hooks/generate-contract-hashes.sh 2>/dev/null || true
  echo "  → hooks installed ($(ls ~/.claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ') shell scripts)"
else
  echo "  → ERROR: hooks/ directory not found in repo"
  exit 1
fi

# ── Step 3: HMAC signing key ─────────────────────────────────
mkdir -p "$SECRETS_DIR"
if [[ ! -f "$SECRETS_DIR/ralph-hmac.key" ]]; then
  echo "[3/11] Generating HMAC signing key ..."
  openssl rand -hex 64 > "$SECRETS_DIR/ralph-hmac.key"
  chmod 600 "$SECRETS_DIR/ralph-hmac.key"
  echo "  → HMAC key generated at ~/.claude/secrets/ralph-hmac.key"
else
  echo "[3/11] HMAC key already present — skipping"
fi

# ── Step 4: Contract hash manifest ──────────────────────────
mkdir -p "$MANIFEST_DIR"
if [[ -x ~/.claude/hooks/generate-contract-hashes.sh ]]; then
  echo "[4/11] Registering contract hashes ..."
  bash ~/.claude/hooks/generate-contract-hashes.sh
  bash ~/.claude/hooks/generate-contract-hashes.sh --verify
  echo "  → manifest generated and verified"
fi

# ── Step 5: State directory ──────────────────────────────────
mkdir -p "$STATE_DIR"
echo "[5/11] State directory ready at $STATE_DIR"

# ── Step 6: SQLite database ──────────────────────────────────
if [[ -x ~/.claude/hooks/ralph-loop-infinite-db.py ]]; then
  echo "[6/11] Initializing SQLite database ..."
  python3 ~/.claude/hooks/ralph-loop-infinite-db.py init >/dev/null 2>&1 && echo "  → DB initialized" || echo "  → DB init failed (non-fatal)"
fi

# ── Step 7: Settings.json hook registration ──────────────────
if [[ -f "$REPO_ROOT/scripts/sync-ralph-config.sh" ]]; then
  echo "[7/11] Registering hooks in settings.json ..."
  chmod +x "$REPO_ROOT/scripts/sync-ralph-config.sh"
  bash "$REPO_ROOT/scripts/sync-ralph-config.sh" >/dev/null 2>&1 && echo "  → settings.json updated" || echo "  → settings.json update failed (non-fatal)"
fi

# ── Step 8: Sub-agents (GENERATOR / CRITIC / JUDGE) ─────────
echo "[8/11] Installing sub-agents to ~/.sub-agents/ ..."
if [[ -d "$REPO_ROOT/sub-agents" ]]; then
  if [[ -d "${HOME}/.sub-agents" ]]; then
    echo "  → ~/.sub-agents already exists — preserving"
  else
    cp -r "$REPO_ROOT/sub-agents" "${HOME}/.sub-agents"
    chmod -R a-w "${HOME}/.sub-agents"
    FILE_COUNT=$(find "${HOME}/.sub-agents" -type f | wc -l | tr -d ' ')
    echo "  → $FILE_COUNT sub-agent files installed"
  fi
fi

# ── Step 9: Commands ──────────────────────────────────────────
echo "[9/11] Installing slash commands to ~/.claude/commands/ ..."
if [[ -d "$REPO_ROOT/commands" ]]; then
  mkdir -p "${HOME}/.claude/commands"
  cp -r "$REPO_ROOT/commands/"* "${HOME}/.claude/commands/"
  chmod 444 "${HOME}/.claude/commands/"*.md 2>/dev/null || true
  echo "  → $(find "$REPO_ROOT/commands" -name '*.md' | wc -l | tr -d ' ') commands installed"
fi

# ── Step 10: Skills ───────────────────────────────────────────
echo "[10/11] Installing skills to ~/.claude/skills/ ..."
if [[ -f "$REPO_ROOT/SKILL.md" ]]; then
  mkdir -p "${HOME}/.claude/skills/ralph-loop-infinite"
  cp "$REPO_ROOT/SKILL.md" "${HOME}/.claude/skills/ralph-loop-infinite/SKILL.md"
  chmod 444 "${HOME}/.claude/skills/ralph-loop-infinite/SKILL.md"
  echo "  → skill installed at ~/.claude/skills/ralph-loop-infinite/SKILL.md"
fi
if [[ -d "$REPO_ROOT/skills" ]]; then
  mkdir -p "${HOME}/.claude/skills"
  cp -r "$REPO_ROOT/skills/"* "${HOME}/.claude/skills/"
  find "${HOME}/.claude/skills" -name 'SKILL.md' -exec chmod 444 {} \;
  echo "  → $(find "$REPO_ROOT/skills" -name 'SKILL.md' | wc -l | tr -d ' ') additional skills installed"
fi

# ── Step 11: Ralph scripts ────────────────────────────────────
echo "[11/11] Installing Ralph scripts ..."
if [[ -f "$REPO_ROOT/scripts/ralph-config.sh" ]]; then
  mkdir -p "${HOME}/.claude/scripts"
  cp "$REPO_ROOT/scripts/ralph-config.sh" "${HOME}/.claude/scripts/"
  chmod +x "${HOME}/.claude/scripts/ralph-config.sh"
  echo "  → ralph-config.sh installed"
fi
if [[ -f "$REPO_ROOT/scripts/ralph-spawn.sh" ]]; then
  mkdir -p "${HOME}/.claude/scripts"
  cp "$REPO_ROOT/scripts/ralph-spawn.sh" "${HOME}/.claude/scripts/"
  chmod +x "${HOME}/.claude/scripts/ralph-spawn.sh"
  echo "  → ralph-spawn.sh installed"
fi

# ── Self-test ─────────────────────────────────────────────────
echo ""
echo "Running self-test ..."
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
echo "  Invoke the loop:     /ralph-loop-infinite"
echo "  Configure params:    /ralph-config list"
echo "  Spawn a sub-agent:   bash ~/.claude/scripts/ralph-spawn.sh list"
echo "  Docs:                $REPO_ROOT/README.md"
