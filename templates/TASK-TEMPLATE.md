# [Title: one-line summary of the change]

## Context
<!-- What's the current state? Why does this need to change? -->


## Requirements
<!-- Specific, testable requirements. Each one becomes a pass/fail criterion. -->
- [ ] 
- [ ] 
- [ ] 

## Files Likely Involved
<!-- Help the agent focus. Not exhaustive, just directional. -->
- `lib/...`
- `test/...`

## Acceptance Criteria
<!-- What does "done" look like? Be concrete — the harness checks these. -->
- `flutter analyze` passes with zero issues
- `flutter build ios --no-codesign` succeeds
- No regressions in existing tests

## Anti-Patterns (DO NOT)
<!-- Guard rails against metric gaming -->
- Do NOT delete or skip existing tests
- Do NOT suppress warnings/errors
- Do NOT hardcode values to pass assertions
- Do NOT add `// ignore` comments to silence analyzer

## References
<!-- Links, related PRs, docs, code snippets -->
- 
