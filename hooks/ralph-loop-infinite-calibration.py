#!/usr/bin/env python3
"""Calibration check: compare Ralph judge decisions across two model policies."""
from __future__ import annotations
import argparse, importlib.util, json, os, sys
from pathlib import Path

def load_ralph(path: Path):
    spec=importlib.util.spec_from_file_location("ralph_loop", str(path))
    mod=importlib.util.module_from_spec(spec); sys.modules["ralph_loop"]=mod; spec.loader.exec_module(mod); return mod

def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--ralph-helper", default=str(Path.home()/".claude/hooks/ralph-loop-infinite-ralph.py"))
    ap.add_argument("--original-prompt-file", required=True)
    ap.add_argument("--agent-output-file", required=True)
    ap.add_argument("--evidence-bundle-file", default="")
    ap.add_argument("--models", default="anthropic:claude-opus-4-7,minimax:minimax-m2.7")
    ap.add_argument("--max-disagreements", type=int, default=1)
    args=ap.parse_args()
    mod=load_ralph(Path(args.ralph_helper))
    orig=Path(args.original_prompt_file).read_text(encoding="utf-8", errors="replace")
    out=Path(args.agent_output_file).read_text(encoding="utf-8", errors="replace")
    bundle=Path(args.evidence_bundle_file).read_text(encoding="utf-8", errors="replace") if args.evidence_bundle_file and Path(args.evidence_bundle_file).exists() else "{}"
    results=[]
    for idx, pair in enumerate([p for p in args.models.split(",") if p.strip()], 1):
        provider, model = pair.split(":",1) if ":" in pair else ("anthropic", pair)
        policy={"provider": provider, "model_primary": model, "judge_policy": {"provider": provider, "model": model}}
        c,j,_=mod.critique_and_judge(original_prompt=orig, agent_output=out, evidence_bundle_json=bundle, policy=policy, session_id="calibration", iteration=idx, fake_anthropic_failure=os.environ.get("RALPH_CALIBRATION_OFFLINE", "1")=="1", fake_minimax_failure=os.environ.get("RALPH_CALIBRATION_OFFLINE", "1")=="1", fake_glm_failure=os.environ.get("RALPH_CALIBRATION_OFFLINE", "1")=="1", fake_deepseek_failure=os.environ.get("RALPH_CALIBRATION_OFFLINE", "1")=="1")
        results.append({"provider":provider,"model":model,"decision":j.decision,"score":j.overall_score})
    decisions={r["decision"] for r in results}; disagreements=max(0,len(decisions)-1)
    status="PASS" if disagreements <= args.max_disagreements else "FAIL"
    print(json.dumps({"status":status,"disagreements":disagreements,"results":results}, indent=2))
    return 0 if status=="PASS" else 1
if __name__ == "__main__": sys.exit(main())
