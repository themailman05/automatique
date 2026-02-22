#!/usr/bin/env bash
###############################################################################
# restart.sh — Kill all running factory jobs and relaunch them
#
# Reads active runs from runs/active.json, kills processes, cleans branches,
# and relaunches with the latest ralph.sh.
#
# Usage: ./restart.sh
###############################################################################
set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "$0")" && pwd)"
ACTIVE_FILE="$FACTORY_DIR/runs/active.json"

echo "🏭 Restarting factory line..."

# ── Kill running processes ───────────────────────────────────────────────────
echo "  🔪 Killing running factory processes..."
pkill -f "ralph.sh" 2>/dev/null || true
pkill -f "claude.*dangerously-skip" 2>/dev/null || true
sleep 2

# ── Read active jobs ─────────────────────────────────────────────────────────
if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "  ⚠️  No active.json found. Nothing to restart."
  exit 0
fi

echo "  📋 Active jobs:"
cat "$ACTIVE_FILE" | python3 -c "
import json, sys
jobs = json.load(sys.stdin)
for j in jobs:
    print(f'     - {j[\"name\"]}: task={j[\"task\"]} trello={j.get(\"trello\",\"none\")}')
"

# ── Clean up stale branches ──────────────────────────────────────────────────
for branch in $(cd "$FACTORY_DIR" && python3 -c "
import json
jobs = json.load(open('$ACTIVE_FILE'))
for j in jobs:
    if 'branch' in j:
        print(j['branch'])
" 2>/dev/null); do
  echo "  🗑️  Deleting branch: $branch"
  (cd "$(python3 -c "import json; print(json.load(open('$ACTIVE_FILE'))[0]['repo'])")" && \
    git branch -D "$branch" 2>/dev/null || true
    git push origin --delete "$branch" 2>/dev/null || true)
done

# ── Relaunch all jobs ────────────────────────────────────────────────────────
echo ""
echo "  🚀 Relaunching..."
python3 -c "
import json, subprocess, os

jobs = json.load(open('$ACTIVE_FILE'))
factory = '$FACTORY_DIR'

for j in jobs:
    task = j['task']
    repo = j['repo']
    trello = j.get('trello', '')
    name = j['name']

    args = [f'{factory}/ralph.sh', task, '--repo', repo]
    if trello:
        args += ['--trello-card', trello]

    log = f'{factory}/runs/restart-{name}.log'
    print(f'     🏭 {name} → {log}')

    with open(log, 'w') as f:
        proc = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT,
                                start_new_session=True, cwd=repo)
        j['pid'] = proc.pid
        print(f'        PID: {proc.pid}')

# Update active file with new PIDs
json.dump(jobs, open('$ACTIVE_FILE', 'w'), indent=2)
"

echo ""
echo "  ✅ Factory line restarted. $(python3 -c "import json; print(len(json.load(open('$ACTIVE_FILE'))))" ) jobs running."
