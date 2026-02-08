#!/usr/bin/env python3
"""
CI/CD hook: Score a PR and post results as a GitHub PR comment.

Called from a GHA workflow step. Reads PR context from env vars,
runs the LLM scorer, posts a comment with scores + Braintrust link.

Environment:
  GITHUB_REPOSITORY   — owner/repo
  PR_NUMBER            — PR number
  PR_BRANCH            — branch name
  BRAINTRUST_API_KEY   — for scoring + logging
  TRELLO_API_KEY       — optional, for card context
  TRELLO_TOKEN         — optional
  BRAINTRUST_CC_PROJECT — project name (default: Factory)
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import braintrust
from braintrust import wrap_openai
from openai import OpenAI

PROJECT = os.environ.get("BRAINTRUST_CC_PROJECT", "Factory")
REPO_SLUG = os.environ.get("GITHUB_REPOSITORY", "")
PR_NUMBER = os.environ.get("PR_NUMBER", "")
PR_BRANCH = os.environ.get("PR_BRANCH", "")
RUN_ID = os.environ.get("GITHUB_RUN_ID", "unknown")
RUN_URL = f"https://github.com/{REPO_SLUG}/actions/runs/{RUN_ID}"

if not PR_NUMBER or not REPO_SLUG:
    print("Missing PR_NUMBER or GITHUB_REPOSITORY", file=sys.stderr)
    sys.exit(1)

# ── Gather PR context ────────────────────────────────────────────────────────

# Get PR body (contains task spec)
pr_body = subprocess.check_output(
    ["gh", "pr", "view", PR_NUMBER, "--json", "body,title", "-q", ".body"],
    text=True, stderr=subprocess.DEVNULL
).strip()

pr_title = subprocess.check_output(
    ["gh", "pr", "view", PR_NUMBER, "--json", "title", "-q", ".title"],
    text=True, stderr=subprocess.DEVNULL
).strip()

# Get diff
diff_stat = subprocess.check_output(
    ["gh", "pr", "diff", PR_NUMBER, "--stat"],
    text=True, stderr=subprocess.DEVNULL
)[:2000]

diff_content = subprocess.check_output(
    ["gh", "pr", "diff", PR_NUMBER],
    text=True, stderr=subprocess.DEVNULL
)[:15000]

# Get CI check results
checks_json = subprocess.check_output(
    ["gh", "pr", "checks", PR_NUMBER, "--json", "name,state,link"],
    text=True, stderr=subprocess.DEVNULL
)
checks = json.loads(checks_json)
ci_summary = "\n".join(
    f"{'✅' if c['state']=='SUCCESS' else '❌' if c['state']=='FAILURE' else '⏳'} {c['name']}: {c['state']}"
    for c in checks
)

# Extract task spec from PR body (between ### Task and ---)
task_text = pr_body
task_match = re.search(r'### Task\s*\n(.*?)(?:\n---|\Z)', pr_body, re.DOTALL)
if task_match:
    task_text = task_match.group(1).strip()

# Try to get Trello card context
trello_info = ""
trello_match = re.search(r'trello\.com/c/(\w+)', pr_body)
if trello_match:
    card_id = trello_match.group(1)
    try:
        api_key = os.environ.get("TRELLO_API_KEY", "")
        token = os.environ.get("TRELLO_TOKEN", "")
        if api_key and token:
            import urllib.request
            url = f"https://api.trello.com/1/cards/{card_id}?key={api_key}&token={token}&fields=name,desc"
            with urllib.request.urlopen(url) as resp:
                card = json.loads(resp.read())
                trello_info = f"Card: {card.get('name', '')}\n{card.get('desc', '')}"
    except Exception:
        pass

# ── Score with LLM ───────────────────────────────────────────────────────────

scoring_prompt = f"""You are evaluating a code PR produced by an automated software factory.

## Original Task
{task_text}

## Trello Card
{trello_info or "(no Trello card linked)"}

## PR: {pr_title}
{diff_stat}

## Diff (truncated)
```diff
{diff_content[:10000]}
```

## CI Results
{ci_summary}

---

Score this PR on the following dimensions (0.0 to 1.0 each):

