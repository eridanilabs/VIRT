# Review r1: ux (claude-sonnet-5.5)

VERDICT: CHANGES
## Findings
- [blocker] (ac) VIRT/SessionChatView.swift:17-24: Only a drag (`.interacting`) can turn following off, and the check is skipped whenever a scroll ends after `.animating`. A user can also scroll up by tapping the status bar to jump to the top, by a VoiceOver three-finger swipe or by moving VoiceOver focus, or by keyboard scrolling. These scrolls don't drag, and the system animates some of them, so `followsBottom` stays true. The next reply delta then runs `proxy.scrollTo(last.id)` and pulls the user back to the bottom. That breaks AC5 ("Once you scroll up away from the bottom, new content doesn't move the view"), and VoiceOver users get the worst of it: they can't stop the chat jumping. The reverse also fails: scrolling back to the bottom by one of these routes doesn't turn following back on. The build notes say nobody has tried the scrolling on a simulator or device, and the tests only cover `setAtBottom` in the view model. I'm going by the documented phase behaviour, not a run on a device. Fix: work out "at bottom" from scroll position changes, not from phases. For example, use `onScrollGeometryChange` and call `setAtBottom(isAtBottom)` only when the content offset changed and the content size didn't, so a growing reply never turns following off. If you keep the phase approach, at least drop the `old != .animating` guard: the view's own `scrollTo` isn't animated, so the guard only hides system scrolls. Then check the status-bar tap and VoiceOver scrolling on a simulator.
- [nit] (polish) Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:88: A cancelled tool call shows the protocol's raw reason token (`.string(s.reason.rawValue)`) as a detail line, so the user sees `result-denied`, `denied` or `skipped`. Fix: map the reason to short words such as "Denied", "Skipped" and "Result denied", or show the token only when there's no `reasonMessage`.
- [nit] (polish) VIRT/SessionChatView.swift:63-88: A tool call whose details are all blank shows the chevron anyway. For example, a blank `toolName` on a call that is still streaming with no invocation message. Tapping it only flips the chevron and reads as "Expanded" with nothing shown. Fix: when `details` is empty, show the summary as a plain row with no chevron, no button and no Expanded/Collapsed value.
- [nit] (polish) VIRT/SessionChatView.swift:65-67: Tapping the last tool call while the chat is at the bottom expands its details below the visible area. Nothing scrolls, because `items` didn't change, so the user has to scroll down to see what they opened. Fix: after `toggle`, if the item is the last one and following is on, call `proxy.scrollTo(item.id, anchor: .bottom)`.
- [note] VIRT/SessionChatView.swift:88: The tool call row is a `Button` with an accessible name (the summary, plus the details when expanded) and an "Expanded" or "Collapsed" value. It can be reached with VoiceOver and Full Keyboard Access, and the whole row width is tappable.
- [note] Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:8-16: Raw HTML stays as literal text, links show only their text and can't be tapped, and if parsing fails the reply shows exactly as sent. This matches AC1 and AC2. User messages and tool call details still use `Text(verbatim:)`.
## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, LOOP.md (Severity), VIRT/SessionChatView.swift (full), VIRT/SessionChatViewModel.swift (full), Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift, Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift (diff and context), ChatMarkdownTests.swift, SessionChatTests.swift and SessionChatViewModelTests.swift (diff), the AHP `ToolCallCancellationReason` and tool call state types (to check the reason tokens and which messages can be missing), and the SwiftUI `ScrollPhase` interface.
- Flows walked:
  - Opening a chat: loading → the first chat arrives → the initial scroll to the bottom; the empty and failed overlays are unchanged.
  - A reply streaming while following: each delta changes `items`, which runs `scrollTo` on the last item.
  - Scrolling up by drag (interacting → decelerating → idle): following turns off and is re-checked at idle.
  - Scrolling up by status-bar tap, VoiceOver or keyboard (no interacting phase): following stays on, the blocker above.
  - Scrolling back to the bottom.
  - Content shorter than the screen.
  - A tool call: collapsed → tap to expand → still expanded across updates → tap to collapse; tool calls with empty details; expanding the last row; what VoiceOver reads for the row.
  - Reply rendering: bold, italic and code; HTML; links and images; the verbatim fallback.
- Commands run:
  - `git diff f6a41eb...HEAD` (stat, sources and tests) → read
  - `./scripts/test.sh` → exit 0, run twice
  - grep of the AHP generated types → reason tokens `denied`, `skipped` and `result-denied`; `invocationMessage` is optional while a tool call streams
