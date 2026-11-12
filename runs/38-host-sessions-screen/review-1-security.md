# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.

- [note] VIRT/HostSessionsView.swift:14: The host sends the session title, state label and folder, and all three are shown with `Text(verbatim:)`, so none of them is read as markdown. The "No sessions" text and its description are fixed text in the app. The navigation title (`host.name`) is text the user typed in, not text from the host. It's passed as a `String`, which SwiftUI shows as plain text without reading markdown. This meets AC6 and the AGENTS.md rule that host input is never rendered as code or markup.
- [note] VIRT/HostSessionsView.swift:38: The status line on the new screen reuses `HostStatusLine`, which calls `Text(_:)` with a `String` value and so also shows it as plain text. Its wording comes from `HostConnector.Status.text`, now shared in `VIRT/HostsViewModel.swift`. That wording is fixed text in the app, plus `Failure.message`, which is also fixed text. The sessions screen never shows the host-sent protocol version, because the status line is hidden once the host is `.connected`. No token or URL reaches the new screen.
- [note] VIRT/HostSessionsViewModel.swift:47: `refresh()` only calls `connector.refreshSessions(host.id)`. That function sends `listSessions` and nothing else, and does nothing for a host that isn't registered. Pull to refresh only appears while the host is connected. No new message types or network paths are added, which stays within the spec's Out of scope list.
- [note] Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift:28: The new public memberwise init lets code build a row without going through `init(summary:)`, which tidies the title. This doesn't weaken the trust boundary, because every row is still shown verbatim. Today only tests and previews call it.

## Coverage
- Files read: AGENTS.md, spec.md, VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, VIRT/HostsView.swift, VIRT/HostsViewModel.swift, Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (Failure, statusUpdates, sessionUpdates, refreshSessions, connect, disconnect, openTransport), the diff of VIRTTests/HostsViewModelTests.swift and SessionRowTests.swift (AC6 byte-for-byte test)
- Flows walked:
  - Tapping a host: `makeSessionsModel`, then `select`, then the screen is pushed with `navigationDestination(item:)`.
  - The status stream from the connector to `statusText` and `HostStatusLine`, for idle, connecting, reconnecting and failed. I checked that this text never holds the token or a URL.
  - The rows stream from the connector to `rows` and the `Text(verbatim:)` list, including the empty state.
  - Pull to refresh, `refreshSessions`, which sends one `listSessions`, plus its guard when the host isn't registered.
  - Picking another host or disconnecting: rows are keyed by host id and cleared on disconnect, so one host's sessions never show on another host's screen.
- Commands run: `git diff --stat origin/main...HEAD` → 7 files changed, 333 lines added and 31 removed. `./scripts/test.sh` → exit 0, all tests passed, including the new HostsViewModelTests and SessionRowTests.
