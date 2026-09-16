# Reduce runtime overhead and simplify ownership

## Status

Planning only; implementation has not started. Keep this PR in draft until its
scope is implemented and its acceptance criteria are verified.

This is milestone 3 of 3. Depends on milestones 1 (clipboard reliability and
recovery) and 2 (keyboard navigation and search).

## Goal

Eliminate avoidable polling, subprocess work, and blocking operations without
changing the established behavior.

## Scope

- Replace frontend timer-based event dispatch with event-driven updates.
- Remove redundant history refresh requests.
- Replace AppleScript clipboard capture/restore with native pasteboard access.
- Move slow clipboard and persistence work outside the history-state lock while
  preserving ordering.
- Remove filesystem checks from the render path.
- Make power-profile behavior match its configuration.
- Consolidate ownership of clipboard operations, backend lifecycle, and storage
  behind tested boundaries, without creating unnecessary tiny modules.
- Record before/after performance measurements.
- Include tests and documentation in this PR.

## Acceptance criteria

- [ ] Milestone 1 and milestone 2 behavior tests still pass.
- [ ] Hotkey and backend delivery no longer wait for the fixed 100 ms frontend timer.
- [ ] Supported clipboard operations no longer launch AppleScript subprocesses.
- [ ] Slow storage or clipboard operations do not hold the history-state mutex.
- [ ] Operation ordering and persistence correctness remain covered by regression tests.
- [ ] Rendering does not perform synchronous filesystem availability checks.
- [ ] Redundant post-command history refresh requests are removed.
- [ ] Power-profile behavior matches its documented configuration.
- [ ] Idle wakeups, capture latency, and selection latency are measured and compared.
- [ ] Runtime ownership boundaries and the measurement procedure are documented.
