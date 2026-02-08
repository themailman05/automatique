#!/usr/bin/env bash
###############################################################################
# regression-eval.sh — Replay dataset tasks through the factory to measure
# harness quality over time.
#
# Fetches tasks from the Braintrust "factory-runs" dataset and re-runs them
# through ralph.sh, comparing new scores against historical expected scores.
#
# Usage:
#   ./regression-eval.sh                    # Run all dataset tasks
#   ./regression-eval.sh --limit 5          # Run first 5
#   ./regression-eval.sh --task-id <id>     # Run a specific task
#
# Creates a single Braintrust experiment with all results for comparison.
###############################################################################
set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
API_KEY="${BRAINTRUST_API_KEY:?BRAINTRUST_API_KEY required}"
PROJECT="${BRAINTRUST_CC_PROJECT:-Factory}"
DATASET_NAME="factory-runs"
API_BASE="https://api.braintrust.dev/v1"
LIMIT=""
TASK_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

echo "🔄 Factory Regression Eval"
echo ""

# ── Fetch dataset ─────────────────────────────────────────────────────────────

PROJECT_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/project?project_name=$(printf '%s' "$PROJECT" | jq -sRr @uri)" \
  | jq -r '.id // empty')

[[ -z "$PROJECT_ID" ]] && { echo "Project not found: $PROJECT" >&2; exit 1; }

DATASET_ID=$(curl -sf \
  -H "Authorization: Bearer $API_KEY" \
  "$API_BASE/dataset?project_id=$PROJECT_ID&dataset_name=$(printf '%s' "$DATASET_NAME" | jq -sRr @uri)" \
  | jq -r '.id // empty')

[[ -z "$DATASET_ID" ]] && { echo "Dataset not found: $DATASET_NAME" >&2; exit 1; }

# Fetch rows
FETCH_BODY='{}'
[[ -n "$LIMIT" ]] && FETCH_BODY=$(jq -n --argjson l "$LIMIT" '{"limit": $l}')
[[ -n "$TASK_ID" ]] && FETCH_BODY=$(jq -n --arg id "$TASK_ID" '{"filters": [{"type": "path_lookup", "path": ["id"], "value": $id}]}')

ROWS=$(curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$FETCH_BODY" \
  "$API_BASE/dataset/$DATASET_ID/fetch" | jq -c '.events // []')

ROW_COUNT=$(echo "$ROWS" | jq 'length')
echo "  Found $ROW_COUNT tasks in dataset"

if [[ "$ROW_COUNT" -eq 0 ]]; then
  echo "  Nothing to replay. Run some tasks first!"
  exit 0
fi

# ── Create regression experiment ──────────────────────────────────────────────

REGRESSION_ID="regression-$(date +%Y%m%d-%H%M%S)"
EXPERIMENT_ID=$(curl -sf -X POST \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"project_id\":\"$PROJECT_ID\",\"name\":\"$REGRESSION_ID\",\"dataset_id\":\"$DATASET_ID\"}" \
  "$API_BASE/experiment" | jq -r '.id')

echo "  Experiment: $REGRESSION_ID"
echo ""

# ── Replay each task ─────────────────────────────────────────────────────────

PASS=0
FAIL=0

echo "$ROWS" | jq -c '.[]' | while read -r row; do
  TASK_INPUT=$(echo "$row" | jq -r '.input')
  ROW_ID=$(echo "$row" | jq -r '.id')
  EXPECTED=$(echo "$row" | jq -c '.expected // {}')

  TASK_TITLE=$(echo "$TASK_INPUT" | head -1 | sed 's/^#\+ //')
  echo "━━━ Replaying: $TASK_TITLE ━━━"

  # Write task to temp file
  TASK_FILE=$(mktemp /tmp/factory-regression-XXXXXX.md)
  echo "$TASK_INPUT" > "$TASK_FILE"

  # Run ralph
  RALPH_BRANCH="agent/regression-$ROW_ID-$(date +%s)"
  RALPH_OUTPUT=$("$FACTORY_DIR/ralph.sh" "$TASK_FILE" --branch "$RALPH_BRANCH" 2>&1 || true)
  RALPH_STATUS=$(echo "$RALPH_OUTPUT" | tail -1)

  # Find the run dir (most recent)
  LATEST_RUN=$(ls -td "$FACTORY_DIR/runs"/*/ 2>/dev/null | head -1)

  if [[ -n "$LATEST_RUN" && -f "$LATEST_RUN/result.json" ]]; then
    NEW_RESULT=$(cat "$LATEST_RUN/result.json")
    NEW_STATUS=$(echo "$NEW_RESULT" | jq -r '.status')
    NEW_ITERS=$(echo "$NEW_RESULT" | jq -r '.iterations')
  else
    NEW_STATUS="error"
    NEW_ITERS=0
  fi

  # Log to experiment
  RESULT_ROW=$(jq -n \
    --arg id "$ROW_ID" \
    --arg input "$TASK_INPUT" \
    --arg status "$NEW_STATUS" \
    --argjson iters "$NEW_ITERS" \
    --argjson expected "$EXPECTED" \
    --arg dataset_id "$DATASET_ID" \
    '{
      id: $id,
      dataset_record_id: $id,
      input: $input,
      output: {
        status: $status,
        iterations: $iters
      },
      expected: $expected,
      scores: {
        build_passes: (if $status == "success" then 1 else 0 end),
        efficiency: (if $iters <= 1 then 1.0 elif $iters <= 2 then 0.8 elif $iters <= 4 then 0.5 else 0.2 end)
      }
    }')

  curl -sf -X POST \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"experiment_id\":\"$EXPERIMENT_ID\",\"events\":[$RESULT_ROW]}" \
    "$API_BASE/experiment/$EXPERIMENT_ID/insert" > /dev/null 2>&1 || true

  if [[ "$NEW_STATUS" == "success" ]]; then
    echo "  ✅ Passed (${NEW_ITERS} iterations)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ Failed"
    FAIL=$((FAIL + 1))
  fi

  # Cleanup regression branch
  git -C "${RALPH_REPO:-$HOME/src/flowstate}" branch -D "$RALPH_BRANCH" 2>/dev/null || true
  rm -f "$TASK_FILE"
done

echo ""
echo "━━━ Regression Complete ━━━"
echo "  Passed: $PASS / $ROW_COUNT"
echo "  View: https://www.braintrust.dev/app/$PROJECT/experiments/$REGRESSION_ID"
