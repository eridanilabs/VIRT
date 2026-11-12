# Build r2 (claude-opus-5.5)

## Summary
I fixed blocker #43: a host could crash the app through the pinned AHP 1.0.0 `chatReducer`. VIRTKit now checks the seed and each chat action against the mirrored chat before running the reducer. If the input would hit a `preconditionFailure`, the chat ends and the app unsubscribes from the chat, then the session. I also fixed all three UX nits. `./scripts/test.sh` passes.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/ChatReducerGuard.swift` (new): `canSeed(_:)` and `canApply(_:to:)`. Timestamps are parsed with the same two `ISO8601DateFormatter` setups the reducer uses (with and without fractional seconds).
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: extended `followChat`.
  - If the seed's active turn has a bad `startedAt`, the stream ends with no value, so the screen shows "Couldn't open this chat."
  - An action that would trap ends the stream. The view model only sets `failed` if no chat ever arrived, so the screen keeps the last good chat. I end the stream rather than skip the action because a skipped action would leave the mirror out of step with the host.
- `Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift`: in `item(_:turn:)`, a tool call whose name is blank after joining lines is called "Tool".
- `VIRT/HostsView.swift`: new `DisclosureChevron` view (hidden from VoiceOver), used on host rows.
- `VIRT/HostSessionsView.swift`: session rows reuse `DisclosureChevron`.
- `VIRT/SessionChatView.swift`: `.accessibilityHidden(true)` on the tool-call icon.
- Tests: `HostConnectorChatTests` (new trap cases), `SessionChatTests` (blank-name case).

## Reducer traps: guarded and checked
The pinned client's sources have only two traps: `preconditionFailure` at `ToolCallStateExtensions.swift:83` (`baseFields` on `.unknown`) and in `addMillisecondsToTimestamp` (Reducers.swift). There is no `fatalError`. Here is how chat actions reach them:

**Guarded:**
- **Ending a turn.** `chat/turnComplete`, `chat/turnCancelled` and `chat/error` call `endTurn`. When the action targets the active turn, I require that turn to have no `.unknown` tool call and an ISO 8601 `startedAt`.
  - This check runs when the turn ends, so it also covers turns that get a bad value another way:
    - `chat/turnResume` (it uses `turn.startedAt ?? state.modifiedAt`);
    - `chat/turnsLoaded`;
    - an `.unknown` tool call added later through `chat/responsePart`.
- **`chat/toolCallComplete`.** If the target in the active turn (including the `""` id of an `.unknown`) is `.unknown`, the action is rejected.
- **`chat/turnStarted`.** Its `startedAt` must be ISO 8601.
- **The seed.** The seeded snapshot's `activeTurn.startedAt` must be ISO 8601.

**Checked and safe:** `chat/toolCallReady`, `toolCallConfirmed`, `toolCallResultConfirmed`, `toolCallAuthRequired` and `toolCallAuthResolved` all check the tool call's state before reading `baseFields`. Every other `remove(at:)`/`removeLast` in the chat reducer checks its index first.

I confirmed the tests catch the traps: with the guard removed, they crash at `ToolCallStateExtensions.swift:83`.

**Client gap (for the PR):** In the pinned 1.0.0 Swift client, `chatReducer` and `AHPStateMirror.apply` crash the app (`preconditionFailure`) on input they should reject:
- An unknown tool-call state reaches `baseFields` in `endTurn` and in `chatToolCallComplete`.
- A turn `startedAt` (or a `modifiedAt` used in its place) that isn't ISO 8601 reaches `addMillisecondsToTimestamp`.

VIRTKit checks every action before applying it as a workaround. This should be reported upstream so the reducer ignores such input instead of trapping. When the client fixes it, `ChatReducerGuard` can go.

## AC coverage
- AC1–AC6: unchanged from build-1, all still covered by the round 1 tests.
- #43 → `HostConnectorChatTests` › "actionThatWouldTrapTheReducerEndsTheChat", which runs six cases: turnComplete, turnCancelled and error, each with an unknown tool call; toolCallComplete on an unknown tool call; turnStarted with a `startedAt` that isn't ISO 8601; turnComplete of a resumed turn with a bad `startedAt`.
- #43 → `HostConnectorChatTests` › "seededActiveTurnWithABadStartedAtFinishesWithoutAValue", with `"yesterday"`, `"2025-03-10 18:05:00"` and `""`.
- Blank tool name → `SessionChatTests` › "toolCallWithABlankNameIsCalledTool", with `""`, `"  "` and `"\n\t"`.

## Findings
- reviewer-security · `[blocker] #43 (security) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:224: **A host can crash the app.**` → **Fixed** in dc172db
- reviewer-ux · `[nit] VIRT/HostSessionsView.swift:17: the session row is a plain `Button` inside a `List`, so it shows no disclosure chevron.` → **Fixed** in a744d7f. I used the trailing `chevron.right` option, on host rows too so the two lists match.
- reviewer-ux · `[nit] VIRT/SessionChatView.swift:23: the tool-call `Label` icon is a bare `Image(systemName:)`, which VoiceOver may read as the symbol name.` → **Fixed** in a744d7f
- reviewer-ux · `[nit] Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:59: a tool call with an empty `displayName` becomes " · Done", with a stray separator.` → **Fixed** in 6ced7d3

**Fixed:** session-row chevron (also added to host rows), tool-call icon hidden from VoiceOver, blank tool name becomes "Tool".
**Declined:** none.

## Tests
`./scripts/test.sh` exits 0:
- VIRTKit: `✔ Test run with 70 tests in 11 suites passed after 1.021 seconds.`
- App (VIRT scheme, iOS simulator): 69 test cases passed, 0 failed.

## New commits
- `dc172db` fix(virtkit): end a chat before a host action can crash the reducer (`Refs: #35`, `Refs: #43`)
- `6ced7d3` fix(virtkit): call a tool call with a blank name "Tool" (`Refs: #35`)
- `a744d7f` fix(sessions): show a chevron on rows that open a screen, hide the tool icon from VoiceOver (`Refs: #35`)