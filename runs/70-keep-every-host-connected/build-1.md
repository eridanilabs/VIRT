# Build r1 (claude-opus-5.5)

## Summary
Every saved host now connects while VIRT is in the foreground, and each host's row shows that host's own status. Tapping a host selects it for alerts and opens its sessions. The tap connects the host only if it's idle or failed, and it never disconnects another host. Going to the background disconnects every host, and coming back reconnects every saved host, failed ones included. The full test suite passes.

## Changes
- `VIRT/HostsViewModel.swift`:
  - Replaced the single `selectedStatus` / `statusTask` with a status and a status task for each host.
  - `load()` now connects each saved host the model hasn't asked to connect yet. A failed host stays failed, and a load in the background connects nothing.
  - A successful `delete` disconnects the host and stops following its status.
  - `select` sets `selectedHostID` and calls `alerts.follow`, then connects only an idle or failed host, and never in the background. It never disconnects anything.
  - `sceneDidChange` disconnects every host the model connected on `.background`. It connects every saved host on `.active`, but only after a background.
  - Edge case: if VIRT becomes active again while the background disconnects are still running, the rest of those disconnects are skipped, so no host is left disconnected in the foreground.
- `VIRT/HostsView.swift`: the row's accessibility hint is now "Opens this host's sessions", and the doc comment is updated.
- `VIRTTests/HostsViewModelTests.swift`:
  - Replaced the one-host-at-a-time tests with tests for every host connecting, each host's own status, taps, the app lifecycle and the token.
  - Changed existing tests that now see a `.connect` from `load()`.
  - Extended the failed load and failed delete tests to check that they make no connector calls.
  - `FakeConnector.Call` is now `Hashable`, so the background test can compare disconnects as a set.
- `README.md`: rewrote the "Connecting to a host" section for the new behaviour, including delete and edit.
- Reused the existing `FakeConnector` (with `holdDisconnects` and `releaseDisconnects`), `connectingModel()`, `send(_:for:to:through:)`, the `HostConnector.Status.text` / `isActive` helpers and `SessionAlertPresenter.follow`.
- `SessionAlertPresenterTests.swift` and VIRTKit are unchanged.
- The change is about 364 lines (218 added, 151 removed).

## AC coverage
- AC1:
  - `VIRTTests/HostsViewModelTests.swift` › "loadConnectsEverySavedHostOnce"
  - "laterLoadConnectsOnlyNewHostsAndLeavesAFailedOneFailed"
  - "deleteDisconnectsTheDeletedHostOnly"
  - "failedDeleteKeepsTheHostAndShowsAnError" (no extra call)
  - "failedLoadOffersARetryAndASuccessfulLoadClearsIt" (calls == [])
- AC2:
  - "oneHostsStatusLeavesTheOtherRowsAlone(status:)" (failed, reconnecting and idle)
  - "rowShowsTheStatus" (the other row stays "Connecting…")
- AC3:
  - "tappingAnotherHostKeepsTheFirstConnected"
  - "selectingABusyHostMakesNoCall(status:)"
  - "selectingAnIdleOrFailedHostConnectsOnlyIt(status:)"
  - "selectedStatusTextFollowsTheSelectedHost"
- AC4:
  - "backgroundDisconnectsEveryHostAndActiveReconnectsThemAll"
  - "inactiveOrActiveWithoutABackgroundCallsNothing"
  - "loadOrTapInTheBackgroundConnectsNothingUntilActive"
  - "activeDuringTheBackgroundsDisconnectsLeavesEveryHostConnected"
- AC5: "connectingEveryHostNeverReadsAToken" (`tokens.reads == 0`, and every connection goes through `connect`)
- AC6: `README.md` › "Connecting to a host". This is a docs change with no test.

## Tests
`./scripts/test.sh` exited 0 after commit `4536b11` (`feat(app): keep every saved host connected while VIRT is open`, with the `Refs: #70` footer and the Copilot trailer).
```
✔ Test reconnectChecksTheTailnetAgain() passed after 1.032 seconds.
✔ Suite HostConnectorTests passed after 1.033 seconds.
✔ Test run with 84 tests in 13 suites passed after 1.033 seconds.
Test case 'SessionAlertPresenterTests/theBannerStaysLongerWithVoiceOverOrSwitchControl()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (98561)' (0.833 seconds)
Test case 'SessionAlertPresenterTests/theBannerClosesByItselfAndTheNextFollows()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (98561)' (0.842 seconds)
```
- VIRTKit `swift test`: 84 passed, 0 failed.
- App `xcodebuild test`: 114 passed, 0 failed.

## Found, not fixed
none
