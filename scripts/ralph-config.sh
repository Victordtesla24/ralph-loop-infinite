#!/usr/bin/env bash
# ralph-loop-infinite — User Configuration Tool
# Allows changing loop dynamics, parameters, thresholds, scoping.
# Safe — only modifies _ralphLoopInfiniteExitPolicy block in settings.json.
# Does NOT touch hooks, contract files, or HMAC key.

set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
SETTINGS_LOCAL="${HOME}/.claude/settings.local.json"
POLICY_PY="${HOME}/.claude/hooks/ralph-loop-infinite-policy.py"

usage() {
    cat <<EOF
Ralph-Loop-Infinite Configuration Tool
======================================

USAGE:
    ralph-config get <key>          Get current value
    ralph-config set <key> <value>  Set value (live, immediate)
    ralph-config list                List all configurable parameters
    ralph-config defaults            Reset all parameters to defaults
    ralph-config show                Show full active policy

EXAMPLES:
    ralph-config get scoring_threshold
    ralph-config set scoring_threshold 0.85
    ralph-config set max_iterations 5
    ralph-config set primary_model claude-opus-4-7
    ralph-config set fallback_model minimax-m2.7
    ralph-config set pass_ttl_seconds 180
    ralph-config list

CONFIGURABLE PARAMETERS:

Loop Dynamics:
    max_iterations        Maximum iterations before HARD BLOCKER (default: 3)
    convergence_escalation Whether convergence triggers escalation not exit (default: true)
    generator_infinite     Whether GENERATOR can never self-declare done (default: true)

Verifier / Judge:
    scoring_threshold     Minimum score per dimension for PASS (default: 0.80)
    pass_ttl_seconds      How long PASS remains valid (default: 120)
    primary_model         Primary verifier model (default: claude-opus-4-7)
    fallback_model        Fallback model (default: minimax-m2.7)
    fallback_provider     Fallback provider (default: minimax)

Scoring Dimensions (comma-separated):
    scoring_dimensions    The 5 dimensions to score (default: completeness,correctness,clarity,depth,actionability)

Provider Chain:
    provider_opus_deepseek  Fallback for Opus/Deepseek (default: minimax/MiniMax-M2.7)
    provider_all_others      Fallback for other agents (default: minimax/MiniMax-M2.7)

Anti-Weak-Criticism:
    anti_weak_criticism   Enforce concrete issues in critique (default: true)
    anti_leniency          Verifier is NOT your ally, strict scoring (default: true)

Output:
    verbose_logs          Log all provider chain events (default: true)
    state_preservation    Carry iteration state forward (default: true)

EOF
}

# Unlock settings files for writing
chmod u+w "$SETTINGS" "$SETTINGS_LOCAL" 2>/dev/null || true

# Load current policy from settings
load_policy() {
    python3 - <<'PY'
import json, sys
from pathlib import Path

settings = {}
for p in [Path.home() / '.claude' / 'settings.json', Path.home() / '.claude' / 'settings.local.json']:
    if p.exists():
        try:
            settings.update(json.loads(p.read_text()))
        except: pass

block = settings.get('_ralphLoopInfiniteExitPolicy', {})
policy = block.get('verifier_policy', {}) if isinstance(block.get('verifier_policy'), dict) else {}

defaults = {
    'scoring_threshold': 0.80,
    'max_iterations': 3,
    'pass_ttl_seconds': 120,
    'primary_model': 'claude-opus-4-7',
    'fallback_model': 'minimax-m2.7',
    'fallback_provider': 'minimax',
    'scoring_dimensions': 'completeness,correctness,clarity,depth,actionability',
    'provider_opus_deepseek': 'minimax/MiniMax-M2.7',
    'provider_all_others': 'minimax/MiniMax-M2.7',
    'convergence_escalation': 'true',
    'generator_infinite': 'true',
    'anti_weak_criticism': 'true',
    'anti_leniency': 'true',
    'verbose_logs': 'true',
    'state_preservation': 'true',
}

for k in defaults:
    policy.setdefault(k, block.get(k, defaults[k]))

print(json.dumps(policy, indent=2))
PY
}

