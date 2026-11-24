# Spec: Raise in-app alerts from every connected host

## Goal
While VIRT is open, a session that finishes, fails or needs input on any saved host shows an in-app alert, not only on the host you last tapped. Tapping the alert opens that host's sessions screen, then the session's chat.

## Acceptance criteria
- AC1: After `HostsViewModel.load()`, `SessionAlertPresenter` follows the status and rows of every saved host, including one added later, without a host tap. A session change on any of these hosts raises an alert whose `hostID` is that host's id. All hosts share one banner queue, kept in arrival order. The existing repeat rule and on-screen-chat rule still apply, matched by host and session. Selecting a host no longer resets the presenter, and it no longer drops the banner or the queue.
- AC2: Each host has its own baseline and its own latest rows. When one host leaves `.connected` (idle, connecting, reconnecting or failed), only that host's baseline is cleared, so that host's next list only sets a new baseline. Other hosts' baselines stay, and their changes keep raising alerts. A return from the background resets every host's baseline.
- AC3: After `delete(_:)` succeeds, the presenter stops following the deleted host. It removes that host's queued alerts and closes its banner if one is showing, then shows the next queued alert. Later row changes from that host raise no alert. A failed delete changes nothing.
- AC4: `tapAlert()` uses the alert's own `hostID`, not `selectedHostID`. It closes the banner and any form, and sets `selectedHostID` to the alert's host. It looks up the session in that host's latest rows. If the alert's host's sessions screen is open, it opens the chat there. If another host's sessions screen is open, or none is, `sessions` becomes a new model for the alert's host, with the chat pending until the screen appears. A session that is no longer in its host's rows only closes the banner.
- AC5: `HostsView` gives each sessions model its own view identity, so the replacement screen shows the alert's host and fresh state, not the old host's.
- AC6: The README no longer says alerts follow the host you last tapped. It says alerts come from every connected saved host.

## Out of scope
- A per-host switch to turn alerts off.
- Background (APNs) alerts.
- Any change to `SessionAlert.alerts(hostID:old:new:)`, the banner's look, or the connector.

## Assumptions
- The presenter's single-host `follow(_:)` and `hostID` give way to a call that sets the whole followed set (for example `follow(_ hostIDs:)`) plus per-host read accessors that tests can use. `HostsViewModel` calls it after each successful load and after each delete.
- Tapping an alert counts as selecting its host for status announcements. It doesn't connect the host, because a host that raises an alert is already connected.
- There is no `docs/board-reads.md` `## Consumers` section, and nothing here changes a schema version, so no `Consumers:` line is needed.
- The board's `settings.size_limit` in the checkout is 400, not 450, so this spec uses 400.

## Likely files
- `VIRT/SessionAlertPresenter.swift`: follows a set of hosts, with per-host tasks, baselines, latest rows and connected state. It drops a removed host's alerts, and `tap()` returns the alert's host with the row.
- `VIRT/HostsViewModel.swift`: syncs the followed hosts on load and delete, `select` stops driving alerts, and `tapAlert` works by the alert's host.
- `VIRT/HostsView.swift`: adds `.id(ObjectIdentifier(sessions))` on `HostSessionsView`.
- `README.md`: updates the alerts sentence.
- `VIRTTests/SessionAlertPresenterTests.swift`, `VIRTTests/HostsViewModelTests.swift`: add the new tests and update the existing `alerts.hostID` and `baseline` checks.

## Test plan
- AC1 → `VIRTTests/SessionAlertPresenterTests.swift`: with two hosts loaded and none selected, a change on each raises alerts carrying the right `hostID`, queued in order. Selecting host B keeps host A's banner.
- AC2 → `VIRTTests/SessionAlertPresenterTests.swift`: host A goes `.reconnecting`, so A's baseline is nil while B's stays. A's next list raises nothing, and B's change still alerts.
- AC3 → `VIRTTests/SessionAlertPresenterTests.swift`: deleting A drops A's showing and queued alerts, so B's queued alert shows next. A later change from A raises nothing.
- AC4 → `VIRTTests/SessionAlertPresenterTests.swift`: tapping B's alert with A's sessions screen open, or none open, gives `sessions.host == B`, a pending chat on B's latest row, and `selectedHostID == B`. With B's screen open, the chat opens on the same model.
- AC5 → manual check on the simulator: tapping B's banner over A's sessions screen shows B's sessions screen, then the chat.
- AC1–AC4 → `VIRTTests/HostsViewModelTests.swift`: replace the `alerts.hostID` checks with checks on the followed host set.

## Size estimate
Estimate: 130 code lines
- Follow every saved host, with alerts carrying their host's id
- Keep a baseline and latest rows for each host separately
- Drop a deleted host's alerts and stop following it
- Open the alert's own host, then the chat, on tap
