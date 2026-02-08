# L'Automatique — Factory Loop Design

## Current (broken) flow
```
claude code → local checks → push → PR → notify "done!" 🎉
                                              ↑ LIES
```

## Correct flow
```
claude code → local checks → push → PR → poll CI → capture results → braintrust eval → notify
                ↑                              ↑                            ↑              ↑
            fast feedback                 wait for GHA              score with evidence   ONLY if real pass
            (analyze, lint)               to complete               (CI logs, test results)
```

## Progress Updates
During the run, send progress to Telegram:
- 🏭 Starting: task name, branch
- 🔄 Iteration N: running claude code...
- 🔍 Iteration N: running local checks...
- ❌ Iteration N: checks failed, retrying...
- 📤 Pushing PR...
- ⏳ Waiting for CI (run #XXXXX)...
- ✅/❌ CI complete: pass/fail + link
- 📊 Braintrust eval: score X

## CI Wait Loop
After PR is created:
1. `gh pr checks <branch> --watch` or poll `gh run list`
2. Wait for all required checks to complete (timeout: 30min)
3. If CI fails: feed errors back into the loop (new iteration)
4. If CI passes: proceed to eval

## Braintrust Eval
After CI passes:
1. Capture: CI run logs, test results, build artifacts
2. Score dimensions:
   - `ci_passes` (binary) — did all GHA checks pass?
   - `iterations` (efficiency) — how many attempts?
   - `diff_size` — lines changed
   - `ci_duration` — how fast was the build?
3. Log experiment to Braintrust with task as input, PR as output
4. Append to `factory-runs` dataset

## Notification Rules
- Progress updates: lightweight, no reply expected
- Final notification: ONLY after CI passes + Braintrust eval logged
- If CI fails and all iterations exhausted: notify with failure + CI logs link
