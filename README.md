# 🏭 Factory

A [Ralph Wiggum Loop](https://beuke.org/ralph-wiggum-loop/) harness for autonomous software development. Runs [Claude Code](https://code.claude.com/) in a retry loop against external checks until all checks pass or safety limits are hit. All sessions traced to [Braintrust](https://braintrust.dev) for observability.

Inspired by Steve Yegge's [Gas Town](https://steve-yegge.medium.com/welcome-to-gas-town-4f25ee16dd04) factory model: specs go in, working software comes out.

## How It Works

```
You (prompt + eval criteria)
    │
    ▼
Orchestrator (OpenClaw / script)
    │
    ├── Creates branch from master
    ├── Writes task file
    ├── Dispatches to ralph.sh
    │       │
    │       ▼
    │   ┌─────────────────────────────┐
    │   │ Claude Code (--print mode)  │
    │   │   • Reads task + feedback   │
    │   │   • Makes changes           │
    │   │   • Commits                 │
    │   └─────────────┬───────────────┘
    │                 │
    │                 ▼
    │   ┌─────────────────────────────┐
    │   │ External Checks             │
    │   │   • Build (flutter/npm/make)│
    │   │   • Test suite              │
    │   │   • Static analysis / lint  │
    │   └─────────────┬───────────────┘
    │                 │
    │           PASS? ├── YES → push + draft PR ✅
    │                 └── NO  → feed errors back ↩️
    │                          (repeat until limit)
    │
    ├── All traces → Braintrust (project: Factory)
    └── Status → Telegram / notifications
```

**Key principle:** The harness decides when it's done, not the agent. External checks are ground truth. The agent proposes, the checks dispose.

## Quick Start

### 1. Install

```bash
git clone https://github.com/themailman05/factory.git
cd factory
```

### 2. Configure

```bash
# Required
export BRAINTRUST_API_KEY="sk-..."

# Optional (defaults shown)
export BRAINTRUST_CC_PROJECT="Factory"
export RALPH_REPO="$HOME/src/your-repo"
export RALPH_MAX_ITERS=8
export RALPH_MAX_COST_USD=5.00
export RALPH_MODEL=sonnet
```

### 3. Install Braintrust Plugin for Claude Code

```bash
claude plugin marketplace add braintrustdata/braintrust-claude-plugin
claude plugin install trace-claude-code@braintrust-claude-plugin
```

Add to `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "trace-claude-code@braintrust-claude-plugin": true
  },
  "env": {
    "TRACE_TO_BRAINTRUST": "true",
    "BRAINTRUST_CC_PROJECT": "Factory",
    "BRAINTRUST_API_KEY": "sk-..."
  }
}
```

### 4. Run

```bash
# Write a task file (see templates/)
./ralph.sh tasks/my-task.md

# With options
./ralph.sh tasks/my-task.md \
  --branch agent/fix-bug \
  --max-iters 10 \
  --model opus \
  --checks "flutter_analyze:flutter_build_ios:flutter_test"
```

## User Guide

### Writing Task Prompts

A good task prompt is the difference between a one-iteration success and a burned budget. Use `templates/TASK-TEMPLATE.md` as a starting point.

**Essential sections:**

| Section | Purpose |
|---------|---------|
| **Title** | One-line summary — becomes the PR title |
| **Context** | Why this change is needed. Current state. |
| **Requirements** | Specific, testable requirements. Each becomes a pass/fail. |
| **Files Likely Involved** | Focus the agent. Not exhaustive, just directional. |
| **Acceptance Criteria** | What "done" looks like. The harness checks these. |
| **Anti-Patterns (DO NOT)** | Guard rails against metric gaming. |

**Example prompt** (just message this):

```
# Fix loop sync drift on pause/resume

## Context
When a user pauses playback and resumes, subsequent recordings
are misaligned with the loop point.

## Requirements
- [ ] Track cumulative pause duration in audio_player_bloc.dart
- [ ] Subtract pause duration from loop point on resume
- [ ] Add unit test for pause→resume→record→verify alignment

## Acceptance Criteria
- flutter analyze passes
- flutter build ios --no-codesign succeeds
- New test passes with 10ms alignment tolerance

## DO NOT
- Delete or skip existing tests
- Change the 200ms sync delay without justification
- Hardcode timing values to pass the test
```

### Writing Eval Criteria

Eval criteria have two layers:

**Automated (harness enforces these):**
- Build passes
- Tests pass
- Static analysis clean

**Human review (you check after PR):**
- Changes are minimal and surgical
- No unrelated refactors
- Edge cases handled
- No regressions

See `templates/EVAL-TEMPLATE.md` for a full scoring rubric compatible with Braintrust.

### Checks

Built-in check types (auto-detected or pass via `--checks`):

| Check | Command |
|-------|---------|
| `flutter_analyze` | `flutter analyze --no-pub` |
| `flutter_build_ios` | `flutter build ios --no-codesign --release` |
| `flutter_test` | `flutter test` |
| `npm_test` | `npm test` |
| `make_test` | `make test` |
| Custom | Any shell command as a string |

Combine with colons: `--checks "flutter_analyze:flutter_build_ios:flutter_test"`

### Safety Limits

| Limit | Default | Flag |
|-------|---------|------|
| Max iterations | 8 | `--max-iters N` / `RALPH_MAX_ITERS` |
| Max cost per run | $5.00 | `--max-cost N` / `RALPH_MAX_COST_USD` |

If the loop hits either limit without passing, it stops and reports failure. Check the logs in `runs/<run-id>/` for diagnostics.

### Run Logs

Every run creates a directory under `runs/<run-id>/` containing:

```
runs/20260208-094500-a1b2c3/
├── task.md                  # Original task file
├── prompt-iter-1.md         # Full prompt sent to Claude (iter 1)
├── claude-iter-1.log        # Claude Code output (iter 1)
├── checks-iter-1.log        # Check output (iter 1)
├── prompt-iter-2.md         # Prompt with failure feedback (iter 2)
├── ...
└── result.json              # Final status, PR URL, iteration count
```

### Observability (Braintrust)

With the trace plugin configured, every Claude Code session appears in Braintrust as:

- **Session root** — overall run
- **Turns** — each conversation exchange
- **Tool calls** — file reads, edits, terminal commands

View at: https://braintrust.dev → Project "Factory" → Logs

## Philosophy

### Ralph Wiggum Loop
> "Run an AI agent in a loop against external checks until the job passes. Instead of asking the model when it's done, the harness decides."

The model proposes code changes. The checks (build, test, lint) are the objective truth. Failed check output feeds back raw and unfiltered — the agent confronts its own mistakes.

### Gas Town (Steve Yegge)
> "When work needs to be done, nature prefers colonies."

Code agents are factory workers, not artisans. The value is in the factory — orchestration, automation, feedback loops — not in any single worker. Scale by having more workers, not smarter ones.

### Guard Rails
Every task includes explicit anti-patterns to prevent metric gaming:
- Don't delete tests to make them "pass"
- Don't suppress errors to make the build "clean"
- Don't hardcode values to make assertions "true"
- Fix the actual underlying problem.

## License

MIT
