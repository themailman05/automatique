#!/usr/bin/env bash
###############################################################################
# dispatch.sh — Dispatch a task to the Ralph Wiggum loop from a message
#
# Called by Le Automat when Liam sends a task via Telegram.
# Writes the task file, kicks off ralph.sh in background, reports status.
#
# Usage:
#   ./dispatch.sh "Fix the login bug" [--checks "flutter_analyze:flutter_test"]
###############################################################################
set -euo pipefail

FACTORY_DIR="$HOME/.openclaw/workspace/factory"
TASK_TEXT="$1"
shift || true

# Generate task file
TASK_ID="$(date +%Y%m%d-%H%M%S)"
TASK_FILE="$FACTORY_DIR/tasks/$TASK_ID.md"
mkdir -p "$FACTORY_DIR/tasks"

echo "$TASK_TEXT" > "$TASK_FILE"

echo "📋 Task written: $TASK_FILE"
echo "🚀 Dispatching to Ralph Wiggum loop..."

# Run ralph in background
nohup "$FACTORY_DIR/ralph.sh" "$TASK_FILE" "$@" \
  > "$FACTORY_DIR/runs/dispatch-$TASK_ID.log" 2>&1 &

echo "PID: $!"
echo "Log: $FACTORY_DIR/runs/dispatch-$TASK_ID.log"
