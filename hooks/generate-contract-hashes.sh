#!/bin/bash
# generate-contract-hashes.sh — Install/update-time manifest generator.
#
# F-02 remediation: this script is the ONLY supported way to mint or refresh
# ~/.claude/manifest/contract-hashes.json. Runtime bootstrap no longer
# silently regenerates the manifest — it fails closed instead and points at
# this script. The harness never invokes this against the live HOME.
#
# Usage:
#   ./generate-contract-hashes.sh          # regenerate + verify
#   ./generate-contract-hashes.sh --verify # verify only (exit 1 if drift)

set -uo pipefail

MANIFEST_DIR="$HOME/.claude/manifest"
MANIFEST="$MANIFEST_DIR/contract-hashes.json"
PROTECTED_FILES=(
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.claude/AGENTS.md"
  "$HOME/.codex/CLAUDE.md"
  "$HOME/.codex/AGENTS.md"
  "$HOME/CLAUDE.md"
  "$HOME/AGENTS.md"
  "$HOME/.cursor/rules/ralph-loop-infinite.mdc"
  "$HOME/.claude/hooks/ralph-loop-infinite-stop.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-prompt.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-pretool.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-session.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-bootstrap.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-verifier.sh"
  "$HOME/.claude/hooks/ralph-loop-infinite-contract.md"
  "$HOME/.claude/hooks/ralph-loop-infinite-db.py"
  "$HOME/.claude/hooks/ralph-loop-infinite-tsparse.py"
  "$HOME/.claude/hooks/ralph-loop-infinite-policy.py"
  "$HOME/.claude/hooks/ralph-loop-infinite-pathguard.py"
  "$HOME/.claude/hooks/ralph-loop-infinite-evidence.py"
  "$HOME/.claude/plugins/ralph-gate.ts"
  "$HOME/.codex/plugins/ralph-gate.ts"
  "$HOME/.codex/plugins/ralph-gate.config.ts"
)

VERIFY_ONLY=0
if [[ "${1:-}" == "--verify" ]]; then
  VERIFY_ONLY=1
fi

mkdir -p "$MANIFEST_DIR"
chmod 700 "$MANIFEST_DIR" 2>/dev/null || true

generate_manifest() {
  local tmpfile
  tmpfile=$(mktemp 2>/dev/null) || tmpfile="/tmp/ralph-manifest.$$"
  python3 - "$tmpfile" "${PROTECTED_FILES[@]}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
entries = {}
for raw in sys.argv[2:]:
    p = Path(raw)
    if not p.is_file():
        continue
    h = hashlib.sha256()
    try:
        with p.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 16), b""):
                h.update(chunk)
        entries[str(p)] = h.hexdigest()
    except OSError:
        continue
out_path.write_text(json.dumps(entries, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  mv "$tmpfile" "$MANIFEST"
  chmod 600 "$MANIFEST"
  echo "Generated: $MANIFEST"
}

verify_manifest() {
  local drift=0
  if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest missing at $MANIFEST"
    return 1
  fi
  for f in "${PROTECTED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      local expected actual
      expected=$(jq -r --arg path "$f" '.[$path] // empty' "$MANIFEST" 2>/dev/null)
      if [[ -z "$expected" ]]; then
        echo "WARN: $f not in manifest"
        continue
      fi
      actual=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
      if [[ "$expected" != "$actual" ]]; then
        echo "DRIFT: $f"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        drift=1
      fi
    fi
  done
  if [[ $drift -eq 1 ]]; then
    echo "FAIL: hash drift detected"
    return 1
  fi
  echo "OK: all hashes match"
  return 0
}

if [[ $VERIFY_ONLY -eq 1 ]]; then
  verify_manifest
else
  generate_manifest
  echo ""
  echo "Verifying generated manifest..."
  verify_manifest
fi
