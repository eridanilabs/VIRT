# Review r2: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/SessionAlertPresenter.swift:134: `usesAssistiveTech` is read once, when a banner is shown. Turning VoiceOver on while a banner is already up doesn't change that banner's timer. The next banner uses the new value. This is harmless.
- [note] VIRT/HostSessionsView.swift:66: `.id(ObjectIdentifier(chat))` is the whole view-level fix for #65, and no test covers it, because the repo has no UI tests. The new view-model test only shows that the tap gives a different chat model. `ObjectIdentifier` values can be reused only after a model is freed, and the old chat model is still alive while its replacement is made, so the two can't collide.

## Coverage
- Files read: AGENTS.md, spec.md, review-1-code.md, triage-1.md, triage-1.2.md, build-2.md, and the delta `93b2756..HEAD`. In full: the changed regions of HostSessionsView.swift, SessionAlertBanner.swift, SessionAlertPresenter.swift, HostsViewModel.swift and SessionAlertPresenterTests.swift. I did not re-read the whole `base...HEAD` diff line by line.
- Flows walked:
  - A banner tap over chat A replaces it with chat B: `tapAlert` sets `sessions.chat` to a new model and `.id(ObjectIdentifier(chat))` gives it a new view identity.
  - Banner timer: the default 4 s, `assistiveDuration` (20 s) when VoiceOver or Switch Control is on, a new banner per `show`, and cancelling the old timer.
  - The banner overlay is always mounted, so `onChange(initial: true)` keeps `usesAssistiveTech` up to date.
  - Tapping with the host form open: this only gets a comment, and #68 is declined and filed.
  - The `isConnected` nit is resolved with a comment that only tests read it. #67 is filed.
- Commands run: `./scripts/test.sh` → exit 0, all VIRTKit and app tests pass, including the two new ones. `git status --short` afterwards → empty.
- Earlier blockers: none from reviewer-code in round 1. The round 1 `(ac)` blocker on AC5 (#65) came from reviewer-ux. From the code side, the replace-in-place fix looks right and → fixed.
- Contracts: the repo has no `docs/board-reads.md`, and no `SCHEMA_VERSION` or `factory-result` change, so no `Consumers:` check applies.

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | Packages/VIRTKit/Sources/VIRTKit/SessionAlert.swift:8-46 | Packages/VIRTKit/Tests/VIRTKitTests/SessionAlertTests.swift › "onlyLeavingWorkingAlerts", "titleAndURIComeFromTheNewRow", "newRemovedAndUnchangedSessionsGiveNone", "severalAlertsFollowTheNewOrder" |
| AC2 | VIRT/SessionAlertPresenter.swift:54-82, VIRT/HostsViewModel.swift:176 | VIRTTests/SessionAlertPresenterTests.swift › "firstListAfterConnectingSetsTheBaselineAndALaterChangeAlerts", "leavingConnectedMakesTheNextListANewBaseline", "returningFromTheBackgroundMakesTheNextListANewBaseline" |
| AC3 | VIRT/SessionAlertPresenter.swift:54-65, VIRT/SessionAlertPresenter.swift:100-128, VIRT/SessionChatView.swift:53-54 | VIRTTests/SessionAlertPresenterTests.swift › "alertsQueueInOrderAndRepeatsAreDropped", "theOnScreenChatsSessionRaisesNoAlert", "openingAChatDropsItsAlertsAndAnotherChatsDisappearanceKeepsIt", "selectingAnotherHostDropsTheBannerAndQueue" |
| AC4 | VIRT/SessionAlertBanner.swift:8-46, VIRT/SessionAlertPresenter.swift:129-143 | VIRTTests/SessionAlertPresenterTests.swift › "bannerAndAnnouncementTextKeepTheTitleAsSent", "closingTheBannerShowsAndAnnouncesTheNextOne", "theBannerClosesByItselfAndTheNextFollows", "theBannerStaysLongerWithVoiceOverOrSwitchControl" (the overlay is SwiftUI, so no test covers it) |
| AC5 | VIRT/SessionAlertPresenter.swift:84-92, VIRT/HostsViewModel.swift:123-140, VIRT/HostSessionsView.swift:62-66 | VIRTTests/SessionAlertPresenterTests.swift › "tapGivesTheSessionsLatestRow", "tapOnAGoneSessionOnlyClosesTheBanner", "tapOpensTheChatOnTheHostsSessionsScreen", "tapOverAnotherSessionsChatReplacesItWithANewChatModel" |
