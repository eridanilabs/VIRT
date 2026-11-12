# Build r2 (claude-opus-5.5)

## Summary
Round 2 fixes the blocker (#30) and all six nits, and `./scripts/test.sh` passes. A tap that lands while an earlier tap is still disconnecting can no longer leave two hosts connected. The model now sets the new selection before any await and keeps a list of every host it asked to connect. Each `select` disconnects all of them except the new host. If a later tap, or the app going to the background, takes over while a disconnect is in flight, the earlier `select` stops without connecting. I added tests that run overlapping taps against a fake whose `disconnect` suspends, and they check only the last-tapped host is left connected.

I didn't rerun the old code against the new race tests to watch them fail. By reasoning, the old code would leave both hosts connected and fail them.

## Changes
- `VIRT/HostsViewModel.swift`:
  - **Blocker:** added `requestedHostIDs` and `isInBackground`. `connect(_:)` now sets the selection first, disconnects every other requested host, then connects unless a later tap or the background took over. `select(_:)` now just calls it. Going to the background disconnects every requested host.
  - **Nits:** the row text comes from one shared function. The protocol version shows only if it matches `[0-9A-Za-z.-]{1,16}`, else the row says "Connected". Added `selectedStatusText` for the VoiceOver announcement.
- `VIRT/HostsView.swift`:
  - A failure shows a red `exclamationmark.triangle.fill` icon beside text in the secondary colour.
  - Every other status line is limited to one line.
  - The row gives VoiceOver its status as `accessibilityValue`, and the status text is hidden from VoiceOver so it isn't read twice.
  - VoiceOver announces each change in the selected host's status (`AccessibilityNotification.Announcement`).
  - Edit uses `.tint(.accentColor)`.
- `VIRTTests/HostsViewModelTests.swift`:
  - Extended `FakeConnector`. It tracks which hosts are connected, and while disconnects are held, `disconnect` suspends.
  - `eventually` now accepts async conditions.
  - New tests: "concurrentTapsLeaveOnlyTheLastHostConnected(first:second:)" (taps A, then B, then A; and A, then B, then C), "backgroundDuringATapConnectsNothingUntilActive" and "selectedStatusTextFollowsTheSelectedHost".
  - Four new protocol-version rows in "rowShowsTheStatus": a newline injection, a space, 17 characters, and `1.0.0-rc.1`.
- `README.md`: says "connecting, connected or reconnecting", and drops the stale milestone sentence.

I left the failed-host-in-background behaviour and the `ScenePhase` parameter as they were, as asked.

## AC coverage
- **AC7** → `VIRTTests/HostsViewModelTests.swift`:
  - "selectingAnotherHostDisconnectsTheFirst"
  - "selectingABusyHostAgainDoesNothing(status:)"
  - "selectingAFailedHostTriesAgain"
  - "concurrentTapsLeaveOnlyTheLastHostConnected(first:second:)" (new, for #30)
- **AC8** → "rowShowsTheStatus(status:text:)", which now includes the hostile version strings, and "selectedStatusTextFollowsTheSelectedHost".
- **AC9** → "backgroundDisconnectsAndActiveReconnects(status:)", "activeDoesNotReconnectAFailedHost", "noSelectedHostOrInactiveCallsNothing" and "backgroundDuringATapConnectsNothingUntilActive" (new).
- **AC10** → the README, for manual review.
- **VIRTKit** → `HostConnectorTests` › "connectsThroughHostConnecting".

## Findings
- reviewer-security · `[blocker] (ac) VIRT/HostsViewModel.swift:90-100: select(_:) sets selectedHostID = nil before it awaits connector.disconnect(previous) … That breaks AC7 ("Only one host is connected at a time").` → **Fixed** in `029834c` (sub-issue #30).
- reviewer-security · `[nit] VIRT/HostsView.swift:21, VIRT/HostsViewModel.swift:82: the row shows the host-sent protocolVersion unchecked, so a host can inject newlines or a long string` → **Fixed** in `baa3fc5`. The version must match `[0-9A-Za-z.-]{1,16}`, else the row says "Connected". Every line except a failure has `.lineLimit(1)`, so failure messages still wrap.
- reviewer-ui-design · `[nit] VIRT/HostsView.swift:23: failed status line is .caption in plain .red, about 3.6:1 in light mode.` → **Fixed** in `baa3fc5`: secondary text with a red `exclamationmark.triangle.fill` icon.
- reviewer-ui-design · `[nit] VIRT/HostsView.swift:36: .tint(.blue) on the Edit swipe action is a fixed colour.` → **Fixed** in `baa3fc5`: `.tint(.accentColor)`.
- reviewer-ux · `[nit] VIRT/HostsView.swift:20-26: VoiceOver doesn't hear status changes.` → **Fixed** in `baa3fc5`: `.accessibilityValue` on the row, plus an announcement when the selected host's status text changes.
- reviewer-ux · `[nit] README.md:62: "already connecting or connected does nothing" leaves out reconnecting.` → **Fixed** in `924d729`.
- reviewer-ux · `[nit] README.md:80: "The milestone that adds connecting documents the exact setup." is now stale.` → **Fixed** in `924d729`: the sentence is gone. The section already gives the loopback URL and where the token is.

## Tests
- **VIRTKit (`swift test`):** 43 tests in 7 suites, all passed.
- **App (`xcodebuild test`, iPhone 18 Pro simulator):** 58 test cases passed, 0 failed. No build warnings in `VIRT/` or `VIRTTests/`.
- I also ran the tests on the blocker commit `029834c` by itself: 43 VIRTKit tests and 53 app test cases passed, 0 failed.

## Commits (round 2)
- `029834c` fix(app): leave only the last-tapped host connected when taps overlap (`Refs: #21`, `Refs: #30`)
- `baa3fc5` fix(app): show only a plain protocol version and make the status row accessible (`Refs: #21`)
- `924d729` docs(readme): mention reconnecting hosts and drop a stale setup note (`Refs: #21`)

Each has the Copilot `Co-authored-by` trailer. Nothing is pushed.

## Left open
The hand checks from round 1 still need a person, a token and a running host. Keep the token out of the PR, logs and screenshots.
- **ATS:** connect to `ws://127.0.0.1:48765` on a simulator and record whether iOS lets a plain WebSocket reach a raw IP. If it doesn't, the row reads "Failed: iOS blocked this plain connection. Use wss:// or a .ts.net name." A fix needs its own card.
- **Tailnet host:** `ws://gallifrey.tail537c2.ts.net:48765` should connect with Tailscale on, and fail with "not on your tailnet" with it off.
- **Lifecycle:** the background, return and Control Center behaviour.
- **Tapping and swiping:** fast taps between hosts, and the Edit and Delete swipe actions.
- **VoiceOver:** the announcement and the row's value on a device.