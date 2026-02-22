#!/usr/bin/env python3
"""
Iteration Eval — dual-model mid-loop assessment via Braintrust.

Runs two independent LLM reviewers (Claude Sonnet + GPT-4o) against the
current diff, then reconciles scores. Both models get a system prompt
with project context so they can evaluate intelligently.

Usage: iter_eval.py <run-dir> <iter-number> <repo-path> <branch>
Output: JSON to stdout, also writes <run-dir>/eval-iter-<N>.json
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import braintrust

RUN_DIR = Path(sys.argv[1])
ITER = int(sys.argv[2])
REPO = sys.argv[3]
BRANCH = sys.argv[4]

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")

MODELS = [
    "claude-sonnet-4-20250514",
    "gpt-4o-2024-11-20",
]

# ── System prompt — reviewer context ─────────────────────────────────────────
SYSTEM_PROMPT = """You are a senior code reviewer for CloudLoop (codename Flowstate), a collaborative loop station app built with Flutter (Dart frontend) and native C++ audio plugins.

Key architecture context:
- **flutter_soloud**: Audio playback plugin (SoLoud engine). Runs in "slave mode" where the recorder's duplex device drives audio output.
- **flutter_recorder**: Audio capture plugin with AEC (acoustic echo cancellation). Contains NLMS/VSS-NLMS adaptive filters and an optional neural post-filter (LiteRT/TFLite).
- **f_link**: Ableton Link integration for tempo sync.
- **Slave bridge**: SoLoud registers a mix callback into flutter_recorder via dlopen/dlsym. On iOS this is `@rpath/flutter_recorder.framework/flutter_recorder`.
- **AEC pipeline**: Reference signal from speaker → adaptive filter estimates echo → subtracted from mic input. Modes: bypass, algo (NLMS), neural (TFLite), hybrid (NLMS + neural), frozen (calibrated FIR), frozenNeural.
- **Dynamic frameworks on iOS**: `use_frameworks!` in Podfile — required to avoid 1206 duplicate miniaudio symbols between flutter_recorder and flutter_soloud.
- **LiteRT on iOS**: Prebuilt `libLiteRt.a` (arm64), needs `tflite_stubs.cpp` for missing `MaybeCreateSignpostProfiler` symbol.
- **CI**: Self-hosted runners — Mac mini (iOS builds, iPad/iPhone tests), Chonk 44-core Linux (Android builds, Lenovo tablet tests), k8s ARC pods (lightweight jobs).
- **Physical devices**: iPad 10th gen, iPhone 11 Pro (Mac mini USB), Lenovo TB330FU (Chonk ADB).

Anti-patterns to watch for in this codebase:
- Deleting tests to make checks pass
- Adding `// ignore` or `// ignore_for_file` annotations
- Using `std::recursive_mutex` to hide lock ordering bugs
- Holding audio-thread locks while calling into SoLoud engine (deadlock)
- Breaking the `sounds` vector thread safety (known race condition)
- Hardcoding values to pass assertions
- Modifying Chonk helm charts (managed by Terraform)

Score honestly. Factory agents sometimes game metrics — look for that."""

# ── Load task ────────────────────────────────────────────────────────────────
task_text = (RUN_DIR / "task.md").read_text() if (RUN_DIR / "task.md").exists() else ""

# ── Gather diff ──────────────────────────────────────────────────────────────
diff_stat = ""
diff_content = ""
try:
    diff_stat = subprocess.check_output(
        ["git", "-C", REPO, "diff", "origin/master...HEAD", "--stat"],
        text=True, stderr=subprocess.DEVNULL
    )[:2000]
    diff_content = subprocess.check_output(
        ["git", "-C", REPO, "diff", "origin/master...HEAD"],
        text=True, stderr=subprocess.DEVNULL
    )[:12000]
except Exception as e:
    print(f"⚠️  Could not get diff: {e}", file=sys.stderr)

# ── Check logs ───────────────────────────────────────────────────────────────
check_log = ""
check_file = RUN_DIR / f"checks-iter-{ITER}.log"
if check_file.exists():
    check_log = check_file.read_text()[-3000:]

# ── Scoring prompt ───────────────────────────────────────────────────────────
scoring_prompt = f"""Evaluate this in-progress code change (iteration {ITER} of a factory loop).

## Original Task
{task_text}

## Current Diff Summary
{diff_stat}

## Current Diff (truncated)
```diff
{diff_content}
```

## Local Check Results (this iteration)
```
{check_log or "(no check output)"}
```

---

Score on these dimensions (0.0-1.0 each with brief justification):

1. **requirements_met**: How many task requirements are addressed?
2. **acceptance_criteria**: How many acceptance criteria would pass now?
3. **no_regressions**: Are "DO NOT" anti-patterns being respected? Look for deleted tests, suppressed warnings, gaming.
4. **code_quality**: Well-structured, idiomatic, maintainable?
5. **completeness**: Complete solution or partial?

