# Spec: Show connection status on the Hosts screen and follow the app lifecycle

## Goal
Tapping a saved host on the Hosts screen connects to it, and its row shows whether VIRT is connecting, connected, reconnecting or failed. VIRT disconnects when the app goes to the background and reconnects the same host when the app becomes active again.

## Acceptance criteria
- AC7: Tapping a host row connects that host and disconnects any other host. Only one host is connected at a time. Tapping a host that is connecting, connected or reconnecting does nothing. Tapping a failed host tries again. Swiping a row shows **Edit**, which opens the edit form, and **Delete**, which deletes as it does now.
- AC8: A row shows one status line under its URL: "Connecting…", "Connected · protocol <v>", "Reconnecting (attempt n)…" or "Failed: <Failure.message>". An idle host shows no status line. The status line never contains the token or a URL with `tkn`.
- AC9: When the scene goes to the background, VIRT disconnects the selected host. When the scene becomes active again, VIRT reconnects it if it was connecting, connected or reconnecting when the app went to the background. If it had failed or was idle, VIRT doesn't reconnect it. Going inactive without going to the background changes nothing.
- AC10: The README's "Connecting to a host" section says how to connect: tap a host to connect, swipe to edit or delete, what each row status means, and that the app disconnects in the background. It no longer says "Tap a host to edit it" and no longer calls the app a scaffold that can't connect.

## Out of scope
- Showing the reconnect reason (`Status.reconnecting(reason:)`) in the row.
- Disconnecting a host when it's deleted or edited, session lists, and a connection detail screen.
- Any new App Transport Security exception. If ATS blocks `ws://127.0.0.1`, the PR says so, and a fix needs its own card.

## Assumptions
- I couldn't read the #4 spec, because reading it needs `git show` on `origin/factory-log`, and this agent may not run git. So AC7 to AC9 come from the desired behaviour in issue #21.
- The view model needs a fake connector in tests. A small `HostConnecting` protocol in VIRTKit (`connect`, `disconnect`, `statusUpdates(for:)`) covers this, and `HostConnector` conforms to it unchanged.
- If `protocolVersion` is empty, the row shows "Connected".
- `VIRTApp` creates one `HostConnector` on the same `HostLibrary` and passes `scenePhase` changes to the view model.
- The manual test against `ws://127.0.0.1:48765` and `ws://gallifrey.tail537c2.ts.net:48765` happens on a Mac. The PR records the results, including whether ATS allows `ws://` to a raw IP. The token never goes in the PR, an issue, a log or a commit.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: add the `HostConnecting` protocol and make `HostConnector` conform to it.
- `VIRT/HostsViewModel.swift`: track the selected host, follow its status, build the row text and handle the scene phase.
- `VIRT/HostsView.swift`: make a tap connect, add swipe actions for Edit and Delete, and show the status line.
- `VIRT/VIRTApp.swift`: create the connector and pass `scenePhase` changes to the view model.
- `VIRTTests/HostsViewModelTests.swift`: add the fake connector and the new tests.
- `README.md`: explain how to connect.

## Test plan
- AC7 → `VIRTTests/HostsViewModelTests.swift`: selecting A, then B, makes the fake connector record connect A, disconnect A, connect B. Selecting a connected host again calls nothing. Selecting a failed host calls `connect` again.
- AC8 → `VIRTTests/HostsViewModelTests.swift`: for each status the fake sends (idle, connecting, connected "0.1.0", connected "", reconnecting 3, each failure), the row text matches exactly and never contains the token.
- AC9 → `VIRTTests/HostsViewModelTests.swift`: with a connected host, background calls `disconnect` and active calls `connect` for the same host. With a failed host, active doesn't call `connect`. An inactive change calls nothing.
- AC10 → manual review of the README.

## Size estimate
Estimate: 160 code lines
- Tapping a host connects it, disconnects any other host, and Edit moves to a swipe action
- The row shows the status text for each state
- VIRT disconnects in the background and reconnects the host that was connected when the app becomes active
- The README says how to connect
