# Build r1 (claude-opus-5.5)

## Summary
All four AC groups for #54 are built and committed in `8b7ffaa` on `factory/54-app-screen-polish`. The connect screens now give clearer URL and save errors and let you retry a failed host list. The sessions screen starts at the right status, shows a spinner and makes VoiceOver announcements, and the chat stops following the bottom while you drag. `./scripts/test.sh` passes: 79/79 VIRTKit tests and 87 app test cases, 0 failures. A Release build also compiles with the previews left out.

## Changes
- `VIRT/HostFormViewModel.swift`:
  - The URL error now reads "VIRT can't read this URL. Enter it like wss://host.example.com."
  - The `token` doc comment says the saved token is trimmed.
  - Editing `name`, `urlText` or `token` clears `saveError` (via `didSet`).
- `VIRT/HostFormView.swift`:
  - In the CGNAT warning the text is `.secondary` and only the icon is orange.
  - The Token section has no header.
  - The previews are inside `#if DEBUG`.
- `VIRT/HostsViewModel.swift`:
  - Added `loadFailed`. A failed `load()` sets it and leaves `errorMessage` alone; a successful one clears it.
  - `makeSessionsModel(for:)` starts an idle or failed host at `.connecting`, and any other host at its current status. It reuses the existing private `isActive` check.
- `VIRT/HostsView.swift`:
  - After a failed load, the screen shows "Couldn't load hosts" with a **Retry** button that calls `load()`, and hides the rows.
  - The Hosts screen's own status announcement is skipped while a sessions screen is open, so VoiceOver doesn't say it twice.
  - Removed `.lineLimit(1)` from `HostStatusLine`.
  - `HostLibrary.preview` and its `#Preview` are inside `#if DEBUG`.
- `VIRT/HostSessionsViewModel.swift`: `init` takes a starting `status` (default `.idle`). Added `showsProgress`, true only for `.connecting` and `.reconnecting`.
- `VIRT/HostSessionsView.swift`:
  - Shows a `ProgressView` next to the status line while `showsProgress` is true.
  - Posts an announcement on each `statusText` change.
  - The preview is inside `#if DEBUG`.
- `VIRT/SessionChatViewModel.swift`:
  - Added `scrollPhaseChanged(interacting:atBottom:)`. Starting a drag turns following off; settling sets it from whether the chat is at the bottom.
  - Extended `scrolled(from:to:)` so it does nothing and returns false during a drag.
- `VIRT/SessionChatView.swift`:
  - `.onScrollPhaseChange` calls the new method on `.interacting` and `.idle`, reusing `isAtBottom(_:)` on the context's geometry.
  - The tool-call `HStack` uses `.firstTextBaseline`.
  - The preview is inside `#if DEBUG`.
- `VIRTTests/HostsViewModelTests.swift`, `VIRTTests/SessionChatViewModelTests.swift`: new and updated tests, listed below.

## AC coverage
- **AC1 (`urlError` text)** → `VIRTTests/HostsViewModelTests.swift` › "unparseableURLDisablesSave" (now checks the exact text).
- **AC1 (save error cleared)** → `VIRTTests/HostsViewModelTests.swift` › "editingAFieldClearsTheSaveError(field:)" (name, urlText, token).
- **AC1 (colours, header, doc comment)** → checked in review.
- **AC2 (failed and successful load)** → `VIRTTests/HostsViewModelTests.swift` › "failedLoadOffersARetryAndASuccessfulLoadClearsIt".
- **AC2 (`#if DEBUG`, `lineLimit`)** → review, plus the Release build compiling without previews.
- **AC3 (starting status)** → `VIRTTests/HostsViewModelTests.swift` › "sessionsModelForAnIdleOrFailedHostStartsConnecting(status:)" and "sessionsModelForABusyHostStartsAtItsStatus(status:)".
- **AC3 (spinner flag)** → `VIRTTests/HostsViewModelTests.swift` › "progressShowsOnlyWhileConnectingOrReconnecting(status:shows:)".
- **AC3 (announcement)** → view code, checked in review.
- **AC4 (drag and settle)** → `VIRTTests/SessionChatViewModelTests.swift` › "aDragTurnsFollowingOffAndSettlingSetsItFromTheBottom".
- **AC4 (baseline)** → checked in review.

## Found, not fixed
none

## Tests
```
✔ Test run with 79 tests in 12 suites passed after 1.041 seconds.
Test case 'HostsViewModelTests/connectedListsEachRowUpdateInTheOrderReceived()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24361)' (0.722 seconds)
Test case 'HostsViewModelTests/notConnectedShowsOnlyTheLiveStatusLine()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (24361)' (0.736 seconds)
./scripts/test.sh exit=0
VIRTKit: 79 passed, 0 failed · VIRT app: 87 test cases passed, 0 failed
```
