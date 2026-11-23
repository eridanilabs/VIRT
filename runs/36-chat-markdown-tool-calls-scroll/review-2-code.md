# Review r2: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/SessionChatViewModel.swift:56: Following turns off when the offset drops by any amount while the chat isn't within 24 pt of the bottom, even by a fraction of a point. The one window where that can happen with following on is after content grows and before the `scrollTo` runs. In that window, a layout nudge that moves the offset up could turn following off by mistake. The builder's simulator run kept up through 3 s of streaming and settled with a 1 pt move. I see no failure here, but if following ever drops on its own on a device, this check is the first place to look.
- [note] VIRT/SessionChatViewModel.swift:59: The chat scrolls to the end only when the content grows and is no longer within 24 pt of the bottom. Two effects follow:
  - A size change that keeps the content height but leaves the view above the end, such as rotating to landscape, keeps following on but doesn't scroll until the next growth.
  - Growth smaller than the margin can leave up to about 4 pt of the last row below the screen. The list's roughly 20 pt bottom padding covers the rest.
  
  Both fit the spec's "about 24 pt" assumption.
- [note] VIRT/SessionChatView.swift:64-66: Tapping a tool call in the middle of the screen while you're at the bottom makes the content grow, so the chat scrolls to the end and the row slides up. This is how following works by design. Whether it feels right is reviewer-ux's call.

## Coverage
- Files read:
  - Setup: AGENTS.md, spec.md, triage-1.md, review-1-code.md, build-2.md, the reviewer-code agent file, LOOP.md `## Severity`.
  - Diffs: the full `f6a41eb...HEAD` diff (as stat plus delta) and the `9bf2d63..HEAD` delta.
  - Source: VIRT/SessionChatView.swift (whole file), VIRT/SessionChatViewModel.swift (whole file), Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:55-100, Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift.
  - Tests: VIRTTests/SessionChatViewModelTests.swift:1-100, the `SessionChatTests.swift` delta and test list.
  - Other: `DisclosureChevron` in VIRT/HostsView.swift:117-124 (it's `accessibilityHidden`), the `ToolCallCancellationReason` cases (denied, skipped, result-denied: the switch covers all three), scripts/test.sh.
- Flows walked:
  - Following the bottom through `scrolled(from:to:)`:
    - Opening the screen: empty content, then the first chat grows the content and it scrolls to the end.
    - Streaming growth while following, including growth inside the 24 pt margin.
    - Moving up by drag, status bar or a scripted jump, including a move reported together with growth. Each turns following off.
    - Growth while scrolled up, and scrolling down short of the end. Neither moves the view.
    - Coming back to the bottom turns following on.
    - The `scrollTo` landing about 20 pt short of the end still counts as at the bottom, and its own geometry change moves the offset down, so it never turns following off.
    - Overscroll and bounce at the end, and short content that doesn't fill the screen.
    - Rotation.
    - Collapsing a row at the bottom shrinks the content, and the clamped offset still counts as at the bottom.
  - Tool call row: no details (a plain label, no button), collapsed, expanded (wrench, details under the summary, chevron turned 90°), the accessibility value, and expanding the last row at the bottom (growth triggers the scroll, so #52 is covered).
  - Cancelled reason words for all three cases, together with a blank or Markdown invocation message and the reason message.
- Commands run:
  - `set -o pipefail; ./scripts/test.sh 2>&1 | tail -40` → exit 0.
  - `set -o pipefail; ./scripts/test.sh 2>&1 | grep …` → exit 0:
    - VIRTKit: "74 tests in 12 suites passed", `SessionChatTests` passed.
    - App: `followsTheBottomUntilYouScrollAway()` and `anyScrollAwayTurnsFollowingOffButGrowingContentDoesNot()` passed.
    - No `warning:` or `error:` lines.
  - `git diff 9bf2d63..HEAD`, `git diff --stat f6a41eb...HEAD` (286+/51−).
- Earlier blockers: none (my round 1 review had no blockers). My round 1 nit, the `old != .animating` guard that skipped the bottom check after an animated scroll, is fixed: commit 96e0150 removes the scroll-phase handling, and following now comes from scroll geometry, so any move up turns it off.

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:8-12, VIRT/SessionChatView.swift:58-59 | Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift › "inlineMarkdownGetsItsStylesAndKeepsLineBreaks", "plainTextComesBackVerbatim" |
| AC2 | Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:9,13-14, VIRT/SessionChatView.swift:49-57 | Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift › "htmlStaysLiteralAndLinksAndImagesAreRemoved", VIRTTests/SessionChatViewModelTests.swift › "showsEachChatItAsSentAndHostTextVerbatim" |
| AC3 | Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:14,59-72,80-99 | Packages/VIRTKit/Tests/VIRTKitTests/SessionChatTests.swift › "itemsFollowTheTurnsInOrderAsPlainText" (fixtures c1–c4, c6), "toolCallDetailsLeaveOutBlankValuesAndKeepMarkdownAsPlainText" |
| AC4 | VIRT/SessionChatViewModel.swift:17-18,37-42, VIRT/SessionChatView.swift:60-99 | VIRTTests/SessionChatViewModelTests.swift › "toolCallStartsCollapsedAndTogglesAndStaysExpandedAcrossUpdates" |
| AC5 | VIRT/SessionChatViewModel.swift:19-20,44-60,83-87, VIRT/SessionChatView.swift:16-26,43-45 | VIRTTests/SessionChatViewModelTests.swift › "followsTheBottomUntilYouScrollAway", "anyScrollAwayTurnsFollowingOffButGrowingContentDoesNot" |
