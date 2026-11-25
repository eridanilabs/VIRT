# Build round 1: builder-app (claude-opus-5.5)

## Summary
Updated the bottom navigation New action to show the chat bubble icon and “New Session” label. Its existing action still opens the new-session form. Committed as `4c19eca`.

## Changes
- `VIRT/AppNavigationView.swift`: changed only the New action’s icon and visible label.

## AC coverage
- AC1 → `VIRT/AppNavigationView.swift` › `Image(systemName: "bubble.left.and.bubble.right")`
- AC2 → `VIRT/AppNavigationView.swift` › `Text("New Session")`
- AC3 → `VIRTTests/HostsViewModelTests.swift` › `newSessionValidatesDirectoryAndOpensCreatedChat`

## Found, not fixed
none

## Tests
`./scripts/test.sh` passed (VIRTKit and app simulator tests). Final five output lines:
```text
Test case 'SessionAlertPresenterTests/everySavedHostRaisesAlertsWithItsOwnIDInOneQueue()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (85722)' (3.245 seconds)
Test case 'SessionAlertPresenterTests/returningFromTheBackgroundMakesEveryHostsNextListANewBaseline()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (85722)' (3.265 seconds)
Test case 'SessionAlertPresenterTests/deletingAHostDropsItsAlertsAndStopsFollowingIt()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (85722)' (2.715 seconds)
Test case 'SessionAlertPresenterTests/theBannerStaysLongerWithVoiceOverOrSwitchControl()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (85722)' (3.511 seconds)
Test case 'SessionAlertPresenterTests/theBannerClosesByItselfAndTheNextFollows()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (85722)' (3.561 seconds)
```
