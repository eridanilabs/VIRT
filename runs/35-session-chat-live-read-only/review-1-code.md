# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:196: `followChat` has no end-to-end test for a host that disconnects after the chat is seeded. The `events` stream can then finish and the stream ends quietly. The screen keeps the stale chat, and `failed` is set only when no chat arrived. This falls under the spec's "Re-seeding on reconnect" out-of-scope item, so I'm not asking for work.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:204: two screens on the same session would share one channel subscription. Whichever closes first sends `unsubscribe` for the session and chat channels. The app can't open two chats at once today, so this is only a future caveat.
- [note] VIRT/SessionChatView.swift:35: `.defaultScrollAnchor(.bottom)` only sets the initial scroll position. New items arriving live won't scroll into view. This is a UX call, so it's for reviewer-ux.
- [note] Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:62: a tool call in a state this protocol version doesn't know (`.unknown`) is dropped, not shown. The spec's "skip `.unknown`" can be read this way, and a test covers it.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md; the full diff of `HostConnector.swift`, `SessionChat.swift`, `SessionChatView.swift`, `SessionChatViewModel.swift`, `HostSessionsView.swift`, `HostSessionsViewModel.swift` and `README.md`; `HostConnectorChatTests.swift`, the start of `SessionChatViewModelTests.swift` and the diffs of `HostConnectorTests.swift` and `HostsViewModelTests.swift`. I did not read `SessionChatTests.swift` or the tail of `SessionChatViewModelTests.swift`.
- Flows walked:
  - Tap a row, then the chat screen starts `follow()`. `chatUpdates` subscribes the session, picks `defaultChat` or the first chat, attaches the listener before subscribing the chat, seeds the mirror and yields. Later actions are filtered by `serverSeq > fromSeq`.
  - Leaving the screen cancels `.task`, which ends the stream. `onTermination` cancels the task, and the `defer` unsubscribes the chat then the session in its own task.
  - Failure paths: host not connected, session subscribe fails, chat subscribe fails, session with no chat. The empty state and the failed state are separate on the screen.
  - Re-running `follow()` resets `failed`.
- Commands run:
  - `swift test` in `Packages/VIRTKit` → 67 tests in 11 suites passed.
  - I did not run the iOS simulator tests. The builder reports 69 app test cases passed.
  - `git status` is clean, and the three commits sit on top of `5eebfdc`.
- Earlier blockers: none (round 1).