Respond in JSON:
```json
{{
  "requirements_met": {{"score": 0.0, "reason": "..."}},
  "acceptance_criteria": {{"score": 0.0, "reason": "..."}},
  "no_regressions": {{"score": 0.0, "reason": "..."}},
  "code_quality": {{"score": 0.0, "reason": "..."}},
  "completeness": {{"score": 0.0, "reason": "..."}},
  "overall": {{"score": 0.0, "reason": "one-line summary"}},
  "verdict": "PASS|FAIL|NEEDS_WORK"
}}
```

Overall = weighted: requirements_met 30%, acceptance_criteria 25%, no_regressions 20%, code_quality 10%, completeness 15%."""


def parse_scores(raw: str) -> dict:
    """Extract JSON from LLM response."""
    text = raw
    if "```json" in text:
        text = text.split("```json")[1].split("```")[0]
    elif "```" in text:
        text = text.split("```")[1].split("```")[0]
    return json.loads(text.strip())


def run_eval(client, model: str, span) -> dict:
    """Run eval with a single model, log to Braintrust span."""
    child = span.start_span(name=f"eval-{model}", input={"model": model})
    try:
        response = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": scoring_prompt},
            ],
            max_tokens=2000,
        )
        raw = response.choices[0].message.content
        scores = parse_scores(raw)
        child.log(
            output=scores,
            scores={k: v["score"] for k, v in scores.items() if isinstance(v, dict) and "score" in v},
            metadata={"model": model},
        )
        return scores
    except Exception as e:
        child.log(output={"error": str(e)}, scores={"overall": 0})
        return {}
    finally:
        child.end()


def reconcile(evals: list[dict]) -> dict:
    """Average scores across models, take lowest verdict."""
    if not evals:
        return {}
    dims = ["requirements_met", "acceptance_criteria", "no_regressions", "code_quality", "completeness", "overall"]
    result = {}
    for dim in dims:
        scores_for_dim = [e[dim] for e in evals if dim in e and isinstance(e[dim], dict)]
        if scores_for_dim:
            avg_score = sum(s["score"] for s in scores_for_dim) / len(scores_for_dim)
            reasons = " | ".join(f"{s.get('reason', 'N/A')}" for s in scores_for_dim)
            result[dim] = {"score": round(avg_score, 2), "reason": reasons}

    # Verdict: take the most conservative
    verdicts = [e.get("verdict", "NEEDS_WORK") for e in evals]
    verdict_order = {"FAIL": 0, "NEEDS_WORK": 1, "PASS": 2}
    result["verdict"] = min(verdicts, key=lambda v: verdict_order.get(v, 1))

    return result


# ── Main ─────────────────────────────────────────────────────────────────────
logger = braintrust.init_logger(project=PROJECT)
span = logger.start_span(
    name=f"iter-eval-{ITER}",
    input={"task": task_text[:2000], "diff_stat": diff_stat, "iteration": ITER},
)

try:
    client = braintrust.wrap_openai(
        __import__("openai").OpenAI(
            api_key=os.environ.get("BRAINTRUST_API_KEY", ""),
            base_url="https://api.braintrust.dev/v1/proxy",
        )
    )

    # Run both models
    model_results = []
    for model in MODELS:
        print(f"  📊 Eval: {model}...", file=sys.stderr)
        result = run_eval(client, model, span)
        if result:
            model_results.append(result)

    # Reconcile
    final = reconcile(model_results)

    span.log(
        output={"reconciled": final, "per_model": model_results},
        scores={k: v["score"] for k, v in final.items() if isinstance(v, dict) and "score" in v},
        metadata={"iteration": ITER, "branch": BRANCH, "models": MODELS},
    )

    # Write to file
    out = {"reconciled": final, "per_model": model_results}
    (RUN_DIR / f"eval-iter-{ITER}.json").write_text(json.dumps(out, indent=2))

    # Build markdown summary
    verdict = final.get("verdict", "UNKNOWN")
    overall = final.get("overall", {})
    md_lines = [
        f"**Verdict:** {verdict} ({overall.get('score', 0):.1f}/1.0) — {len(model_results)} models",
        f"**Summary:** {overall.get('reason', 'N/A')}",
        "",
    ]
    for dim in ["requirements_met", "acceptance_criteria", "no_regressions", "code_quality", "completeness"]:
        s = final.get(dim, {})
        md_lines.append(f"- **{dim}**: {s.get('score', 0):.1f} — {s.get('reason', 'N/A')}")

    print(json.dumps({"scores": final, "markdown": "\n".join(md_lines)}))

except Exception as e:
    span.log(output={"error": str(e)}, scores={"overall": 0})
    print(json.dumps({"scores": {}, "markdown": f"⚠️ Eval failed: {e}"}))

finally:
    span.end()
    logger.flush()
