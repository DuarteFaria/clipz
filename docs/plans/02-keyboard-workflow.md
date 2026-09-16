# Improve keyboard navigation and search

## Status

Planning only; implementation has not started. Keep this PR in draft until its
scope is implemented and its acceptance criteria are verified.

This is milestone 2 of 3. Depends on milestone 1 (clipboard reliability and
recovery). Merge before milestone 3 (runtime overhead and ownership).

## Goal

Everyday use works without reaching for the mouse.

## Scope

- Preserve focus by stable entry ID across live updates.
- Replace debug-string key matching with framework actions/keybindings.
- Separate explicit open, close, and toggle behavior.
- Fix Escape for empty history and define its behavior during search.
- Add search with predictable navigation through results.
- Make the global shortcut configurable, persisted, and accurately displayed.
- Handle shortcut conflicts without crashing.
- Add keyboard pin/delete and visible shortcut hints.
- Close after successful selection; keep failures visible.
- Correct and validate multi-monitor popover positioning.
- Include tests and documentation in this PR.

## Scope boundary

Keep Enter as **copy**, not automatic paste into the previous app. Direct paste,
including its Accessibility permission and focus-restoration requirements, stays
out of these three milestones.

## Acceptance criteria

- [ ] Incoming clipboard changes never silently move selection to a different item.
- [ ] Search, navigation, selection, pinning, and deletion are keyboard-accessible.
- [ ] Escape behaves consistently with empty history, active search, and normal results.
- [ ] Shortcut settings survive restart; registration conflicts leave the app usable.
- [ ] Displayed shortcut hints match the active bindings.
- [ ] Successful selection closes the popover; failures remain visible.
- [ ] Open, close, and toggle behavior is explicit and covered by tests.
- [ ] Popover placement works across different display arrangements.
- [ ] Enter remains a copy action, without automatic paste.
- [ ] Regression tests and user documentation cover the keyboard workflow.
