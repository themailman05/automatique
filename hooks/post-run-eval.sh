#!/usr/bin/env bash
###############################################################################
# post-run-eval.sh — Post-run evaluation hook
#
# Called by ralph.sh after a successful run. Logs structured eval data to
# Braintrust as an experiment, scoring the run on multiple dimensions.
#
# Usage: ./post-run-eval.sh <run-dir>
#
# Reads result.json and run artifacts from <run-dir>, scores them, and
# submits to Braintrust as an experiment in the Factory project.
###############################################################################
set -euo pipefail

RUN_DIR="${1:?Usage: post-run-eval.sh <run-dir>}"
API_KEY="${BRAINTRUST_API_KEY:?BRAINTRUST_API_KEY required}"
PROJECT="${BRAINTRUST_CC_PROJECT:-Factory}"
API_BASE="https://api.braintrust.dev/v1"

if [[ ! -f "$RUN_DIR/result.json" ]]; then
  echo "No result.json in $RUN_DIR" >&2
  exit 1
fi

RESULT=$(cat "$RUN_DIR/result.json")
RUN_ID=$(echo "$RESULT" | jq -r '.run_id')
STATUS=$(echo "$RESULT" | jq -r '.status')
ITERS=$(echo "$RESULT" | jq -r '.iterations')
BRANCH=$(echo "$RESULT" | jq -r '.branch // ""')
PR=$(echo "$RESULT" | jq -r '.pr // ""')
TASK=$(cat "$RUN_DIR/task.md" 2>/dev/null || echo "unknown")
TASK_TITLE=$(head -1 "$RUN_DIR/task.md" 2>/dev/null | sed 's/^#\+ //')

# ── Scoring ───────────────────────────────────────────────────────────────────

# Build pass score (binary)
BUILD_SCORE=0
if [[ "$STATUS" == "success" ]]; then
  BUILD_SCORE=1
fi

# Efficiency score (fewer iterations = better)
MAX_ITERS="${RALPH_MAX_ITERS:-8}"
if [[ "$ITERS" -le 1 ]]; then
  EFFICIENCY_SCORE=1.0
elif [[ "$ITERS" -le 2 ]]; then
  EFFICIENCY_SCORE=0.8
elif [[ "$ITERS" -le 4 ]]; then
  EFFICIENCY_SCORE=0.5
elif [[ "$ITERS" -le "$MAX_ITERS" ]]; then
  EFFICIENCY_SCORE=0.2
else
  EFFICIENCY_SCORE=0.0
fi

# Diff size score (smaller = better) — measures surgical precision
DIFF_LINES=0
if git -C "$(echo "$RESULT" | jq -r '.repo // ""' 2>/dev/null || echo "$RALPH_REPO")" diff origin/master..."$BRANCH" --stat 2>/dev/null | tail -1 | grep -oP '\d+ insertion' | grep -oP '\d+'; then
  INSERTIONS=$(git -C "${RALPH_REPO:-$HOME/src/flowstate}" diff origin/master..."$BRANCH" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
  DELETIONS=$(git -C "${RALPH_REPO:-$HOME/src/flowstate}" diff origin/master..."$BRANCH" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
  DIFF_LINES=$((${INSERTIONS:-0} + ${DELETIONS:-0}))
fi

if [[ "$DIFF_LINES" -le 50 ]]; then
  DIFF_SCORE=1.0
elif [[ "$DIFF_LINES" -le 150 ]]; then
  DIFF_SCORE=0.7
elif [[ "$DIFF_LINES" -le 500 ]]; then
  DIFF_SCORE=0.4
else
  DIFF_SCORE=0.1
fi

# ── Get or create project ─────────────────────────────────────────────────────

PROJECT_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/project" | jq -r ".objects[] | select(.name==\"$PROJECT\") | .id")

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(curl -sf \
    -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$PROJECT\"}" \
    "$API_BASE/project" | jq -r '.id')
fi

# ── Create experiment ─────────────────────────────────────────────────────────

EXPERIMENT_ID=$(curl -sf \
  -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"project_id\":\"$PROJECT_ID\",\"name\":\"ralph-$RUN_ID\"}" \
  "$API_BASE/experiment" | jq -r '.id')

echo "📊 Experiment: ralph-$RUN_ID (id: $EXPERIMENT_ID)"

# ── Log eval row ──────────────────────────────────────────────────────────────

EVAL_ROW=$(jq -n \
  --arg experiment_id "$EXPERIMENT_ID" \
  --arg run_id "$RUN_ID" \
  --arg task "$TASK" \
  --arg task_title "$TASK_TITLE" \
  --arg status "$STATUS" \
  --argjson iters "$ITERS" \
  --arg branch "$BRANCH" \
  --arg pr "$PR" \
  --argjson build_score "$BUILD_SCORE" \
  --argjson efficiency "$EFFICIENCY_SCORE" \
  --argjson diff_score "$DIFF_SCORE" \
  --argjson diff_lines "$DIFF_LINES" \
  '{
    id: $run_id,
    input: $task,
    output: {
      status: $status,
      iterations: $iters,
      branch: $branch,
      pr: $pr,
      diff_lines: $diff_lines
    },
    expected: {
      status: "success",
      max_iterations: 1
    },
    scores: {
      build_passes: $build_score,
      efficiency: $efficiency,
      diff_precision: $diff_score
    },
    metadata: {
      run_id: $run_id,
      task_title: $task_title,
      branch: $branch,
      pr: $pr
    }
  }')

curl -sf \
  -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"experiment_id\":\"$EXPERIMENT_ID\",\"events\":[$EVAL_ROW]}" \
  "$API_BASE/experiment/$EXPERIMENT_ID/insert" > /dev/null

echo "✅ Eval logged: build=$BUILD_SCORE efficiency=$EFFICIENCY_SCORE diff=$DIFF_SCORE (${DIFF_LINES} lines)"
