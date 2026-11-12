# Spec: List a host's sessions

## Goal
When I open a connected host, I see its agent sessions with the newest activity first. Each row shows a title, a state and a working folder. The list updates live, and I can pull to refresh it.

## Acceptance criteria
- AC1: Tapping a host still connects it, and now also pushes a sessions screen titled with the host's name. If the host isn't connected, the screen shows the host's status line. Once the host is connected, it lists the sessions. If the host has no sessions, it shows a "No sessions" empty state.
- AC2: Each row shows a display title, a state and a working folder. The state is "Failed" if `status` has `.error`, otherwise "Waiting for input" if it has `.inputNeeded`, otherwise "Working" if it has `.inProgress`, otherwise "Idle". The working folder is the first of `workingDirectories`, or nothing if there are none. Rows sort by `modifiedAt` (ISO 8601) with the newest first. Ties sort by `resource`, and a date that won't parse sorts last.
- AC3: If `resource` matches `ahp-session:/guppi.<owner>.<name>.<issue>.<attempt>`, the row shows `<owner>/<name> #<issue>`, or `<owner>/<name> #<issue> (attempt <n>)` when the attempt is above 1. The owner is the first part and the issue and attempt are the last two. Everything in between is the name, so a repo name can contain dots. The issue and attempt must be positive integers. Any other session shows its `title`, or "Untitled session" if the title is empty.
- AC4: `HostConnecting` gains `sessionUpdates(for:)`, which yields the host's current sorted rows and then each change. It is fed by `MultiHostClient.sessionSummaries(host:)`, which `refreshSessionSummariesOnConnect` seeds and which `notify/sessionAdded`, `notify/sessionRemoved` and `notify/sessionSummaryChanged` keep current. A new session appears and a changed state shows without any timer or polling.
- AC5: `HostConnecting` gains `refreshSessions(_:)`. It sends `listSessions` on `ahp-root://` through `MultiHostClient.client(for:)` and gives the result to that host's session listeners. Pull to refresh on the screen calls it. A failed refresh keeps the current list.

## Out of scope
- Opening a session, its chats, or acting on it (create, archive, delete).
- Grouping by folder (as in the sample's `FolderSessionsView`), filtering, searching, and hiding archived sessions.
- Showing sessions from more than one host at a time.

## Assumptions
- Guppi names are matched on `resource`, which is the session URI, not on `title`.
- Archived sessions show like any other session.
- Everything from the host is untrusted, so titles and folders render with `Text(verbatim:)` and never as markdown.
- Gap in the client: a manual `listSessions` doesn't update `MultiHostClient`'s summary cache. The PR notes this, and `HostConnector` gives the refreshed list to listeners itself.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostSession.swift`: new. The row model, the state mapping and the sort.
- `Packages/VIRTKit/Sources/VIRTKit/GuppiSessionName.swift`: new. Parses guppi session names.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: adds `sessionUpdates(for:)`, `refreshSessions(_:)` and the protocol members.
- `VIRT/HostSessionsView.swift`, `VIRT/HostSessionsViewModel.swift`: new. The sessions screen and its view model.
- `VIRT/HostsView.swift`, `VIRT/HostsViewModel.swift`: push the screen for the selected host.
- `VIRTTests/HostsViewModelTests.swift`: update `FakeConnector` for the new protocol members.

## Test plan
- AC1 → `VIRTTests/HostSessionsViewModelTests.swift`: with a fake connector, the model shows the status line while connecting, the rows once connected, and the empty state when there are no rows.
- AC2 → `Packages/VIRTKit/Tests/VIRTKitTests/HostSessionTests.swift`: each status combination maps to the right state (24 maps to waiting, and error wins). The folder is the first working directory. The sort, the tie-break and bad dates behave as AC2 says.
- AC3 → `Packages/VIRTKit/Tests/VIRTKitTests/GuppiSessionNameTests.swift`: attempt 1 and attempt 3, a repo name with dots, a non-numeric or zero issue, a wrong prefix, and the empty-title fallback.
- AC4 → `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: the `InMemoryTransport` host answers `listSessions`, then sends `notify/sessionAdded` and `notify/sessionSummaryChanged`. The stream yields the seeded rows, then the new row, then the changed state.
- AC5 → `HostConnectorTests.swift`: after the host's list changes on the server side, `refreshSessions` yields the new list. An error reply keeps the old one.

## Size estimate
Estimate: 540 code lines
- The host sessions screen opens for the tapped host
- Rows show title, state and folder, newest first
- Guppi sessions show as `<owner>/<name> #<issue>`, with the attempt above 1
- The list updates live from the client's session summaries
- Pull to refresh re-reads `listSessions`

## Proposed split
- Part 1: Session list model and live updates in VIRTKit: rows, guppi names, live updates and refresh (AC2–AC5, with their VIRTKit tests). About 330 code lines.
- Part 2: Host sessions screen: the screen, its view model, navigation, pull to refresh and the fake connector update (AC1, plus wiring AC4 and AC5 into the UI). About 210 code lines.
