#!/usr/bin/env python3
"""ralph-loop-infinite-ralph.py — Explicit RALPH internal thinking loop.

Implements the architecture from the blog "RALPH Loop: Building Self-Improving
AI Systems WITHOUT Claude" (https://gowrishankar.info/blog/...):

    1. Generate / collect candidate output evidence
    2. Critique against the original raw user prompt + sealed evidence bundle
    3. Judge using explicit scoring dimensions
    4. Remediate / re-delegate with a targeted critique-anchored prompt

Design principles, in order:

* Plain Python, stdlib only.
* Explicit function calls between stages — no implicit framework magic.
* Clear state passing via small dataclasses.
* Logged outputs at every stage (~/.claude/state/ralph-thinking-loop.jsonl).
* Deterministic flow / visible state / predictable behavior.

External hook architecture (Stop hook, verifier shell, signing) is preserved.
This helper only owns the *thinking* inside the loop. The shell still emits
the HMAC-signed verdict.

Provider policy
---------------
* Primary: Anthropic ``claude-opus-4-7`` (per policy helper).
* Fallback: MiniMax ``minimax-m2.7`` for both Opus 4.7 and Deepseek failures;
  GLM for all other AI-agent lineages (or whatever the policy file names).
  Fallback is used **only** when the prior provider explicitly fails — never as
  a silent downgrade. Every provider switch is logged to the stage log with
  reason + outcome and recorded in the signed verdict metadata.

The helper never prints API key values. It only prints the *name* of the
source it loaded the key from (env var name, env file path) and the SHA-256
prefix of the key bytes (12 hex chars) so the call-site can verify the key
shape changed without leaking the secret.

Scoring dimensions (exact list from the blog)::

    completeness, correctness, clarity, depth, actionability

Each dimension carries a 0.0-1.0 ``score`` plus ``evidence`` rationale. The
acceptance threshold is 0.8 *per dimension* AND the overall verdict must be
PASS. Any dimension below threshold -> FAIL, period.

Subcommands
-----------
* ``judge``          — run critique+judge; emit Judgement JSON to stdout
* ``remediation``    — emit the canonical remediation prompt from a critique
* ``creds-check``    — report which provider keys are loaded (no values)
* ``self-test``      — pure-Python tests over the prompt builders + parser
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants & paths
# ---------------------------------------------------------------------------

HOME = Path(os.environ.get("HOME", str(Path.home())))
STATE_DIR = HOME / ".claude" / "state"
THINKING_LOG = STATE_DIR / "ralph-thinking-loop.jsonl"
ENV_PRODUCTION = HOME / ".claude" / ".env.production"
POLICY_HELPER = HOME / ".claude" / "hooks" / "ralph-loop-infinite-policy.py"

SCORING_DIMENSIONS: tuple[str, ...] = (
    "completeness",
    "correctness",
    "clarity",
    "depth",
    "actionability",
)

DEFAULT_THRESHOLD = 0.8
DEFAULT_PROVIDER_PRIMARY = "anthropic"
DEFAULT_MODEL_PRIMARY = "claude-opus-4-7"
DEFAULT_PROVIDER_FALLBACK = "minimax"
DEFAULT_MODEL_FALLBACK = "minimax-m2.7"
DEFAULT_PROVIDER_OTHER_FALLBACK = "glm"
DEFAULT_MODEL_OTHER_FALLBACK = "glm-4.5"
DEFAULT_EFFORT = "max"
DEFAULT_TIMEOUT_S = 90


# ---------------------------------------------------------------------------
# Dataclasses — explicit state between stages
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class Generated:
    """Stage-1 output. The agent's §3 exit report is the generated artifact."""

    content: str
    assumptions: list[str] = dataclasses.field(default_factory=list)

    @property
    def content_hash(self) -> str:
        return hashlib.sha256(self.content.encode("utf-8", errors="replace")).hexdigest()


@dataclasses.dataclass
class Critique:
    """Stage-2 critique anchored against the original prompt + evidence."""

    issues: list[str] = dataclasses.field(default_factory=list)
    severity: list[int] = dataclasses.field(default_factory=list)
    suggestions: list[str] = dataclasses.field(default_factory=list)
    raw_rationale: str = ""

    def is_empty(self) -> bool:
        return not (self.issues or self.suggestions or self.raw_rationale.strip())


@dataclasses.dataclass
class DimensionScore:
    score: float
    evidence: str

    def to_dict(self) -> dict[str, Any]:
        return {"score": round(float(self.score), 4), "evidence": self.evidence}


@dataclasses.dataclass
class Judgement:
    """Stage-3 judgement using explicit scoring dimensions."""

    decision: str  # "accept" | "revise"
    overall_score: float
    threshold: float
    breakdown: dict[str, DimensionScore]
    reasoning: str
    missing: list[str] = dataclasses.field(default_factory=list)
    deviations: list[str] = dataclasses.field(default_factory=list)
    provider: str = ""
    model: str = ""
    effort: str = ""
    raw_model_text: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "decision": self.decision,
            "verdict": "PASS" if self.decision == "accept" else "FAIL",
            "overall_score": round(float(self.overall_score), 4),
            "threshold": round(float(self.threshold), 4),
            "scoring_dimensions": {k: v.to_dict() for k, v in self.breakdown.items()},
            "reasoning": self.reasoning,
            "missing": list(self.missing),
            "deviations": list(self.deviations),
            "provider": self.provider,
            "model": self.model,
            "effort": self.effort,
        }


@dataclasses.dataclass
class LoopState:
    """The full state passed between stages. Each field is explicit."""

    session_id: str
    iteration: int
    original_prompt_hash: str
    current_output_hash: str
    evidence_bundle_hash: str
    provider: str
    model: str
    effort: str
    threshold: float
    decision: str = ""
    next_remediation_prompt: str = ""
    verifier_pass_at: str = ""
    pass_expires_at: str = ""

    def to_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


