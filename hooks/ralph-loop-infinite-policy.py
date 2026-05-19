#!/usr/bin/env python3
"""ralph-loop-infinite-policy.py — Single source of truth for verifier policy.

F-12 + RALPH-refactor remediation: provider/model policy was scattered across
stop.sh, verifier.sh, and settings.json with contradictory defaults. This
helper centralises the policy under
``settings.json._ralphLoopInfiniteExitPolicy.verifier_policy`` and exposes a
small CLI used by every hook that needs to authorise a verdict or invoke an
API.

Default canonical policy::

    {
      "provider": "anthropic",
      "model_primary": "claude-opus-4-7",
      "model_allowlist": ["claude-opus-4-7", "deepseek-v4-pro", "minimax-m2.7", "glm-4.5"],
      "model_fallback_provider": "minimax",
      "model_fallback": "minimax-m2.7",
      "fallback_policy": {
        "opus_4_7_and_deepseek": {"provider":"minimax", "model":"minimax-m2.7"},
        "other_agents": {"provider":"glm", "model":"glm-4.5"}
      },
      "effort": "max",
      "pass_ttl_seconds": 120,
      "scoring_dimensions": ["completeness","correctness","clarity","depth","actionability"],
      "scoring_threshold": 0.8,
      "forbid_downgrade_without_unavailability_record": true
    }

Subcommands
-----------
* ``current``  — print the merged active policy as JSON
* ``allow PROVIDER MODEL`` — exit 0 if allowed, 1 with reason otherwise
* ``provider`` / ``model`` / ``effort`` — print primary values
* ``fallback-provider`` / ``fallback-model`` — print fallback values
* ``scoring-threshold`` / ``scoring-dimensions``

If settings.json supplies a ``verifier_policy`` block under
``_ralphLoopInfiniteExitPolicy`` it overrides these defaults. The legacy
``verifier_model`` / ``verifier_provider`` keys remain readable but are
deprecated and only used if no ``verifier_policy`` is present.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SCORING_DIMENSIONS = [
    "completeness",
    "correctness",
    "clarity",
    "depth",
    "actionability",
]

DEFAULT_POLICY = {
    "provider": "anthropic",
    "model_primary": "claude-opus-4-7",
    "model_allowlist": ["claude-opus-4-7", "deepseek-v4-pro", "minimax-m2.7", "glm-4.5"],
    "model_fallback_provider": "minimax",
    "model_fallback": "minimax-m2.7",
    "judge_policy": {"provider": "minimax", "model": "minimax-m2.7"},
    "fallback_policy": {
        "opus_4_7_and_deepseek": {"provider": "minimax", "model": "minimax-m2.7"},
        "other_agents": {"provider": "glm", "model": "glm-4.5"},
    },
    "effort": "max",
    "pass_ttl_seconds": 120,
    "scoring_dimensions": list(SCORING_DIMENSIONS),
    "scoring_threshold": 0.8,
    "forbid_downgrade_without_unavailability_record": True,
}


def settings_paths() -> list[Path]:
    home = Path(os.environ.get("HOME", str(Path.home())))
    return [
        home / ".claude" / "settings.json",
        home / ".claude" / "settings.local.json",
    ]


def load_policy() -> dict:
    """Return the active policy. settings.json overrides defaults if present."""
    policy = dict(DEFAULT_POLICY)
    for path in settings_paths():
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        block = data.get("_ralphLoopInfiniteExitPolicy", {}) or {}
        explicit = block.get("verifier_policy")
        if isinstance(explicit, dict):
            for key, value in explicit.items():
                if key == "model_allowlist" and isinstance(value, list):
                    policy[key] = list(value)
                else:
                    policy[key] = value
        else:
            # Legacy fallbacks (kept for transitional compatibility only).
            legacy_provider = block.get("verifier_provider")
            if isinstance(legacy_provider, str) and legacy_provider:
                policy["provider"] = legacy_provider
            legacy_model = block.get("verifier_model")
            if isinstance(legacy_model, str) and legacy_model:
                policy["model_primary"] = legacy_model
                if legacy_model not in policy["model_allowlist"]:
                    policy["model_allowlist"] = [legacy_model] + policy["model_allowlist"]
            legacy_effort = block.get("verifier_effort")
            if isinstance(legacy_effort, str) and legacy_effort:
                policy["effort"] = legacy_effort
            legacy_ttl = block.get("pass_ttl_seconds")
            if isinstance(legacy_ttl, int):
                policy["pass_ttl_seconds"] = legacy_ttl

    # Ensure every configured fallback is always allowlisted so a legitimate
    # fallback verdict can be cached without later policy-violation rejection.
    allowlist = list(policy.get("model_allowlist", []) or [])
    judge_policy = policy.get("judge_policy") if isinstance(policy.get("judge_policy"), dict) else {}
    jm = judge_policy.get("model")
    if isinstance(jm, str) and jm and jm not in allowlist:
        allowlist.append(jm)
    fb = policy.get("model_fallback")
    if isinstance(fb, str) and fb and fb not in allowlist:
        allowlist.append(fb)
    fallback_policy = policy.get("fallback_policy") or {}
    if isinstance(fallback_policy, dict):
        for cell in fallback_policy.values():
            if isinstance(cell, dict):
                m = cell.get("model")
                if isinstance(m, str) and m and m not in allowlist:
                    allowlist.append(m)
    policy["model_allowlist"] = allowlist
    return policy


def fallback_for(provider: str, model: str) -> tuple[str, str]:
    """Return required fallback for a provider/model lineage.

    Production policy:
    - MiniMax-M2.7 is fallback for Opus 4.7 and Deepseek.
    - GLM is fallback for all other AI agents.
    """
    policy = load_policy()
    fp = policy.get("fallback_policy") if isinstance(policy.get("fallback_policy"), dict) else {}
    mm = fp.get("opus_4_7_and_deepseek", {}) if isinstance(fp, dict) else {}
    glm = fp.get("other_agents", {}) if isinstance(fp, dict) else {}
    provider_l = (provider or "").lower()
    model_l = (model or "").lower()
    if "opus-4-7" in model_l or "opus 4.7" in model_l or provider_l == "deepseek" or "deepseek" in model_l:
        return str(mm.get("provider") or "minimax"), str(mm.get("model") or "minimax-m2.7")
    return str(glm.get("provider") or "glm"), str(glm.get("model") or "glm-4.5")


def allow(provider: str, model: str) -> tuple[bool, str]:
    policy = load_policy()
    expected_provider = policy.get("provider", "anthropic")
    fallback_provider = policy.get("model_fallback_provider", "")
    fallback_providers = {str(fallback_provider)} if fallback_provider else set()
    judge_policy = policy.get("judge_policy") if isinstance(policy.get("judge_policy"), dict) else {}
    if judge_policy.get("provider"):
        fallback_providers.add(str(judge_policy.get("provider")))
    fallback_policy = policy.get("fallback_policy") or {}
    if isinstance(fallback_policy, dict):
        for cell in fallback_policy.values():
            if isinstance(cell, dict) and cell.get("provider"):
                fallback_providers.add(str(cell.get("provider")))
    allowlist = policy.get("model_allowlist") or [policy.get("model_primary")]
    if not provider:
        return False, "provider missing in signed verdict"
    if provider not in ({str(expected_provider)} | fallback_providers):
        return False, f"provider '{provider}' not in {{primary={expected_provider}, fallbacks={sorted(fallback_providers)}}}"
    if not model:
        return False, "model missing in signed verdict"
    if model not in allowlist:
        return False, f"model '{model}' not in allowlist {allowlist}"
    return True, "ok"


def main() -> int:
    parser = argparse.ArgumentParser(description="Ralph Loop Infinite verifier policy helper")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("current", help="print the merged active policy as JSON")

    allow_parser = sub.add_parser("allow", help="check provider+model against policy")
    allow_parser.add_argument("provider")
    allow_parser.add_argument("model")

    sub.add_parser("provider", help="print primary provider")
    sub.add_parser("model", help="print primary model")
    sub.add_parser("effort", help="print primary effort level")
    sub.add_parser("fallback-provider", help="print fallback provider")
    sub.add_parser("fallback-model", help="print fallback model")
    sub.add_parser("judge-provider", help="print judge provider")
    sub.add_parser("judge-model", help="print judge model")
    fb_for = sub.add_parser("fallback-for", help="print required fallback for PROVIDER MODEL as JSON")
    fb_for.add_argument("provider")
    fb_for.add_argument("model")
    sub.add_parser("pass-ttl", help="print pass TTL seconds")
    sub.add_parser("allowlist", help="print model allowlist (one per line)")
    sub.add_parser("scoring-threshold", help="print scoring threshold")
    sub.add_parser("scoring-dimensions", help="print scoring dimensions (one per line)")

    args = parser.parse_args()
    if not args.cmd:
        parser.print_help()
        return 2

    policy = load_policy()
    if args.cmd == "current":
        print(json.dumps(policy, indent=2))
        return 0
    if args.cmd == "provider":
        print(policy.get("provider", ""))
        return 0
    if args.cmd == "model":
        print(policy.get("model_primary", ""))
        return 0
    if args.cmd == "effort":
        print(policy.get("effort", ""))
        return 0
    if args.cmd == "fallback-provider":
        print(policy.get("model_fallback_provider", ""))
        return 0
    if args.cmd == "fallback-model":
        print(policy.get("model_fallback", ""))
        return 0
    if args.cmd == "judge-provider":
        jp = policy.get("judge_policy") if isinstance(policy.get("judge_policy"), dict) else {}
        print(jp.get("provider", policy.get("model_fallback_provider", "")))
        return 0
    if args.cmd == "judge-model":
        jp = policy.get("judge_policy") if isinstance(policy.get("judge_policy"), dict) else {}
        print(jp.get("model", policy.get("model_fallback", "")))
        return 0
    if args.cmd == "fallback-for":
        provider, model = fallback_for(args.provider, args.model)
        print(json.dumps({"provider": provider, "model": model}))
        return 0
    if args.cmd == "pass-ttl":
        print(int(policy.get("pass_ttl_seconds", 120)))
        return 0
    if args.cmd == "allowlist":
        for m in policy.get("model_allowlist") or []:
            print(m)
        return 0
    if args.cmd == "scoring-threshold":
        print(policy.get("scoring_threshold", 0.8))
        return 0
    if args.cmd == "scoring-dimensions":
        for d in policy.get("scoring_dimensions") or []:
            print(d)
        return 0
    if args.cmd == "allow":
        ok, reason = allow(args.provider, args.model)
        if ok:
            print("ok")
            return 0
        print(reason, file=sys.stderr)
        return 1

    return 2


if __name__ == "__main__":
    sys.exit(main())
