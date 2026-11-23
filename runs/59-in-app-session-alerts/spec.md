# Spec: Show an in-app alert when a session finishes, fails or needs input

## Goal
While VIRT is open, a short banner and a VoiceOver announcement tell you when a session on the connected host finishes, fails or needs input. Tapping the banner opens that session's chat.

## Acceptance criteria
- AC1: VIRTKit has `SessionAlert`, a `Sendable`, `Equatable` value with a host id, a session URI, a kind (`finished`, `inputNeeded` or `failed`) and a title. VIRTKit also has a pure rule that takes the host id, the old `[SessionRow]` and the new `[SessionRow]`, and returns alerts. A session that is in both lists and goes from `.working` to `.idle` gives `finished`. Going from `.working` to `.waitingForInput` gives `inputNeeded`, and going from `.working` to `.failed` gives `failed`. The alert's title is the new row's `title`. Any other change, a new session, a removed session or an unchanged state gives no alert.
- AC2: An app presenter follows only the host `HostsViewModel` has selected, through `HostConnecting.sessionUpdates` and `statusUpdates`. When the status stops being `.connected`, the presenter drops its baseline. The first row list after that only sets a new baseline and raises no alert. This covers the first connect, a reconnect and coming back from the background. Each later list goes through the AC1 rule.
- AC3: The presenter shows one banner at a time and queues the rest in order. It drops an alert if one with the same host, session and kind is already showing or queued. It drops alerts for the session whose chat is on screen. When the selected host changes, it drops the old host's banner and queue.
- AC4: The banner shows over every screen, with the title as plain text (`Text(verbatim:)`) and words for the kind: "Finished", "Needs input" or "Failed". Showing a banner posts a VoiceOver announcement of the same text. The banner closes by itself after a few seconds, and the next queued alert follows.
- AC5: Tapping the banner closes it and opens that session's chat, using the row from the host's latest rows. The host's sessions screen opens first if it isn't on screen. If the session is no longer in the rows, the tap only closes the banner.

## Out of scope
- Answering input or approving tool calls from the banner.
- Alerts for hosts other than the connected one (#60), and push alerts while VIRT is in the background or closed (#61).
- Notification permission, sounds and persisting alerts.

## Assumptions
- I read "from Working to Idle, to Waiting for input, or to Failed" as: every alert starts from `.working`. If VIRT never sees the Working state between two lists, it raises no alert.
- A "repeat" is an alert that matches one already showing or queued. The same session finishing again on a later turn alerts again.
- Reading from the connection stays in the app, behind `HostConnecting`, so the presenter is tested with the existing fake connector. No `InMemoryTransport` test is needed.
- The repo has no `docs/board-reads.md`, so there are no known consumers, and this change doesn't trigger a `Consumers:` line.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/SessionAlert.swift`: the type and the transition rule (no SwiftUI).
- `VIRT/SessionAlertPresenter.swift`: the baseline, the queue, de-duplication, suppressing the on-screen chat, and taps.
- `VIRT/SessionAlertBanner.swift`: the banner view and the announcement.
- `VIRT/VIRTApp.swift`, `VIRT/HostsViewModel.swift`, `VIRT/HostsView.swift`, `VIRT/SessionChatView.swift`: owning the presenter, following the selected host, the banner overlay, reporting the on-screen chat, and tap navigation.

## Test plan
- AC1 → `Packages/VIRTKit/Tests/VIRTKitTests/SessionAlertTests.swift`: parameterised old/new states give the right kind or no alert; new, removed and unchanged rows give none; the title and URI come from the new row.
- AC2 → `VIRTTests/SessionAlertPresenterTests.swift`: the first list after `.connected` raises nothing. After `.reconnecting` then `.connected`, the next list is a new baseline. A later Working→Idle change raises `finished`.
- AC3 → `VIRTTests/SessionAlertPresenterTests.swift`: alerts queue in order; a duplicate of the showing or a queued alert is dropped; the on-screen chat's session is dropped; selecting another host clears the queue.
- AC4 → `VIRTTests/SessionAlertPresenterTests.swift`: the banner and announcement text for each kind, with a title containing Markdown or HTML characters kept unchanged; closing the banner shows the next queued one.
- AC5 → `VIRTTests/SessionAlertPresenterTests.swift`: a tap gives the session's row from the latest rows; a session that has gone gives none and only closes the banner.

## Size estimate
Estimate: 330 code lines
- The `SessionAlert` type and the Working→Idle/Waiting/Failed rule in VIRTKit
- A baseline that resets on connect, reconnect and return from the background, for the selected host
- A presenter that queues, drops repeats and drops the on-screen chat, plus the plain-text banner with its VoiceOver announcement
- Tapping the banner opens the session's chat
