# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/SessionAlertPresenter.swift:27: `connectedHostIDs` exists only for tests, as `isConnected` did before. The doc comment says so. No action needed.
- [note] VIRT/HostsView.swift:93: `.id(ObjectIdentifier(sessions))` (AC5) has no unit test. The spec's test plan makes it a manual simulator check, which I didn't do here.
- [note] VIRT/HostsViewModel.swift:83: `delete` syncs the followed set with `follow(hostIDs.subtracting([id]))`. It reads the presenter's own set, so it is safe if the delete runs before any load.

## Coverage
- Files read: AGENTS.md, spec.md, VIRT/SessionAlertPresenter.swift (full), VIRT/HostsViewModel.swift (full), VIRT/HostsView.swift (hunk), README.md (hunk), VIRTTests/SessionAlertPresenterTests.swift (diff), VIRTTests/HostsViewModelTests.swift (diff)
- Flows walked:
  - Load: follow runs before `connectAll`, so no early status or rows are missed. It is idempotent on reload and after a form save, so an existing host keeps its baseline, rows and alerts.
  - Added host: it is followed on the next load.
  - Delete success: tasks are cancelled, per-host state and queued alerts are dropped, and the next queued alert shows if the deleted host's banner was up.
  - Delete failure: the early return leaves the followed set unchanged.
  - Select: no longer touches the presenter, so the banner and queue stay.
  - Status leaves `.connected` for one host: only that host's baseline is cleared.
  - Background: every host goes idle, so every baseline is cleared. The test covers this.
  - Tap: for a gone session, a gone host, no sessions screen, another host's screen and the same host's screen.
  - Repeat and on-screen-chat rules are matched by host and session.
- Commands run: `./scripts/test.sh` → exit 0, all test cases passed, including the new `tapOpensTheAlertsOwnHostThenTheChat`, `oneHostLeavingConnectedClearsOnlyItsBaseline`, `deletingAHostDropsItsAlertsAndStopsFollowingIt`, `everySavedHostRaisesAlertsWithItsOwnIDInOneQueue` and `aHostAddedLaterRaisesAlertsWithoutATap`. The worktree stayed clean (`git status` showed nothing).
- Grep for stale uses of `follow(` (single-host), `hostID`, `baseline` and `isConnected` on the presenter found none.
- Earlier blockers: none (round 1)

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | VIRT/SessionAlertPresenter.swift:52-60,90-108,114-121; VIRT/HostsViewModel.swift:69,153-159 | VIRTTests/SessionAlertPresenterTests.swift › "everySavedHostRaisesAlertsWithItsOwnIDInOneQueue", "aHostAddedLaterRaisesAlertsWithoutATap"; VIRTTests/HostsViewModelTests.swift › the `alerts.hostIDs` checks |
| AC2 | VIRT/SessionAlertPresenter.swift:91-98 | VIRTTests/SessionAlertPresenterTests.swift › "oneHostLeavingConnectedClearsOnlyItsBaseline", "returningFromTheBackgroundMakesEveryHostsNextListANewBaseline", "leavingConnectedMakesTheNextListANewBaseline(status:)" |
| AC3 | VIRT/HostsViewModel.swift:76-87; VIRT/SessionAlertPresenter.swift:110-119 | VIRTTests/SessionAlertPresenterTests.swift › "deletingAHostDropsItsAlertsAndStopsFollowingIt"; VIRTTests/HostsViewModelTests.swift › failed-delete test (`alerts.hostIDs == [saved.id]`) and "deleteDisconnectsTheDeletedHostOnly" |
| AC4 | VIRT/HostsViewModel.swift:138-152; VIRT/SessionAlertPresenter.swift:67-75 | VIRTTests/SessionAlertPresenterTests.swift › "tapOpensTheAlertsOwnHostThenTheChat(openScreen:)", "tapOnAGoneSessionOnlyClosesTheBanner", "tapOpensTheChatOnTheOpenSessionsScreenOrOnANewOne" (same-host case) |
| AC5 | VIRT/HostsView.swift:91-94 | none (the spec's test plan makes this a manual simulator check) |
| AC6 | README.md:62 | none (docs only) |
