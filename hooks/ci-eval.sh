#!/usr/bin/env bash
###############################################################################
# ci-eval.sh — CI/CD hook for Braintrust eval on PR
#
# Run in GitHub Actions (or any CI) to evaluate a PR's changes and post
# results as a Braintrust experiment + PR comment.
#
# Usage (in workflow):
#   - name: Evaluate PR
#     run: ./factory/hooks/ci-eval.sh
#     env:
#       BRAINTRUST_API_KEY: ${{ secrets.BRAINTRUST_API_KEY }}
#       PR_NUMBER: ${{ github.event.pull_request.number }}
#       PR_BRANCH: ${{ github.head_ref }}
#       COMMIT_SHA: ${{ github.sha }}
###############################################################################
set -euo pipefail

API_KEY="${BRAINTRUST_API_KEY:?BRAINTRUST_API_KEY required}"
PROJECT="${BRAINTRUST_CC_PROJECT:-Factory}"
API_BASE="https://api.braintrust.dev/v1"
PR_NUMBER="${PR_NUMBER:-unknown}"
PR_BRANCH="${PR_BRANCH:-unknown}"
COMMIT_SHA="${COMMIT_SHA:-$(git rev-parse HEAD)}"
SHORT_SHA="${COMMIT_SHA:0:7}"

echo "🏭 Factory CI Eval — PR #$PR_NUMBER ($PR_BRANCH @ $SHORT_SHA)"

# ── Run checks and capture results ───────────────────────────────────────────

SCORES='{}'
DETAILS=""

run_check() {
  local name="$1"
  local cmd="$2"
  local score=0
  local output=""

  echo "  ▶ $name"
  if output=$(eval "$cmd" 2>&1); then
    score=1
    echo "    ✅ passed"
  else
    echo "    ❌ failed"
  fi

  SCORES=$(echo "$SCORES" | jq --arg name "$name" --argjson score "$score" '. + {($name): $score}')
  DETAILS="$DETAILS\n### $name: $([ $score -eq 1 ] && echo '✅' || echo '❌')\n\`\`\`\n$(echo "$output" | tail -20)\n\`\`\`\n"
}

# Auto-detect and run checks
if [[ -f "pubspec.yaml" ]]; then
  run_check "analyze" "flutter analyze --no-pub"
  run_check "build_ios" "flutter build ios --no-codesign --release 2>&1 | tail -30"
  run_check "test" "flutter test 2>&1 | tail -30"
elif [[ -f "package.json" ]]; then
  run_check "lint" "npm run lint 2>&1 | tail -30"
  run_check "test" "npm test 2>&1 | tail -30"
  run_check "build" "npm run build 2>&1 | tail -30"
fi

# ── Diff metrics ──────────────────────────────────────────────────────────────

STAT_LINE=$(git diff origin/main...HEAD --stat 2>/dev/null | tail -1 || echo "0 files")
FILES_CHANGED=$(echo "$STAT_LINE" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
INSERTIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
DELETIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
TOTAL_DIFF=$(( ${INSERTIONS:-0} + ${DELETIONS:-0} ))

SCORES=$(echo "$SCORES" | jq \
  --argjson files "${FILES_CHANGED:-0}" \
  --argjson diff "$TOTAL_DIFF" \
  '. + {
    diff_precision: (if $diff <= 50 then 1.0 elif $diff <= 150 then 0.7 elif $diff <= 500 then 0.4 else 0.1 end)
  }')

# ── Submit to Braintrust ─────────────────────────────────────────────────────

PROJECT_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/project" | jq -r ".objects[] | select(.name==\"$PROJECT\") | .id")

EXPERIMENT_ID=$(curl -sf \
  -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"project_id\":\"$PROJECT_ID\",\"name\":\"ci-pr${PR_NUMBER}-${SHORT_SHA}\"}" \
  "$API_BASE/experiment" | jq -r '.id')

EVAL_ROW=$(jq -n \
  --arg pr "PR #$PR_NUMBER" \
  --arg branch "$PR_BRANCH" \
  --arg sha "$SHORT_SHA" \
  --argjson scores "$SCORES" \
  --argjson files "${FILES_CHANGED:-0}" \
  --argjson diff "$TOTAL_DIFF" \
  '{
    id: ($pr + "-" + $sha),
    input: ($pr + " (" + $branch + ")"),
    output: {
      commit: $sha,
      files_changed: $files,
      diff_lines: $diff,
      scores: $scores
    },
    scores: $scores,
    metadata: {
      pr_number: $pr,
      branch: $branch,
      commit: $sha
    }
  }')

curl -sf \
  -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"experiment_id\":\"$EXPERIMENT_ID\",\"events\":[$EVAL_ROW]}" \
  "$API_BASE/experiment/$EXPERIMENT_ID/insert" > /dev/null

echo ""
echo "📊 Braintrust experiment: ci-pr${PR_NUMBER}-${SHORT_SHA}"
echo "   View: https://www.braintrust.dev/app/Factory/experiments/ci-pr${PR_NUMBER}-${SHORT_SHA}"

# ── Output for GitHub Actions summary ────────────────────────────────────────

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## 🏭 Factory Eval — PR #$PR_NUMBER"
    echo ""
    echo "| Metric | Score |"
    echo "|--------|-------|"
    echo "$SCORES" | jq -r 'to_entries[] | "| \(.key) | \(.value) |"'
    echo ""
    echo "**Diff:** $FILES_CHANGED files, +$INSERTIONS/-$DELETIONS ($TOTAL_DIFF total)"
    echo ""
    echo "[View in Braintrust](https://www.braintrust.dev/app/Factory/experiments/ci-pr${PR_NUMBER}-${SHORT_SHA})"
    echo ""
    echo -e "$DETAILS"
  } >> "$GITHUB_STEP_SUMMARY"
fi