# ---------------------------------------------------------------------------
# Logging — one JSON line per stage, structured + greppable
# ---------------------------------------------------------------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log_stage(stage: str, payload: dict[str, Any]) -> None:
    """Append a structured stage log line. Never raises; never leaks secrets.

    Fix 5: Also records current_stage to the state file so the stop hook
    can read it and enforce the GCJ classification per stage.
    """
    _write_current_stage(stage)  # Fix 5: GCJ stage enforcement
    try:
        THINKING_LOG.parent.mkdir(parents=True, exist_ok=True)
        scrubbed = _scrub_secrets(payload)
        record = {"ts": now_iso(), "stage": stage, **scrubbed}
        with THINKING_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")
    except Exception:
        # Logging must never fail the loop.
        pass


def _write_current_stage(stage: str) -> None:
    """Fix 5: Write current GCJ stage to state file for stop hook GCJ enforcement."""
    try:
        state_file = Path.home() / ".claude" / "state" / "ralph-loop-infinite.local"
        state_file.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        if state_file.exists():
            lines = state_file.read_text(encoding="utf-8").splitlines()
        out_lines = []
        found = False
        for line in lines:
            if line.startswith("current_stage:"):
                out_lines.append(f"current_stage: {stage}")
                found = True
            else:
                out_lines.append(line)
        if not found:
            out_lines.append(f"current_stage: {stage}")
        state_file.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    except Exception:
        pass  # Must never fail
    try:
        THINKING_LOG.parent.mkdir(parents=True, exist_ok=True)
        scrubbed = _scrub_secrets(payload)
        record = {"ts": now_iso(), "stage": stage, **scrubbed}
        with THINKING_LOG.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")
    except Exception:
        # Logging must never fail the loop.
        pass


_SECRET_LOOKING_RX = re.compile(
    r"(?i)(api[_\-]?key|secret|token|password|authorization|bearer)"
)


def _scrub_secrets(payload: Any) -> Any:
    """Recursively strip values that look like secrets from a JSON-safe dict."""
    if isinstance(payload, dict):
        out: dict[str, Any] = {}
        for k, v in payload.items():
            if isinstance(k, str) and _SECRET_LOOKING_RX.search(k):
                out[k] = "<redacted>"
            else:
                out[k] = _scrub_secrets(v)
        return out
    if isinstance(payload, list):
        return [_scrub_secrets(x) for x in payload]
    if isinstance(payload, str):
        # Strip values that look like raw API keys (sk-..., ds-..., etc.)
        if re.match(r"^(sk-|ds-|sk_live|sk_test|ya29\.|gh[ps]_)", payload):
            return "<redacted>"
    return payload


# ---------------------------------------------------------------------------
# Provider credentials — explicit loading, never print values
# ---------------------------------------------------------------------------

def parse_env_file(path: Path) -> dict[str, str]:
    """Parse a simple KEY=VALUE env file. Quotes are stripped. Comments skipped."""
    out: dict[str, str] = {}
    if not path.exists():
        return out
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export ") :].strip()
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if (value.startswith('"') and value.endswith('"')) or (
                value.startswith("'") and value.endswith("'")
            ):
                value = value[1:-1]
            out[key] = value
    except OSError:
        pass
    return out


def load_key(env_name: str) -> tuple[str, str]:
    """Return (key, source). Empty key + "missing" if not found.

    Resolution order (deterministic, documented):
        1. Process env var ``env_name``
        2. ``RALPH_VERIFIER_<env_name>`` (legacy opt-in override)
        3. ``RALPH_VERIFIER_ENV_FILE`` (if set and readable)
        4. ``~/.claude/.env.production`` (the global env file the user owns)

    The key value is never logged — only the source name.
    """
    val = os.environ.get(env_name, "").strip()
    if val:
        return val, f"env:{env_name}"

    override_env = f"RALPH_VERIFIER_{env_name}"
    val = os.environ.get(override_env, "").strip()
    if val:
        return val, f"env:{override_env}"

    extra_file = os.environ.get("RALPH_VERIFIER_ENV_FILE", "").strip()
    if extra_file:
        p = Path(extra_file).expanduser()
        if p.is_file():
            extra = parse_env_file(p)
            val = extra.get(env_name, "").strip()
            if val:
                return val, f"file:{p}"

    if ENV_PRODUCTION.is_file():
        prod = parse_env_file(ENV_PRODUCTION)
        val = prod.get(env_name, "").strip()
        if val:
            return val, f"file:{ENV_PRODUCTION}"

    return "", "missing"


def key_fingerprint(key: str) -> str:
    if not key:
        return ""
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------------------
# Policy loader — single source of truth for provider/model
# ---------------------------------------------------------------------------

