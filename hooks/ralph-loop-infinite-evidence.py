#!/usr/bin/env python3
"""ralph-loop-infinite-evidence.py — Sealed evidence bundle builder + precheck.

F-07 + RALPH-refactor remediation: the verifier previously consumed only the
last assistant text. A polished-but-false report could therefore pass HMAC
validation without anchoring to real artifacts. This helper builds a
deterministic JSON bundle from observable inputs the verifier should
actually judge:

* sha256 of the original sealed user prompt
* sha256 of the agent's final output / report
* sha256 of the transcript file (if present)
* cited artifact paths extracted from the report, with existence/sha256/stat
* recent hook/verifier log snippets relevant to the current session
* current signed state/pass rows from the DB if available

It also exposes a deterministic ``precheck`` subcommand that returns
``verdict=FAIL`` if the report cites artifacts that do not exist OR if the
numeric claims in the prose are not corroborated by the *bytes* of any cited
artifact. Stop calls precheck BEFORE invoking the verifier LLM and refuses
to sign PASS on FAIL.

Content-aware checks performed against the bytes of cited artifacts
(closes the validation-report R8 FAIL — "evidence precheck rejects
mismatched test count"):

* ``Tests: N passed, M failed`` — N must appear as ``N passed`` (with
  optional thousands separator) inside at least one cited artifact's bytes
  AND M must appear as ``M failed``.
* ``Server exceptions ... 0`` — at least one cited log artifact (or the
  transcript) must exist whose mtime is within the last 24h.
* ``Requirements satisfied: N/M (100%)`` — require N == M and that at
  least one cited artifact's bytes contain ``N/M`` or ``100%``.
* ``Success criteria passed: N/M (100%)`` — same as above.
* ``Deliverables verified: N/M (100%)`` — same as above.

The output JSON enumerates each unmatched claim under
``precheck.reasons`` so the agent's next iteration sees what needs to be
fixed.

Subcommands
-----------
* ``build``    — print the bundle JSON
* ``precheck`` — print {verdict, reasons[]}; exit 0 if PASS, 1 if FAIL
* ``self-test`` — run pure-python tests; exit 0 on PASS
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any


CITED_PATH_RX = re.compile(
    r"(?<![\w/])(?:~/|\$HOME/|/)[\w@.+/:\-]{2,}",
)

CITATION_AFTER_ARROW_RX = re.compile(r"[←⇐][\s]+([^\s,;]+)")

TESTS_LINE_RX = re.compile(
    r"Tests:\s*([\d,]+)\s+passed,\s*([\d,]+)\s+failed",
    re.IGNORECASE,
)
SERVER_EXC_RX = re.compile(
    r"Server\s+exceptions(?:\s*\([^)]*\))?:\s*([0-9]+|N/A)\b",
    re.IGNORECASE,
)
RATIO_RX = re.compile(
    r"(Requirements\s+satisfied|Success\s+criteria\s+passed|Deliverables\s+verified)"
    r":\s*([\d,]+)\s*/\s*([\d,]+)\s*\((100%|\d+%)\)",
    re.IGNORECASE,
)

ONE_DAY_S = 86400


def _sha256(path: Path) -> str:
    try:
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 16), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""


def _sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()


def _stat_record(path: Path) -> dict[str, Any]:
    try:
        st = path.stat()
        return {
            "exists": True,
            "size": st.st_size,
            "mode": oct(st.st_mode & 0o777),
            "mtime": int(st.st_mtime),
        }
    except FileNotFoundError:
        return {"exists": False}
    except Exception as exc:
        return {"exists": False, "error": str(exc)}


def _extract_cited_paths(report: str) -> list[str]:
    candidates: set[str] = set()
    for m in CITED_PATH_RX.finditer(report):
        token = m.group(0).rstrip(".,)—–")
        candidates.add(token)
    for m in CITATION_AFTER_ARROW_RX.finditer(report):
        token = m.group(1).rstrip(".,);—–")
        if token.startswith(("/", "~", "$HOME")):
            candidates.add(token)
    return sorted(c for c in candidates if not c.startswith("N/A"))


def _resolve(token: str) -> Path:
    expanded = os.path.expandvars(os.path.expanduser(token))
    return Path(expanded)


def _tail_log_for_session(log_path: Path, session_id: str, lines: int = 200) -> list[str]:
    if not log_path.exists():
        return []
    try:
        with log_path.open("r", encoding="utf-8", errors="replace") as fh:
            data = fh.readlines()
    except Exception:
        return []
    tail = data[-lines:]
    if session_id:
        return [line.rstrip("\n") for line in tail if session_id in line or "[stop]" in line or "[verifier]" in line]
    return [line.rstrip("\n") for line in tail]


def _read_artifact_bytes(record: dict[str, Any], max_bytes: int = 4 * 1024 * 1024) -> bytes:
    if not record.get("exists"):
        return b""
    resolved = record.get("resolved_path") or ""
    if not resolved:
        return b""
    try:
        with open(resolved, "rb") as fh:
            return fh.read(max_bytes)
    except Exception:
        return b""


def _normalize_number(token: str) -> str:
    return token.replace(",", "").strip()


def _bytes_contain_numeric_token(blob: bytes, number: str, suffix: str) -> bool:
    """Return True if `blob` contains `<number> <suffix>` (with thousands sep variants)."""
    if not blob:
        return False
    try:
        text = blob.decode("utf-8", errors="replace")
    except Exception:
        return False
    n = _normalize_number(number)
    if not n.isdigit():
        return False
    candidates = {n}
    if len(n) > 3:
        with_sep = ""
        rest = n
        while len(rest) > 3:
            with_sep = "," + rest[-3:] + with_sep
            rest = rest[:-3]
        candidates.add(rest + with_sep)
    pattern = (
        r"(?:^|[^0-9])("
        + "|".join(re.escape(c) for c in candidates)
        + r")\s+"
        + re.escape(suffix)
        + r"\b"
    )
    return re.search(pattern, text, re.IGNORECASE) is not None


def _bytes_contain_ratio(blob: bytes, num: str, denom: str) -> bool:
    if not blob:
        return False
    try:
        text = blob.decode("utf-8", errors="replace")
    except Exception:
        return False
    n = _normalize_number(num)
    d = _normalize_number(denom)
    if not (n.isdigit() and d.isdigit()):
        return False
    if re.search(rf"\b{re.escape(n)}\s*/\s*{re.escape(d)}\b", text):
        return True
    return "100%" in text and n == d


# Heuristic markers that indicate genuine test infrastructure output, not just
# a fabricated claim string. At least one of these must be present alongside
# the "N passed" token for the artifact to be considered a real test run.
_TEST_INFRA_MARKERS = [
    b"pytest", b"unittest", b"jest", b"mocha", b"vitest",
    b"npm test", b"yarn test", b"pnpm test",
    b"python -m pytest", b"python -m unittest",
    b"go test", b"cargo test", b"cargo nextest",
    b"rspec", b"minitest", b"testsuite",
    b"--tb=", b"--verbose", b"--v", b"-v ",
    b"PASSED", b"FAILED", b"ERROR",
    b"test result", b"testsuit",
    b"Collecting", b"running", b"collected",
]


def _artifact_looks_like_test_output(blob: bytes) -> bool:
    """Return True if `blob` contains at least one test-infrastructure marker.

    This distinguishes genuine test execution output (pytest summary, jest
    output, etc.) from a fabricated file that merely contains the claim
    string "N passed" without any actual test infrastructure evidence.
    """
    if not blob:
        return False
    for marker in _TEST_INFRA_MARKERS:
        if marker in blob:
            return True
    return False


def build_bundle(
    *,
    agent_output: str,
    original_prompt: str,
    transcript_path: str,
    session_id: str,
    iteration: int,
    state_file: str,
) -> dict[str, Any]:
    cited_tokens = _extract_cited_paths(agent_output)
    cited_artifacts: list[dict[str, Any]] = []
    missing: list[str] = []
    for token in cited_tokens:
        resolved = _resolve(token)
        rec = {
            "cited_as": token,
            "resolved_path": str(resolved),
            **_stat_record(resolved),
        }
        if rec.get("exists"):
            rec["sha256"] = _sha256(resolved)
        else:
            missing.append(token)
        cited_artifacts.append(rec)

    transcript = Path(transcript_path) if transcript_path else None
    transcript_stat = _stat_record(transcript) if transcript else {"exists": False}
    transcript_sha = _sha256(transcript) if transcript and transcript.exists() else ""

    state_records: dict[str, Any] = {}
    if state_file:
        sp = Path(state_file)
        if sp.exists():
            try:
                state_records = {
                    line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
                    for line in sp.read_text(encoding="utf-8", errors="replace").splitlines()
                    if ":" in line
                }
            except Exception:
                state_records = {}

    log_path = Path.home() / ".claude" / "state" / "ralph-gate.log"
    verifier_log = Path.home() / ".claude" / "state" / "ralph-verifier.jsonl"
    bundle: dict[str, Any] = {
        "schema": "ralph-loop-infinite-evidence-bundle/v1",
        "session_id": session_id,
        "iteration": iteration,
        "original_prompt_hash": _sha256_text(original_prompt),
        "original_prompt_bytes": len(original_prompt.encode("utf-8", errors="replace")),
        "agent_output_hash": _sha256_text(agent_output),
        "agent_output_bytes": len(agent_output.encode("utf-8", errors="replace")),
        "transcript": {
            "path": str(transcript) if transcript else "",
            "stat": transcript_stat,
            "sha256": transcript_sha,
        },
        "cited_artifacts": cited_artifacts,
        "cited_artifacts_missing": missing,
        "state_records": state_records,
        "gate_log_tail": _tail_log_for_session(log_path, session_id),
        "verifier_log_tail": _tail_log_for_session(verifier_log, session_id, 50),
    }
    bundle["bundle_sha256"] = _sha256_text(json.dumps(bundle, sort_keys=True))
    return bundle


def _any_artifact_or_transcript_supports(
    bundle: dict[str, Any], predicate
) -> bool:
    transcript = bundle.get("transcript") or {}
    tpath = transcript.get("path") or ""
    if tpath and (transcript.get("stat") or {}).get("exists"):
        try:
            with open(tpath, "rb") as fh:
                if predicate(fh.read(4 * 1024 * 1024)):
                    return True
        except Exception:
            pass
    for rec in bundle.get("cited_artifacts") or []:
        blob = _read_artifact_bytes(rec)
        if predicate(blob):
            return True
    return False


def precheck(bundle: dict[str, Any], agent_output: str) -> dict[str, Any]:
    """Deterministic content-aware precheck.

    Returns ``{"verdict": "PASS"|"FAIL", "reasons": [...], "bundle_sha256": ...}``.
    Reasons enumerate every unmatched claim so the agent's next iteration
    knows what to fix.
    """
    reasons: list[str] = []
    if bundle.get("cited_artifacts_missing"):
        reasons.append(
            f"report cites artifacts that do not exist: {', '.join(bundle['cited_artifacts_missing'])}"
        )
    if not agent_output.strip():
        reasons.append("agent output is empty")
    transcript_present = bool((bundle.get("transcript") or {}).get("stat", {}).get("exists"))
    if not (transcript_present or bundle.get("cited_artifacts")):
        reasons.append("no transcript and no cited artifacts to anchor the report")

    tests_match = TESTS_LINE_RX.search(agent_output)
    if tests_match:
        passed_raw = tests_match.group(1)
        failed_raw = tests_match.group(2)
        passed_n = _normalize_number(passed_raw)
        failed_n = _normalize_number(failed_raw)
        if passed_n.isdigit() and int(passed_n) > 0:
            ok_pass = _any_artifact_or_transcript_supports(
                bundle, lambda blob, n=passed_n: _bytes_contain_numeric_token(blob, n, "passed")
            )
            if not ok_pass:
                reasons.append(
                    f"claim 'Tests: {passed_raw} passed' has no matching '{passed_n} passed' "
                    f"token in any cited artifact or the transcript"
                )
            elif not _any_artifact_or_transcript_supports(
                bundle, lambda blob: _artifact_looks_like_test_output(blob)
            ):
                reasons.append(
                    f"claim 'Tests: {passed_raw} passed' — artifacts contain '{passed_n} passed' "
                    f"but lack any test-infrastructure marker (pytest, unittest, jest, etc.)"
                )
        if failed_n.isdigit():
            ok_fail = _any_artifact_or_transcript_supports(
                bundle, lambda blob, n=failed_n: _bytes_contain_numeric_token(blob, n, "failed")
            )
            if not ok_fail:
                reasons.append(
                    f"claim 'Tests: {failed_raw} failed' has no matching '{failed_n} failed' "
                    f"token in any cited artifact or the transcript"
                )

    server_exc_match = SERVER_EXC_RX.search(agent_output)
    if server_exc_match:
        value = server_exc_match.group(1)
        if value == "0":
            now = time.time()
            fresh_log = False
            transcript = bundle.get("transcript") or {}
            tstat = transcript.get("stat") or {}
            if tstat.get("exists") and now - int(tstat.get("mtime", 0)) <= ONE_DAY_S:
                fresh_log = True
            else:
                for rec in bundle.get("cited_artifacts") or []:
                    if rec.get("exists") and now - int(rec.get("mtime", 0)) <= ONE_DAY_S:
                        fresh_log = True
                        break
            if not fresh_log:
                reasons.append(
                    "claim 'Server exceptions: 0' requires a transcript or cited log "
                    "artifact with mtime within the last 24h; none found"
                )

    for ratio_match in RATIO_RX.finditer(agent_output):
        label = ratio_match.group(1)
        num = _normalize_number(ratio_match.group(2))
        denom = _normalize_number(ratio_match.group(3))
        if not (num.isdigit() and denom.isdigit()):
            continue
        if int(num) != int(denom):
            reasons.append(
                f"claim '{label}: {ratio_match.group(2)}/{ratio_match.group(3)} (100%)' "
                f"is structurally invalid ({num} != {denom})"
            )
            continue
        ok_ratio = _any_artifact_or_transcript_supports(
            bundle, lambda blob, n=num, d=denom: _bytes_contain_ratio(blob, n, d)
        )
        if not ok_ratio:
            reasons.append(
                f"claim '{label}: {num}/{denom} (100%)' has no matching "
                f"'{num}/{denom}' or '100%' token in any cited artifact or the transcript"
            )

    verdict = "FAIL" if reasons else "PASS"
    return {"verdict": verdict, "reasons": reasons, "bundle_sha256": bundle.get("bundle_sha256")}


def _read_file(path: str | None) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        return ""
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def _self_test() -> int:
    failures: list[str] = []
    tmp = Path(os.environ.get("TMPDIR", "/tmp")) / f"rli-evidence-{os.getpid()}"
    tmp.mkdir(parents=True, exist_ok=True)
    art_match = tmp / "report-match.log"
    art_match.write_bytes(
        b"============================= test session starts ==============================\n"
        b"collected 42 items\n"
        b"tests/test_core.py::test_ok PASSED\n"
        b"42 passed, 0 failed in 3.14s\n"
        b"requirements 17/17 (100%)\n"
    )
    art_mismatch = tmp / "report-mismatch.log"
    art_mismatch.write_bytes(b"this artifact mentions nothing about tests")

    agent_output_match = (
        "Tests: 42 passed, 0 failed\n"
        "Server exceptions: 0\n"
        "Requirements satisfied: 17/17 (100%)\n"
        f"see {art_match}\n"
    )
    agent_output_mismatch = (
        "Tests: 42 passed, 0 failed\n"
        "Server exceptions: 0\n"
        "Requirements satisfied: 17/17 (100%)\n"
        f"see {art_mismatch}\n"
    )

    bundle_match = build_bundle(
        agent_output=agent_output_match,
        original_prompt="test",
        transcript_path="",
        session_id="self-test",
        iteration=1,
        state_file="",
    )
    pre_match = precheck(bundle_match, agent_output_match)
    if pre_match["verdict"] != "PASS":
        failures.append(f"matching artifact should PASS precheck, got {pre_match}")

    bundle_mismatch = build_bundle(
        agent_output=agent_output_mismatch,
        original_prompt="test",
        transcript_path="",
        session_id="self-test",
        iteration=1,
        state_file="",
    )
    pre_mismatch = precheck(bundle_mismatch, agent_output_mismatch)
    if pre_mismatch["verdict"] != "FAIL":
        failures.append(f"mismatched artifact should FAIL precheck, got {pre_mismatch}")
    if not any("42 passed" in r for r in pre_mismatch.get("reasons", [])):
        failures.append("FAIL reason should name the unmatched '42 passed' claim")

    invalid_output = (
        "Tests: 1 passed, 0 failed\n"
        "Requirements satisfied: 4/5 (100%)\n"
        f"see {art_match}\n"
    )
    bundle_inv = build_bundle(
        agent_output=invalid_output,
        original_prompt="test",
        transcript_path="",
        session_id="self-test",
        iteration=1,
        state_file="",
    )
    pre_inv = precheck(bundle_inv, invalid_output)
    if pre_inv["verdict"] != "FAIL":
        failures.append("structural 4/5 (100%) claim should FAIL")

    # Fix 5: fake test output — contains "42 passed" but no test infra markers
    art_fake = tmp / "report-fake.log"
    art_fake.write_bytes(b"summary: 42 passed, 0 failed\nsome log entry\nno test runner here\n")
    agent_output_fake = (
        f"Tests: 42 passed, 0 failed\n"
        f"Server exceptions: 0\n"
        f"Requirements satisfied: 17/17 (100%)\n"
        f"see {art_fake}\n"
    )
    bundle_fake = build_bundle(
        agent_output=agent_output_fake,
        original_prompt="test",
        transcript_path="",
        session_id="self-test",
        iteration=1,
        state_file="",
    )
    pre_fake = precheck(bundle_fake, agent_output_fake)
    if pre_fake["verdict"] != "FAIL":
        failures.append(f"fake test output (no infra markers) should FAIL precheck, got {pre_fake}")
    if not any("test-infrastructure marker" in r for r in pre_fake.get("reasons", [])):
        failures.append("FAIL reason for fake test output should mention missing infra markers")

    # Fix 5: real test output — contains "42 passed" AND pytest markers
    art_real = tmp / "report-real.log"
    art_real.write_bytes(
        b"============================= test session starts ==============================\n"
        b"collected 42 items\n"
        b"tests/test_core.py::test_ok PASSED\n"
        b"tests/test_api.py::test_health PASSED\n"
        b"42 passed, 0 failed in 3.14s\n"
        b"requirements 17/17 (100%)\n"
    )
    agent_output_real = (
        f"Tests: 42 passed, 0 failed\n"
        f"Server exceptions: 0\n"
        f"Requirements satisfied: 17/17 (100%)\n"
        f"see {art_real}\n"
    )
    bundle_real = build_bundle(
        agent_output=agent_output_real,
        original_prompt="test",
        transcript_path="",
        session_id="self-test",
        iteration=1,
        state_file="",
    )
    pre_real = precheck(bundle_real, agent_output_real)
    if pre_real["verdict"] != "PASS":
        failures.append(f"real test output (has pytest + '42 passed') should PASS precheck, got {pre_real}")

    for p in (art_match, art_mismatch, art_fake, art_real):
        try:
            p.unlink()
        except OSError:
            pass
    try:
        tmp.rmdir()
    except OSError:
        pass

    if failures:
        print(json.dumps({"status": "FAIL", "failures": failures}, indent=2))
        return 1
    print(json.dumps({"status": "PASS", "tests_run": 5}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Ralph Loop Infinite evidence bundler")
    parser.add_argument(
        "cmd",
        choices=["build", "precheck", "self-test"],
    )
    parser.add_argument("--agent-output-file", default="")
    parser.add_argument("--original-prompt-file", default="")
    parser.add_argument("--transcript-path", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--iteration", type=int, default=0)
    parser.add_argument(
        "--state-file",
        default=str(Path.home() / ".claude" / "state" / "ralph-loop-infinite.local"),
    )

    args = parser.parse_args()

    if args.cmd == "self-test":
        return _self_test()

    if not args.agent_output_file:
        print(json.dumps({"verdict": "FAIL", "reasons": ["--agent-output-file required"]}))
        return 1

    agent_output = _read_file(args.agent_output_file)
    original_prompt = _read_file(args.original_prompt_file)
    bundle = build_bundle(
        agent_output=agent_output,
        original_prompt=original_prompt,
        transcript_path=args.transcript_path,
        session_id=args.session_id,
        iteration=args.iteration,
        state_file=args.state_file,
    )

    if args.cmd == "build":
        print(json.dumps(bundle, indent=2))
        return 0

    result = precheck(bundle, agent_output)
    print(json.dumps({"precheck": result, "bundle": bundle}, indent=2))
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
