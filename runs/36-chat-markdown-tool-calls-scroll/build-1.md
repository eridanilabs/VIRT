# Build r1 (claude-opus-5.5)

## Summary
The chat now shows replies as inline Markdown with HTML kept as plain characters and links and images removed. Tapping a tool call shows or hides its detail lines. The chat stays at the bottom while you're there, and stops moving once you scroll up. All tests pass (`./scripts/test.sh` exit 0), but nobody has checked the scrolling on a simulator or device yet. The tests only cover the follow on/off switch in the view model, not the code in the view that decides when you've scrolled away.

Everything is in one commit, 9bf2d63 (`feat(chat): …`, with `Refs: #36` and the Copilot co-author trailer). The change is about 277 lines, under the 400 limit. It isn't pushed.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift` (new): `ChatMarkdown.attributed(_:)` reads a reply as inline Markdown and keeps its whitespace and line breaks. It removes every link and image, so nothing can be tapped or loaded. If parsing fails, the text shows exactly as sent.
- `Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift`:
  - A tool call item now holds its unchanged one-line summary plus a list of detail lines: the tool name, the invocation message, the past-tense message when completed, and the reason when cancelled.
  - Blank or missing values are left out. Messages sent as Markdown are shown as plain text.
  - I replaced the old `statusWord()` with `status()`, which returns the status word and these messages together.
  - For a cancelled call, the details also include the host's optional explanation of the cancellation (`reasonMessage`) when it isn't blank. The spec didn't ask for this.
- `VIRT/SessionChatViewModel.swift`: added `isExpanded(_:)` and `toggle(_:)`, which remember expanded tool calls by item id. Added `followsBottom` (on when the screen opens) and `setAtBottom(_:)`.
- `VIRT/SessionChatView.swift`:
  - Replies use `ChatMarkdown`. User messages and detail lines are still shown exactly as sent.
  - A tool call is a plain button showing a chevron and its summary. It reads as "Expanded" or "Collapsed" to VoiceOver.
  - The chat only starts at the bottom when the screen opens. Before, it could also pull the view down when content grew while you were scrolled up.
  - Only your own scrolling turns following on or off, so a reply that grows while it streams doesn't switch it off. "At the bottom" means within 24 pt of the end.
  - When following is on, the chat scrolls to the last item each time the items change.
  - I updated the comment at the top of the view.
- Tests: updated the existing tool call fixtures and added new tests (listed below).

## AC coverage
- **AC1** → `ChatMarkdownTests.swift` › `inlineMarkdownGetsItsStylesAndKeepsLineBreaks`, `plainTextComesBackVerbatim`
- **AC2** → `ChatMarkdownTests.swift` › `htmlStaysLiteralAndLinksAndImagesAreRemoved`; `SessionChatViewModelTests` › `showsEachChatItAsSentAndHostTextVerbatim` (user text unchanged)
- **AC3** → `SessionChatTests.swift` › `itemsFollowTheTurnsInOrderAsPlainText` (c1–c4), `replayThroughTheMirrorGrowsTheChat` (c6 while running, ready and done), `toolCallDetailsLeaveOutBlankValuesAndKeepMarkdownAsPlainText`, `toolCallWithABlankNameIsCalledTool`
- **AC4** → `VIRTTests/SessionChatViewModelTests.swift` › `toolCallStartsCollapsedAndTogglesAndStaysExpandedAcrossUpdates`
- **AC5** → `VIRTTests/SessionChatViewModelTests.swift` › `followsTheBottomUntilYouScrollAway`

## Tests
- **VIRTKit (`swift test`):** 74 tests in 12 suites passed (`✔ Test run with 74 tests in 12 suites passed after 1.129 seconds.`).
- **App (`xcodebuild test`, iPhone 18 Pro simulator):** 41 distinct test cases passed, 0 failed, including all six in `SessionChatViewModelTests`. There were no build warnings.

## Found, not fixed
none
