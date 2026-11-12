# Build r1 (claude-opus-5.5)

## Summary
I built issue #21, and `./scripts/test.sh` passes. Tapping a host on the Hosts screen now connects it and disconnects any other host. Edit and Delete are now swipe actions. Each row shows a status line under its URL. VIRT disconnects the selected host when the app goes to the background and reconnects it on return if it was connecting, connected or reconnecting. A new `HostConnecting` protocol in VIRTKit lets the view model tests use a fake connector instead of a real host.

I made one choice the spec doesn't spell out (AC9): **a failed host isn't disconnected when the app goes to the background.** It has no live connection, and disconnecting would set it to idle and erase the "Failed: …" message. So the error stays visible when you come back, and VIRT doesn't retry it. If you want the literal reading ("always disconnect the selected host"), it's a one-line change.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: added the public `HostConnecting` protocol (`connect`, `disconnect`, `statusUpdates(for:)`). `HostConnector` conforms to it with no other change.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: added the test "connectsThroughHostConnecting". It reuses the existing `FakeHosts`, `next(_:until:)` and `saved()` helpers.
- `VIRT/HostsViewModel.swift`: extended the existing model with:
  - a connector, the selected host and its status;
  - `status(for:)` and `statusText(for:)` for the row;
  - `select(_:)` for a tap;
  - `sceneDidChange(to:)` for the app lifecycle.

  It removes the old `delete(at:)`, which nothing uses now that Delete is a swipe action calling the existing `delete(_:)`.
- `VIRT/HostsView.swift`: a tap connects the host (accessibility hint "Connects to this host"). Edit and Delete are swipe actions. The status line uses `Text`, never HTML, and failures show in red. The preview passes a connector.
- `VIRT/VIRTApp.swift`: creates one `HostConnector` on the same `HostLibrary` and passes `scenePhase` changes to the view model.
- `VIRTTests/HostsViewModelTests.swift`: added a `FakeConnector` actor, an `eventually` helper that waits for status changes, and the new tests. Existing tests now pass a fake connector, and the delete test calls `delete(_:)`.
- `README.md`: the status line no longer calls the app a scaffold that can't connect. "Connecting to a host" replaces "Tap a host to edit it" with how to connect, swipe to edit or delete, what each row status means, and the background behaviour.

## AC coverage
- **AC7** → `VIRTTests/HostsViewModelTests.swift`:
  - "selectingAnotherHostDisconnectsTheFirst" checks the calls are connect A, disconnect A, connect B.
  - "selectingABusyHostAgainDoesNothing(status:)" covers connecting, connected and reconnecting.
  - "selectingAFailedHostTriesAgain".
  - The swipe Edit and Delete are view code. Delete reuses `delete(_:)`, which "deleteRemovesTheHostAndItsToken" and "failedDeleteKeepsTheHostAndShowsAnError" already cover.
- **AC8** → "rowShowsTheStatus(status:text:)": one case each for idle, connecting, connected "0.1.0", connected "", reconnecting 3 (with and without a reason) and every failure, including each URL refusal. Each case checks the exact text, that other rows stay idle, and that the text has no token and no `tkn`.
- **AC9** → "backgroundDisconnectsAndActiveReconnects(status:)", "activeDoesNotReconnectAFailedHost" and "noSelectedHostOrInactiveCallsNothing" (going inactive, or inactive then active, calls nothing).
- **AC10** → the README change, for manual review.
- VIRTKit protocol → `HostConnectorTests` › "connectsThroughHostConnecting".

## Tests
- **VIRTKit (`swift test`):** 43 tests in 7 suites, all passed.
- **App (`xcodebuild test`, iPhone 18 Pro simulator):** 50 test cases passed, 0 failed. No build warnings in VIRT files.

## Commits
- `368f005` feat(virtkit): add a HostConnecting protocol that HostConnector conforms to
- `40565fa` feat(app): connect a host on tap, show its status and follow the app lifecycle
- `4588d24` docs(readme): explain how to connect to a host and what row statuses mean

Each commit has the `Refs: #21` footer and the Copilot `Co-authored-by` trailer. Nothing is pushed.

## Left open: checks a person must do by hand
I didn't run these: they need a token and a running host. Keep the token out of the PR, logs, screenshots and commits.
1. **`ws://127.0.0.1:48765`** on a simulator on the host's Mac. Tap the host and check the row goes "Connecting…" → "Connected · protocol <v>".
   - **ATS is the open question.** `Info.plist` has an exception only for `ts.net`, nothing for raw IPs. I don't know whether iOS lets a WebSocket to `127.0.0.1` through without one.
   - If ATS blocks it, the row should read "Failed: iOS blocked this plain connection. Use wss:// or a .ts.net name." Record that in the PR. Per the spec, the fix needs its own card, not a new exception here.
2. **`ws://gallifrey.tail537c2.ts.net:48765`** with Tailscale on. It should connect. With Tailscale off, it should read "Failed: This address isn't on your tailnet. Is Tailscale on?"
3. **Lifecycle.**
   - While connected, send the app to the background: the host should disconnect.
   - Bring it back: the row should go "Connecting…" → "Connected".
   - Open Control Center (inactive only): nothing should change.
   - With a failed host, background and return: it should stay failed and not retry.
4. **Switching hosts.** Tap host A, then host B: A's status line should disappear and B should connect. Tapping a connected host again should do nothing.
5. **Swipe actions.** Swiping a row should show **Edit**, which opens the form, and **Delete**, which removes the host.
