#!/usr/bin/env bash
###############################################################################
# notify.sh — Post run results to Telegram / webhook
#
# Called by ralph.sh on completion. Sends a summary to the configured channel.
#
# Usage: ./notify.sh <run-dir> [chat-id]
#
# Environment:
#   TELEGRAM_BOT_TOKEN — Bot token for Telegram notifications
#   NOTIFY_WEBHOOK     — Alternative: generic webhook URL (POST JSON)
###############################################################################
set -euo pipefail

RUN_DIR="${1:?Usage: notify.sh <run-dir> [chat-id]}"
CHAT_ID="${2:-${RALPH_NOTIFY_CHAT:-}}"

if [[ ! -f "$RUN_DIR/result.json" ]]; then
  echo "No result.json" >&2
  exit 1
fi

RESULT=$(cat "$RUN_DIR/result.json")
RUN_ID=$(echo "$RESULT" | jq -r '.run_id')
STATUS=$(echo "$RESULT" | jq -r '.status')
ITERS=$(echo "$RESULT" | jq -r '.iterations')
BRANCH=$(echo "$RESULT" | jq -r '.branch // "unknown"')
PR=$(echo "$RESULT" | jq -r '.pr // "none"')
TASK_TITLE=$(head -1 "$RUN_DIR/task.md" 2>/dev/null | sed 's/^#\+ //' || echo "unknown")

if [[ "$STATUS" == "success" ]]; then
  EMOJI="✅"
  STATUS_TEXT="All checks passed"
else
  EMOJI="❌"
  STATUS_TEXT="Failed after $ITERS iterations"
fi

MESSAGE="🏭 *Factory Run Complete*

$EMOJI *$TASK_TITLE*

Status: $STATUS_TEXT
Iterations: $ITERS
Branch: \`$BRANCH\`
PR: $PR
Run: \`$RUN_ID\`"

# ── Telegram ──────────────────────────────────────────────────────────────────

if [[ -n "$CHAT_ID" && -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  curl -sf -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "text=$MESSAGE" \
    -d "parse_mode=Markdown" \
    > /dev/null
  echo "📨 Notified Telegram: $CHAT_ID"
fi

# ── Webhook ───────────────────────────────────────────────────────────────────

if [[ -n "${NOTIFY_WEBHOOK:-}" ]]; then
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "$RESULT" \
    "$NOTIFY_WEBHOOK" > /dev/null
  echo "📨 Notified webhook"
fi

echo "$MESSAGE"
