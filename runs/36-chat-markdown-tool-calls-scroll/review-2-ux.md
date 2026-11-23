# Review r2: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) VIRT/SessionChatViewModel.swift:53-59: A drag no longer turns following off when it starts. It only turns off once the drag leaves the 24 pt "at the bottom" margin. While a reply streams, each piece that makes the content taller runs `proxy.scrollTo(last.id)` (VIRT/SessionChatView.swift:23-24). That happens because the offset didn't go down in that report and following is still on. So if you start a slow drag up from the bottom, the chat pulls you back down every time new text arrives, until you get more than 24 pt up between two pieces. Round 1 turned following off as soon as the drag started (`.interacting`), so this is a step back for touch users, though it's minor. Fix: keep the geometry rule, and also call `setAtBottom(false)` when the scroll phase becomes `.interacting`. Then call `setAtBottom(isAtBottom(context.geometry))` when it returns to `.idle`, so a touch that doesn't move doesn't leave following off.
- [note] VIRT/SessionChatViewModel.swift:53-59: Following now comes only from the scroll position. It turns on when the view reaches the bottom and off when the offset goes down. It no longer depends on scroll phases, so a status-bar tap, a VoiceOver three-finger swipe, VoiceOver moving focus to an earlier row, and keyboard scrolling all turn it off. Each of them makes the offset go down. If content shrinks at the bottom, such as when you collapse the last tool call, the offset is clamped but the view is still at the bottom, so following stays on. The "at bottom" check runs first in that case. Nobody has checked VoiceOver, keyboard scrolling or real touches on a device, as build-2.md says. Self-sizing `List` corrections could still lower the offset in the moment after the content grows and before `scrollTo` runs, which would turn following off on its own. The builder's 3 s streaming run on the simulator didn't show this, but a device pass should watch for it.
- [note] VIRT/SessionChatView.swift:60-77: A tool call with details is a `Button` with a trailing `DisclosureChevron` (VoiceOver skips it) and an "Expanded" or "Collapsed" value. A tool call with no details is a plain row that VoiceOver reads as just the summary. The reason a tool call was cancelled now shows as "Denied", "Skipped" or "Result denied". The `switch` covers all 3 cases of the generated `ToolCallCancellationReason` enum.
## Coverage
- Files read: the agent file; LOOP.md (Severity); AGENTS.md; spec.md, triage-1.md, review-1-ux.md and build-2.md; VIRT/SessionChatView.swift (full); VIRT/SessionChatViewModel.swift (full); Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift (tool call details and the status mapping); the delta in SessionChatTests.swift and SessionChatViewModelTests.swift; `DisclosureChevron` in VIRT/HostsView.swift; the generated `ToolCallCancellationReason` enum.
- Flows walked:
  - Opening the chat: loading → the first chat arrives → the content grows while following → scroll to the end.
  - A reply streaming at the bottom: each change in content height scrolls to the end. Growth of less than 4 pt stays inside the margin and doesn't scroll.
  - Scrolling up by drag, status bar, VoiceOver swipe or focus move, or keyboard: the offset goes down, so following turns off, even when the same report includes growth.
  - A slow drag starting at the bottom while a reply streams (the nit).
  - Scrolling back to within 24 pt of the end: following turns on.
  - Content shorter than the screen: it's always at the bottom, and once it outgrows the screen, the view scrolls.
  - Content shrinking at the bottom (collapsing a tool call, or the Markdown re-parse dropping a line): the offset is clamped but the view is still at the bottom, so following stays on.
  - Expanding the last tool call at the bottom: the content grows, following is on, and the view scrolls to the end (#52). Expanding a tool call while scrolled up: nothing moves.
  - A tool call with no details is a plain row. A tool call whose details arrive later becomes a `Button`.
  - A cancelled tool call: the reason shows in words, followed by the reason message.
- Commands run:
  - `git diff 9bf2d63..HEAD` (stat and full) → read
  - `git log --oneline -6` → the commits are 96e0150, 1090b1d and b04efb4
  - `set -o pipefail; ./scripts/test.sh` → exit 0 (VIRTKit and the app tests pass on the iPhone 18 Pro simulator)
- Earlier blockers: [blocker] (ac) VIRT/SessionChatView.swift:17-24, only a drag turns following off (AC5), sub-issue #49 → fixed. Any scroll that lowers the offset now turns following off, and reaching the bottom turns it back on. The test `anyScrollAwayTurnsFollowingOffButGrowingContentDoesNot` covers the rule. VoiceOver, keyboard and real-touch scrolling are still unchecked on a device, which is the note above.
- Earlier nits: #51 (the reason in words) → fixed. #52 (expanding the last tool call scrolls it into view) → fixed in the code by the growth rule, but not checked on the simulator. #50, my part (a tool call with no details is a plain row) → fixed.
