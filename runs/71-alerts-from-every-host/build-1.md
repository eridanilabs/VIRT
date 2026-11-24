# Build r1 (builder-app · claude-opus-5.5)

## Summary
In-app alerts now come from every saved host, not just the one you last tapped. `SessionAlertPresenter` follows a set of hosts, and each host has its own baseline and latest rows. All hosts share one banner queue, kept in the order alerts arrive. Tapping an alert opens that alert's own host and then the chat, even if another host's sessions screen is open. `./scripts/test.sh` passes, and the work is committed as `05c3f3e`. AC5 (the right screen appears on the simulator) is a manual check that I haven't done.

## Changes
- `VIRT/SessionAlertPresenter.swift`: replaced the single-host `follow(_:)`/`hostID` with `follow(_ hostIDs: Set<UUID>)` and a read-only `hostIDs`. Each host gets its own status and rows tasks. `baseline`, `latestRows` and `isConnected` became per-host `baselines`, `latestRows` and `connectedHostIDs`. When a host is dropped, its tasks stop, its queued alerts go, and if its banner is showing, the next queued alert shows. `tap()` now returns the alert's host along with the row. `enqueue`, `matches` and the on-screen-chat check are reused unchanged, so the repeat and on-screen rules still match by host and session.
- `VIRT/HostsViewModel.swift`: `load()` calls `alerts.follow(...)` after each successful load, so a host added through the form is followed too. `delete(_:)` stops following the host only after the delete succeeds. `select(_:)` no longer touches the alerts. `tapAlert()` uses the alert's `hostID` and sets `selectedHostID`. It reuses the existing `makeSessionsModel(for:)`, `openChatOnAppear(_:)` and `makeChatModel(for:)`.
- `VIRT/HostsView.swift`: added `.id(ObjectIdentifier(sessions))` on `HostSessionsView`.
- `README.md`: now says alerts come from every connected saved host, and that tapping one opens its host's sessions, then the chat.
- `VIRTTests/SessionAlertPresenterTests.swift`: updated the helpers to the per-host API. `hostsModel(_ names:)` now sets up several hosts and uses the shared `TemporaryDefaults`. Added new tests, replaced the old "selecting drops the banner" test, and removed the `select` calls the tap tests no longer need.
- `VIRTTests/HostsViewModelTests.swift`: `TemporaryDefaults` is no longer `private`, so both test files can use it. The `alerts.hostID` checks are now checks on `alerts.hostIDs`, the set of followed hosts. Added the same check to the load, later-load, delete and failed-delete tests.

## AC coverage
- **AC1** →
  - `VIRTTests/SessionAlertPresenterTests.swift` › "everySavedHostRaisesAlertsWithItsOwnIDInOneQueue": two hosts, none selected; one queue in arrival order; repeat and on-screen-chat rules by host; `select` keeps the banner and queue.
  - Same file › "aHostAddedLaterRaisesAlertsWithoutATap".
  - `VIRTTests/HostsViewModelTests.swift` › "laterLoadConnectsOnlyNewHostsAndLeavesAFailedOneFailed", "tappingAnotherHostKeepsTheFirstConnected".
- **AC2** →
  - `VIRTTests/SessionAlertPresenterTests.swift` › "oneHostLeavingConnectedClearsOnlyItsBaseline".
  - Same file › "returningFromTheBackgroundMakesEveryHostsNextListANewBaseline".
  - Same file › "leavingConnectedMakesTheNextListANewBaseline(status:)": idle, connecting, reconnecting and failed.
- **AC3** →
  - `VIRTTests/SessionAlertPresenterTests.swift` › "deletingAHostDropsItsAlertsAndStopsFollowingIt".
  - `VIRTTests/HostsViewModelTests.swift` › "deleteDisconnectsTheDeletedHostOnly", "failedDeleteKeepsTheHostAndShowsAnError".
- **AC4** →
  - `VIRTTests/SessionAlertPresenterTests.swift` › "tapOpensTheAlertsOwnHostThenTheChat(openScreen:)": no screen open, A's screen open, or B's screen open.
  - Same file › "tapOnAGoneSessionOnlyClosesTheBanner", "tapOpensTheChatOnTheHostsSessionsScreen(sessionsOpen:)".
- **AC5** → the `.id(ObjectIdentifier(sessions))` change in `HostsView.swift`. The model side (a new, separate model for host B) is checked in "tapOpensTheAlertsOwnHostThenTheChat(openScreen: "A")". The simulator check (tap B's banner over A's screen) is still to do by hand.
- **AC6** → `README.md`, connecting section (docs only, no test).

## Found, not fixed
none

## Tests
`./scripts/test.sh` exited 0: `swift test` on VIRTKit passed, and so did `xcodebuild test` on the VIRT scheme on the iPhone 18 Pro simulator. Last 5 lines:
```
Test case 'SessionAlertPresenterTests/returningFromTheBackgroundMakesEveryHostsNextListANewBaseline()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24793)' (0.601 seconds)
Test case 'SessionAlertPresenterTests/everySavedHostRaisesAlertsWithItsOwnIDInOneQueue()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24793)' (0.613 seconds)
Test case 'SessionAlertPresenterTests/deletingAHostDropsItsAlertsAndStopsFollowingIt()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24793)' (0.612 seconds)
Test case 'SessionAlertPresenterTests/theBannerStaysLongerWithVoiceOverOrSwitchControl()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24793)' (0.870 seconds)
Test case 'SessionAlertPresenterTests/theBannerClosesByItselfAndTheNextFollows()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24793)' (0.882 seconds)
```
