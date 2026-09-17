# Fix clipboard reliability and recovery

## Status

Implementation is in progress on `plan/clipboard-reliability`. Automated backend,
protocol, and frontend tests pass locally. Keep this PR in draft until CI and the
manual macOS checks below have been reviewed.

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

- [x] A → B → A correctly makes A current without changing its identity.
- [x] Startup captures the existing clipboard.
- [x] Transient capture failures are retried without losing the pending change.
- [x] Pinned entries cannot silently disable new captures.
- [x] Distinct images cannot be discarded because their prefixes match.
- [x] History and retained images survive restart.
- [x] Legacy image paths and missing assets are handled explicitly.
- [x] Failed saves remain pending; damaged history is not silently overwritten.
- [x] Persistence round-trips supported content, including control characters.
- [x] Clipboard restoration failures are reported accurately.
- [x] Backend failure is surfaced with Restart backend and Dismiss actions.
- [x] Pending history is flushed by the normal shutdown path.
- [x] CI actually executes the regression tests.
- [x] Architecture and protocol documentation reflect the implementation.

## Implementation decisions

- `max_entries` bounds unpinned history; pins are retained separately.
- Current clipboard identity is explicit and unknown until capture succeeds.
- Images are removed only after the history update is durable.
- Legacy image files are copied, not moved or deleted. Known PNG/JPEG/TIFF
  signatures correct legacy extension mismatches during migration.
- A damaged history file is quarantined before starting an empty history.
- Restart/Quit wait for normal backend exit off the UI thread, with a two-second
  forced-termination fallback. That fallback cannot guarantee unsaved data.
- Keyboard/search work and the native pasteboard/event-driven refactor remain
  in PR 2 and PR 3.

## Local verification

- `zig build test --summary all`: 28 tests passed.
- `python3 scripts/test-json-api.py`: 8 tests passed.
- `cargo test --locked -p clipz-gpui`: 14 tests passed.
- `zig build` and `cargo build --locked -p clipz-gpui`: passed.
- Zig/Rust formatting and `git diff --check`: passed.
- Five AppleScript templates compiled with `osacompile` without execution.

Tests use injected clipboards, isolated history/image directories, and fake
processes. The protocol harness runs the real backend with fake AppleScript I/O
and verifies startup capture, failure frames, corrupt-history recovery, pending
shutdown saves, and image persistence/deduplication across restart.

File-selection follow-up: capture now recognizes both Finder file URLs and the
AppleScript alias representation written by file restoration. Protocol errors
identify capture versus restore, and successful retries clear only the matching
transient warning. Tests cover restored-alias recapture and capture recovery;
the reported real Finder workflow still needs a user recheck.

## Manual macOS checks still required

- [ ] Copy and restore real text, Finder files/folders, and PNG/JPEG/TIFF images.
- [ ] Verify the error banner, Dismiss, and Restart backend in the actual popover.
- [ ] Quit through the menu, relaunch, and confirm the most recent history and
  images are present.
