# Spec: Render chat replies as Markdown, expand tool calls, keep the chat scrolled

## Goal
On a phone, replies in a session's read-only chat show formatting such as bold, italics and code, tapping a tool call shows its details, and the chat follows new output unless you've scrolled up to read.

## Acceptance criteria
- AC1: A reply's text is parsed as inline Markdown into an `AttributedString` (whitespace and line breaks are kept), so `**x**`, `*y*` and `` `z` `` show as bold, italic and code. If parsing throws, the reply shows as verbatim text.
- AC2: Nothing in a reply is shown as HTML or run as code. Raw HTML such as `<script>alert(1)</script>` appears as literal characters. Link and image attributes are removed, so a link shows its text but can't be tapped, and no image or URL is loaded. User messages stay verbatim.
- AC3: Each tool call item in `VIRTKit` carries its one-line summary (unchanged from today) and plain-text detail lines: `toolName`, the invocation message, the past-tense message when completed, and the reason when cancelled. Blank or missing values are left out.
- AC4: A tool call starts collapsed and shows only its summary. Tapping it expands it to show its detail lines, and tapping again collapses it. The expanded state is kept by item id, so it survives chat updates while the tool call runs.
- AC5: The chat stays scrolled to the bottom as turns are added and replies stream. Once you scroll up away from the bottom, new content doesn't move the view. Scrolling back to the bottom turns following on again.

## Out of scope
- Block Markdown layout (headings, lists, tables, code blocks as separate views), syntax highlighting, tappable links, and images.
- Tool input or output content, and acting on tool calls (confirming or cancelling them).
- Sending messages or any other change to the chat stream.

## Assumptions
- "Render as Markdown" means `AttributedString(markdown:options:)` with `.inlineOnlyPreservingWhitespace`. SwiftUI `Text` renders inline styles only.
- Links are removed rather than opened. This matches the rule that host text is untrusted.
- If the client models a message as string-or-markdown, the plain string is used as a detail line.
- "At the bottom" means within a small threshold, about 24 pt, of the end of the content. Following is on when the screen opens.
- There's no `docs/board-reads.md` with a `## Consumers` section, and no schema constant changes, so nothing here triggers a consumer check.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift` (new): untrusted Markdown → sanitized `AttributedString`, with a verbatim fallback.
- `Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift`: tool call content becomes a summary plus detail lines.
- `VIRT/SessionChatViewModel.swift`: expanded ids with `toggle(_:)`/`isExpanded(_:)`, and follow-bottom state with `setAtBottom(_:)`.
- `VIRT/SessionChatView.swift`: render replies, a tappable tool call row, scroll position and geometry handling. Also update the doc comment.
- `Packages/VIRTKit/Tests/VIRTKitTests/SessionChatTests.swift`, `VIRTTests/SessionChatViewModelTests.swift`: update fixtures and add the tests below.

## Test plan
- AC1 → `Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift`: bold, italic and code runs carry the right inline intents, and line breaks are kept.
- AC2 → `ChatMarkdownTests.swift`: `<script>…</script>` stays as literal characters, no run has a `link` or `imageURL`, and the link text is still there.
- AC3 → `SessionChatTests.swift`: fixture tool calls c1–c4 and the streamed c6 have the expected detail lines, and blank values are omitted.
- AC4 → `VIRTTests/SessionChatViewModelTests.swift`: the item starts collapsed, `toggle` expands it and toggling again collapses it, and it stays expanded after a new chat with the same id arrives.
- AC5 → `SessionChatViewModelTests.swift`: following starts on, `setAtBottom(false)` turns it off, and `setAtBottom(true)` turns it back on.

## Size estimate
Estimate: 300 code lines
- Replies render as sanitized inline Markdown
- Tool call items carry plain-text details
- Tapping a tool call expands or collapses it
- The chat follows the bottom unless you've scrolled up
