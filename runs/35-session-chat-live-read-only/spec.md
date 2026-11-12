# Spec: Show a session's chat live, read-only

## Goal
Tap a session on a host's sessions screen to read its chat on your phone. You see user messages, the agent's replies and one-line tool calls, and the chat updates live as the agent works. You can't send anything yet.

## Acceptance criteria
- AC1: `SessionChat(state: ChatState)` in VIRTKit lists the chat's items in order: completed `turns`, then the `activeTurn`. Each turn gives a `.user(text)` item, then one item per response part in stream order. A `markdown` part becomes `.reply(text)`, holding its content as plain text. A `toolCall` part becomes `.toolCall(summary)`, one line: `displayName` and a status word (Running, Done, Failed, Cancelled, Waiting). All other part kinds, including `.unknown`, are skipped, and `baseFields` is never called on `.unknown`. Item ids come from the turn id and the part id, so they stay the same while a reply streams.
- AC2: When `AHPStateMirror` seeds a chat from a recorded `Snapshot` and applies recorded `ActionEnvelope`s (turn started, markdown deltas, tool call start and complete, turn complete), `SessionChat` shows the new turn, the reply growing with each delta, and the tool call's status changing.
- AC3: `HostConnecting.chatUpdates(for:session:)` is a new method. It subscribes to the session channel, picks the chat channel (`defaultChat`, or else the first `chats` entry) and subscribes to it. It listens through `MultiHostClient.events(host:uri:)`, attaching the listener before subscribing, and seeds an `AHPStateMirror` with the snapshot. It yields a `SessionChat` after the seed and after each action. A session with no chat yields an empty chat. If the host isn't connected or the subscribe fails, the stream finishes without a value.
- AC4: When the caller stops listening to the stream, VIRTKit sends `unsubscribe` for the chat channel and for the session channel.
- AC5: Tapping a row in `HostSessionsView` opens `SessionChatView`. Its title is the row's title. It shows user messages, replies and one-line tool calls with `Text(verbatim:)` only: no Markdown, no HTML, no links, no web view. It shows "No messages yet" for an empty chat and "Couldn't open this chat." when the stream ends with no chat. It has no composer and no buttons that act on the session.
- AC6: Leaving the screen cancels its `.task`, which ends the stream, so AC4's unsubscribes happen.

## Out of scope
- Sending messages, approving tool calls, cancelling turns and answering input requests (milestone 1).
- Markdown rendering (the next part of #6).
- Reasoning, content refs, system notifications, input requests and error parts.
- Loading older turns (`turnsNextCursor` / `fetchTurns`).
- Picking among several chats, and following a `defaultChat` change while the screen is open.
- Re-seeding on reconnect beyond the client's own resubscribe and replay.

## Assumptions
- In the pinned protocol (1.0.0), turns live on the `ahp-chat:` channel's `ChatState`, not on `SessionState`. The sample app reads `session.turns`, which looks out of date. If VS Code's agent host differs, the PR says so and matches the host.
- The user message is `turn.message.text`. Adjacent markdown parts stay separate items rather than being merged.
- The view model follows the stream only while the screen is shown, like `HostSessionsViewModel.follow()`.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift` (new): `ChatItem` and the `ChatState` → items mapping.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: `chatUpdates`, the mirror, subscribe and unsubscribe.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: `FakeHosts` answers `subscribe` with snapshots, records `unsubscribe` and pushes `action` notifications.
- `VIRT/SessionChatView.swift`, `VIRT/SessionChatViewModel.swift` (new). `VIRT/HostSessionsView.swift` and `VIRT/HostSessionsViewModel.swift` change for row navigation.
- `VIRTTests/HostsViewModelTests.swift`: `FakeConnector` gets `chatUpdates`.

## Test plan
- AC1 → `Packages/VIRTKit/Tests/VIRTKitTests/SessionChatTests.swift`: checks item order, plain text, tool call summaries, skipped part kinds, `.unknown` not crashing, and stable ids.
- AC2 → `SessionChatTests.swift`: replays a recorded snapshot and actions through `AHPStateMirror` and checks `SessionChat` after each step.
- AC3, AC4 → `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift`: on `InMemoryTransport`, checks the seed, live actions, the empty chat, the finish when the host isn't connected, and both `unsubscribe` requests after the stream ends.
- AC5, AC6 → `VIRTTests/SessionChatViewModelTests.swift`: with the fake connector, checks the items, empty and failed states, and that cancelling `follow()` ends the stream.

## Size estimate
Estimate: 620 code lines
- Map a chat's state to read-only items (user, reply, one-line tool call), checked by replay tests through `AHPStateMirror`
- Subscribe to a session's chat and stream live updates
- Unsubscribe from the chat and session channels when the stream ends
- Chat screen opened from a session row, showing plain text only, with empty and failed states

## Proposed split
- Part 1: Chat items from chat state: the mapping behaviour, AC1, AC2, about 220 code lines
- Part 2: Live chat subscription in VIRTKit: the subscribe and unsubscribe behaviours, AC3, AC4, plus the `FakeHosts` and `FakeConnector` changes, about 240 code lines
- Part 3: Chat screen: the screen behaviour, AC5, AC6, about 170 code lines