# Get current value
do_get() {
    val=$(load_policy | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1', 'not set'))")
    echo "$1 = $val"
}

# Set value
do_set() {
    key="$1"
    value="$2"
    python3 - <<PY
import json
from pathlib import Path

settings_path = Path.home() / '.claude' / 'settings.json'
settings_local = Path.home() / '.claude' / 'settings.local.json'

# Read
data = {}
for p in [settings_path, settings_local]:
    if p.exists():
        try: data = json.loads(p.read_text())
        except: data = {}

if '_ralphLoopInfiniteExitPolicy' not in data:
    data['_ralphLoopInfiniteExitPolicy'] = {}
if 'verifier_policy' not in data['_ralphLoopInfiniteExitPolicy']:
    data['_ralphLoopInfiniteExitPolicy']['verifier_policy'] = {}

vp = data['_ralphLoopInfiniteExitPolicy']['verifier_policy']

# Normalize key
key_map = {
    'scoring_threshold': 'scoring_threshold',
    'max_iterations': 'max_iterations',
    'pass_ttl_seconds': 'pass_ttl_seconds',
    'primary_model': 'model_primary',
    'fallback_model': 'model_fallback',
    'fallback_provider': 'model_fallback_provider',
    'scoring_dimensions': 'scoring_dimensions',
    'provider_opus_deepseek': 'opus_4_7_and_deepseek_fallback',
    'provider_all_others': 'other_agents_fallback',
    'convergence_escalation': 'convergence_escalation',
    'generator_infinite': 'generator_infinite',
    'anti_weak_criticism': 'anti_weak_criticism',
    'anti_leniency': 'anti_leniency',
    'verbose_logs': 'verbose_logs',
    'state_preservation': 'state_preservation',
}

mapped_key = key_map.get(key, key)

# Type inference
if value in ('true', 'false'):
    typed_value = value == 'true'
elif value.isdigit():
    typed_value = int(value)
else:
    try:
        typed_value = float(value)
    except:
        typed_value = value

vp[mapped_key] = typed_value

# Write back
settings_path.write_text(json.dumps(data, indent=2) + '\n')
print(f"Set {key} = {typed_value} (as {mapped_key})")
PY

    # Re-apply chmod
    chmod 444 "$SETTINGS" "$SETTINGS_LOCAL" 2>/dev/null || true
}

# List all
do_list() {
    echo "CURRENT CONFIGURATION:"
    echo ""
    load_policy | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k in sorted(d.keys()):
    print(f'  {k}: {d[k]}')"
}

# Show defaults
do_defaults() {
    echo "DEFAULT CONFIGURATION:"
    echo "  scoring_threshold = 0.80"
    echo "  max_iterations = 3"
    echo "  pass_ttl_seconds = 120"
    echo "  primary_model = claude-opus-4-7"
    echo "  fallback_model = minimax-m2.7"
    echo "  fallback_provider = minimax"
    echo "  scoring_dimensions = completeness,correctness,clarity,depth,actionability"
    echo "  provider_opus_deepseek = minimax/MiniMax-M2.7"
    echo "  provider_all_others = minimax/MiniMax-M2.7"
    echo "  convergence_escalation = true"
    echo "  generator_infinite = true"
    echo "  anti_weak_criticism = true"
    echo "  anti_leniency = true"
    echo "  verbose_logs = true"
    echo "  state_preservation = true"
}

# Show full
do_show() {
    echo "FULL ACTIVE POLICY:"
    load_policy | python3 -m json.tool
}

COMMAND="${1:-}"
case "$COMMAND" in
    get)    do_get "${2:-}" ;;
    set)    do_set "${2:-}" "${3:-}" ;;
    list)   do_list ;;
    defaults) do_defaults ;;
    show)   do_show ;;
    *)      usage ;;
esac