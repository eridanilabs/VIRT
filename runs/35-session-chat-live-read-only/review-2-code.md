# Review r2: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:226: When `ChatReducerGuard` rejects an action, the stream ends and the screen keeps the last good chat. Nothing on screen says the chat has stopped updating. This is the same stale-chat behaviour as my round 1 note and falls under the spec's reconnect out-of-scope item, so I'm asking for no work.
- [note] Packages/VIRTKit/Sources/VIRTKit/ChatReducerGuard.swift:55: `isTimestamp` builds two `ISO8601DateFormatter`s on each call. It runs only for turn start and turn end, so the cost is negligible.

## Coverage
- Files read: `ChatReducerGuard.swift`, `HostConnector.swift` (`followChat` and `chatUpdates`), `SessionChat.swift` delta, `HostsView.swift`, `HostSessionsView.swift` and `SessionChatView.swift` deltas, build-2.md, triage-1.md. For the pinned AHP client I read `Reducers.swift` (`chatReducer`, `endTurn`, `updateToolCall`, `addMillisecondsToTimestamp`) and `ToolCallStateExtensions.swift`. I did not read the new tests in `HostConnectorChatTests` or `SessionChatTests`; I relied on the passing run and build-2's account of them.
- Flows walked:
  - Seed with a bad `startedAt` or an unknown tool call, then the chat stream.
  - `turnComplete`, `turnCancelled` and `error` on an active turn holding an unknown tool call or a bad `startedAt`.
  - `toolCallComplete` on an unknown tool call, including the empty tool-call id.
  - `turnStarted` with a bad `startedAt`.
  - `turnResume` followed by a turn end.
  - Stream end: unsubscribe from the chat, then the session.
  - The guard's rejection test (`ChatReducerGuard.canApply`) uses the same `state` that the mirror holds, so it stays in step with the mirror.
- Commands run: `./scripts/test.sh` → the output was piped through `tail`, so I didn't capture the exit code. Every test case shown passed, and build-2 reports exit 0.
- Reducer trap sites: the pinned client has only two `preconditionFailure` calls, `baseFields` on `.unknown` and `addMillisecondsToTimestamp`. I checked every `baseFields` use in `chatReducer`. `toolCallReady`, `toolCallConfirmed`, `toolCallResultConfirmed`, `toolCallAuthRequired` and `toolCallAuthResolved` check the tool call's state first, so they are safe. `toolCallComplete` and `endTurn` are the unguarded ones, and `ChatReducerGuard` covers both. `endTurn` is the only caller of `addMillisecondsToTimestamp`, and the guard's timestamp check mirrors the reducer's two formatters.
- Earlier blockers: (security) a host can crash the app through `chatReducer` traps (#43) → fixed. My own round 1 review had no blockers.
