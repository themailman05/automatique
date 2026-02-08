# Fix loop sync drift on pause/resume

## Context
When a user pauses playback and resumes, subsequent recordings are misaligned with the loop point. The `AudioLoop.startTimeOffset` doesn't account for time spent paused, causing cumulative drift.

## Requirements
- [ ] Track cumulative pause duration in `audio_player_bloc.dart`
- [ ] Subtract pause duration from loop point calculation on resume
- [ ] Ensure `AudioLoop.recordingStartTime` is adjusted on resume
- [ ] Add unit test covering pause→resume→record→verify-alignment scenario

## Files Likely Involved
- `lib/audio/audio_player_bloc.dart` — pause/unpause handlers
- `lib/audio/audio_engine_bloc.dart` — RequestSyncPlay orchestration
- `lib/models/audio_loop.dart` — AudioLoop model
- `test/audio/` — new test file

## Acceptance Criteria
- `flutter analyze` passes with zero issues
- `flutter build ios --no-codesign` succeeds
- New unit test passes: pause 2s, resume, record, verify alignment within 10ms tolerance

## Anti-Patterns (DO NOT)
- Do NOT delete or skip existing tests
- Do NOT change the 200ms sync delay in `_audioEngineRequestSyncPlay` without justification
- Do NOT modify SoLoud bindings
- Do NOT hardcode timing values to pass the test
