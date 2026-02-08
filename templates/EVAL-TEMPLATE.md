# Evaluation Criteria: [Feature/Bug Name]

## Automated Checks (harness runs these)
<!-- These run after every iteration. ALL must pass to exit the loop. -->

### Build
- `flutter analyze --no-pub` → zero issues
- `flutter build ios --no-codesign --release` → exit 0

### Tests
- `flutter test` → all pass
- `flutter test test/specific_test.dart` → specific coverage

### Lint / Static Analysis
- No new `// ignore` annotations added
- No TODO comments without ticket reference

## Human Review Criteria (post-PR)
<!-- These are evaluated by Liam after the PR is created -->

### Code Quality
- [ ] Changes are minimal and surgical — no unrelated refactors
- [ ] No copy-paste duplication introduced
- [ ] Naming is clear and consistent with codebase conventions
- [ ] No magic numbers — constants are named

### Architecture
- [ ] Respects existing patterns (BLoC, repository, etc.)
- [ ] No new dependencies added without justification
- [ ] State management follows existing conventions

### Behavior
- [ ] Feature works as described in task requirements
- [ ] Edge cases handled (null, empty, overflow, concurrent access)
- [ ] No regressions in existing functionality

### Audio-Specific (CloudLoop)
- [ ] AEC pipeline untouched unless task requires it
- [ ] Sample rates and buffer sizes unchanged unless intentional
- [ ] Loop timing/sync logic unchanged unless task requires it
- [ ] Recording alignment preserved

## Scoring (for Braintrust)
<!-- Map criteria to numeric scores for tracking over time -->
| Dimension        | Weight | Score (0-1) | Notes |
|-----------------|--------|-------------|-------|
| Build passes    | 0.3    |             |       |
| Tests pass      | 0.3    |             |       |
| Code quality    | 0.2    |             |       |
| Minimal diff    | 0.1    |             |       |
| No regressions  | 0.1    |             |       |
