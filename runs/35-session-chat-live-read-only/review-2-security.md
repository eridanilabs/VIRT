# Review r2: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.

- [note] Packages/VIRTKit/Sources/VIRTKit/ChatReducerGuard.swift:12: The guard only covers the trap sites in AHP client 1.0.0 (revision 5f16d81, pinned in `Package.resolved`). When that pin is bumped, someone needs to grep the new client for `preconditionFailure`, `fatalError` and `baseFields` again. They should also check whether the reducer still traps and whether the guard is still needed. The builder's "Client gap" paragraph in build-2.md explains this. I couldn't confirm it reached the PR body because this review doesn't call `gh`.

## Coverage
- **Files read:**
  - Run records: review-1-security.md, triage-1.md, build-2.md
  - Delta: `git diff 270dc9c..HEAD`, all 8 files: ChatReducerGuard.swift, HostConnector.swift, SessionChat.swift, HostConnectorChatTests.swift, SessionChatTests.swift, HostSessionsView.swift, HostsView.swift, SessionChatView.swift
  - The full `followChat` and `chatUpdates` in HostConnector.swift
  - The pinned client: `Reducers.swift`, including the chat reducer, `endTurn`, `updateToolCall`, `addMillisecondsToTimestamp` and the formatter setup at lines 6–13. Also `ToolCallStateExtensions.swift` (`toolCallId` and `baseFields`) and `AgentHostProtocolClient/AHPStateMirror.swift`.
  - AGENTS.md, the testing section
- **Flows walked:**
  - **Host actions into the reducer.** I checked every `baseFields` call in the pinned client (Reducers.swift:302, 348, 391, 482, 532, 555, 1210). All are guarded by a state check except two:
    - `toolCallComplete` (391): the guard rejects it when the target in the active turn is `.unknown`. It matches on `toolCallId` the same way `updateToolCall` does, so `""` matches an `.unknown` tool call.
    - `endTurn` (1210): the guard covers it through `canEnd` for turnComplete, turnCancelled and error.
  - **Bad timestamps.** `addMillisecondsToTimestamp` has one caller, `endTurn` at line 1263. `canEnd` checks `activeTurn.startedAt` there with the same two formatter setups the reducer uses. That catches every way a bad `startedAt` can reach the active turn: turnStarted, turnResume (including its `modifiedAt` fallback), and turnsLoaded followed by turnResume.
  - **Traps elsewhere.** The only `preconditionFailure` or `fatalError` calls in AgentHostProtocol are the two above. The others are in `InMemoryTransport`, which is test-only.
  - **Whether the guard sees the same state the reducer uses.** The mirror is local to `followChat`, so nothing else changes it. `state` is re-read after each `apply`, so the guard always checks the state the reducer will run on. `AHPStateMirror.apply` routes actions by channel: an envelope for a chat that wasn't seeded is dropped, and the root channel runs `rootReducer`, which has no traps.
  - **Failure path.** When the guard rejects an action, `followChat` returns. The `defer` unsubscribes from the chat, then the session, in its own task, and the stream finishes. The tests check this order.
  - **Seed path.** `canSeed` rejects a bad active-turn `startedAt`, and the stream ends with no value. A seed snapshot whose resource isn't the chat leaves `chats[chat]` empty, and the stream returns.
  - **UI delta.** No new place shows host text. The chevron and the hidden tool icon have no security effect. Host rows still use `Text(host.name)` with a `String`, which isn't parsed as Markdown, and that name is entered by the user, not sent by the host.
  - **Supply chain and secrets.** No new dependencies, network calls, logging or tokens, and no workflow or project changes.
- **Commands run:**
  - `git log` / `git diff 270dc9c..HEAD` → 3 commits, 8 files
  - Grep of the pinned client for `preconditionFailure`, `fatalError` and `baseFields` → the sites listed above
  - `./scripts/test.sh` → exit 0. VIRTKit: 70 tests in 11 suites passed, including the 6 trap cases and the 3 bad-seed cases. App: all test cases passed.
- **Earlier blockers:**
  - #43, a host can crash the app through the pinned `chatReducer`'s `preconditionFailure` paths → **fixed** in dc172db. All three trap paths from round 1 are guarded: an `.unknown` tool call when a turn ends, `toolCallComplete` on an `.unknown` tool call, and a `startedAt` that isn't ISO 8601. The tests exercise each one.
