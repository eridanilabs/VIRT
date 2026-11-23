# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (logic) VIRT/HostsViewModel.swift:197: `connectAll` loops over a copy of `hosts` taken when the loop starts, and `connect(_:)` only checks `hosts.contains` after its connector awaits. If a `delete` of a not-yet-visited host finishes between two iterations, the loop still calls `connector.connect` for the deleted host. That host then fails on a missing host or token, and its row is gone. The window is small. Fix: add `guard hosts.contains(where: { $0.id == hostID }) else { return }` at the top of `connect(_:)`, next to the `isInBackground` guard.
- [note] VIRT/HostsViewModel.swift:132: In `sceneDidChange(.background)`, the `connected` snapshot can include a host deleted mid-loop. That host then gets a second, harmless `disconnect`.
- [note] VIRT/HostsViewModel.swift:176: `connector.connect` returns once the client has added the host, because `MultiHostClient.add` doesn't wait for the handshake. So `connectAll`'s sequential loop doesn't make a slow host block the others.

## Coverage
- Files read: AGENTS.md, spec.md, VIRT/HostsViewModel.swift (full), VIRT/HostsView.swift, README.md diff, VIRTTests/HostsViewModelTests.swift (fakes, and the connect, tap, row, lifecycle and token sections), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (connect, disconnect, statusUpdates), AHP `MultiHostClient.add` and `remove`.
- Flows walked:
  - Load: first load, later load after add, failed load.
  - Delete: success, and a failed delete.
  - Select: busy host, idle or failed host, and in the background.
  - Background then active: failed hosts included, and `.inactive` or a plain `.active` doing nothing.
  - `.active` arriving mid-way through the background's disconnect loop.
  - Per-host status isolation.
  - Concurrent select during `connectAll`.
  - Delete during `connectAll` (the nit above).
- Commands run: `./scripts/test.sh` → exit 0. The log ends with "done 0", and the VIRTKit package tests and the app tests on the simulator pass, including `SessionAlertPresenterTests`.
- Earlier blockers: none (round 1).
- Contracts: `docs/board-reads.md` isn't relevant. The diff changes no schema or event constants and doesn't touch VIRTKit.

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | VIRT/HostsViewModel.swift:61-72, VIRT/HostsViewModel.swift:75-87, VIRT/HostsViewModel.swift:176-182 | VIRTTests/HostsViewModelTests.swift › "loadConnectsEverySavedHostOnce", "laterLoadConnectsOnlyNewHostsAndLeavesAFailedOneFailed", "deleteDisconnectsTheDeletedHostOnly", "failedDeleteKeepsTheHostAndShowsAnError", "failedLoadOffersARetryAndASuccessfulLoadClearsIt" |
| AC2 | VIRT/HostsViewModel.swift:101-110, VIRT/HostsViewModel.swift:200-207 | VIRTTests/HostsViewModelTests.swift › "oneHostsStatusLeavesTheOtherRowsAlone", "rowShowsTheStatus" |
| AC3 | VIRT/HostsViewModel.swift:145-150 | VIRTTests/HostsViewModelTests.swift › "tappingAnotherHostKeepsTheFirstConnected", "selectingABusyHostMakesNoCall", "selectingAnIdleOrFailedHostConnectsOnlyIt", "selectedStatusTextFollowsTheSelectedHost" |
| AC4 | VIRT/HostsViewModel.swift:154-175, VIRT/HostsViewModel.swift:191-196 | VIRTTests/HostsViewModelTests.swift › "backgroundDisconnectsEveryHostAndActiveReconnectsThemAll", "inactiveOrActiveWithoutABackgroundCallsNothing", "loadOrTapInTheBackgroundConnectsNothingUntilActive", "activeDuringTheBackgroundsDisconnectsLeavesEveryHostConnected" |
| AC5 | VIRT/HostsViewModel.swift (no token reads; every connection goes through `connector.connect`) | VIRTTests/HostsViewModelTests.swift › "connectingEveryHostNeverReadsAToken" |
| AC6 | README.md:62-69 | none (docs; no test needed) |
