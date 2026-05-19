#!/bin/bash
# ralph-loop-infinite-bootstrap.sh — Boot-time integrity check.
#
# v4.0.0 (F-02/F-03 remediation):
#   * Treats integrity violations as fail-closed by default. Missing manifest,
#     hash drift, missing protected file, missing required hook registration,
#     and missing HMAC key all cause the bootstrap to emit a SessionStart
#     context that names the failure, and to exit non-zero so the surrounding
#     runtime sees a hard error.
#   * Manifest generation is treated as an install/update-time operation. At
#     runtime the bootstrap only INSPECTS the manifest; if it is absent, the
#     hook fails closed and instructs the operator to run
#     ~/.claude/hooks/generate-contract-hashes.sh manually.
#   * Strictness can be relaxed only via an explicit
#     RALPH_BOOTSTRAP_STRICT=0 override; the previous "warning by default"
#     behaviour is no longer accessible without that opt-out.

set -uo pipefail

STATE_FILE="$HOME/.claude/state/ralph-loop-infinite.local"
LOG_FILE="$HOME/.claude/state/ralph-gate.log"
MANIFEST="$HOME/.claude/manifest/contract-hashes.json"
HMAC_KEY_FILE="$HOME/.claude/secrets/ralph-hmac.key"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$(dirname "$LOG_FILE")"

log() { printf '[%s] [bootstrap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

# Canonical (required) contract surface for Claude Code on this host.
# Cross-runtime files (Codex, Cursor) and home-root duplicates live in
# OPTIONAL_PROTECTED_FILES below — they are hash-tracked if present but
# never fatal if absent, because the canonical Claude Code CLAUDE.md /
# AGENTS.md location is ~/.claude/. Listing home-root copies as required
# was the cause of the long-running bootstrap FAIL loop.
PROTECTED_FILES=(
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.claude/AGENTS.md"
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
)

# Hash-tracked if present, never fatal if absent. These cover other
# runtimes (Codex CLI, Cursor) and legacy home-root duplicates.
OPTIONAL_PROTECTED_FILES=(
  "$HOME/.codex/CLAUDE.md"
  "$HOME/.codex/AGENTS.md"
  "$HOME/CLAUDE.md"
  "$HOME/AGENTS.md"
  "$HOME/.cursor/rules/ralph-loop-infinite.mdc"
  "$HOME/.codex/plugins/ralph-gate.ts"
  "$HOME/.codex/plugins/ralph-gate.config.ts"
)

HMAC_OK=1
if [[ ! -f "$HMAC_KEY_FILE" ]]; then
  log "FAIL: HMAC key missing at $HMAC_KEY_FILE"
  HMAC_OK=0
fi

MISSING=()
INSTALLED_PROTECTED=()
# Required files: a miss is fatal.
for f in "${PROTECTED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    INSTALLED_PROTECTED+=("$f")
  else
    MISSING+=("${f#$HOME/}")
  fi
done
# Optional files: hash-tracked if present, never fatal if absent.
for f in "${OPTIONAL_PROTECTED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    INSTALLED_PROTECTED+=("$f")
  fi
done

HASH_OK=1
DRIFT=()
MANIFEST_GENERATOR="$HOME/.claude/hooks/generate-contract-hashes.sh"
if [[ ! -f "$MANIFEST" ]]; then
  log "FAIL: manifest absent at $MANIFEST — run $MANIFEST_GENERATOR to regenerate."
  HASH_OK=0
elif command -v jq >/dev/null 2>&1; then
  for f in "${INSTALLED_PROTECTED[@]}"; do
    EXPECTED=$(jq -r --arg path "$f" '.[$path] // empty' "$MANIFEST" 2>/dev/null)
    if [[ -z "$EXPECTED" ]]; then
      # Tracked file present but not in manifest → drift (manifest stale).
      DRIFT+=("$(basename "$f") [missing from manifest]")
      HASH_OK=0
      continue
    fi
    ACTUAL=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
      DRIFT+=("$(basename "$f")")
      HASH_OK=0
    fi
  done
fi

SETTINGS_OK=1
if [[ -f "$SETTINGS" ]]; then
  REQUIRED_HOOKS=(
    "ralph-loop-infinite-bootstrap.sh"
    "ralph-loop-infinite-session.sh"
    "ralph-loop-infinite-prompt.sh"
    "ralph-loop-infinite-pretool.sh"
    "ralph-loop-infinite-stop.sh"
  )
  for h in "${REQUIRED_HOOKS[@]}"; do
    grep -q "$h" "$SETTINGS" 2>/dev/null || { SETTINGS_OK=0; log "FAIL: settings.json missing registration for $h"; }
  done
else
  SETTINGS_OK=0
  log "FAIL: settings.json missing at $SETTINGS"
fi

STATUS_OK=1
[[ $HMAC_OK -eq 0 || ${#MISSING[@]} -gt 0 || $HASH_OK -eq 0 || $SETTINGS_OK -eq 0 ]] && STATUS_OK=0

if [[ $STATUS_OK -eq 1 ]]; then
  log "OK: all integrity checks passed"
  CTX="[ralph-loop-infinite] bootstrap: integrity verified ✓ — verifier-PASS is the only valid exit."
  jq -n --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(printf '%s' "$CTX" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
  exit 0
fi

REASON_PARTS=()
[[ $HMAC_OK -eq 0 ]] && REASON_PARTS+=("HMAC key missing")
[[ ${#MISSING[@]} -gt 0 ]] && REASON_PARTS+=("missing files: ${MISSING[*]}")
[[ $HASH_OK -eq 0 ]] && REASON_PARTS+=("hash drift: ${DRIFT[*]:-(manifest missing)}")
[[ $SETTINGS_OK -eq 0 ]] && REASON_PARTS+=("settings.json registrations missing")
REASON=$(IFS='; '; echo "${REASON_PARTS[*]}")
log "FAIL: $REASON"

CTX="[⛔ RALPH-LOOP-INFINITE: BOOTSTRAP FAILED] Integrity check failed: $REASON. Run ~/.claude/hooks/generate-contract-hashes.sh after restoring missing files; do not bypass. Override only via RALPH_BOOTSTRAP_STRICT=0 (NOT recommended)."

# F-03: strictness is the default. Set RALPH_BOOTSTRAP_STRICT=0 to demote
# failures to a non-blocking warning (will still log).
if [[ "${RALPH_BOOTSTRAP_STRICT:-1}" == "0" ]]; then
  log "WARN: RALPH_BOOTSTRAP_STRICT=0 explicit override — continuing with degraded integrity"
  jq -n --arg ctx "$CTX (NON-STRICT MODE — explicit override)" \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(printf '%s' "$CTX (NON-STRICT MODE — explicit override)" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
  exit 0
fi

# Strict mode (default): emit failure context AND non-zero exit so the
# runtime treats this as a hard error.
jq -n --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}' 2>/dev/null \
  || printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(printf '%s' "$CTX" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
exit 1