def load_policy_with_fallback() -> dict[str, Any]:
    """Read policy via the helper, layering in fallback defaults.

    The policy helper file is the canonical source; this function adds the
    fallback fields (model_fallback_provider, model_fallback, scoring_*) if
    the operator hasn't overridden them in settings.json yet. We never
    silently substitute the *primary* — only the fallback shape.
    """
    primary: dict[str, Any] = {
        "provider": DEFAULT_PROVIDER_PRIMARY,
        "model_primary": DEFAULT_MODEL_PRIMARY,
        "effort": DEFAULT_EFFORT,
    }
    if POLICY_HELPER.exists():
        try:
            import subprocess

            res = subprocess.run(
                [sys.executable, str(POLICY_HELPER), "current"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if res.returncode == 0 and res.stdout.strip():
                parsed = json.loads(res.stdout.strip())
                if isinstance(parsed, dict):
                    primary.update({k: v for k, v in parsed.items() if v is not None})
        except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
            pass

    primary.setdefault("model_fallback_provider", DEFAULT_PROVIDER_FALLBACK)
    primary.setdefault("model_fallback", DEFAULT_MODEL_FALLBACK)
    primary.setdefault(
        "fallback_policy",
        {
            "opus_4_7_and_deepseek": {
                "provider": DEFAULT_PROVIDER_FALLBACK,
                "model": DEFAULT_MODEL_FALLBACK,
            },
            "other_agents": {
                "provider": DEFAULT_PROVIDER_OTHER_FALLBACK,
                "model": DEFAULT_MODEL_OTHER_FALLBACK,
            },
        },
    )
    primary.setdefault("scoring_threshold", DEFAULT_THRESHOLD)
    primary.setdefault("scoring_dimensions", list(SCORING_DIMENSIONS))
    return primary


def fallback_for_lineage(policy: dict[str, Any], provider: str, model: str) -> tuple[str, str]:
    """Select the mandated fallback for the verifier lineage.

    MiniMax-M2.7 is the fallback for Opus 4.7 and Deepseek. GLM is the
    fallback for every other AI-agent lineage.
    """
    fp = policy.get("fallback_policy") if isinstance(policy.get("fallback_policy"), dict) else {}
    mm = fp.get("opus_4_7_and_deepseek", {}) if isinstance(fp, dict) else {}
    glm = fp.get("other_agents", {}) if isinstance(fp, dict) else {}
    provider_l = (provider or "").lower()
    model_l = (model or "").lower()
    if "opus-4-7" in model_l or "opus 4.7" in model_l or provider_l == "deepseek" or "deepseek" in model_l:
        return str(mm.get("provider") or DEFAULT_PROVIDER_FALLBACK), str(mm.get("model") or DEFAULT_MODEL_FALLBACK)
    return str(glm.get("provider") or DEFAULT_PROVIDER_OTHER_FALLBACK), str(glm.get("model") or DEFAULT_MODEL_OTHER_FALLBACK)


def provider_env_names(provider: str) -> tuple[str, ...]:
    p = (provider or "").lower()
    if p == "anthropic":
        return ("ANTHROPIC_API_KEY",)
    if p == "deepseek":
        return ("DEEPSEEK_API_KEY",)
    if p == "minimax":
        return ("MINIMAX_API_KEY",)
    if p in {"glm", "zai", "zhipu"}:
        return ("ZAI_API_KEY", "GLM_API_KEY", "ZHIPUAI_API_KEY")
    return (f"{p.upper()}_API_KEY",)


def load_first_key(names: tuple[str, ...]) -> tuple[str, str, str]:
    for name in names:
        key, source = load_key(name)
        if key:
            return key, source, name
    return "", "missing", names[0] if names else ""


# ---------------------------------------------------------------------------
# Prompt builders — Stage-1 critique/judge prompt + Stage-4 remediation prompt
# ---------------------------------------------------------------------------

CRITIQUE_JUDGE_SYSTEM_PROMPT = (
    "You are the Ralph-Loop-Infinite internal-thinking-loop judge.\n"
    "Inputs you receive in the user message:\n"
    "  1. ORIGINAL USER PROMPT (verbatim -- NEVER modified)\n"
    "  2. AGENT FINAL OUTPUT (the §3 exit report)\n"
    "  3. SEALED EVIDENCE BUNDLE (JSON of cited artifacts + hashes + state)\n"
    "\n"
    "Your job is to run two stages explicitly:\n"
    "  - CRITIQUE: list every issue, with severity (1-5) and a specific suggestion.\n"
    "  - JUDGE: score the five scoring dimensions (each 0.0-1.0):\n"
    "       completeness, correctness, clarity, depth, actionability.\n"
    "    Then choose a decision: accept (score >= threshold on EVERY dimension)\n"
    "    or revise (any dimension < threshold OR any required artifact missing).\n"
    "\n"
    "ANTI-WEAK-CRITICISM RULES (strictly enforced):\n"
    "  - Vague feedback (\"could be better\", \"not quite right\", \"needs improvement\", \"some gaps\")\n"
    "    is NOT a valid critique item -- it produces weak remediation that changes nothing.\n"
    "    Every issue MUST be concrete and specific: name the exact artifact, exact requirement,\n"
    "    exact dimension, and the exact gap between what was requested and what was delivered.\n"
    "  - Each issue MUST correspond to at least one scoring dimension that scored < threshold.\n"
    "    Issues that don't map to any failed dimension are non-actionable -- exclude them.\n"
    "  - Each suggestion MUST be actionable: a skilled developer reading it knows exactly what\n"
    "    file to open, what to change, and why. Vague suggestions (\"improve quality\", \"add more\")\n"
    "    are rejected and replaced with concrete ones.\n"
    "  - Severity 1-2 issues without corresponding dimension score < 0.8 are informational only\n"
    "    and MUST NOT dominate the critique.\n"
    "\n"
    "ANTI-LENIENCY RULES (strictly enforced -- the verifier is NOT your ally):\n"
    "  - Do NOT give credit for partial delivery. If any dimension is < threshold, the decision\n"
    "    MUST be 'revise'. There is no 'mostly complete', 'broadly correct', 'good enough'.\n"
    "  - Do NOT softenFAILs with neutral wording. Every missing required artifact is a concrete\n"
    "    deviation, not a footnote. Every dimension below threshold is a FAIL condition, not a\n"
    "    'minor concern' or 'suggested improvement'.\n"
    "  - The agent's §3 exit report is a self-assessment -- it is NOT evidence of quality.\n"
    "    You verify against the ORIGINAL USER PROMPT, not against what the agent said it did.\n"
    "  - Any attempt by the agent to claim credit for work not evidenced in the artifact bundle\n"
    "    is a deviation. Claiming tests passed that aren't in the evidence is a deviation.\n"
    "  - If two or more dimensions score below threshold, the overall decision is automatically\n"
    "    'revise' -- do not pass on an average. Average掩盖 failure.\n"
    "\n"
    "Mandatory rules:\n"
    "  - Judge artifacts in the evidence bundle, not prose alone.\n"
    "  - Cited artifacts that the bundle reports as missing -> automatic FAIL.\n"
    "  - 'Looks good', 'should work', 'appears to pass' -> FAIL words.\n"
    "  - X requested -> Y delivered -> FAIL with a deviation.\n"
    "  - You CANNOT be persuaded by the agent's prose -- verify against the original prompt.\n"
    "  - If you cannot identify at least one concrete specific issue for every failed dimension,\n"
    "    return 'missing: [\"critique lacks specificity for dimension X\"]' instead.\n"
    "\n"
    "Return STRICT JSON ONLY (no markdown, no commentary):\n"
    "{\n"
    "  \"critique\": {\n"
    "    \"issues\": [\"<specific issue>\"],\n"
    "    \"severity\": [1-5, ...],\n"
    "    \"suggestions\": [\"<concrete actionable fix>\"]\n"
    "  },\n"
    "  \"scoring_dimensions\": {\n"
    "    \"completeness\":   {\"score\": <float 0.0-1.0>, \"evidence\": \"<rationale>\"},\n"
    "    \"correctness\":    {\"score\": <float 0.0-1.0>, \"evidence\": \"<rationale>\"},\n"
    "    \"clarity\":        {\"score\": <float 0.0-1.0>, \"evidence\": \"<rationale>\"},\n"
    "    \"depth\":          {\"score\": <float 0.0-1.0>, \"evidence\": \"<rationale>\"},\n"
    "    \"actionability\":  {\"score\": <float 0.0-1.0>, \"evidence\": \"<rationale>\"}\n"
    "  },\n"
    "  \"decision\": \"accept\"|\"revise\",\n"
    "  \"overall_score\": <float 0.0-1.0>,\n"
    "  \"reasoning\": \"...\n"
    "  \"missing\": [\"...\"],\n"
    "  \"deviations\": [\"...\"]\n"
    "}\n"
)


def build_user_message(
    *,
    original_prompt: str,
    agent_output: str,
    evidence_bundle_json: str,
    threshold: float,
) -> str:
    return (
        f"=== THRESHOLD ===\n{threshold}\n\n"
        f"=== ORIGINAL USER PROMPT (verbatim) ===\n{original_prompt}\n\n"
        f"=== AGENT FINAL OUTPUT ===\n{agent_output}\n\n"
        f"=== SEALED EVIDENCE BUNDLE (JSON) ===\n{evidence_bundle_json}\n"
    )


REMEDIATION_TEMPLATE = (
    "You are improving an existing output based on a critique.\n"
    "\n"
    "Original Output:\n{generated_content}\n"
    "\n"
    "Identified Issues:\n{issues}\n"
    "\n"
    "Suggested Fixes:\n{suggestions}\n"
    "\n"
    "Instructions:\n"
    "- Fix each issue explicitly\n"
    "- Do NOT rewrite the entire response\n"
    "- Preserve correct and useful parts\n"
    "- Improve clarity and depth only where needed\n"
    "- Avoid introducing new information unless required\n"
    "\n"
    "Return the improved version.\n"
)


def build_remediation_prompt(
    *, original_user_prompt: str, generated: Generated, critique: Critique
) -> str:
    """Build the targeted remediation prompt.

    The original user prompt is preserved verbatim at the top of the prompt;
    the remediation block below anchors the agent to the prior output and the
    critique. This matches the canonical template from the blog/PDF (R-1,R-3).
    """
    issues = "\n".join(f"- {i}" for i in critique.issues) or "- (no specific issues)"
    suggestions = (
        "\n".join(f"- {s}" for s in critique.suggestions) or "- (no specific suggestions)"
    )
    body = REMEDIATION_TEMPLATE.format(
        generated_content=generated.content.rstrip(),
        issues=issues,
        suggestions=suggestions,
    )
    header = (
        "=== ORIGINAL USER PROMPT (verbatim -- DO NOT MODIFY) ===\n"
        f"{original_user_prompt}\n"
        "=== END ORIGINAL USER PROMPT ===\n\n"
    )
    return header + body


# ---------------------------------------------------------------------------
# Provider calls — Anthropic/Deepseek primary lineages fall back to MiniMax-M2.7;
# all other AI-agent lineages fall back to GLM. Pure stdlib HTTP.
# ---------------------------------------------------------------------------

class ProviderError(RuntimeError):
    """Raised when a provider call fails so the caller can choose to fall back."""


def _post_json(
    *, url: str, headers: dict[str, str], body: dict[str, Any], timeout: int
) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url=url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            err_body = ""
        raise ProviderError(f"HTTP {exc.code} {exc.reason}: {err_body[:400]}")
    except urllib.error.URLError as exc:
        raise ProviderError(f"URL error: {exc}")
    except (TimeoutError, OSError) as exc:
        raise ProviderError(f"timeout/io: {exc}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProviderError(f"non-JSON response: {raw[:200]}: {exc}")


def call_anthropic(
    *, key: str, model: str, system: str, user: str, timeout: int = DEFAULT_TIMEOUT_S
) -> str:
    if not key:
        raise ProviderError("anthropic key missing")
    body = {
        "model": model,
        "max_tokens": 2048,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }
    headers = {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    resp = _post_json(
        url="https://api.anthropic.com/v1/messages",
        headers=headers,
        body=body,
        timeout=timeout,
    )
    if "error" in resp:
        raise ProviderError(f"anthropic error: {json.dumps(resp['error'])[:300]}")
    try:
        return str(resp["content"][0]["text"])
    except (KeyError, IndexError, TypeError) as exc:
        raise ProviderError(f"anthropic shape: {exc}; raw={json.dumps(resp)[:200]}")


def call_deepseek(
    *, key: str, model: str, system: str, user: str, timeout: int = DEFAULT_TIMEOUT_S
) -> str:
    if not key:
        raise ProviderError("deepseek key missing")
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "max_tokens": 2048,
    }
    headers = {
        "authorization": f"Bearer {key}",
        "content-type": "application/json",
    }
    resp = _post_json(
        url="https://api.deepseek.com/chat/completions",
        headers=headers,
        body=body,
        timeout=timeout,
    )
    if "error" in resp:
        raise ProviderError(f"deepseek error: {json.dumps(resp['error'])[:300]}")
    try:
        return str(resp["choices"][0]["message"]["content"])
    except (KeyError, IndexError, TypeError) as exc:
        raise ProviderError(f"deepseek shape: {exc}; raw={json.dumps(resp)[:200]}")


def call_openai_compatible(
    *, provider: str, key: str, model: str, system: str, user: str, url: str, timeout: int = DEFAULT_TIMEOUT_S
) -> str:
    if not key:
        raise ProviderError(f"{provider} key missing")
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "max_tokens": 2048,
    }
    headers = {"authorization": f"Bearer {key}", "content-type": "application/json"}
    resp = _post_json(url=url, headers=headers, body=body, timeout=timeout)
    if "error" in resp:
        raise ProviderError(f"{provider} error: {json.dumps(resp['error'])[:300]}")
    try:
        return str(resp["choices"][0]["message"]["content"])
    except (KeyError, IndexError, TypeError) as exc:
        raise ProviderError(f"{provider} shape: {exc}; raw={json.dumps(resp)[:200]}")


def call_minimax(
    *, key: str, model: str, system: str, user: str, timeout: int = DEFAULT_TIMEOUT_S
) -> str:
    # MiniMax's current public API exposes OpenAI-compatible chat completions.
    return call_openai_compatible(
        provider="minimax",
        key=key,
        model=model,
        system=system,
        user=user,
        url=os.environ.get("MINIMAX_BASE_URL", "https://api.minimax.chat/v1/chat/completions"),
        timeout=timeout,
    )


def call_glm(
    *, key: str, model: str, system: str, user: str, timeout: int = DEFAULT_TIMEOUT_S
) -> str:
    # GLM/Z.ai also supports OpenAI-compatible chat completions.
    return call_openai_compatible(
        provider="glm",
        key=key,
        model=model,
        system=system,
        user=user,
        url=os.environ.get("GLM_BASE_URL", os.environ.get("ZAI_BASE_URL", "https://open.bigmodel.cn/api/paas/v4/chat/completions")),
        timeout=timeout,
    )


def call_provider(provider: str, *, key: str, model: str, system: str, user: str) -> str:
    p = (provider or "").lower()
    if p == "anthropic":
        return call_anthropic(key=key, model=model, system=system, user=user)
    if p == "deepseek":
        return call_deepseek(key=key, model=model, system=system, user=user)
    if p == "minimax":
        return call_minimax(key=key, model=model, system=system, user=user)
    if p in {"glm", "zai", "zhipu"}:
        return call_glm(key=key, model=model, system=system, user=user)
    raise ProviderError(f"unsupported provider: {provider}")


# ---------------------------------------------------------------------------
# Stage runners
# ---------------------------------------------------------------------------

def critique_and_judge(
    *,
    original_prompt: str,
    agent_output: str,
    evidence_bundle_json: str,
    policy: dict[str, Any],
    session_id: str,
    iteration: int,
    forced_fail: bool = False,
    fake_anthropic_failure: bool = False,
    fake_deepseek_failure: bool = False,
    fake_minimax_failure: bool = False,
    fake_glm_failure: bool = False,
) -> tuple[Critique, Judgement, str]:
    """Run the explicit Critique + Judge stages.

    Returns (critique, judgement, raw_model_text). Provider fallback is logged
    at every step; if both providers fail the judgement is FAIL with an
    explicit reason.
    """
    threshold = float(policy.get("scoring_threshold", DEFAULT_THRESHOLD))
    primary_provider = str(policy.get("provider", DEFAULT_PROVIDER_PRIMARY))
    primary_model = str(policy.get("model_primary", DEFAULT_MODEL_PRIMARY))
    configured_fallback_provider = str(policy.get("model_fallback_provider", DEFAULT_PROVIDER_FALLBACK))
    configured_fallback_model = str(policy.get("model_fallback", DEFAULT_MODEL_FALLBACK))
    required_fallback_provider, required_fallback_model = fallback_for_lineage(policy, primary_provider, primary_model)
    # The mandated fallback policy takes precedence over legacy settings. A
    # configured fallback is appended only when it differs, preserving operator
    # visibility without weakening the required MiniMax/GLM chain.
    provider_chain: list[tuple[str, str, bool]] = [(primary_provider, primary_model, False)]
    provider_chain.append((required_fallback_provider, required_fallback_model, True))
    if (configured_fallback_provider, configured_fallback_model) not in [
        (p, m) for p, m, _ in provider_chain
    ]:
        provider_chain.append((configured_fallback_provider, configured_fallback_model, True))
    effort = str(policy.get("effort", DEFAULT_EFFORT))

    user_msg = build_user_message(
        original_prompt=original_prompt,
        agent_output=agent_output,
        evidence_bundle_json=evidence_bundle_json,
        threshold=threshold,
    )
    log_stage(
        "judge_input",
        {
            "session_id": session_id,
            "iteration": iteration,
            "policy": {
                "provider_primary": primary_provider,
                "model_primary": primary_model,
                "provider_fallback": required_fallback_provider,
                "model_fallback": required_fallback_model,
                "configured_provider_fallback": configured_fallback_provider,
                "configured_model_fallback": configured_fallback_model,
                "provider_chain": [
                    {"provider": p, "model": m, "fallback": fb} for p, m, fb in provider_chain
                ],
                "threshold": threshold,
                "effort": effort,
            },
            "original_prompt_hash": hashlib.sha256(original_prompt.encode("utf-8")).hexdigest(),
            "agent_output_hash": hashlib.sha256(agent_output.encode("utf-8")).hexdigest(),
            "evidence_bundle_bytes": len(evidence_bundle_json.encode("utf-8")),
        },
    )

    if forced_fail:
        log_stage("judge_forced_fail", {"session_id": session_id, "iteration": iteration})
        return _forced_fail_outputs(
            threshold=threshold, provider=primary_provider, model=primary_model, effort=effort
        )

    raw_text = ""
    used_provider = primary_provider
    used_model = primary_model
    fake_failure = {
        "anthropic": fake_anthropic_failure,
        "deepseek": fake_deepseek_failure,
        "minimax": fake_minimax_failure,
        "glm": fake_glm_failure,
        "zai": fake_glm_failure,
        "zhipu": fake_glm_failure,
    }

    # Try primary, then mandated fallback(s). Every skip/failure is logged so
    # fallback is never a silent downgrade.
    for provider, model, is_fallback in provider_chain:
        provider_l = provider.lower()
        if raw_text:
            break
        if fake_failure.get(provider_l, False):
            log_stage(
                "provider_fail",
                {
                    "provider": provider,
                    "model": model,
                    "error": "forced fake failure",
                    "fallback": is_fallback,
                    "session_id": session_id,
                    "iteration": iteration,
                },
            )
            continue
        key, source, key_name = load_first_key(provider_env_names(provider))
        log_stage(
            "provider_attempt",
            {
                "provider": provider,
                "model": model,
                "key_name": key_name,
                "key_source": source,
                "key_fingerprint": key_fingerprint(key),
                "session_id": session_id,
                "iteration": iteration,
                "fallback": is_fallback,
            },
        )
        if not key:
            log_stage(
                "provider_skip",
                {
                    "provider": provider,
                    "model": model,
                    "reason": "no api key",
                    "fallback": is_fallback,
                    "session_id": session_id,
                    "iteration": iteration,
                },
            )
            continue
        try:
            raw_text = call_provider(
                provider,
                key=key,
                model=model,
                system=CRITIQUE_JUDGE_SYSTEM_PROMPT,
                user=user_msg,
            )
            used_provider = provider
            used_model = model
            log_stage(
                "provider_ok",
                {"provider": used_provider, "model": used_model, "response_bytes": len(raw_text), "fallback": is_fallback},
            )
        except ProviderError as exc:
            log_stage(
                "provider_fail",
                {"provider": provider, "model": model, "error": str(exc)[:400], "fallback": is_fallback},
            )
            raw_text = ""

    if not raw_text:
        log_stage(
            "judge_all_providers_failed",
            {"session_id": session_id, "iteration": iteration, "provider_chain": [p for p, _, _ in provider_chain]},
        )
        critique = Critique(
            issues=["all configured providers unavailable; no judgement could be formed"],
            severity=[5],
            suggestions=["restore provider API keys in ~/.claude/.env.production"],
            raw_rationale="",
        )
        judgement = Judgement(
            decision="revise",
            overall_score=0.0,
            threshold=threshold,
            breakdown={d: DimensionScore(0.0, "no judgement formed") for d in SCORING_DIMENSIONS},
            reasoning="all configured verifier providers failed; failing closed",
            missing=["judgement"],
            deviations=[],
            provider="",
            model="",
            effort=effort,
            raw_model_text="",
        )
        return critique, judgement, ""

    critique, judgement = parse_model_output(
        raw_text=raw_text,
        threshold=threshold,
        provider=used_provider,
        model=used_model,
        effort=effort,
    )
    log_stage(
        "judge_output",
        {
            "session_id": session_id,
            "iteration": iteration,
            "decision": judgement.decision,
            "overall_score": judgement.overall_score,
            "scoring_dimensions": {k: v.to_dict() for k, v in judgement.breakdown.items()},
            "missing": judgement.missing,
            "deviations": judgement.deviations,
            "provider": judgement.provider,
            "model": judgement.model,
        },
    )
    return critique, judgement, raw_text


def _forced_fail_outputs(
    *, threshold: float, provider: str, model: str, effort: str
) -> tuple[Critique, Judgement, str]:
    critique = Critique(
        issues=["forced FAIL via RALPH_FORCE_FAIL"],
        severity=[5],
        suggestions=["unset RALPH_FORCE_FAIL"],
        raw_rationale="forced",
    )
    judgement = Judgement(
        decision="revise",
        overall_score=0.0,
        threshold=threshold,
        breakdown={d: DimensionScore(0.0, "forced") for d in SCORING_DIMENSIONS},
        reasoning="forced FAIL",
        missing=["forced fail"],
        deviations=[],
        provider=provider,
        model=model,
        effort=effort,
        raw_model_text="",
    )
    return critique, judgement, ""


# ---------------------------------------------------------------------------
# Parser — extract critique + judgement from a JSON-leaning model response
# ---------------------------------------------------------------------------

def parse_model_output(
    *, raw_text: str, threshold: float, provider: str, model: str, effort: str
) -> tuple[Critique, Judgement]:
    raw_text = raw_text.strip()
    obj: dict[str, Any] | None = None
    decoder = json.JSONDecoder()
    try:
        obj, _ = decoder.raw_decode(raw_text)
    except json.JSONDecodeError:
        idx = raw_text.find("{")
        if idx >= 0:
            try:
                obj, _ = decoder.raw_decode(raw_text[idx:])
            except json.JSONDecodeError:
                obj = None
    if not isinstance(obj, dict):
        critique = Critique(issues=["model returned unparseable text"], severity=[5])
        judgement = Judgement(
            decision="revise",
            overall_score=0.0,
            threshold=threshold,
            breakdown={d: DimensionScore(0.0, "no JSON") for d in SCORING_DIMENSIONS},
            reasoning="model output did not contain JSON",
            missing=["judgement-json"],
            deviations=[],
            provider=provider,
            model=model,
            effort=effort,
            raw_model_text=raw_text[:500],
        )
        return critique, judgement

    crit_obj = obj.get("critique") if isinstance(obj.get("critique"), dict) else {}
    issues = list(crit_obj.get("issues") or [])
    suggestions = list(crit_obj.get("suggestions") or [])
    severity = [int(x) for x in (crit_obj.get("severity") or []) if isinstance(x, (int, float))]
    critique = Critique(
        issues=[str(i)[:400] for i in issues],
        severity=severity,
        suggestions=[str(s)[:400] for s in suggestions],
        raw_rationale=str(obj.get("reasoning", ""))[:1000],
    )

    sd_obj = obj.get("scoring_dimensions")
    breakdown: dict[str, DimensionScore] = {}
    if isinstance(sd_obj, dict):
        for dim in SCORING_DIMENSIONS:
            cell = sd_obj.get(dim)
            if isinstance(cell, dict):
                try:
                    score = float(cell.get("score", 0.0))
                except (TypeError, ValueError):
                    score = 0.0
                ev = str(cell.get("evidence", ""))[:400]
            else:
                score = 0.0
                ev = "missing"
            breakdown[dim] = DimensionScore(max(0.0, min(1.0, score)), ev)
    else:
        for dim in SCORING_DIMENSIONS:
            breakdown[dim] = DimensionScore(0.0, "missing scoring_dimensions")

    raw_decision = str(obj.get("decision", "")).strip().lower()
    overall_score_raw = obj.get("overall_score")
    try:
        overall_score = float(overall_score_raw)
    except (TypeError, ValueError):
        overall_score = sum(d.score for d in breakdown.values()) / len(breakdown)
    overall_score = max(0.0, min(1.0, overall_score))

    missing = obj.get("missing") if isinstance(obj.get("missing"), list) else []
    deviations = obj.get("deviations") if isinstance(obj.get("deviations"), list) else []

    threshold_violated = any(d.score < threshold for d in breakdown.values())
    structural_issue = bool(missing) or bool(deviations)

    if raw_decision == "accept" and (threshold_violated or structural_issue):
        raw_decision = "revise"
    if raw_decision not in {"accept", "revise"}:
        raw_decision = "revise" if (threshold_violated or structural_issue) else "accept"

    judgement = Judgement(
        decision=raw_decision,
        overall_score=overall_score,
        threshold=threshold,
        breakdown=breakdown,
        reasoning=str(obj.get("reasoning", ""))[:1000],
        missing=[str(m)[:400] for m in missing],
        deviations=[str(d)[:400] for d in deviations],
        provider=provider,
        model=model,
        effort=effort,
        raw_model_text=raw_text[:2000],
    )
    return critique, judgement


# ---------------------------------------------------------------------------
# CLI surface
# ---------------------------------------------------------------------------

def _read(path_str: str) -> str:
    if not path_str:
        return ""
    p = Path(path_str)
    if not p.exists():
        return ""
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def cmd_judge(args: argparse.Namespace) -> int:
    original_prompt = _read(args.original_prompt_file)
    agent_output = _read(args.agent_output_file)
    bundle = _read(args.evidence_bundle_file)
    if not bundle:
        bundle = "{}"
    policy = load_policy_with_fallback()

    forced = os.environ.get("RALPH_FORCE_FAIL", "0") == "1"
    fake_a = os.environ.get("RALPH_FAKE_ANTHROPIC_FAIL", "0") == "1"
    fake_d = os.environ.get("RALPH_FAKE_DEEPSEEK_FAIL", "0") == "1"
    fake_m = os.environ.get("RALPH_FAKE_MINIMAX_FAIL", "0") == "1"
    fake_g = os.environ.get("RALPH_FAKE_GLM_FAIL", "0") == "1"

    critique, judgement, _ = critique_and_judge(
        original_prompt=original_prompt,
        agent_output=agent_output,
        evidence_bundle_json=bundle,
        policy=policy,
        session_id=args.session_id,
        iteration=args.iteration,
        forced_fail=forced,
        fake_anthropic_failure=fake_a,
        fake_deepseek_failure=fake_d,
        fake_minimax_failure=fake_m,
        fake_glm_failure=fake_g,
    )
    out = {
        "session_id": args.session_id,
        "iteration": args.iteration,
        "critique": {
            "issues": critique.issues,
            "severity": critique.severity,
            "suggestions": critique.suggestions,
        },
        **judgement.to_dict(),
        "original_prompt_hash": hashlib.sha256(original_prompt.encode("utf-8")).hexdigest(),
        "agent_output_hash": hashlib.sha256(agent_output.encode("utf-8")).hexdigest(),
        "evidence_bundle_bytes": len(bundle.encode("utf-8")),
    }
    print(json.dumps(out, separators=(",", ":")))
    return 0


def cmd_remediation(args: argparse.Namespace) -> int:
    original_prompt = _read(args.original_prompt_file)
    agent_output = _read(args.agent_output_file)
    critique_obj: dict[str, Any] = {}
    if args.critique_file:
        try:
            critique_obj = json.loads(_read(args.critique_file) or "{}")
        except json.JSONDecodeError:
            critique_obj = {}
    issues = critique_obj.get("issues") or []
    suggestions = critique_obj.get("suggestions") or []
    if isinstance(critique_obj.get("critique"), dict):
        inner = critique_obj["critique"]
        issues = issues or inner.get("issues") or []
        suggestions = suggestions or inner.get("suggestions") or []

    critique = Critique(
        issues=[str(i)[:400] for i in issues],
        suggestions=[str(s)[:400] for s in suggestions],
    )
    generated = Generated(content=agent_output)
    prompt_text = build_remediation_prompt(
        original_user_prompt=original_prompt,
        generated=generated,
        critique=critique,
    )
    log_stage(
        "remediation_prompt_built",
        {
            "session_id": args.session_id,
            "iteration": args.iteration,
            "issue_count": len(critique.issues),
            "suggestion_count": len(critique.suggestions),
            "remediation_prompt_bytes": len(prompt_text.encode("utf-8")),
        },
    )
    if args.output_file:
        Path(args.output_file).write_text(prompt_text, encoding="utf-8")
    print(prompt_text)
    return 0


def cmd_creds_check(args: argparse.Namespace) -> int:
    keys = ("ANTHROPIC_API_KEY", "DEEPSEEK_API_KEY", "MINIMAX_API_KEY", "ZAI_API_KEY", "GLM_API_KEY")
    report: dict[str, Any] = {"env_file": str(ENV_PRODUCTION), "providers": {}}
    for k in keys:
        v, src = load_key(k)
        report["providers"][k] = {
            "present": bool(v),
            "source": src,
            "fingerprint": key_fingerprint(v),
        }
    print(json.dumps(report, indent=2))
    return 0


def cmd_self_test(args: argparse.Namespace) -> int:
    failures: list[str] = []

    expected = ("completeness", "correctness", "clarity", "depth", "actionability")
    if SCORING_DIMENSIONS != expected:
        failures.append(f"SCORING_DIMENSIONS drift: {SCORING_DIMENSIONS}")

    gen = Generated(content="hello world")
    crit = Critique(issues=["issue A"], suggestions=["fix A"])
    prompt = build_remediation_prompt(
        original_user_prompt="ORIG", generated=gen, critique=crit
    )
    for needle in (
        "ORIGINAL USER PROMPT (verbatim -- DO NOT MODIFY)",
        "Original Output:",
        "hello world",
        "Identified Issues:",
        "- issue A",
        "Suggested Fixes:",
        "- fix A",
        "Do NOT rewrite the entire response",
    ):
        if needle not in prompt:
            failures.append(f"remediation prompt missing '{needle}'")

    raw = json.dumps(
        {
            "critique": {"issues": ["x"], "severity": [3], "suggestions": ["y"]},
            "scoring_dimensions": {
                "completeness": {"score": 0.95, "evidence": "all in"},
                "correctness": {"score": 0.95, "evidence": "matches"},
                "clarity": {"score": 0.7, "evidence": "could improve"},
                "depth": {"score": 0.9, "evidence": "good"},
                "actionability": {"score": 0.9, "evidence": "good"},
            },
            "decision": "accept",
            "overall_score": 0.88,
            "reasoning": "looks close",
            "missing": [],
            "deviations": [],
        }
    )
    _, j = parse_model_output(
        raw_text=raw, threshold=0.8, provider="anthropic", model="claude-opus-4-7", effort="max"
    )
    if j.decision != "revise":
        failures.append("parser failed to override accept when a dim < 0.8")

    scrubbed = _scrub_secrets({"api_key": "sk-abc", "ok": "value", "nested": {"token": "ds-xyz"}})
    if scrubbed.get("api_key") != "<redacted>" or scrubbed["nested"].get("token") != "<redacted>":
        failures.append("scrub_secrets failed to redact key/token keys")
    if scrubbed.get("ok") != "value":
        failures.append("scrub_secrets dropped non-secret value")

    tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"rli-env-{os.getpid()}.env"
    tmp.write_text("export FOO=\"bar baz\"\n# comment\nBAR=qux\n", encoding="utf-8")
    parsed = parse_env_file(tmp)
    tmp.unlink(missing_ok=True)
    if parsed.get("FOO") != "bar baz" or parsed.get("BAR") != "qux":
        failures.append(f"parse_env_file failed: {parsed}")

    pol = load_policy_with_fallback()
    if "model_fallback" not in pol or "scoring_threshold" not in pol:
        failures.append(f"policy fallback fields missing: {pol}")
    fb1 = fallback_for_lineage(pol, "anthropic", "claude-opus-4-7")
    fb2 = fallback_for_lineage(pol, "deepseek", "deepseek-v4-pro")
    fb3 = fallback_for_lineage(pol, "openai", "gpt-5")
    if fb1 != ("minimax", "minimax-m2.7") or fb2 != ("minimax", "minimax-m2.7"):
        failures.append(f"MiniMax fallback policy wrong: opus={fb1} deepseek={fb2}")
    if fb3[0] != "glm" or not fb3[1].startswith("glm"):
        failures.append(f"GLM fallback policy wrong for other agents: {fb3}")

    raw_no_validation = json.dumps({"decision": "accept", "overall_score": 1.0})
    _, j_no_val = parse_model_output(
        raw_text=raw_no_validation, threshold=0.8, provider="anthropic", model="claude-opus-4-7", effort="max"
    )
    if j_no_val.decision != "revise":
        failures.append("PASS remained possible without scoring_dimensions validation result")

    _, j2, _ = critique_and_judge(
        original_prompt="p", agent_output="o", evidence_bundle_json="{}",
        policy={"provider": "anthropic", "model_primary": "claude-opus-4-7"},
        session_id="self-test", iteration=1, forced_fail=True,
    )
    if j2.decision != "revise" or j2.overall_score != 0.0 or j2.provider != "anthropic":
        failures.append(f"forced_fail path wrong: {j2}")

    if failures:
        print(json.dumps({"status": "FAIL", "failures": failures}, indent=2))
        return 1
    print(json.dumps({"status": "PASS", "tests_run": 10}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Ralph-loop-infinite internal thinking loop")
    sub = parser.add_subparsers(dest="cmd")

    p_j = sub.add_parser("judge", help="run critique+judge and emit Judgement JSON")
    p_j.add_argument("--original-prompt-file", required=True)
    p_j.add_argument("--agent-output-file", required=True)
    p_j.add_argument("--evidence-bundle-file", default="")
    p_j.add_argument("--session-id", required=True)
    p_j.add_argument("--iteration", type=int, required=True)

    p_r = sub.add_parser("remediation", help="emit the canonical remediation prompt")
    p_r.add_argument("--original-prompt-file", required=True)
    p_r.add_argument("--agent-output-file", required=True)
    p_r.add_argument("--critique-file", default="")
    p_r.add_argument("--output-file", default="")
    p_r.add_argument("--session-id", required=True)
    p_r.add_argument("--iteration", type=int, required=True)

    sub.add_parser("creds-check", help="report which provider keys load (no values)")
    sub.add_parser("self-test", help="run pure-python tests")

    args = parser.parse_args()
    if not args.cmd:
        parser.print_help()
        return 2

    if args.cmd == "judge":
        return cmd_judge(args)
    if args.cmd == "remediation":
        return cmd_remediation(args)
    if args.cmd == "creds-check":
        return cmd_creds_check(args)
    if args.cmd == "self-test":
        return cmd_self_test(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
