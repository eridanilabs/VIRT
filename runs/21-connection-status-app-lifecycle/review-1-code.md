# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (convention) VIRT/HostsViewModel.swift:~96: `sceneDidChange` skips `disconnect` when the selected host has failed. AC9 says "VIRT disconnects the selected host" in the background. The builder's report calls this out, and the effect is harmless: a failed host has no registration in `HostConnector`, and a disconnect would only wipe the "Failed: …" line. `activeDoesNotReconnectAFailedHost` pins the behaviour. The README says "A failed host stays failed until you tap it", which matches. Fix: leave it. Optionally add one line to the spec or PR saying so.
- [nit] (simplicity) VIRT/HostsViewModel.swift:3: the view model imports SwiftUI only for `ScenePhase`. A plain `isBackground`/`isActive` signal from `VIRTApp` would keep the view model free of SwiftUI. Fix: optional. The current approach matches the spec's "passes `scenePhase` changes to the view model".
- [note] VIRT/VIRTApp.swift:20: the background disconnect runs in an unstructured `Task`, with no `beginBackgroundTask`. iOS may suspend the app before the disconnect finishes. The socket then drops when the system suspends it. On return, `reconnectsWhenActive` is already set, so the reconnect still happens. That is acceptable for this card.
- [note] VIRT/HostsViewModel.swift:`select`: during the short window while the previous host is being disconnected, `selectedHostID` is nil. A background event in that window would not disconnect the newly selected host. This is a negligible race, because it needs a tap and a backgrounding at the same moment.
- [note] The spec's manual checks are still open: ATS behaviour for `ws://127.0.0.1`, the live host, and the lifecycle. They are the PR author's to record. AC10 is covered by the README diff, and the wording matches the spec.

## Coverage
- Files read: AGENTS.md, the spec, build-1.md, VIRT/HostsViewModel.swift, VIRT/HostsView.swift (diff), VIRT/VIRTApp.swift (diff), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (connect, disconnect, stop, handle, publish), the HostConnectorTests diff, VIRTTests/HostsViewModelTests.swift (fake connector, `eventually` helper, new tests), the README diff.
- Flows walked:
  - Tap A then B: previous host disconnected, new host connected. The stale `connect(A)` in flight is guarded by `registrations[hostID] == id` in the connector, and by `selectedHostID == hostID` in the view model.
  - Tap a busy host: no-op.
  - Tap a failed host: retries. The connector clears the registration on failure, so `connect` proceeds.
  - Background then active, including a quick bounce: new unique registration ids make the stale `remove` harmless. The old status task is cancelled before the new one starts.
  - Going inactive only: nothing changes.
  - Failed or idle host when backgrounded: no disconnect and no reconnect.
  - First `.active` at launch: nothing happens.
  - Swipe Edit and Delete: Delete reuses the existing `delete(_:)`.
  - Status text: no token or `tkn` can appear, because the text comes only from `Failure.message` and the protocol version.
- Commands run: `./scripts/test.sh` → exit 0 (rerun to confirm). VIRTKit `swift test` ran 43 tests in 7 suites and passed. The app's `xcodebuild test` had 0 failures.
- Earlier blockers: none (round 1).
