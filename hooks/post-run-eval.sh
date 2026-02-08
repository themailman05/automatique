#!/usr/bin/env bash
###############################################################################
# post-run-eval.sh — Post-run evaluation: score, log experiment, build dataset
#
# Called by ralph.sh after completion. Does three things:
# 1. Scores the run on multiple dimensions
# 2. Logs an experiment row to Braintrust (for comparing runs over time)
# 3. Appends to the Factory dataset (for regression testing the harness)
#
# Uses the same Braintrust API patterns as the trace-claude-code plugin.
#
# Usage: ./post-run-eval.sh <run-dir>
###############################################################################
set -euo pipefail

RUN_DIR="${1:?Usage: post-run-eval.sh <run-dir>}"
API_KEY="${BRAINTRUST_API_KEY:?BRAINTRUST_API_KEY required}"
PROJECT="${BRAINTRUST_CC_PROJECT:-Factory}"
API_BASE="https://api.braintrust.dev/v1"
DATASET_NAME="factory-runs"

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
TASK_TITLE=$(head -1 "$RUN_DIR/task.md" 2>/dev/null | sed 's/^#\+ //' || echo "unknown")

# ── Scoring ───────────────────────────────────────────────────────────────────

BUILD_SCORE=0
[[ "$STATUS" == "success" ]] && BUILD_SCORE=1

# Efficiency: 1-shot is ideal
if [[ "$ITERS" -le 1 ]]; then EFFICIENCY=1.0
elif [[ "$ITERS" -le 2 ]]; then EFFICIENCY=0.8
elif [[ "$ITERS" -le 4 ]]; then EFFICIENCY=0.5
else EFFICIENCY=0.2; fi

# Diff precision: smaller is better
REPO="${RALPH_REPO:-$HOME/src/flowstate}"
INSERTIONS=$(git -C "$REPO" diff origin/master..."$BRANCH" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
DELETIONS=$(git -C "$REPO" diff origin/master..."$BRANCH" --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
DIFF_LINES=$(( ${INSERTIONS:-0} + ${DELETIONS:-0} ))

if [[ "$DIFF_LINES" -le 50 ]]; then DIFF_SCORE=1.0
elif [[ "$DIFF_LINES" -le 150 ]]; then DIFF_SCORE=0.7
elif [[ "$DIFF_LINES" -le 500 ]]; then DIFF_SCORE=0.4
else DIFF_SCORE=0.1; fi

# Check output quality: did any iteration produce metric-gaming? (test deletion, ignore annotations)
GAMING_SCORE=1.0
DIFF_CONTENT=$(git -C "$REPO" diff origin/master..."$BRANCH" 2>/dev/null || echo "")
if echo "$DIFF_CONTENT" | grep -qE '^\+.*//\s*(ignore|nolint|no-check)'; then
  GAMING_SCORE=0.3
fi
if echo "$DIFF_CONTENT" | grep -qE '^\-.*test\(|^\-.*expect\(|^\-.*assert'; then
  # Deleted test assertions — possible gaming
  GAMING_SCORE=$(echo "$GAMING_SCORE * 0.5" | bc)
fi

echo "  Scores: build=$BUILD_SCORE efficiency=$EFFICIENCY diff=$DIFF_SCORE ($DIFF_LINES lines) integrity=$GAMING_SCORE"

# ── Get project ID ────────────────────────────────────────────────────────────

PROJECT_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/project?project_name=$(printf '%s' "$PROJECT" | jq -sRr @uri)" 2>/dev/null \
  | jq -r '.id // empty')

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(curl -sf -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$PROJECT\"}" \
    "$API_BASE/project" | jq -r '.id')
fi

# ── 1. Log to project logs (traces) ──────────────────────────────────────────
# This appears alongside the Claude Code session traces in the Logs view

LOG_EVENT=$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg task "$TASK_TITLE" \
  --arg status "$STATUS" \
  --argjson iters "$ITERS" \
  --arg branch "$BRANCH" \
  --arg pr "$PR" \
  --argjson build "$BUILD_SCORE" \
  --argjson efficiency "$EFFICIENCY" \
  --argjson diff "$DIFF_SCORE" \
  --argjson integrity "$GAMING_SCORE" \
  --argjson diff_lines "$DIFF_LINES" \
  '{
    id: $run_id,
    input: $task,
    output: $status,
    scores: {
      build_passes: $build,
      efficiency: $efficiency,
      diff_precision: $diff,
      integrity: $integrity
    },
    metadata: {
      run_id: $run_id,
      status: $status,
      iterations: $iters,
      branch: $branch,
      pr: $pr,
      diff_lines: $diff_lines,
      source: "ralph-loop"
    },
    span_attributes: {
      name: ("Ralph Run: " + $task),
      type: "eval"
    }
  }')

curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"events\":[$LOG_EVENT]}" \
  "$API_BASE/project_logs/$PROJECT_ID/insert" > /dev/null 2>&1 || true

echo "  📊 Logged to project traces"

# ── 2. Create experiment row ──────────────────────────────────────────────────

EXPERIMENT_ID=$(curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"project_id\":\"$PROJECT_ID\",\"name\":\"ralph-$RUN_ID\"}" \
  "$API_BASE/experiment" | jq -r '.id')

EVAL_ROW=$(jq -n \
  --arg run_id "$RUN_ID" \
  --arg task "$TASK" \
  --arg status "$STATUS" \
  --argjson iters "$ITERS" \
  --arg branch "$BRANCH" \
  --arg pr "$PR" \
  --argjson build "$BUILD_SCORE" \
  --argjson efficiency "$EFFICIENCY" \
  --argjson diff "$DIFF_SCORE" \
  --argjson integrity "$GAMING_SCORE" \
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
      build_passes: $build,
      efficiency: $efficiency,
      diff_precision: $diff,
      integrity: $integrity
    },
    metadata: {
      run_id: $run_id,
      task_title: ("'"$TASK_TITLE"'"),
      branch: $branch,
      pr: $pr
    }
  }')

curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"experiment_id\":\"$EXPERIMENT_ID\",\"events\":[$EVAL_ROW]}" \
  "$API_BASE/experiment/$EXPERIMENT_ID/insert" > /dev/null

echo "  🧪 Experiment: ralph-$RUN_ID"

# ── 3. Append to dataset ─────────────────────────────────────────────────────
# Builds a growing dataset of task→outcome pairs for regression testing

# Get or create dataset
DATASET_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/dataset?project_id=$PROJECT_ID&dataset_name=$(printf '%s' "$DATASET_NAME" | jq -sRr @uri)" 2>/dev/null \
  | jq -r '.id // empty')

if [[ -z "$DATASET_ID" ]]; then
  DATASET_ID=$(curl -sf -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"project_id\":\"$PROJECT_ID\",\"name\":\"$DATASET_NAME\",\"description\":\"Accumulated factory run task/outcome pairs for regression testing\"}" \
    "$API_BASE/dataset" | jq -r '.id')
  echo "  📦 Created dataset: $DATASET_NAME"
fi

# Collect the actual diff as the "output" (what the agent produced)
DIFF_SUMMARY=""
if [[ -n "$BRANCH" ]]; then
  DIFF_SUMMARY=$(git -C "$REPO" diff origin/master..."$BRANCH" --stat 2>/dev/null | head -30 || echo "")
fi

# Collect check output from final iteration
FINAL_CHECK_LOG=""
if [[ -f "$RUN_DIR/checks-iter-${ITERS}.log" ]]; then
  FINAL_CHECK_LOG=$(tail -30 "$RUN_DIR/checks-iter-${ITERS}.log" 2>/dev/null || echo "")
fi

DATASET_ROW=$(jq -n \
  --arg id "$RUN_ID" \
  --arg task "$TASK" \
  --arg status "$STATUS" \
  --argjson iters "$ITERS" \
  --arg diff_summary "$DIFF_SUMMARY" \
  --arg check_output "$FINAL_CHECK_LOG" \
  --argjson build "$BUILD_SCORE" \
  --argjson efficiency "$EFFICIENCY" \
  --argjson diff "$DIFF_SCORE" \
  --argjson integrity "$GAMING_SCORE" \
  '{
    id: $id,
    input: $task,
    expected: {
      status: "success",
      scores: {
        build_passes: 1,
        efficiency: 1.0,
        diff_precision: 0.7,
        integrity: 1.0
      }
    },
    metadata: {
      actual_status: $status,
      actual_iterations: $iters,
      actual_scores: {
        build_passes: $build,
        efficiency: $efficiency,
        diff_precision: $diff,
        integrity: $integrity
      },
      diff_summary: $diff_summary,
      check_output: $check_output
    }
  }')

curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"dataset_id\":\"$DATASET_ID\",\"events\":[$DATASET_ROW]}" \
  "$API_BASE/dataset/$DATASET_ID/insert" > /dev/null 2>&1 || true

echo "  📦 Appended to dataset: $DATASET_NAME"
echo ""
echo "  View: https://www.braintrust.dev/app/$PROJECT/experiments/ralph-$RUN_ID"
