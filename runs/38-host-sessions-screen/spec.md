# Spec: Host sessions screen

## Goal
When you tap a saved host, VIRT connects it and opens a screen titled with the host's name. The screen shows the connection status until the host connects, then a live list of the host's sessions that you can pull to refresh.

## Acceptance criteria
- AC1: Tapping a host still calls `HostsViewModel.select(_:)`. It also pushes a sessions screen whose navigation title is `host.name`. `HostsViewModel.makeSessionsModel(for:)` builds that screen's model with the same `HostConnecting`.
- AC2: While the host's status isn't `.connected`, the screen shows only the status line. It uses the same wording as the Hosts row ("Connecting…", "Reconnecting (attempt n)…", "Failed: …"), or "Not connected" when the host is idle. It follows `statusUpdates(for:)` live.
- AC3: Once the host is `.connected`, the screen lists the rows from `sessionUpdates(for:)` in the order received. Each row shows `title`, `state.rawValue` and, if present, `folder`. Every row update replaces the list.
- AC4: When the host is connected and the latest rows are `[]`, the screen shows a "No sessions" `ContentUnavailableView`.
- AC5: Pull to refresh calls `refreshSessions(host.id)` once and returns when that call returns.
- AC6: The view renders host-sent text (title, folder) with `Text(verbatim:)`. The model passes those strings through unchanged, so a title like `**x** [y](z)` comes out exactly as sent.

## Out of scope
- Opening a session, session detail, or sending any message other than `listSessions`.
- Disconnecting when you leave the screen. The connection lifecycle stays as `HostsViewModel` runs it now.
- UI tests. Changes to `HostConnector`'s behaviour.

## Assumptions
- The parent #5 spec couldn't be read from disk, so this spec relies on #38's text and the merged #37 code.
- `HostSessionsViewModel(host:connector:)` follows its own `statusUpdates` and `sessionUpdates` streams from a `follow()` method that the view runs in `.task`. That keeps it independent of `HostsViewModel` and testable with the fake connector.
- The status wording moves from `HostsViewModel`'s private `text(for:)` into a shared internal helper, so both screens show the same text. "Not connected" is shown for `.idle`, which has no text on the Hosts screen.
- App tests can't build a `SessionSummary` without importing `AgentHostProtocol`. So `SessionRow` gains a public memberwise `init(resource:title:state:folder:modifiedAt:)`, with a VIRTKit test.
- The "No sessions" state shows only while the host is connected. Before that, AC2 applies.

## Likely files
- `VIRT/HostSessionsViewModel.swift` (new): status, rows, `statusText`, `isConnected`, `showsEmptyState`, `follow()`, `refresh()`.
- `VIRT/HostSessionsView.swift` (new): the status line, the list with `Text(verbatim:)`, the empty state and `.refreshable`.
- `VIRT/HostsView.swift`: the tap pushes the screen with `.navigationDestination(item:)`.
- `VIRT/HostsViewModel.swift`: adds `makeSessionsModel(for:)` and moves the shared status text out.
- `Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift`: the public memberwise init.
- `VIRTTests/HostsViewModelTests.swift`: `FakeConnector` gains a `.refresh(UUID)` call, live row listeners and `sendRows(_:for:)`, plus the new tests.

## Test plan
- AC1 → `VIRTTests/HostsViewModelTests.swift`: `makeSessionsModel(for:)` gives a model with title `host.name`. `select` still records `.connect(host.id)`.
- AC2 → same file: the fake sends `.idle`, `.connecting`, `.reconnecting` and `.failed`. `statusText` matches each, `isConnected` is false, and the rows are hidden.
- AC3 → same file: the fake sends `.connected` then two row lists. The model's `rows` equals the latest list.
- AC4 → same file: connected with `[]` gives `showsEmptyState`. Connected with rows, or not connected, doesn't.
- AC5 → same file: `refresh()` records exactly `.refresh(host.id)` in `calls`.
- AC6 → same file: a markdown-like title and folder come out of `rows` byte for byte. Code review checks `Text(verbatim:)` in `HostSessionsView`.
- `SessionRow` init → `Packages/VIRTKit/Tests/VIRTKitTests/SessionRowTests.swift`: the memberwise init stores every field.

## Size estimate
Estimate: 175 code lines
- Tapping a host connects it and pushes a sessions screen titled with the host's name
- The screen shows the host's live status line while it isn't connected
- The screen lists live session rows (title, state, folder, as verbatim text) once connected, with a "No sessions" empty state
- Pull to refresh calls `refreshSessions(_:)`
