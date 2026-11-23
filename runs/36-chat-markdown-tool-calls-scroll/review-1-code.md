# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) VIRT/SessionChatView.swift:21: The `old != .animating` guard skips the bottom check after any animated scroll. That includes tapping the status bar to jump to the top (idle → animating → idle). If you were following before the tap, `followsBottom` stays `true`, so the next streamed delta jumps the view back to the bottom. AC5 says new content mustn't move the view once you've scrolled up. `scrollTo` in `onChange` isn't animated, so it never produces an `.animating` phase that the guard would need to filter out. Fix: on every change to `.idle`, set the bottom state from `isAtBottom(context.geometry)`, or handle `.animating → .idle` the same way.
- [note] Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:10-12: No test covers the verbatim fallback for text the parser rejects. `.inlineOnlyPreservingWhitespace` almost never throws, and the spec's test plan doesn't ask for this test. The fallback is a plain `AttributedString(text)`, which is correct on inspection.
- [note] VIRT/SessionChatViewModel.swift:18: The `expanded` set grows only by the tool calls you tap, and it lives only as long as the screen's model, so it can't grow without limit.

## Coverage
- Files read: AGENTS.md, spec.md, the reviewer-code agent file, LOOP.md (`## Severity`), the full `f6a41eb...HEAD` diff, VIRT/SessionChatView.swift (whole file), VIRT/SessionChatViewModel.swift (whole file), Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift, the `SessionChat.swift` hunks, the `SessionChatTests.swift` fixture (snapshot c1–c6 and steps), ChatMarkdownTests.swift, the `SessionChatViewModelTests.swift` hunks, scripts/test.sh, Package.swift platforms, the generated AHP `State.generated.swift` tool call fields (which messages are optional), and the deployment target in project.pbxproj.
- Flows walked:
  - Reply rendering: Markdown parse → link and image attributes cleared → `Text(AttributedString)`. Covered HTML, links, images, autolinks and the parse-throw fallback.
  - Building a tool call item, for each `ToolCallState` case: streaming, running, the three waiting states, completed (success and failure), cancelled (reason plus message, blank and markdown values) and unknown (dropped).
  - Expanding and collapsing: tap → `toggle` → `isExpanded`, and the expanded state survives a new chat with the same id.
  - Following the bottom:
    - Opening the screen: initial anchor, loading, then the first chat arrives and `onChange` scrolls to the last item.
    - Streaming deltas while following.
    - Dragging up (interacting → off).
    - Dragging back to the bottom (idle with geometry → on).
    - Short content that doesn't fill the screen (counts as at the bottom).
    - Status-bar scroll to top (the nit above).
    - Expanding the last row (no scroll until the next update).
  - Callers of the changed `ChatItem.Content.toolCall` (only SessionChat.swift and SessionChatView.swift).
- Commands run:
  - `./scripts/test.sh 2>&1 | tail -60` → every app test case shown passed, including the 2 new view model tests and `showsEachChatItAsSentAndHostTextVerbatim`. Piping through `tail` hid the script's exit code, so I re-ran the package tests on their own.
  - `swift test` (Packages/VIRTKit) → exit 0, "74 tests in 12 suites passed".
- Earlier blockers: none (round 1).

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:8-16, VIRT/SessionChatView.swift:61-62 | Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift › "inlineMarkdownGetsItsStylesAndKeepsLineBreaks", "plainTextComesBackVerbatim" |
| AC2 | Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:9,13-14, VIRT/SessionChatView.swift:52-58 | Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift › "htmlStaysLiteralAndLinksAndImagesAreRemoved" |
| AC3 | Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:11-14,60-72,78-91 | Packages/VIRTKit/Tests/VIRTKitTests/SessionChatTests.swift › seeded and streamed fixtures (c1–c4, c6), "toolCallWithABlankNameIsCalledTool", "toolCallDetailsLeaveOutBlankValuesAndKeepMarkdownAsPlainText" |
| AC4 | VIRT/SessionChatViewModel.swift:17-18,37-42, VIRT/SessionChatView.swift:63-89 | VIRTTests/SessionChatViewModelTests.swift › "toolCallStartsCollapsedAndTogglesAndStaysExpandedAcrossUpdates" |
| AC5 | VIRT/SessionChatViewModel.swift:19-20,44-47, VIRT/SessionChatView.swift:12-29,45-47 | VIRTTests/SessionChatViewModelTests.swift › "followsTheBottomUntilYouScrollAway" |
