# Fix clipboard reliability and recovery

## Status

Planning only; implementation has not started. Keep this PR in draft until its
scope is implemented and its acceptance criteria are verified.

This is milestone 1 of 3. Merge before milestone 2 (keyboard navigation and
search), then milestone 3 (runtime overhead and ownership).

## Goal

Clipz captures, restores, and retains the right content, and makes failures visible.

## Scope

- Fix Zig test discovery and add pull-request CI.
- Correct current-item tracking: capture on startup, promote duplicates while
  preserving IDs, and retry transient capture failures.
- Prevent pinned entries from silently disabling new captures.
- Replace partial-image comparison with full-content equality.
- Move retained images into private, durable application storage; handle legacy
  paths and missing assets.
- Fix persistence escaping, retain dirty state after failed saves, and preserve
  corrupt history for recovery.
- Report clipboard restoration failures accurately.
- Surface backend startup errors, command failures, and disconnection; provide
  a retry/restart action.
- Replace fixed-sleep shutdown with graceful exit and a bounded timeout.
- Update stale architecture and protocol documentation.
- Include regression tests and documentation in this PR. Small structural changes
  needed for reliable testing belong here; broad runtime restructuring belongs
  in milestone 3.

## Acceptance criteria

- [ ] A → B → A correctly makes A current without changing its identity.
- [ ] Startup captures the existing clipboard.
- [ ] Transient capture failures are retried without losing the pending change.
- [ ] Pinned entries cannot silently disable new captures.
- [ ] Distinct images cannot be discarded because their prefixes match.
- [ ] History and retained images survive restart.
- [ ] Legacy image paths and missing assets are handled explicitly.
- [ ] Failed saves remain pending; damaged history is not silently overwritten.
- [ ] Persistence round-trips supported content, including control characters.
- [ ] Clipboard restoration failures are reported accurately.
- [ ] Backend failure is visible and recoverable.
- [ ] Pending history survives normal application quit.
- [ ] CI actually executes the regression tests.
- [ ] Architecture and protocol documentation reflect the implementation.
