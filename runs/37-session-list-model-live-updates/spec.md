# Spec r1 (writer-spec · claude-opus-5.5)

# Spec: Session list model and live updates in VIRTKit

## Goal
VIRTKit gives each connected host a sorted list of session rows (title, state, folder) that stays current as the host's sessions change. The sessions screen (#38) will display this list.

## Acceptance criteria
- AC1: `SessionRow(summary:)` is `Sendable`, `Equatable` and `Identifiable` (`id` = `resource`). Its `state` is "Failed" when `status.contains(.error)`. Otherwise it is "Waiting for input" when `status.contains(.inputNeeded)` (both bits, raw 24), then "Working" when `status.contains(.inProgress)`, else "Idle" (status 0 and unknown bits included). `folder` is `workingDirectories?.first`, or nil when the array is missing or empty.
- AC2: `SessionRow.sorted(_:)` orders rows by `modifiedAt` newest first. It parses ISO 8601 with or without fractional seconds. Equal dates are ordered by `resource`, ascending. Dates that don't parse come last, also ordered by `resource`.
- AC3: `ahp-session:/guppi.<owner>.<name>.<issue>.<attempt>` gets the title `<owner>/<name> #<issue>`, with ` (attempt <n>)` added when attempt > 1. The name may contain dots. The owner and name are non-empty. Issue and attempt are ASCII digits with a value ≥ 1. Any other resource shows `title`, or "Untitled session" when `title` is empty.
- AC4: `HostConnecting.sessionUpdates(for:)` first yields the host's current rows, which are `[]` if it isn't connected. It then yields freshly sorted rows each time `MultiHostClient.sessionSummaries(host:)` yields: the on-connect `listSessions` and `root/sessionAdded`, `root/sessionRemoved` and `root/sessionSummaryChanged`. VIRT sends no `listSessions` of its own (no polling). Rows become `[]` on `disconnect` or on a stopping failure. The stream lasts through later connects, like `statusUpdates`.
- AC5: `HostConnecting.refreshSessions(_:)` sends one `listSessions` request (`ListSessionsParams(channel: "ahp-root://")`) through `MultiHostClient.client(for:)`. It gives the mapped, sorted items to that host's listeners. An error reply, a stale handle or a host that isn't connected yields nothing and leaves the current rows as they are. The method doesn't throw.
- AC6: `VIRTTests`' `FakeConnector` implements the two new methods, so the app and all existing tests still build and pass.

## Out of scope
- The sessions screen, any UI, and opening a session (#38).
- `listSessions` pagination (`nextCursor`), and the `activity`, `changes`, `isRead` and `isArchived` fields.

## Assumptions
- The pinned client (1.0.0) receives the notifications as `root/sessionAdded`, `root/sessionRemoved` and `root/sessionSummaryChanged`. Its docs call them `notify/…`, so the tests send the `root/` names.
- A manual refresh can't write into `MultiHostClient`'s internal cache. The next notification therefore replaces the refresh result with the client's cached list.
- The folder appears as the host sends it: VIRT does no conversion from URI to path. Rows are plain text taken from untrusted host data, and they never contain the token.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift`: new file with the row, state, title parsing and sort.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: the two protocol methods, the per-host row cache and listeners, and a summaries watcher for each registration.
- `VIRTTests/HostsViewModelTests.swift`: stubs on `FakeConnector`.
- `Packages/VIRTKit/Tests/VIRTKitTests/SessionRowTests.swift`, `HostConnectorSessionTests.swift`: new tests. `FakeHosts` also learns to serve summaries, push notifications and fail `listSessions`.

## Test plan
- AC1 → `SessionRowTests.swift`: parameterised status and state pairs (error+inputNeeded→Failed, 24→Waiting, 8→Working, 0/1/32→Idle), plus folder present, empty and nil.
- AC2 → `SessionRowTests.swift`: mixed dates with and without fractional seconds, ties and unparseable dates sort as specified.
- AC3 → `SessionRowTests.swift`: dotted name, attempt 1 versus 3, and fallback for a 0, negative or non-digit issue, a missing part, an empty title and a non-guppi resource.
- AC4 → `HostConnectorSessionTests.swift`: works against `InMemoryTransport`. A host that isn't connected yields `[]`. Connecting yields the seeded rows. Each `root/*` notification yields updated rows. Only one `listSessions` is recorded. Disconnect yields `[]`.
- AC5 → `HostConnectorSessionTests.swift`: a refresh records `listSessions` on `ahp-root://` and yields the new rows. An error reply, or a host that isn't connected, yields nothing and leaves the rows unchanged.
- AC6 → `./scripts/test.sh`: builds and runs both test suites.

## Size estimate
Estimate: 410 code lines
- Map a session summary to a row's state and folder
- Sort rows by `modifiedAt`, then by resource, with unparseable dates last
- Parse guppi resource names into titles, with a fallback title
- Live session rows through `sessionUpdates(for:)`
- Manual `refreshSessions(_:)` that keeps the current list when it fails

## Proposed split
- Part 1: Session row model: state and folder mapping, sort and guppi titles (AC1–AC3), about 180 code lines
- Part 2: Live session updates and refresh on `HostConnecting`: `sessionUpdates` and `refreshSessions` (AC4–AC6), about 230 code lines
