## Build round 3

Updated the test to host the actual `AppNavigationView` with a chat route and a simulated keyboard inset. It measures the production composer and bottom bar, verifying both remain above the keyboard area and the composer remains above navigation.

## Changed files
- `VIRT/AppNavigationView.swift`: exposes the production bottom bar’s frame to the layout test.
- `VIRTTests/SessionChatViewTests.swift`: tests the actual app navigation and chat route under a keyboard-sized inset.

## Tests
`./scripts/test.sh` passed, including the hosted layout test. Last five lines:
```text
Test case 'SessionAlertPresenterTests/returningFromTheBackgroundMakesEveryHostsNextListANewBaseline()' passed
Test case 'SessionAlertPresenterTests/everySavedHostRaisesAlertsWithItsOwnIDInOneQueue()' passed
Test case 'SessionAlertPresenterTests/deletingAHostDropsItsAlertsAndStopsFollowingIt()' passed
Test case 'SessionAlertPresenterTests/theBannerStaysLongerWithVoiceOverOrSwitchControl()' passed
Test case 'SessionAlertPresenterTests/theBannerClosesByItselfAndTheNextFollows()' passed
```

## Commit
`bbd58f1` — `fix(chat): exercise production composer layout`  
Includes `Refs: #92` and `Refs: #97`. Not pushed.

## Found, not fixed
none

## Findings (resumed only)
- reviewer · `VIRTTests/SessionChatViewTests.swift currently manually composes the chat, composer, navigation placeholder, and keyboard inset rather than exercising AppNavigationView, so the test passes even if production stops placing the composer above navigation or in the keyboard-adjusted viewport. Fix by testing the actual app navigation with a chat route and simulated keyboard inset, or sharing the production layout with the test.` → **Fixed** in `bbd58f1`