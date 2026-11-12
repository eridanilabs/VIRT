# Review r1: security (claude-opus-5.5)

VERDICT: CHANGES

The full test suite passes. One security problem blocks the merge: data from the host can now crash the app.

## Findings
- [blocker] (security) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:224: **A host can crash the app.** `followChat` passes every action from the host straight to `AHPStateMirror.apply`. That method runs the pinned 1.0.0 `chatReducer`, which calls `preconditionFailure` on input it should reject, and the new code doesn't guard against that input. There are three ways to trigger it:
  1. **Turn end with an unknown tool call.** `chat/turnComplete`, `chat/turnCancelled` and `chat/error` all call `endTurn` (Reducers.swift:181–187). `endTurn` reads `tc.baseFields` on every tool call that isn't completed or cancelled (Reducers.swift:1210), and `.unknown` falls into that branch. `baseFields` on `.unknown` is a `preconditionFailure` (ToolCallStateExtensions.swift:83).
  2. **Completing an unknown tool call.** `chat/toolCallComplete` calls `tc.baseFields` with no guard on the state (Reducers.swift:391). An `.unknown` tool call has the id `""`, so the host can target it with `toolCallId: ""`.
  3. **A bad start time.** `endTurn` passes `activeTurn.startedAt`, a string the host sends, to `addMillisecondsToTimestamp`. That function calls `preconditionFailure` when the string isn't ISO 8601 (Reducers.swift:1052, 1263).

  A host only one protocol version ahead could do this by accident: any tool call in a state 1.0.0 doesn't know, followed by the turn ending, crashes VIRT. `origin/main` never ran these reducers, so this diff adds the risk. AGENTS.md says to treat everything from the host as untrusted. The spec's AC1 shows the concern too: `SessionChat` avoids `baseFields` on `.unknown` (SessionChat.swift:59–60), but the reducer just before it doesn't.

  **Fix:** before `mirror.apply(envelope)`, check the action against `mirror.chats[chat]`. When an action would hit one of these traps, end the stream (the screen then shows "Couldn't open this chat.") or skip the action. That means:
  - a turn-ending action while the active turn has an `.unknown` tool call, or a `startedAt` that `ISO8601DateFormatter` (with and without fractional seconds) can't parse;
  - a `chat/toolCallComplete` whose target is `.unknown`.

  Also check `startedAt` in `chat/turnStarted` and in the seeded snapshot's `activeTurn`. Add `HostConnectorChatTests` cases for each, and note the client gap in the PR, as AGENTS.md asks.

## Coverage
- **Files read:**
  - Conventions and run files: AGENTS.md, the spec, build-1.md, `.agents/skills/factory/LOOP.md` (Severity section)
  - VIRTKit: `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift` (protocol, header and the new `chatUpdates`/`followChat`), `SessionChat.swift`
  - App: `VIRT/HostSessionsView.swift`, `HostSessionsViewModel.swift`, `SessionChatView.swift`, `SessionChatViewModel.swift`, README.md
  - Test diffs, scanned for tokens, logging and unknown-state coverage
  - Pinned client 1.0.0: `Reducers.swift` (chat reducer, `updateToolCall`, `endTurn`, `addMillisecondsToTimestamp`), `ToolCallStateExtensions.swift`, `AHPStateMirror.swift`
- **Flows walked:**
  - **Host text to the screen:** every piece of host text shown in `SessionChatView` and `HostSessionsView` goes through `Text(verbatim:)`, including the navigation title. The only plain `Text(...)` strings are fixed labels, and there's no Markdown, HTML, links or web view. Tool call names have newlines collapsed and are limited to one line.
  - **Host-chosen chat URI:** the `defaultChat` or `chats.first` URI is subscribed on the same host only. If its snapshot isn't a chat, the stream ends.
  - **Untrusted actions into the mirror reducers:** the blocker above.
  - **Subscribe and unsubscribe:** both channels are unsubscribed in a separate task when the stream ends, including after a failed subscribe. Stale actions (`serverSeq` at or below `fromSeq`) are dropped.
  - **Token handling:** no new logging, and the token never reaches a `Status`, the UI or a URL.
  - **Supply chain:** no new dependencies, workflows, project or Info.plist changes, and no change to App Transport Security.
- **Commands run:**
  - `git log` / `git diff origin/main...HEAD`: read the three commits and 12 files.
  - grep of the pinned client for `preconditionFailure`, `fatalError` and `baseFields`: found the trap sites above.
  - `git grep` on `origin/main`: no earlier use of `AHPStateMirror` or the reducers.
  - `./scripts/test.sh` (piped to `tail`, so I didn't capture the exit code): every visible test case passed, with no failures in the output.
