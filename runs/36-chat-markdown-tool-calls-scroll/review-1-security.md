# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.

- [note] Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift:9: The options leave `allowsExtendedAttributes` at its default of false. A probe confirmed that `^[x](inflect: true)` gives the text "x" with no attributes, so host text can't add custom attributes. Inline HTML gets only `inlinePresentationIntent` `.inlineHTML`, so it shows as literal characters. Image alt text stays as plain text, with `alternateDescription` as its only attribute. Bare URLs, autolinks, `javascript:` links and reference links all end with no `link` or `imageURL` on any run.
- [note] Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:70: Tool call details show `.markdown` messages as plain strings, and the view shows every detail line with `Text(verbatim:)`. This meets AC2 and the spec's assumption about string-or-markdown messages.
- [note] VIRT/SessionChatView.swift:59: `ChatMarkdown.attributed` parses again every time a row renders. A probe with 60k characters of nested emphasis and brackets parsed in about 8 ms, so I found no denial-of-service risk. Any remaining performance question belongs to reviewer-code.

## Coverage
- Files read: the pinned `reviewer-security.agent.md`, `AGENTS.md` (including its Security section), `spec.md`, the full diff `f6a41eb...9bf2d63`, and all of `VIRT/SessionChatView.swift`, `VIRT/SessionChatViewModel.swift`, `Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift`, `Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift` and `Packages/VIRTKit/Tests/VIRTKitTests/ChatMarkdownTests.swift`.
- Flows walked:
  - **Host reply to screen:** a `ChatState` markdown part becomes `ChatItem.reply`, then `ChatMarkdown.attributed`, then `Text(AttributedString)`. Parsing either succeeds and is sanitized, or fails and falls back to verbatim text. Nothing loads, opens a URL or renders HTML.
  - **Host tool call to screen:** `ToolCallState` gives the summary and detail lines (with `.unknown` skipped), then the `Button` toggles the expanded set by item id, then each line is shown with `Text(verbatim:)`.
  - **User messages:** still shown with `Text(verbatim:)`.
  - **Scroll following:** `followsBottom` and `setAtBottom` handle only local UI state, and no host input reaches them.
  - **Secrets and supply chain:** no new dependencies, no new network calls, no logging, no Keychain or token code touched, no changes to `Info.plist` or ATS, no changes to the project or workflows.
- Commands run:
  - `git diff --stat` and `git diff f6a41eb...HEAD` → 7 files, +227/−50
  - `git log f6a41eb..HEAD` → 1 commit
  - `./scripts/test.sh` (with `pipefail`) → exit 0. The VIRTKit run reported 74 tests in 12 suites passed, and the VIRT simulator tests passed too, including `SessionChatViewModelTests`.
  - A probe script piped to `swift -` (no files written) → links and images stripped, HTML literal, extended attributes ignored, pathological input parsed in about 8 ms.
