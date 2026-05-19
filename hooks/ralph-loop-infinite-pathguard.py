#!/usr/bin/env python3
"""ralph-loop-infinite-pathguard.py — Canonical path policy decisions.

F-09 / F-15 remediation: pretool.sh previously matched protected paths via
regexes that missed symlinks, relative paths, $HOME / ~ variants, and quoted
shell forms. This helper:

* canonicalises an arbitrary path-like input via ``os.path.realpath`` after
  ``~`` and ``$HOME`` substitution,
* matches it against a single denylist of protected roots,
* understands plain Bash command strings well enough to extract redirection
  targets and the first positional argument to common file readers
  (``cat``, ``less``, ``head``, ``tail``, ``shasum``, ``openssl``,
  ``security find-generic-password``, ``cp``, ``mv``, ``rm``, ``tee``,
  ``sed -i``, etc.).

Subcommands
-----------
* ``classify-path PATH``  → exit 0 + ``allow`` / 1 + ``deny:<reason>``
* ``classify-bash CMD``   → same, but inspects every plausible path/redirection
                            target in ``CMD``

This helper is intentionally conservative: when in doubt it denies and
explains why. Hooks treat a non-zero exit as a deny verdict.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import sys
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))


def _denylist_roots() -> list[Path]:
    roots = [
        HOME / ".claude" / "secrets",
        HOME / ".claude" / "state",
        HOME / ".claude" / "manifest",
        HOME / ".claude" / "hooks",
        HOME / ".claude" / "tasks",
        HOME / ".claude" / "orchestrator",
        HOME / ".claude" / "verifier",
        HOME / ".codex" / "secrets",
        HOME / ".cursor" / "secrets",
    ]
    return [r for r in roots]


def _denylist_files() -> list[Path]:
    files = [
        HOME / ".claude" / "CLAUDE.md",
        HOME / ".claude" / "AGENTS.md",
        HOME / ".claude" / "settings.json",
        HOME / ".claude" / "settings.local.json",
        HOME / ".claude" / "plugins" / "ralph-gate.ts",
        HOME / ".codex" / "CLAUDE.md",
        HOME / ".codex" / "AGENTS.md",
        HOME / ".codex" / "plugins" / "ralph-gate.ts",
        HOME / ".codex" / "plugins" / "ralph-gate.config.ts",
        HOME / ".cursor" / "rules" / "ralph-loop-infinite.mdc",
        HOME / ".cursor" / "hooks.json",
        HOME / "CLAUDE.md",
        HOME / "AGENTS.md",
    ]
    return files


def _denylist_substrings() -> list[str]:
    return [
        "ralph-hmac.key",
        "ralph-loop-infinite.local",
        "ralph-loop-outsiders.local",
        "ralph-loop-monitors.local",
        "ralph-loop-infinite.sqlite3",
        "contract-hashes.json",
        "allowed_workers",
    ]


_HOME_TILDE_RX = re.compile(r"(?:^|(?<=[\s\"\'=:]))~(/|$)")
_HOME_VAR_RX = re.compile(r"\$\{?HOME\}?")


def _canonicalise(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    # Strip surrounding quotes if present
    if (raw.startswith("\"") and raw.endswith("\"")) or (raw.startswith("'") and raw.endswith("'")):
        raw = raw[1:-1]
    # Substitute ~ and $HOME
    raw = _HOME_TILDE_RX.sub(str(HOME) + r"\1", raw)
    raw = _HOME_VAR_RX.sub(str(HOME), raw)
    raw = os.path.expandvars(raw)
    raw = os.path.expanduser(raw)
    try:
        absolute = os.path.realpath(raw)
    except (OSError, ValueError):
        absolute = os.path.abspath(raw)
    return absolute


def _is_within(child: str, parent: Path) -> bool:
    try:
        Path(child).resolve(strict=False).relative_to(parent.resolve(strict=False))
        return True
    except Exception:
        return False


def classify_path(raw: str) -> tuple[str, str]:
    """Return ('allow'|'deny', reason)."""
    if not raw:
        return "allow", "empty path"
    abs_path = _canonicalise(raw)
    if not abs_path:
        return "allow", "empty after canonicalise"
    # Direct match against protected files
    for f in _denylist_files():
        if abs_path == str(f.resolve(strict=False)):
            return "deny", f"protected file {abs_path}"
    # Substring matches (handles non-existent paths and weird encodings)
    for needle in _denylist_substrings():
        if needle in abs_path or needle in raw:
            return "deny", f"protected substring '{needle}' in path"
    # Root containment
    for root in _denylist_roots():
        if _is_within(abs_path, root):
            return "deny", f"path under protected root {root}"
    return "allow", "ok"


_BASH_READ_TARGETS = {
    "cat", "less", "more", "head", "tail", "shasum", "sha256sum",
    "md5", "md5sum", "openssl", "xxd", "od", "strings",
    "grep", "rg", "egrep", "fgrep", "ack", "ag",
    "cp", "mv", "rm", "tee", "ln", "install",
}


def _iter_tokens(cmd: str) -> list[str]:
    try:
        return shlex.split(cmd, posix=True)
    except ValueError:
        # Fall back to a naive whitespace split on lex failure
        return cmd.split()


def classify_bash(cmd: str) -> tuple[str, str]:
    if not cmd or not cmd.strip():
        return "allow", "empty cmd"
    # Quick substring guard for raw secret references
    for needle in _denylist_substrings():
        if needle in cmd:
            return "deny", f"command references protected substring '{needle}'"
    # Tokenise and inspect each token
    tokens = _iter_tokens(cmd)
    for token in tokens:
        if not token or token in {"|", "||", "&&", ";", "(", ")", "&"}:
            continue
        # Redirection: >, >>, < etc. become their own token after shlex if quoted;
        # otherwise embedded in the previous token. Handle both.
        stripped = token.lstrip("<>")
        # Skip flags and option-style tokens
        if stripped.startswith("-") and "/" not in stripped:
            continue
        if stripped in _BASH_READ_TARGETS:
            continue
        if "/" in stripped or stripped.startswith("~") or stripped.startswith("$"):
            decision, reason = classify_path(stripped)
            if decision == "deny":
                return decision, reason
    # `security find-generic-password ... ralph-gate-hmac`
    if "security" in tokens and "find-generic-password" in cmd and "ralph-gate-hmac" in cmd:
        return "deny", "macOS Keychain query for ralph-gate-hmac"
    return "allow", "ok"


def main() -> int:
    parser = argparse.ArgumentParser(description="ralph-loop-infinite path guard")
    sub = parser.add_subparsers(dest="cmd")

    p1 = sub.add_parser("classify-path", help="canonicalise + classify a single path")
    p1.add_argument("path")

    p2 = sub.add_parser("classify-bash", help="classify a bash command string")
    p2.add_argument("cmd")

    args = parser.parse_args()
    if not args.cmd:
        parser.print_help()
        return 2

    if args.cmd == "classify-path":
        decision, reason = classify_path(args.path)
    else:
        decision, reason = classify_bash(args.cmd)
    print(f"{decision}:{reason}")
    return 0 if decision == "allow" else 1


if __name__ == "__main__":
    sys.exit(main())