1. **requirements_met**: Did the PR address ALL requirements listed in the task?
2. **acceptance_criteria**: Did the PR meet the stated acceptance criteria?
3. **no_regressions**: Did the PR avoid the "DO NOT" items and not break existing functionality?
4. **code_quality**: Is the code well-structured, idiomatic, and maintainable?
5. **completeness**: Is this a complete solution or partial/WIP?

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

Overall = weighted avg: requirements_met (30%), acceptance_criteria (25%), no_regressions (20%), code_quality (10%), completeness (15%).
PASS if >= 0.7, NEEDS_WORK if >= 0.4, FAIL otherwise.
"""

client = wrap_openai(OpenAI(
    api_key=os.environ.get("BRAINTRUST_API_KEY"),
    base_url="https://api.braintrust.dev/v1/proxy",
))

response = client.chat.completions.create(
    model="claude-sonnet-4-20250514",
    messages=[
        {"role": "system", "content": "You are a code review scorer. Be precise and honest."},
        {"role": "user", "content": scoring_prompt},
    ],
    temperature=0,
    max_tokens=2000,
)

raw = response.choices[0].message.content
json_match = re.search(r'```json\s*(.*?)\s*```', raw, re.DOTALL)
scores_json = json.loads(json_match.group(1) if json_match else raw)

scores = {}
reasons = {}
for key in ["requirements_met", "acceptance_criteria", "no_regressions", "code_quality", "completeness", "overall"]:
    entry = scores_json.get(key, {})
    scores[key] = float(entry.get("score", 0.0))
    reasons[key] = entry.get("reason", "")

verdict = scores_json.get("verdict", "UNKNOWN")

# ── Log to Braintrust ────────────────────────────────────────────────────────

logger = braintrust.init_logger(project=PROJECT)
span = logger.log(
    input={"task": task_text[:5000], "trello": trello_info[:2000], "pr_title": pr_title},
    output={"verdict": verdict, "pr": f"https://github.com/{REPO_SLUG}/pull/{PR_NUMBER}", "ci": ci_summary},
    scores=scores,
    metadata={
        "scorer": "ci-pr-scorer",
        "pr_number": PR_NUMBER,
        "branch": PR_BRANCH,
        "run_url": RUN_URL,
        "reasons": reasons,
    },
)

# Get Braintrust trace URL
bt_org = os.environ.get("BRAINTRUST_ORG_ID", "")
trace_url = f"https://www.braintrust.dev/app/{PROJECT}/logs"

# ── Post GitHub PR comment ───────────────────────────────────────────────────

verdict_emoji = {"PASS": "✅", "NEEDS_WORK": "⚠️", "FAIL": "❌"}.get(verdict, "❓")

def score_bar(score):
    filled = int(score * 10)
    return "█" * filled + "░" * (10 - filled)

comment = f"""## 🏭 L'Automatique — PR Evaluation

{verdict_emoji} **Verdict: {verdict}** (overall: {scores['overall']:.1f}/1.0)

> {reasons.get('overall', '')}

### Scores

| Criteria | Score | Detail |
|----------|-------|--------|
| Requirements Met | `{score_bar(scores['requirements_met'])}` {scores['requirements_met']:.1f} | {reasons.get('requirements_met', '')} |
| Acceptance Criteria | `{score_bar(scores['acceptance_criteria'])}` {scores['acceptance_criteria']:.1f} | {reasons.get('acceptance_criteria', '')} |
| No Regressions | `{score_bar(scores['no_regressions'])}` {scores['no_regressions']:.1f} | {reasons.get('no_regressions', '')} |
| Code Quality | `{score_bar(scores['code_quality'])}` {scores['code_quality']:.1f} | {reasons.get('code_quality', '')} |
| Completeness | `{score_bar(scores['completeness'])}` {scores['completeness']:.1f} | {reasons.get('completeness', '')} |

### CI Status
{ci_summary}

### Observability
🔗 [Braintrust Trace]({trace_url})
🔗 [CI Run]({RUN_URL})

---
<sub>Scored by L'Automatique CI eval • Model: claude-sonnet-4-20250514</sub>
"""

# Post comment via gh CLI
subprocess.run(
    ["gh", "pr", "comment", PR_NUMBER, "--body", comment],
    check=True, text=True
)

print(f"✅ Posted eval comment on PR #{PR_NUMBER}")
print(f"   Verdict: {verdict} ({scores['overall']:.1f})")
