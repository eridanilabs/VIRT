# Build r2: builder-app (claude-opus-5.5)

## Summary
I fixed blocker #49: any scroll up now turns following off, not only a drag. I checked this with a status-bar scroll to the top on the simulator, but couldn't test VoiceOver, keyboard scrolling or a real tap (details below). Following is now worked out from the scroll position alone. Reaching the bottom turns it on, and any move up turns it off, so the phase checks and the `old != .animating` guard are gone.

The chat now scrolls to the end only when the content grows while following is on. My first version scrolled whenever the items changed. On the simulator that pulled the view back down when a status-bar scroll started just after a reply arrived, because SwiftUI reported the scroll too late. All five nits are fixed too.

The branch is now 286 lines added and 51 removed against the base, under the 400 limit. Nothing is pushed.

## Commits
- `96e0150` fix(chat): turn following off for any scroll up, not only a drag (`Refs: #36`, `Refs: #49`)
- `1090b1d` fix(chat): keep the wrench on tool calls and line details up with the summary (`Refs: #36`)
- `b04efb4` fix(chat): show a cancelled tool call's reason in words (`Refs: #36`)

All three have the Copilot co-author trailer.

## Changes
- **`VIRT/SessionChatViewModel.swift`:** added `ChatScroll` (offset, height, at bottom) and `scrolled(from:to:) -> Bool`. It calls the existing `setAtBottom(_:)` and returns whether to scroll to the end.
- **`VIRT/SessionChatView.swift`:**
  - The scroll handling is replaced by one scroll-geometry handler that calls `scrolled(from:to:)` and scrolls to the last item only when told to.
  - A tool call keeps its wrench icon and gets the existing `DisclosureChevron` at the trailing edge, turned 90° when open.
  - Detail lines sit under the summary text, with default spacing.
  - A tool call with no details is a plain row.
- **`Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift`:** a cancelled call's reason shows as "Denied", "Skipped" or "Result denied".
- **Tests:** added `anyScrollAwayTurnsFollowingOffButGrowingContentDoesNot` and updated the cancelled fixtures in `SessionChatTests`.

## Simulator check (iPhone 18 Pro, iOS 27)
I used a temporary harness that I didn't commit and have since removed. It opens the chat on a fake connector that streams a reply every 250 ms, then logs whether following is on and the scroll offset.

| Step | Result |
|---|---|
| Status-bar scroll to the top (UIKit's private status-bar scroll-to-top call, run from the harness) | Following turned off. The view stayed at the top for 3 s of streaming (it moved 1 pt as it settled). |
| Animated scroll to the top, a scroll down short of the bottom, and a sudden jump up (all scripted) | Following turned off and stayed off. The view didn't move while content streamed. |
| Scroll back to the bottom (scripted, animated) | Following came back on and kept up for the next 3 s (19 pt from the end). |
| VoiceOver three-finger swipe | **Not verified.** `accessibilityScroll(.up)` returned false with VoiceOver off. |
| Keyboard scrolling | **Not verified.** I had no way to drive it. |
| Real finger tap on the status bar, or a real drag | **Not verified.** `simctl` can't inject touches. |

VoiceOver and keyboard scrolls move the same scroll offset, so the new rule should cover them, but it's worth checking on a device. The details opening at the bottom (see the reviewer-ux nits below) also wasn't checked on the simulator; it relies on the same growth rule.

Two things I learned on the way:
- `.scrollPosition` doesn't work with `List`: the chat stayed at the top. So the chat still uses `ScrollViewReader`.
- Scrolling the `List` to its last item stops about 20 pt short of the true end, because of the list's bottom padding. That is inside the 24 pt "at the bottom" margin, but only just.

## Findings
- reviewer-ux · `[blocker] (ac) VIRT/SessionChatView.swift:17-24: Only a drag (`.interacting`) can turn following off, …` → **Fixed** in 96e0150 (sub-issue #49). Following now comes from scroll position changes, by any route.
- reviewer-code · `[nit] (polish) VIRT/SessionChatView.swift:21: The `old != .animating` guard skips the bottom check after any animated scroll, such as a status-bar tap to the top.` → **Fixed** in 96e0150. The scroll-phase handling is gone.
- reviewer-ui-design · `[nit] (polish) VIRT/SessionChatView.swift:73: The tool call row's icon is now `chevron.right` / `chevron.down` instead of `wrench.and.screwdriver`, …` → **Fixed** in 1090b1d. The wrench is back, with a trailing `DisclosureChevron` turned 90° when open.
- reviewer-ui-design · `[nit] (polish) VIRT/SessionChatView.swift:68-80: Expanded detail lines line up under the icon, not the summary text, and use a hard-coded `spacing: 4`.` → **Fixed** in 1090b1d. The details are inside the label's text, with default spacing.
- reviewer-ux · `[nit] (polish) Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:88: A cancelled tool call shows the raw reason token (`result-denied`, `denied`, `skipped`) as a detail line.` → **Fixed** in b04efb4. It shows "Denied", "Skipped" or "Result denied".
- reviewer-ux · `[nit] (polish) VIRT/SessionChatView.swift:63-88: A tool call with no details still shows a chevron and toggles to nothing …` → **Fixed** in 1090b1d. It's a plain row with no button, chevron or Expanded/Collapsed value.
- reviewer-ux · `[nit] (polish) VIRT/SessionChatView.swift:65-67: Tapping the last tool call while at the bottom expands its details below the visible area.` → **Fixed** in 96e0150. Opening details makes the content taller, and that scrolls to the end when following is on, so no separate scroll on tap is needed.

## Tests
`./scripts/test.sh` passes (exit 0) with no build warnings:
- **VIRTKit:** `✔ Test run with 74 tests in 12 suites passed after 0.976 seconds.`
- **App (iPhone 18 Pro simulator):** 42 test cases passed, 0 failed.

## Found, not fixed
none
