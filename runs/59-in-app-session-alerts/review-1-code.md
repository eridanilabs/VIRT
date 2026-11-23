# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (simplicity) VIRT/SessionAlertPresenter.swift:28: `isConnected` is written in `follow` but no production code reads it. Only two tests use it, as a wait condition. Fix: delete it and wait on `baseline == nil` in the tests, or note that it exists for tests.
- [note] VIRT/HostSessionsView.swift:69: the deferred chat push opens the chat from `.onAppear` of the screen that was just pushed. Whether SwiftUI honours a `navigationDestination(item:)` change during the push transition is not covered by tests. `build-1.2.md` says it was not run on a simulator.
- [note] VIRT/SessionAlertPresenter.swift:58: the status and row streams run in separate tasks, so their relative order is not fixed. A row list queued before a `.reconnecting` status could set a stale baseline after the reset. A later list could then alert across the gap. This is rare and harmless, and AC2 doesn't rule it out.

## Coverage
- Files read: AGENTS.md, spec.md, found-1.md, build-1.2.md, the full `base...HEAD` diff for the source files, SessionAlertPresenter.swift, HostConnector.swift (status and row streams), HostsViewModel.swift (connect, sceneDidChange, tapAlert), and the test names in SessionAlertPresenterTests.swift.
- Flows walked:
  - First connect: the rows list is [] or the initial list, so it only sets a baseline.
  - Reconnect, `.failed`, `.idle` and background: each drops the baseline.
  - Same-host `follow` is a no-op.
  - Switching host clears the banner and queue.
  - De-duplication and queue order, and auto-close with the next alert following.
  - On-screen chat suppression, and the chat disappearing after another chat took its place.
  - Tap, with the session present, gone, the form open, and the sessions screen open or not.
- Commands run: `./scripts/test.sh` → exit 0, VIRTKit and app tests all pass, worktree left clean. I confirmed with `git status --short` only after the test run; the output was empty.
- Earlier blockers: none (round 1).
- Consumers check: the repo has no `docs/board-reads.md`, and no `SCHEMA_VERSION` or `factory-result` change, so nothing triggers.

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | Packages/VIRTKit/Sources/VIRTKit/SessionAlert.swift:8-46 | Packages/VIRTKit/Tests/VIRTKitTests/SessionAlertTests.swift › "onlyLeavingWorkingAlerts", "titleAndURIComeFromTheNewRow", "newRemovedAndUnchangedSessionsGiveNone", "severalAlertsFollowTheNewOrder" |
| AC2 | VIRT/SessionAlertPresenter.swift:47-75, VIRT/SessionAlertPresenter.swift:109-114, VIRT/HostsViewModel.swift:176 | VIRTTests/SessionAlertPresenterTests.swift › "firstListAfterConnectingSetsTheBaselineAndALaterChangeAlerts", "leavingConnectedMakesTheNextListANewBaseline", "returningFromTheBackgroundMakesTheNextListANewBaseline" |
| AC3 | VIRT/SessionAlertPresenter.swift:47-58, VIRT/SessionAlertPresenter.swift:93-107, VIRT/SessionAlertPresenter.swift:116-128, VIRT/SessionChatView.swift:53-54 | VIRTTests/SessionAlertPresenterTests.swift › "alertsQueueInOrderAndRepeatsAreDropped", "theOnScreenChatsSessionRaisesNoAlert", "openingAChatDropsItsAlertsAndAnotherChatsDisappearanceKeepsIt", "selectingAnotherHostDropsTheBannerAndQueue" |
| AC4 | VIRT/SessionAlertBanner.swift:8-36, VIRT/SessionAlertBanner.swift:39-47, VIRT/VIRTApp.swift:19-21, VIRT/HostsView.swift:85-88, VIRT/SessionAlertPresenter.swift:116-148 | VIRTTests/SessionAlertPresenterTests.swift › "bannerAndAnnouncementTextKeepTheTitleAsSent", "closingTheBannerShowsAndAnnouncesTheNextOne", "theBannerClosesByItselfAndTheNextFollows" (the overlay is SwiftUI, so no test covers it) |
| AC5 | VIRT/SessionAlertPresenter.swift:77-85, VIRT/HostsViewModel.swift:123-138, VIRT/HostSessionsViewModel.swift:68-78, VIRT/HostSessionsView.swift:69 | VIRTTests/SessionAlertPresenterTests.swift › "tapGivesTheSessionsLatestRow", "tapOnAGoneSessionOnlyClosesTheBanner", "tapOpensTheChatOnTheHostsSessionsScreen" |
