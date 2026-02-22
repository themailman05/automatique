#!/usr/bin/env python3
"""
Iteration Eval — mid-loop self-assessment via Braintrust LLM scorer.

Runs after each ralph loop iteration to evaluate the current diff against
the task requirements and anti-patterns. Outputs a JSON score + markdown
summary suitable for posting as a Trello comment.

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
scoring_prompt = f"""You are evaluating an in-progress code change produced by an automated software factory (iteration {ITER}).

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

Score this iteration on the following dimensions. For each, provide a score from 0.0 to 1.0 and a brief justification.

1. **requirements_met**: How many of the task requirements are addressed so far?
2. **acceptance_criteria**: How many acceptance criteria would pass right now?
3. **no_regressions**: Are the "DO NOT" anti-patterns being respected?
4. **code_quality**: Is the code well-structured and idiomatic?
5. **completeness**: Is this a complete solution or partial?

Respond in JSON format:
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

# ── Run eval via Braintrust ──────────────────────────────────────────────────
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
    response = client.chat.completions.create(
        model="claude-sonnet-4-20250514",
        messages=[{"role": "user", "content": scoring_prompt}],
        max_tokens=2000,
    )
    raw = response.choices[0].message.content

    # Extract JSON from response
    json_match = raw
    if "```json" in raw:
        json_match = raw.split("```json")[1].split("```")[0]
    elif "```" in raw:
        json_match = raw.split("```")[1].split("```")[0]

    scores = json.loads(json_match.strip())

    span.log(
        output=scores,
        scores={k: v["score"] for k, v in scores.items() if isinstance(v, dict) and "score" in v},
        metadata={"iteration": ITER, "branch": BRANCH},
    )

    # Write to file
    out_file = RUN_DIR / f"eval-iter-{ITER}.json"
    out_file.write_text(json.dumps(scores, indent=2))

    # Build markdown summary for Trello
    verdict = scores.get("verdict", "UNKNOWN")
    overall = scores.get("overall", {})
    md_lines = [
        f"**Verdict:** {verdict} ({overall.get('score', 0):.1f}/1.0)",
        f"**Summary:** {overall.get('reason', 'N/A')}",
        "",
    ]
    for dim in ["requirements_met", "acceptance_criteria", "no_regressions", "code_quality", "completeness"]:
        s = scores.get(dim, {})
        md_lines.append(f"- **{dim}**: {s.get('score', 0):.1f} — {s.get('reason', 'N/A')}")

    print(json.dumps({"scores": scores, "markdown": "\n".join(md_lines)}))

except Exception as e:
    span.log(output={"error": str(e)}, scores={"overall": 0})
    print(json.dumps({"scores": {}, "markdown": f"⚠️ Eval failed: {e}"}))

finally:
    span.end()
    logger.flush()
